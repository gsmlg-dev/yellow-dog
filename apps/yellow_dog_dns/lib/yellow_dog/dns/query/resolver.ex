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

  require Logger
  alias YellowDog.Dns.Zone
  alias YellowDog.Dns.Zone.Storage

  @type resolve_result ::
          {:ok, [Zone.Record.t()], [Zone.Record.t()]}
          | {:nxdomain, [], [Zone.SOA.t()]}
          | {:nodata, [], [Zone.SOA.t()]}
          | {:servfail, [], []}

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

  defp do_resolve(zone_name, owner, qtype) do
    # Check if zone exists
    unless Storage.zone_exists?(zone_name) do
      Logger.debug("Zone not found", zone: zone_name)
      {:servfail, [], []}
    else

    # Normalize owner name
    normalized_owner = normalize_owner(owner, zone_name)

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
  end

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
    Logger.warning("CNAME chain too deep", chain_length: length(chain))
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
          answers = Enum.map(records, fn storage_data ->
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
              answers = Enum.map(records, fn storage_data ->
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
      wildcard_base == normalized_zone <> "." or String.ends_with?(wildcard_base, "." <> normalized_zone <> ".")
    end)
    |> Enum.sort_by(&(-String.length(&1)))  # Sort by length descending (most specific first)
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
end
