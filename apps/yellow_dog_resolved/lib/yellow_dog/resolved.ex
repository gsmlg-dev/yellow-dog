defmodule YellowDog.Resolved do
  @moduledoc """
  DNS stub resolver: intercept rules, cache, upstream forwarding, EDNS discovery.
  """

  alias YellowDog.Resolved.{Cache, Config, Counters, Forwarder, LinkDns, QueryLogger, RateLimiter}

  @doc """
  Set per-link DNS configuration for a network interface.

  Called by YellowDog.Netman when a connection becomes activated.
  Higher-priority links' DNS servers are prepended to the upstream list.

  ## Parameters

    * `interface` - Network interface name (e.g., "eth0")
    * `config` - Map with `:servers` (IP tuples), `:search` (domain strings),
      and `:priority` (integer)
  """
  @spec set_link_dns(String.t(), map()) :: :ok
  def set_link_dns(interface, config) do
    LinkDns.set_link_dns(interface, config)
  end

  @doc """
  Remove per-link DNS configuration for a network interface.

  Called by YellowDog.Netman when a connection is deactivated.
  """
  @spec reset_link_dns(String.t()) :: :ok
  def reset_link_dns(interface) do
    LinkDns.reset_link_dns(interface)
  end

  @doc "Returns recent query log entries (newest first)."
  @spec recent_queries(non_neg_integer()) :: [map()]
  def recent_queries(limit \\ 50) do
    QueryLogger.recent(limit)
  end

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
