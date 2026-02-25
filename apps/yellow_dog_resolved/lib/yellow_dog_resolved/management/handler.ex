defmodule YellowDog.Resolved.Management.Handler do
  @moduledoc """
  Command dispatch for the management WebSocket protocol.

  Handles incoming commands from the YellowDog DNS management server:
  - `cache_flush` — flush all or matching cache entries
  - `cache_stats` — return current cache statistics
  - `ping` — health check with uptime and query counts
  """

  alias YellowDog.Resolved.Cache

  require Logger

  @doc """
  Dispatch a management command and return the response message.
  Returns `nil` if no response is needed.
  """
  @spec handle_command(map()) :: map() | nil
  def handle_command(%{"type" => "cache_flush", "id" => id, "data" => data}) do
    count =
      case Map.get(data, "pattern") do
        nil ->
          stats = Cache.stats()
          Cache.flush()
          stats.entries

        pattern ->
          Cache.flush_pattern(pattern)
      end

    :telemetry.execute(
      [:yellow_dog, :resolved, :management, :command],
      %{},
      %{type: :cache_flush}
    )

    %{
      "type" => "cache_flush_result",
      "id" => id,
      "data" => %{"flushed" => count}
    }
  end

  def handle_command(%{"type" => "cache_stats", "id" => id}) do
    stats = Cache.stats()

    :telemetry.execute(
      [:yellow_dog, :resolved, :management, :command],
      %{},
      %{type: :cache_stats}
    )

    %{
      "type" => "cache_stats_result",
      "id" => id,
      "data" => %{
        "entries" => stats.entries,
        "hits" => stats.hits,
        "misses" => stats.misses,
        "evictions" => stats.evictions,
        "hit_rate" => stats.hit_rate
      }
    }
  end

  def handle_command(%{"type" => "ping", "id" => id, "data" => _data}) do
    uptime_s = div(System.monotonic_time(:millisecond), 1000)
    counts = YellowDog.Resolved.Metrics.get_query_counts()

    :telemetry.execute(
      [:yellow_dog, :resolved, :management, :command],
      %{},
      %{type: :ping}
    )

    %{
      "type" => "pong",
      "id" => id,
      "data" => %{
        "uptime_s" => uptime_s,
        "queries_total" => counts.total,
        "queries_intercepted" => counts.intercepted,
        "queries_cached" => counts.cached,
        "queries_forwarded" => counts.forwarded
      }
    }
  end

  def handle_command(unknown) do
    Logger.warning("Unknown management command: #{inspect(unknown)}")
    nil
  end

  @doc "Build the 'connected' event message sent after WebSocket connection."
  @spec build_connected_event(binary()) :: map()
  def build_connected_event(instance_id) do
    {:ok, hostname} = :inet.gethostname()

    # Try to fetch real config values, fall back to defaults
    {upstreams, rule_count, cache_max} = fetch_config_summary()

    %{
      "type" => "connected",
      "id" => "evt-#{System.unique_integer([:positive])}",
      "data" => %{
        "instance_id" => Base.encode16(instance_id, case: :lower),
        "version" => "0.1.0",
        "hostname" => to_string(hostname),
        "upstreams" => upstreams,
        "intercept_rule_count" => rule_count,
        "cache_max_entries" => cache_max
      }
    }
  end

  defp fetch_config_summary do
    config = YellowDog.Resolved.Config.get()
    upstreams = Enum.map(config.upstreams, &to_string(:inet.ntoa(&1)))
    {upstreams, length(config.intercept_rules), config.cache.max_entries}
  rescue
    _ -> {[], 0, 10_000}
  catch
    _, _ -> {[], 0, 10_000}
  end
end
