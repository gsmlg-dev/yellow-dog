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
        "queries_total" => 0,
        "queries_intercepted" => 0,
        "queries_cached" => 0,
        "queries_forwarded" => 0
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

    %{
      "type" => "connected",
      "id" => "evt-#{System.unique_integer([:positive])}",
      "data" => %{
        "instance_id" => Base.encode16(instance_id, case: :lower),
        "version" => "0.1.0",
        "hostname" => to_string(hostname),
        "upstreams" => [],
        "intercept_rule_count" => 0,
        "cache_max_entries" => 10_000
      }
    }
  end
end
