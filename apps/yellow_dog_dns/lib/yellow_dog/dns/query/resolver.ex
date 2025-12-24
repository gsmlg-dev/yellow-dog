defmodule YellowDog.Dns.Query.Resolver do
  @moduledoc """
  Authoritative DNS query resolver.

  Resolves DNS queries from loaded zones stored in Zone.Storage.
  Supports:
  - All standard record types (A, AAAA, NS, SOA, MX, TXT, CNAME, etc.)
  - CNAME chain resolution
  - SOA for NXDOMAIN responses
  - Authority section population

  ## Examples

      iex> Resolver.resolve("example.com", "www", :A)
      {:ok, [%Record{...}], []}

      iex> Resolver.resolve("example.com", "nonexistent", :A)
      {:nxdomain, [], [%SOA{...}]}
  """

  alias YellowDog.Dns.Zone
  alias YellowDog.Dns.Zone.Storage
  alias YellowDog.Dns.Query.Forwarder
  alias YellowDog.Dns.Query.Recursive
  alias YellowDog.Dns.Query.Delegation
  alias YellowDog.Dns.Query.Cache.Manager, as: CacheManager

  @type resolve_result ::
          {:ok, [Zone.Record.t()], [Zone.Record.t()]}
          | {:nxdomain, [], [Zone.SOA.t()]}
          | {:nodata, [], [Zone.SOA.t()]}
          | {:delegation, [Zone.Record.t()], [Zone.Record.t()]}
          | {:rpz_block, atom(), []}
          | {:rpz_rewrite, [Zone.Record.t()], []}
          | {:servfail, [], []}

  @doc """
  Resolves a DNS query with RPZ policy checking.

  Checks RPZ policies before performing normal resolution.

  ## Parameters
  - `zone_name` - The zone to query (e.g., "example.com")
  - `owner` - The record owner/name (e.g., "www", "@")
  - `qtype` - The query type atom (e.g., :A, :AAAA, :MX)
  - `client_ip` - Client IP address for RPZ checking
  - `opts` - Options:
    - `:skip_rpz` - Skip RPZ checking (default: false)

  ## Returns
  Same as `resolve/3` with additional RPZ results

  ## Examples

      iex> Resolver.resolve_with_rpz("example.com", "malware.example.com.", :A, {192, 0, 2, 1})
      {:rpz_block, :nxdomain, []}
  """
  @spec resolve_with_rpz(String.t(), String.t(), atom(), tuple(), keyword()) :: resolve_result()
  def resolve_with_rpz(zone_name, owner, qtype, client_ip, opts \\ []) do
    skip_rpz = Keyword.get(opts, :skip_rpz, false)

    if skip_rpz do
      resolve(zone_name, owner, qtype)
    else
      # Check RPZ policies first
      case check_rpz_policy(owner, qtype, client_ip) do
        :passthru ->
          # No RPZ match, proceed with normal resolution
          resolve(zone_name, owner, qtype)

        {:passthru, _} ->
          # Explicit passthru
          resolve(zone_name, owner, qtype)

        {:block, action, _} ->
          # RPZ block
          {:rpz_block, action, []}

        {:rewrite, records, _} ->
          # RPZ rewrite with local data
          {:rpz_rewrite, records, []}
      end
    end
  end

  @doc """
  Resolves a DNS query for a specific zone, owner, and record type.

  ## Parameters
  - `zone_name` - The zone to query (e.g., "example.com")
  - `owner` - The record owner/name (e.g., "www", "@")
  - `qtype` - The query type atom (e.g., :A, :AAAA, :MX)

  ## Returns
  - `{:ok, answers, authority}` - Successful resolution
  - `{:nxdomain, [], authority}` - Name does not exist
  - `{:nodata, [], authority}` - Name exists but no records of requested type
  - `{:servfail, [], []}` - Server failure

  ## Examples

      iex> Resolver.resolve("example.com", "www.example.com.", :A)
      {:ok, [%Record{owner: "www.example.com.", type: :A, rdata: {192, 168, 1, 100}}], []}

      iex> Resolver.resolve("example.com", "nonexistent", :A)
      {:nxdomain, [], [%SOA{...}]}
  """
  @spec resolve(String.t(), String.t(), atom()) :: resolve_result()
  def resolve(zone_name, owner, qtype) do
    # Emit telemetry event for query
    :telemetry.execute([:yellow_dog, :dns, :query, :start], %{}, %{
      zone: zone_name,
      owner: owner,
      type: qtype
    })

    result = do_resolve(zone_name, owner, qtype)

    # Emit telemetry event for result
    :telemetry.execute([:yellow_dog, :dns, :query, :complete], %{}, %{
      zone: zone_name,
      owner: owner,
      type: qtype,
      result: elem(result, 0)
    })

    result
  end

  @doc """
  Resolves a query with caching support.

  Checks the cache first, and if not found or expired, performs resolution
  and caches the result. Uses the same resolution logic as `resolve/3` but
  with caching layer.

  ## Parameters
  - `zone_name` - The zone to query (e.g., "example.com")
  - `owner` - The record owner/name (e.g., "www", "@")
  - `qtype` - The query type atom (e.g., :A, :AAAA, :MX)
  - `opts` - Options:
    - `:cache` - Enable/disable cache for this query (default: true)
    - `:query_class` - Query class (default: :IN)

  ## Returns
  Same as `resolve/3`

  ## Examples

      iex> Resolver.resolve_cached("example.com", "www.example.com.", :A)
      {:ok, [%Record{...}], []}
  """
  @spec resolve_cached(String.t(), String.t(), atom(), keyword()) :: resolve_result()
  def resolve_cached(zone_name, owner, qtype, opts \\ []) do
    use_cache = Keyword.get(opts, :cache, true)
    query_class = Keyword.get(opts, :query_class, :IN)

    if use_cache and cache_enabled?() do
      # Try cache first
      case CacheManager.get(owner, qtype, query_class) do
        {:ok, records, authority} ->
          # Cache hit
          {:ok, records, authority}

        {:error, :not_found} ->
          # Cache miss, perform resolution
          result = resolve(zone_name, owner, qtype)

          # Cache the result
          cache_result(owner, qtype, query_class, result)

          result

        {:error, :disabled} ->
          # Cache disabled, fall back to regular resolution
          resolve(zone_name, owner, qtype)
      end
    else
      # Cache not enabled, use regular resolution
      resolve(zone_name, owner, qtype)
    end
  end

  @doc """
  Resolves a query with CNAME chain following.

  Follows CNAME records up to a maximum depth to prevent loops.

  ## Parameters
  - `zone_name` - The zone to query
  - `owner` - The record owner/name
  - `qtype` - The query type atom
  - `opts` - Options (max_depth: integer)

  ## Returns
  Same as `resolve/3` but with CNAME chain resolved
  """
  @spec resolve_with_cname(String.t(), String.t(), atom(), keyword()) :: resolve_result()
  def resolve_with_cname(zone_name, owner, qtype, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 10)
    do_resolve_with_cname(zone_name, owner, qtype, max_depth, [])
  end

  # Private functions

  defp check_rpz_policy(qname, qtype, client_ip) do
    # Check if RPZ Manager is available
    case Process.whereis(YellowDog.Dns.RPZ.Manager) do
      nil ->
        :passthru

      _pid ->
        try do
          YellowDog.Dns.RPZ.Manager.check_policy(qname, qtype, client_ip)
        rescue
          _ -> :passthru
        catch
          :exit, _ -> :passthru
        end
    end
  end

  defp do_resolve(zone_name, owner, qtype) do
    # Check if zone exists
    unless Storage.zone_exists?(zone_name) do
      :telemetry.execute(
        [:yellow_dog, :dns, :query, :error],
        %{count: 1},
        %{source: __MODULE__, zone: zone_name, reason: :zone_not_found, severity: :debug}
      )
      {:servfail, [], []}
    else
      # Check zone type - forward and hint zones use different resolution
      case Storage.get_zone_metadata(zone_name) do
        {:ok, %{type: :forward} = metadata} ->
          # This is a forward zone
          resolve_forward(zone_name, owner, qtype, metadata)

        {:ok, %{type: :hint} = metadata} ->
          # This is a hint/recursive zone - perform recursive resolution
          resolve_recursive(owner, qtype, metadata)

        {:ok, _metadata} ->
          # This is an authoritative zone (master, slave, etc.)
          resolve_authoritative(zone_name, owner, qtype)

        {:error, _} ->
          {:servfail, [], []}
      end
    end
  end

  defp resolve_authoritative(zone_name, owner, qtype) do
    # Normalize owner name
    normalized_owner = normalize_owner(owner, zone_name)

    # Check for delegation first (before looking up records)
    case Delegation.check_delegation(zone_name, normalized_owner, qtype) do
      {:delegated, _delegation_point, ns_records, glue_records} ->
        # This query is for a delegated sub-zone
        # Return referral with NS records in authority and glue in additional
        :telemetry.execute(
          [:yellow_dog, :dns, :query, :referral],
          %{count: 1, ns_count: length(ns_records)},
          %{source: __MODULE__, query_name: normalized_owner, zone: zone_name}
        )
        {:delegation, ns_records, glue_records}

      :not_delegated ->
        # No delegation, proceed with normal authoritative resolution
        resolve_authoritative_without_delegation(zone_name, normalized_owner, qtype)
    end
  end

  defp resolve_authoritative_without_delegation(zone_name, normalized_owner, qtype) do
    # Look up records
    case Storage.lookup_record(zone_name, normalized_owner, qtype) do
      {:ok, records} ->
        # Convert storage format to Zone.Record
        answers = Enum.map(records, &storage_to_record(normalized_owner, qtype, &1))
        {:ok, answers, []}

      {:error, :not_found} ->
        # Try wildcard matching before NXDOMAIN
        case try_wildcard_match(zone_name, normalized_owner, qtype) do
          {:ok, records} ->
            {:ok, records, []}

          {:error, :not_found} ->
            # Check if the name exists with other types
            case check_name_exists(zone_name, normalized_owner) do
              true ->
                # Name exists but no records of this type (NODATA)
                authority = get_soa_authority(zone_name)
                {:nodata, [], authority}

              false ->
                # Name doesn't exist (NXDOMAIN)
                authority = get_soa_authority(zone_name)
                {:nxdomain, [], authority}
            end
        end
    end
  end

  defp resolve_forward(zone_name, owner, qtype, metadata) do
    # Extract forward configuration from metadata
    forwarders = Map.get(metadata, :forwarders, [])
    forward_mode = Map.get(metadata, :forward_mode, :only)
    timeout_ms = Map.get(metadata, :timeout_ms, 5000)
    max_retries = Map.get(metadata, :max_retries, 2)

    case forward_mode do
      :only ->
        # Always forward, never try local resolution
        forward_to_upstream(owner, qtype, forwarders, timeout_ms, max_retries)

      :first ->
        # Try local authoritative first, forward on NXDOMAIN
        case resolve_authoritative(zone_name, owner, qtype) do
          {:nxdomain, _, _} ->
            # Name not found locally, try forwarding
            forward_to_upstream(owner, qtype, forwarders, timeout_ms, max_retries)

          other_result ->
            # Return local result (could be :ok, :nodata, or :servfail)
            other_result
        end
    end
  end

  defp forward_to_upstream(query_name, query_type, forwarders, timeout_ms, max_retries) do
    opts = [timeout_ms: timeout_ms, max_retries: max_retries]

    case Forwarder.forward_query(query_name, query_type, forwarders, opts) do
      {:ok, dns_records} ->
        # Convert DNS.Message.Record to Zone.Record format
        zone_records = convert_dns_records_to_zone_records(dns_records)
        {:ok, zone_records, []}

      {:nxdomain, _} ->
        {:nxdomain, [], []}

      {:servfail, _} ->
        {:servfail, [], []}

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dns, :query, :forward_error],
          %{count: 1},
          %{source: __MODULE__, query_name: query_name, reason: reason, severity: :warning}
        )
        {:servfail, [], []}
    end
  end

  defp resolve_recursive(query_name, query_type, metadata) do
    # Extract configuration from metadata
    timeout_ms = Map.get(metadata, :timeout_ms, 10000)
    max_depth = Map.get(metadata, :max_recursion_depth, 16)
    ip_version = Map.get(metadata, :ip_version, :ipv4)

    opts = [
      timeout_ms: timeout_ms,
      max_depth: max_depth,
      ip_version: ip_version
    ]

    case Recursive.resolve(query_name, query_type, opts) do
      {:ok, dns_records, authority} ->
        # Convert DNS.Message.Record to Zone.Record format
        zone_records = convert_dns_records_to_zone_records(dns_records)
        authority_records = convert_dns_records_to_zone_records(authority)
        {:ok, zone_records, authority_records}

      {:nxdomain, [], authority} ->
        authority_records = convert_dns_records_to_zone_records(authority)
        {:nxdomain, [], authority_records}

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dns, :query, :recursive_error],
          %{count: 1},
          %{source: __MODULE__, query_name: query_name, query_type: query_type, reason: reason, severity: :warning}
        )
        {:servfail, [], []}
    end
  end

  defp convert_dns_records_to_zone_records(dns_records) do
    Enum.map(dns_records, fn dns_record ->
      # Extract fields from DNS.Message.Record
      owner = dns_record.name.value
      type = convert_dns_type_to_zone_type(dns_record.type)
      ttl = dns_record.ttl
      class = convert_dns_class(dns_record.class)
      rdata = convert_dns_rdata(dns_record.type, dns_record.data)

      Zone.Record.new(owner, type, rdata, ttl: ttl, class: class)
    end)
  end

  defp convert_dns_type_to_zone_type(type) when is_atom(type) do
    # Convert lowercase atom to uppercase (e.g., :a -> :A)
    type
    |> Atom.to_string()
    |> String.upcase()
    |> String.to_atom()
  end

  defp convert_dns_class(:in), do: :IN
  defp convert_dns_class(:ch), do: :CH
  defp convert_dns_class(:hs), do: :HS
  defp convert_dns_class(other), do: other

  defp convert_dns_rdata(:a, data) when is_tuple(data), do: data
  defp convert_dns_rdata(:aaaa, data) when is_tuple(data), do: data
  defp convert_dns_rdata(:ns, data) when is_binary(data), do: data
  defp convert_dns_rdata(:cname, data) when is_binary(data), do: data
  defp convert_dns_rdata(:ptr, data) when is_binary(data), do: data
  defp convert_dns_rdata(:txt, data) when is_list(data), do: Enum.join(data, "")
  defp convert_dns_rdata(:mx, %{preference: pref, exchange: exch}), do: {pref, exch}

  defp convert_dns_rdata(:srv, %{priority: pri, weight: w, port: p, target: t}),
    do: {pri, w, p, t}

  defp convert_dns_rdata(:soa, %{} = soa_map) do
    %Zone.SOA{
      mname: Map.get(soa_map, :mname),
      rname: Map.get(soa_map, :rname),
      serial: Map.get(soa_map, :serial),
      refresh: Map.get(soa_map, :refresh),
      retry: Map.get(soa_map, :retry),
      expire: Map.get(soa_map, :expire),
      minimum: Map.get(soa_map, :minimum)
    }
  end

  defp convert_dns_rdata(_type, data), do: data

  defp do_resolve_with_cname(zone_name, owner, qtype, depth, chain) when depth > 0 do
    # First check for direct answer
    case do_resolve(zone_name, owner, qtype) do
      {:ok, answers, authority} ->
        # Check if we got a CNAME instead of the requested type
        case answers do
          [%{type: :CNAME, rdata: target} | _] when qtype != :CNAME ->
            # Got CNAME, follow it
            do_resolve_with_cname(zone_name, target, qtype, depth - 1, chain ++ answers)

          _ ->
            # Got direct answer of requested type
            {:ok, chain ++ answers, authority}
        end

      {:nxdomain, _, authority} ->
        # Name doesn't exist for requested type - check for CNAME (including wildcards)
        case do_resolve(zone_name, owner, :CNAME) do
          {:ok, [cname_record | _], _} ->
            # Found CNAME, follow it
            target = cname_record.rdata
            do_resolve_with_cname(zone_name, target, qtype, depth - 1, chain ++ [cname_record])

          _ ->
            # No CNAME either, return NXDOMAIN with chain
            {:nxdomain, chain, authority}
        end

      {:nodata, [], authority} ->
        # No direct answer, check for CNAME
        case do_resolve(zone_name, owner, :CNAME) do
          {:ok, [cname_record | _], _} ->
            # Found CNAME, follow it
            target = cname_record.rdata
            do_resolve_with_cname(zone_name, target, qtype, depth - 1, chain ++ [cname_record])

          _ ->
            # No CNAME either, return NODATA with chain
            {:nodata, chain, authority}
        end

      other ->
        other
    end
  end

  defp do_resolve_with_cname(_zone_name, _owner, _qtype, 0, chain) do
    # Hit max depth, return what we have with SERVFAIL
    :telemetry.execute(
      [:yellow_dog, :dns, :query, :error],
      %{count: 1},
      %{source: __MODULE__, reason: :cname_chain_too_deep, chain_length: length(chain), severity: :warning}
    )
    {:servfail, chain, []}
  end

  defp check_name_exists(zone_name, owner) do
    # Check if any records exist for this owner
    # We check a few common types to determine if the name exists
    types_to_check = [:A, :AAAA, :NS, :MX, :TXT, :CNAME, :SOA]

    Enum.any?(types_to_check, fn type ->
      case Storage.lookup_record(zone_name, owner, type) do
        {:ok, _} -> true
        {:error, :not_found} -> false
      end
    end)
  end

  defp try_wildcard_match(zone_name, owner, qtype) do
    # Generate wildcard candidates from the owner name
    # For example, for "foo.bar.example.com.", generate:
    # ["*.bar.example.com.", "*.example.com.", "*.com."]
    wildcard_candidates = generate_wildcard_candidates(owner, zone_name)

    # Try each wildcard candidate, most specific first
    # According to RFC 4592, we should find the closest enclosing wildcard regardless of type
    Enum.reduce_while(wildcard_candidates, {:error, :not_found}, fn wildcard_owner, _acc ->
      # First try the requested type
      case Storage.lookup_record(zone_name, wildcard_owner, qtype) do
        {:ok, records} ->
          # Found a match! Convert records but use the original query name as owner
          answers =
            Enum.map(records, fn storage_data ->
              # Wildcard expansion: use the original queried name as the owner
              storage_to_record(owner, qtype, storage_data)
            end)

          {:halt, {:ok, answers}}

        {:error, :not_found} ->
          # No match for requested type, check for CNAME at this specificity level
          case Storage.lookup_record(zone_name, wildcard_owner, :CNAME) do
            {:ok, records} ->
              # Found wildcard CNAME! Convert and return it
              # The caller (do_resolve_with_cname) will follow the CNAME
              answers =
                Enum.map(records, fn storage_data ->
                  storage_to_record(owner, :CNAME, storage_data)
                end)

              {:halt, {:ok, answers}}

            {:error, :not_found} ->
              # No match at this level, continue to next (less specific) wildcard
              {:cont, {:error, :not_found}}
          end
      end
    end)
  end

  defp generate_wildcard_candidates(owner, zone_name) do
    # Normalize names
    normalized_owner = String.downcase(owner) |> String.trim_trailing(".")
    normalized_zone = String.downcase(zone_name) |> String.trim_trailing(".")

    # Split the owner into labels
    labels = String.split(normalized_owner, ".")

    # Generate wildcard candidates from most specific to least specific
    # For "foo.bar.example.com" with zone "example.com", generate:
    # ["*.bar.example.com.", "*.example.com."]
    # We skip the first label (foo) and start from the second
    1..(length(labels) - 1)
    |> Enum.map(fn skip_count ->
      remaining_labels = Enum.drop(labels, skip_count)
      wildcard_name = ["*" | remaining_labels] |> Enum.join(".")
      wildcard_name <> "."
    end)
    |> Enum.filter(fn wildcard_name ->
      # Only include wildcards that are within our zone
      wildcard_base = String.trim_leading(wildcard_name, "*.")

      wildcard_base == normalized_zone <> "." or
        String.ends_with?(wildcard_base, "." <> normalized_zone <> ".")
    end)
    # Sort by length descending (most specific first)
    |> Enum.sort_by(&(-String.length(&1)))
  end

  defp get_soa_authority(zone_name) do
    case Storage.get_zone_metadata(zone_name) do
      {:ok, _metadata} ->
        case Storage.lookup_record(zone_name, "@", :SOA) do
          {:ok, [soa_data]} ->
            # SOA is stored as Zone.SOA struct in rdata
            [soa_data.rdata]

          _ ->
            []
        end

      _ ->
        []
    end
  end

  defp normalize_owner("@", _zone_name), do: "@"

  defp normalize_owner(owner, zone_name) do
    normalized_zone = normalize_zone_name(zone_name)

    cond do
      # Already has trailing dot (absolute)
      String.ends_with?(owner, ".") ->
        owner

      # Relative name within zone
      String.ends_with?(owner, "." <> normalized_zone) ->
        owner

      # Relative name, make absolute
      true ->
        owner <> "." <> normalized_zone <> "."
    end
  end

  defp normalize_zone_name(zone_name) do
    zone_name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp storage_to_record(owner, type, storage_data) do
    Zone.Record.new(
      owner,
      type,
      storage_data.rdata,
      ttl: storage_data.ttl,
      class: storage_data.class
    )
  end

  # Cache-related helper functions

  defp cache_enabled? do
    # Check if CacheManager is running
    Process.whereis(CacheManager) != nil and CacheManager.enabled?()
  rescue
    _ -> false
  end

  defp cache_result(query_name, query_type, query_class, result) do
    case result do
      {:ok, records, authority} ->
        # Cache successful answer
        ttl = extract_min_ttl(records)

        CacheManager.put(query_name, query_type, records, authority, ttl,
          query_class: query_class
        )

      {:nxdomain, [], authority} ->
        # Cache negative response (NXDOMAIN)
        ttl = extract_soa_minimum(authority)

        CacheManager.put(query_name, query_type, [], authority, ttl,
          query_class: query_class,
          response_type: :nxdomain
        )

      {:nodata, [], authority} ->
        # Cache negative response (NODATA)
        ttl = extract_soa_minimum(authority)

        CacheManager.put(query_name, query_type, [], authority, ttl,
          query_class: query_class,
          response_type: :nodata
        )

      _ ->
        # Don't cache errors
        :ok
    end
  rescue
    _ -> :ok
  end

  defp extract_min_ttl([]), do: 300

  defp extract_min_ttl(records) do
    records
    |> Enum.map(fn
      %Zone.Record{ttl: ttl} -> ttl
      _ -> 300
    end)
    |> Enum.min(fn -> 300 end)
  end

  defp extract_soa_minimum([]), do: 300

  defp extract_soa_minimum(authority) do
    Enum.find_value(authority, 300, fn
      %Zone.SOA{minimum: minimum} -> minimum
      _ -> nil
    end)
  end
end
