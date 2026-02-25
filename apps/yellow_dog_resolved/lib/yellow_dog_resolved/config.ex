defmodule YellowDog.Resolved.Config do
  @moduledoc """
  TOML configuration loader and watcher for the resolved DNS stub resolver.

  Loads configuration from a TOML file and watches for changes to enable
  hot-reload of settings like intercept rules and upstream servers.
  """

  use GenServer

  require Logger

  @default_config_path "config/resolved.toml"

  @type intercept_rule :: %{
          match: {:exact, String.t()} | {:suffix, String.t()} | {:prefix, String.t()},
          type: atom(),
          value: String.t(),
          ttl: pos_integer()
        }

  @type cache_config :: %{
          enabled: boolean(),
          max_entries: pos_integer(),
          min_ttl_s: non_neg_integer(),
          max_ttl_s: pos_integer(),
          negative_ttl_s: non_neg_integer(),
          sweep_interval_s: pos_integer()
        }

  @type discovery_config :: %{
          enabled: boolean(),
          websocket: %{
            heartbeat_interval_s: pos_integer(),
            reconnect_base_s: pos_integer(),
            reconnect_max_s: pos_integer()
          }
        }

  @type t :: %{
          listen: :inet.ip_address(),
          port: :inet.port_number(),
          upstreams: [:inet.ip_address()],
          upstream_timeout_ms: pos_integer(),
          upstream_failure_threshold: pos_integer(),
          intercept_rules: [intercept_rule()],
          cache: cache_config(),
          discovery: discovery_config(),
          config_path: String.t()
        }

  # Client API

  @doc "Start the config GenServer with an already-parsed config map."
  @spec start_link(t()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Get the full configuration map."
  @spec get() :: t()
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @doc "Get the list of intercept rules."
  @spec get_intercept_rules() :: [intercept_rule()]
  def get_intercept_rules do
    GenServer.call(__MODULE__, :get_intercept_rules)
  end

  @doc "Get the list of upstream DNS server IPs."
  @spec get_upstreams() :: [:inet.ip_address()]
  def get_upstreams do
    GenServer.call(__MODULE__, :get_upstreams)
  end

  @doc """
  Load and parse a TOML config file into a structured config map.
  Can be called without starting the GenServer (used by Supervisor).
  """
  @spec load() :: t()
  def load do
    load(config_path())
  end

  @spec load(String.t()) :: t()
  def load(path) do
    case Toml.decode_file(path) do
      {:ok, toml} -> parse_config(toml, path)
      {:error, reason} -> raise "Failed to load config #{path}: #{inspect(reason)}"
    end
  end

  # GenServer callbacks

  @impl true
  def init(config) do
    state = %{config: config, watcher_pid: nil}
    state = maybe_start_watcher(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.config, state}
  end

  @impl true
  def handle_call(:get_intercept_rules, _from, state) do
    {:reply, state.config.intercept_rules, state}
  end

  @impl true
  def handle_call(:get_upstreams, _from, state) do
    {:reply, state.config.upstreams, state}
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    if String.ends_with?(path, ".toml") do
      Logger.info("Config file changed, reloading: #{path}")

      case reload_config(state.config.config_path) do
        {:ok, new_config} ->
          :telemetry.execute(
            [:yellow_dog, :resolved, :config, :reload],
            %{},
            %{path: path}
          )

          {:noreply, %{state | config: new_config}}

        {:error, reason} ->
          Logger.warning("Failed to reload config: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp config_path do
    Application.get_env(:yellow_dog_resolved, :config_path, default_config_path())
  end

  defp default_config_path do
    # Try app_dir first (release/prod)
    try do
      app_dir = Application.app_dir(:yellow_dog_resolved)
      path = Path.join(app_dir, @default_config_path)

      if File.exists?(path) do
        path
      else
        fallback_config_path()
      end
    rescue
      _ -> fallback_config_path()
    end
  end

  defp fallback_config_path do
    cwd = File.cwd!()

    # If cwd is already inside the app directory
    app_path = Path.join(cwd, @default_config_path)

    if File.exists?(app_path) do
      app_path
    else
      # Try from umbrella root
      Path.join([cwd, "apps", "yellow_dog_resolved", @default_config_path])
    end
  end

  defp reload_config(path) do
    case Toml.decode_file(path) do
      {:ok, toml} -> {:ok, parse_config(toml, path)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_start_watcher(state) do
    dir = Path.dirname(state.config.config_path)

    case FileSystem.start_link(dirs: [dir]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        %{state | watcher_pid: pid}

      {:error, _reason} ->
        state
    end
  end

  @spec parse_config(map(), String.t()) :: t()
  defp parse_config(toml, path) do
    resolved = Map.get(toml, "resolved", %{})

    %{
      listen: parse_ip(Map.get(resolved, "listen", "127.0.0.1")),
      port: Map.get(resolved, "port", 53),
      upstreams: parse_upstreams(Map.get(resolved, "upstreams", ["1.1.1.1", "8.8.8.8"])),
      upstream_timeout_ms: Map.get(resolved, "upstream_timeout_ms", 3000),
      upstream_failure_threshold: Map.get(resolved, "upstream_failure_threshold", 3),
      intercept_rules: parse_intercept_rules(Map.get(resolved, "intercept", [])),
      cache: parse_cache_config(Map.get(resolved, "cache", %{})),
      discovery: parse_discovery_config(Map.get(resolved, "discovery", %{})),
      config_path: path
    }
  end

  defp parse_ip(ip_string) when is_binary(ip_string) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(ip_string))
    ip
  end

  defp parse_upstreams(list) when is_list(list) do
    Enum.map(list, &parse_ip/1)
  end

  defp parse_intercept_rules(rules) when is_list(rules) do
    Enum.map(rules, &parse_intercept_rule/1)
  end

  defp parse_intercept_rule(rule) do
    %{
      match: parse_match_pattern(Map.fetch!(rule, "match")),
      type: parse_record_type(Map.fetch!(rule, "type")),
      value: Map.fetch!(rule, "value"),
      ttl: Map.get(rule, "ttl", 300)
    }
  end

  @spec parse_match_pattern(String.t()) :: {:exact | :suffix | :prefix, String.t()}
  defp parse_match_pattern("*." <> rest), do: {:suffix, String.downcase(rest)}

  defp parse_match_pattern(pattern) when is_binary(pattern) do
    if String.ends_with?(pattern, "*") do
      {:prefix, String.downcase(String.trim_trailing(pattern, "*"))}
    else
      {:exact, String.downcase(pattern)}
    end
  end

  @valid_types ~w(A AAAA CNAME TXT MX SRV)
  defp parse_record_type(type) when type in @valid_types do
    type |> String.downcase() |> String.to_atom()
  end

  defp parse_cache_config(cache) do
    %{
      enabled: Map.get(cache, "enabled", true),
      max_entries: Map.get(cache, "max_entries", 10_000),
      min_ttl_s: Map.get(cache, "min_ttl_s", 30),
      max_ttl_s: Map.get(cache, "max_ttl_s", 86_400),
      negative_ttl_s: Map.get(cache, "negative_ttl_s", 60),
      sweep_interval_s: Map.get(cache, "sweep_interval_s", 60)
    }
  end

  defp parse_discovery_config(discovery) do
    ws = Map.get(discovery, "websocket", %{})

    %{
      enabled: Map.get(discovery, "enabled", true),
      websocket: %{
        heartbeat_interval_s: Map.get(ws, "heartbeat_interval_s", 30),
        reconnect_base_s: Map.get(ws, "reconnect_base_s", 5),
        reconnect_max_s: Map.get(ws, "reconnect_max_s", 60)
      }
    }
  end
end
