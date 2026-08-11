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

  @doc "Returns managed and active per-link DNS upstreams."
  @spec upstreams() :: [%{address: :inet.ip_address(), source: :managed | :static}]
  def upstreams do
    managed = Enum.map(Config.get(:upstreams) || [], &%{address: &1, source: :managed})

    per_link =
      LinkDns.list_all()
      |> Enum.sort_by(fn {interface, config} -> {-(config.priority || 0), interface} end)
      |> Enum.flat_map(fn {_interface, config} ->
        Enum.map(config.servers || [], &%{address: &1, source: :static})
      end)

    Enum.uniq_by(managed ++ per_link, & &1.address)
  end

  @doc "Returns effective managed and per-link DNS search domains."
  @spec search_domains() :: [%{domain: String.t(), routing_only: boolean()}]
  def search_domains do
    (LinkDns.effective_search_domains() ++ (Config.get(:search_domains) || []))
    |> Enum.uniq()
    |> Enum.map(&%{domain: &1, routing_only: false})
  end

  @doc "Returns address-bearing, unexpired cache entries."
  @spec cache_entries() :: [map()]
  def cache_entries, do: Cache.entries()

  @doc false
  @spec cache_revision_material() :: [map()]
  def cache_revision_material, do: Cache.revision_material()

  @doc "Returns cache hit and miss counters."
  @spec cache_counters() :: %{hits: non_neg_integer(), misses: non_neg_integer()}
  def cache_counters do
    stats = Cache.stats()
    %{hits: stats.hits, misses: stats.misses}
  end

  @doc "Flushes every resolver cache entry and returns the number removed."
  @spec flush_cache() :: non_neg_integer()
  def flush_cache, do: Cache.flush()

  @doc "Returns the canonical revision of the managed resolver configuration."
  @spec config_revision() :: {:ok, String.t()} | {:error, term()}
  def config_revision, do: Config.revision()

  @doc "Atomically applies managed upstream and search-domain configuration."
  @spec update_config(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_config(config, opts \\ []) do
    with {:ok, managed} <- normalize_managed_config(config) do
      Config.update_managed(managed, opts)
    end
  end

  @doc "Restores a retained managed resolver configuration revision."
  @spec rollback_config(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def rollback_config(target_revision, opts \\ []) do
    Config.rollback_managed(target_revision, opts)
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

  defp normalize_managed_config(config) when is_map(config) do
    with true <- Enum.sort(Map.keys(config)) == ["search_domains", "upstreams"],
         {:ok, upstreams} <- parse_ip_list(config["upstreams"]),
         {:ok, domains} <- parse_domain_list(config["search_domains"]) do
      {:ok, %{upstreams: Enum.uniq(upstreams), search_domains: Enum.uniq(domains)}}
    else
      _ -> {:error, :invalid_config}
    end
  end

  defp normalize_managed_config(_config), do: {:error, :invalid_config}

  defp parse_ip_list(values) when is_list(values) do
    reduce_values(values, fn
      value when is_binary(value) ->
        case :inet.parse_address(String.to_charlist(value)) do
          {:ok, address} -> {:ok, address}
          _error -> :error
        end

      _value ->
        :error
    end)
  end

  defp parse_ip_list(_values), do: :error

  defp parse_domain_list(values) when is_list(values) do
    reduce_values(values, fn
      value when is_binary(value) -> normalize_search_domain(value)
      _value -> :error
    end)
  end

  defp parse_domain_list(_values), do: :error

  defp reduce_values(values, parser) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, parsed} ->
      case parser.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | parsed]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      :error -> :error
    end
  end

  defp normalize_search_domain(value) do
    normalized = value |> String.downcase() |> String.trim_trailing(".")
    labels = String.split(normalized, ".")

    if byte_size(normalized) in 1..253 and
         Enum.all?(labels, &valid_domain_label?/1) do
      {:ok, normalized}
    else
      :error
    end
  end

  defp valid_domain_label?(label) do
    byte_size(label) in 1..63 and
      Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, label)
  end
end
