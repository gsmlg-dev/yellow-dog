defmodule YellowDog.Resolved.Config do
  @moduledoc """
  Configuration server for yellow_dog_resolved.
  Loads TOML config and watches for changes.
  """
  use GenServer

  require Logger

  @default_config %{
    listen: {127, 0, 0, 1},
    port: 53,
    upstreams: [{1, 1, 1, 1}, {8, 8, 8, 8}],
    upstream_timeout_ms: 3000,
    upstream_failure_threshold: 3,
    cache: %{
      enabled: true,
      max_entries: 10_000,
      min_ttl_s: 30,
      max_ttl_s: 86_400,
      negative_ttl_s: 60,
      sweep_interval_s: 60
    },
    discovery: %{
      enabled: true,
      websocket: %{
        heartbeat_interval_s: 30,
        reconnect_base_s: 5,
        reconnect_max_s: 60
      }
    },
    intercept_rules: []
  }

  @config_paths [
    "config/resolved.toml",
    "/etc/yellowdog/resolved.toml"
  ]

  # Client API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec get() :: map()
  def get do
    GenServer.call(__MODULE__, :get)
  end

  @spec get(atom()) :: term()
  def get(key) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc """
  Loads config from TOML file or returns defaults.
  Called before supervisor starts.
  """
  @spec load() :: map()
  def load do
    config_path = find_config_file()

    case config_path do
      nil ->
        Logger.info("[Resolved] No config file found, using defaults")
        @default_config

      path ->
        Logger.info("[Resolved] Loading config from #{path}")
        load_from_file(path)
    end
  end

  # Server callbacks

  @impl true
  def init(config) do
    config_path = find_config_file()

    state = %{
      config: config,
      config_path: config_path,
      watcher_pid: nil
    }

    state = maybe_start_watcher(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state.config, key), state}
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    if path == state.config_path do
      Logger.info("[Resolved] Config file changed, reloading")

      case load_from_file(path) do
        config when is_map(config) ->
          {:noreply, %{state | config: config}}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  defp find_config_file do
    Enum.find(@config_paths, &File.exists?/1)
  end

  defp load_from_file(path) do
    case Toml.decode_file(path) do
      {:ok, toml} ->
        parse_toml(toml)

      {:error, reason} ->
        Logger.warning("[Resolved] Failed to parse config: #{inspect(reason)}")
        @default_config
    end
  end

  defp parse_toml(toml) do
    resolved = Map.get(toml, "resolved", %{})

    %{
      listen: parse_ip(Map.get(resolved, "listen", "127.0.0.1")),
      port: Map.get(resolved, "port", 53),
      upstreams: parse_upstreams(Map.get(resolved, "upstreams", ["1.1.1.1", "8.8.8.8"])),
      upstream_timeout_ms: Map.get(resolved, "upstream_timeout_ms", 3000),
      upstream_failure_threshold: Map.get(resolved, "upstream_failure_threshold", 3),
      cache: parse_cache_config(Map.get(resolved, "cache", %{})),
      discovery: parse_discovery_config(Map.get(resolved, "discovery", %{})),
      intercept_rules: parse_intercept_rules(Map.get(resolved, "intercept", []))
    }
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

  defp parse_intercept_rules(rules) when is_list(rules) do
    Enum.map(rules, &parse_rule/1)
  end

  defp parse_intercept_rules(_), do: []

  defp parse_rule(rule) do
    match_str = Map.get(rule, "match", "")
    type_str = Map.get(rule, "type", "A")
    value = Map.get(rule, "value", "")
    ttl = Map.get(rule, "ttl", 300)

    %{
      match: parse_match_pattern(match_str),
      type: parse_record_type(type_str),
      value: value,
      ttl: ttl
    }
  end

  defp parse_match_pattern("*." <> suffix), do: {:suffix, suffix}

  defp parse_match_pattern(pattern) do
    if String.ends_with?(pattern, "*") do
      {:prefix, String.trim_trailing(pattern, "*")}
    else
      {:exact, pattern}
    end
  end

  defp parse_record_type("A"), do: :a
  defp parse_record_type("AAAA"), do: :aaaa
  defp parse_record_type("CNAME"), do: :cname
  defp parse_record_type("TXT"), do: :txt
  defp parse_record_type("MX"), do: :mx
  defp parse_record_type("SRV"), do: :srv
  defp parse_record_type(_), do: :a

  defp parse_ip(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> ip
      _ -> {127, 0, 0, 1}
    end
  end

  defp parse_ip(ip) when is_tuple(ip), do: ip
  defp parse_ip(_), do: {127, 0, 0, 1}

  defp parse_upstreams(upstreams) when is_list(upstreams) do
    Enum.map(upstreams, &parse_ip/1)
  end

  defp parse_upstreams(_), do: [{1, 1, 1, 1}, {8, 8, 8, 8}]

  defp maybe_start_watcher(%{config_path: nil} = state), do: state

  defp maybe_start_watcher(%{config_path: path} = state) do
    dir = Path.dirname(path)

    case FileSystem.start_link(dirs: [dir]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        %{state | watcher_pid: pid}

      {:error, _} ->
        state
    end
  end
end
