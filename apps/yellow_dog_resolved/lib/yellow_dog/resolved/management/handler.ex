defmodule YellowDog.Resolved.Management.Handler do
  @moduledoc """
  Command dispatch for management WebSocket messages.
  Handles cache_flush, cache_stats, and ping commands.
  """

  alias YellowDog.Resolved.{Cache, Counters, RateLimiter}

  require Logger

  @doc """
  Handle an incoming management command and return a response message.
  """
  @spec handle_command(map()) :: map() | nil
  def handle_command(%{"type" => "cache_flush", "id" => id, "data" => data}) do
    :telemetry.execute(
      [:yellow_dog, :resolved, :management, :command],
      %{},
      %{type: :cache_flush}
    )

    pattern = if is_map(data), do: Map.get(data, "pattern"), else: nil

    flushed =
      case pattern do
        nil ->
          Cache.flush()

        domain when is_binary(domain) ->
          if String.starts_with?(domain, "*.") do
            Cache.flush_pattern(domain)
          else
            Cache.flush(domain)
          end
      end

    %{
      "type" => "cache_flush_result",
      "id" => id,
      "data" => %{"flushed" => flushed}
    }
  end

  def handle_command(%{"type" => "cache_stats", "id" => id}) do
    :telemetry.execute(
      [:yellow_dog, :resolved, :management, :command],
      %{},
      %{type: :cache_stats}
    )

    stats = Cache.stats()

    %{
      "type" => "cache_stats_result",
      "id" => id,
      "data" => %{
        "entries" => stats.entries,
        "hits" => stats.hits,
        "misses" => stats.misses,
        "evictions" => stats.evictions,
        "hit_rate" => stats.hit_rate,
        "oldest_entry_age_s" => stats.oldest_entry_age_s
      }
    }
  end

  def handle_command(%{"type" => "ping", "id" => id, "data" => _data}) do
    :telemetry.execute(
      [:yellow_dog, :resolved, :management, :command],
      %{},
      %{type: :ping}
    )

    counters = Counters.get()

    %{
      "type" => "pong",
      "id" => id,
      "data" => %{
        "uptime_s" => uptime_seconds(),
        "queries_total" => counters.total,
        "queries_intercepted" => counters.intercepted,
        "queries_cached" => counters.cached,
        "queries_forwarded" => counters.forwarded,
        "queries_error" => counters.error,
        "queries_rate_limited" => counters.rate_limited,
        "rate_limited_tracked_ips" => RateLimiter.tracked_ips()
      }
    }
  end

  def handle_command(%{"type" => "counters_reset", "id" => id}) do
    :telemetry.execute(
      [:yellow_dog, :resolved, :management, :command],
      %{},
      %{type: :counters_reset}
    )

    old_counters = Counters.get()
    Counters.reset()

    %{
      "type" => "counters_reset_result",
      "id" => id,
      "data" => %{
        "previous_total" => old_counters.total,
        "previous_forwarded" => old_counters.forwarded,
        "previous_cached" => old_counters.cached,
        "previous_intercepted" => old_counters.intercepted,
        "previous_error" => old_counters.error,
        "previous_rate_limited" => old_counters.rate_limited
      }
    }
  end

  def handle_command(%{"type" => type}) do
    Logger.warning("[Resolved] Unknown management command: #{type}")
    nil
  end

  def handle_command(_), do: nil

  @doc """
  Build the 'connected' event sent after WebSocket handshake.
  """
  @spec connected_event(binary()) :: map()
  def connected_event(instance_id) do
    config = YellowDog.Resolved.Config.get()

    %{
      "type" => "connected",
      "id" => "evt-#{System.unique_integer([:positive])}",
      "data" => %{
        "instance_id" => Base.encode16(instance_id, case: :lower),
        "version" => "0.1.0",
        "hostname" => hostname(),
        "upstreams" => Enum.map(config.upstreams, &to_string(:inet.ntoa(&1))),
        "intercept_rule_count" => length(config.intercept_rules),
        "cache_max_entries" => get_in(config, [:cache, :max_entries]) || 10_000
      }
    }
  end

  # Private

  defp uptime_seconds do
    System.monotonic_time(:second) - Counters.started_at()
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      {:error, _} -> "unknown"
    end
  end
end
