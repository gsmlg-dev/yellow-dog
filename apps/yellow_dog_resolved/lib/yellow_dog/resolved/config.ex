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
    rate_limit: %{
      burst: 50,
      rate: 20
    },
    intercept_rules: []
  }

  @persistent_term_key {__MODULE__, :config}

  @doc false
  @spec parse_toml_for_test(map()) :: map()
  def parse_toml_for_test(toml), do: parse_toml(toml)

  @config_paths [
    "config/resolved.toml",
    "/etc/yellowdog/resolved.toml"
  ]

  # Client API

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec get() :: map()
  def get do
    :persistent_term.get(@persistent_term_key)
  end

  @spec get(atom()) :: term()
  def get(key) do
    Map.get(:persistent_term.get(@persistent_term_key), key)
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
    :persistent_term.put(@persistent_term_key, config)
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
  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    if path == state.config_path do
      Logger.info("[Resolved] Config file changed, reloading")

      case load_from_file(path) do
        config when is_map(config) ->
          :persistent_term.put(@persistent_term_key, config)
          propagate_config(config, state.config)
          {:noreply, %{state | config: config}}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    :persistent_term.erase(@persistent_term_key)
    :ok
  end

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
      port: clamp_int(Map.get(resolved, "port", 53), 1, 65_535),
      upstreams: parse_upstreams(Map.get(resolved, "upstreams", ["1.1.1.1", "8.8.8.8"])),
      upstream_timeout_ms: clamp_int(Map.get(resolved, "upstream_timeout_ms", 3000), 100, 30_000),
      upstream_failure_threshold:
        clamp_int(Map.get(resolved, "upstream_failure_threshold", 3), 1, 100),
      cache: parse_cache_config(Map.get(resolved, "cache", %{})),
      discovery: parse_discovery_config(Map.get(resolved, "discovery", %{})),
      rate_limit: parse_rate_limit_config(Map.get(resolved, "rate_limit", %{})),
      intercept_rules: parse_intercept_rules(Map.get(resolved, "intercept", []))
    }
  end

  defp parse_cache_config(cache) do
    min_ttl = clamp_int(Map.get(cache, "min_ttl_s", 30), 0, 86_400)
    max_ttl = clamp_int(Map.get(cache, "max_ttl_s", 86_400), 1, 604_800)

    if min_ttl > max_ttl do
      Logger.warning(
        "[Resolved] Cache min_ttl_s (#{min_ttl}) exceeds max_ttl_s (#{max_ttl}); clamping min_ttl_s to #{max_ttl}"
      )
    end

    %{
      enabled: Map.get(cache, "enabled", true),
      max_entries: clamp_int(Map.get(cache, "max_entries", 10_000), 1, 1_000_000),
      min_ttl_s: min(min_ttl, max_ttl),
      max_ttl_s: max_ttl,
      negative_ttl_s: clamp_int(Map.get(cache, "negative_ttl_s", 60), 0, 86_400),
      sweep_interval_s: clamp_int(Map.get(cache, "sweep_interval_s", 60), 1, 86_400)
    }
  end

  defp parse_discovery_config(discovery) do
    ws = Map.get(discovery, "websocket", %{})

    %{
      enabled: Map.get(discovery, "enabled", true),
      websocket: %{
        heartbeat_interval_s: clamp_int(Map.get(ws, "heartbeat_interval_s", 30), 5, 300),
        reconnect_base_s: clamp_int(Map.get(ws, "reconnect_base_s", 5), 1, 60),
        reconnect_max_s: clamp_int(Map.get(ws, "reconnect_max_s", 60), 5, 600)
      }
    }
  end

  defp parse_rate_limit_config(rl) do
    burst = clamp_int(Map.get(rl, "burst", 50), 1, 10_000)
    rate = clamp_int(Map.get(rl, "rate", 20), 1, 10_000)

    if burst < rate do
      Logger.warning(
        "[Resolved] Rate limiter burst (#{burst}) < rate (#{rate}); clamping burst to #{rate}"
      )
    end

    %{
      burst: max(burst, rate),
      rate: rate
    }
  end

  defp parse_intercept_rules(rules) when is_list(rules) do
    rules
    |> Enum.map(&parse_rule/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_intercept_rules(_), do: []

  defp parse_rule(rule) do
    match_str = Map.get(rule, "match", "")
    type_str = Map.get(rule, "type", "A")
    value = Map.get(rule, "value", "")
    ttl = clamp_int(Map.get(rule, "ttl", 300), 1, 604_800)
    type = parse_record_type(type_str)

    case validate_rule_value(type, value) do
      :ok ->
        %{
          match: parse_match_pattern(match_str),
          type: type,
          value: value,
          ttl: ttl
        }

      :error ->
        Logger.warning(
          "[Resolved] Skipping invalid intercept rule: type=#{type_str} value=#{inspect(value)} match=#{inspect(match_str)}"
        )

        nil
    end
  end

  defp validate_rule_value(:a, value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, {_, _, _, _}} -> :ok
      _ -> :error
    end
  end

  defp validate_rule_value(:aaaa, value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, {_, _, _, _, _, _, _, _}} -> :ok
      _ -> :error
    end
  end

  defp validate_rule_value(:mx, value) do
    case String.split(value, " ", parts: 2) do
      [priority_str, _exchange] ->
        case Integer.parse(priority_str) do
          {_, ""} -> :ok
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp validate_rule_value(:srv, value) do
    case String.split(value, " ", parts: 4) do
      [pri_s, weight_s, port_s, _target] ->
        with {_, ""} <- Integer.parse(pri_s),
             {_, ""} <- Integer.parse(weight_s),
             {_, ""} <- Integer.parse(port_s) do
          :ok
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp validate_rule_value(:unknown, _value), do: :error
  defp validate_rule_value(_type, _value), do: :ok

  defp parse_match_pattern("*." <> suffix),
    do: {:suffix, suffix |> String.downcase() |> String.trim_trailing(".")}

  defp parse_match_pattern(pattern) do
    if String.ends_with?(pattern, "*") do
      {:prefix, String.downcase(String.trim_trailing(pattern, "*"))}
    else
      {:exact, pattern |> String.downcase() |> String.trim_trailing(".")}
    end
  end

  defp parse_record_type("A"), do: :a
  defp parse_record_type("AAAA"), do: :aaaa
  defp parse_record_type("CNAME"), do: :cname
  defp parse_record_type("TXT"), do: :txt
  defp parse_record_type("MX"), do: :mx
  defp parse_record_type("SRV"), do: :srv
  defp parse_record_type("NS"), do: :ns
  defp parse_record_type("PTR"), do: :ptr
  defp parse_record_type(_), do: :unknown

  defp clamp_int(val, min_val, max_val) when is_integer(val) do
    val |> max(min_val) |> min(max_val)
  end

  defp clamp_int(val, min_val, max_val) when is_float(val) do
    rounded = round(val)

    Logger.warning(
      "[Resolved] Config value #{val} is a float; expected integer. Rounding to #{rounded}"
    )

    clamp_int(rounded, min_val, max_val)
  end

  defp clamp_int(_val, min_val, _max_val), do: min_val

  defp parse_ip(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip} -> ip
      _ -> {127, 0, 0, 1}
    end
  end

  defp parse_ip(ip) when is_tuple(ip), do: ip
  defp parse_ip(_), do: {127, 0, 0, 1}

  defp parse_upstreams(upstreams) when is_list(upstreams) do
    upstreams
    |> Enum.reduce([], fn upstream, acc ->
      case parse_upstream_ip(upstream) do
        {:ok, ip} ->
          [ip | acc]

        :error ->
          Logger.warning("[Resolved] Skipping invalid upstream address: #{inspect(upstream)}")
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp parse_upstreams(_), do: [{1, 1, 1, 1}, {8, 8, 8, 8}]

  # Returns {:ok, ip_tuple} or :error — used for upstream list validation so that
  # invalid entries are skipped (with a warning) rather than silently replaced with
  # the loopback address, which could cause DNS query loops.
  defp parse_upstream_ip(ip) when is_tuple(ip), do: {:ok, ip}

  defp parse_upstream_ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, ip_tuple} -> {:ok, ip_tuple}
      _ -> :error
    end
  end

  defp parse_upstream_ip(_), do: :error

  defp propagate_config(new_config, old_config) do
    # Note: Discovery is not explicitly notified here because it reads
    # Config.get(:upstreams) fresh on each :probe cycle, so upstream
    # changes are picked up automatically on the next probe interval.

    # Notify Forwarder if upstream settings changed
    if new_config.upstreams != old_config.upstreams or
         new_config.upstream_timeout_ms != old_config.upstream_timeout_ms or
         new_config.upstream_failure_threshold != old_config.upstream_failure_threshold do
      if Process.whereis(YellowDog.Resolved.Forwarder) do
        GenServer.cast(YellowDog.Resolved.Forwarder, {:update_config, new_config})
      end
    end

    # Notify Cache if cache settings changed
    if new_config.cache != old_config.cache do
      if Process.whereis(YellowDog.Resolved.Cache) do
        GenServer.cast(YellowDog.Resolved.Cache, {:update_config, new_config.cache})
      end
    end

    # Notify RateLimiter if rate_limit settings changed
    if new_config.rate_limit != old_config.rate_limit do
      if Process.whereis(YellowDog.Resolved.RateLimiter) do
        GenServer.cast(YellowDog.Resolved.RateLimiter, {:update_config, new_config})
      end
    end
  end

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
