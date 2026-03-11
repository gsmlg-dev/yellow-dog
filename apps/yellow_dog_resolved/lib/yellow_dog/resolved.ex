defmodule YellowDog.Resolved do
  @moduledoc """
  DNS stub resolver: intercept rules, cache, upstream forwarding, EDNS discovery.
  """

  alias YellowDog.Resolved.{Cache, Config, Counters, Forwarder, RateLimiter}

  @doc """
  Returns a diagnostic snapshot of the resolver's current state.
  Useful for console integration and remote monitoring.
  """
  @spec status() :: map()
  def status do
    config = Config.get()
    counters = Counters.get()
    cache_stats = Cache.stats()

    %{
      config: %{
        listen: config.listen,
        port: config.port,
        upstreams: config.upstreams,
        cache_enabled: get_in(config, [:cache, :enabled]),
        discovery_enabled: get_in(config, [:discovery, :enabled]),
        intercept_rule_count: length(config.intercept_rules)
      },
      counters: counters,
      cache: cache_stats,
      upstream_latencies: Forwarder.upstream_latencies(),
      rate_limiter: %{
        tracked_ips: RateLimiter.tracked_ips()
      }
    }
  end
end
