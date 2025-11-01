defmodule YellowDog.Dns.Query.Delegation do
  @moduledoc """
  Handles DNS sub-zone delegation with NS records and glue records.

  When a query matches a delegated sub-zone, this module generates
  a referral response containing:
  - NS records in the authority section
  - Glue records (A/AAAA) in the additional section for in-bailiwick nameservers

  ## Delegation Algorithm

  1. Check if the query name matches any NS records in the zone
  2. Find the closest enclosing delegation point
  3. Collect all NS records for that delegation
  4. For each NS hostname, check if it's in-bailiwick (under the delegation)
  5. Add glue records (A/AAAA) for in-bailiwick nameservers

  ## Examples

      # Zone: example.com
      # Delegation: sub.example.com NS ns1.sub.example.com
      # Glue: ns1.sub.example.com A 192.0.2.1

      iex> Delegation.check_delegation("example.com", "www.sub.example.com.", :A)
      {:delegated, "sub.example.com", [ns_records], [glue_records]}

      iex> Delegation.check_delegation("example.com", "www.example.com.", :A)
      :not_delegated
  """

  require Logger
  alias YellowDog.Dns.Zone
  alias YellowDog.Dns.Zone.Storage

  @type delegation_result ::
          {:delegated, String.t(), [Zone.Record.t()], [Zone.Record.t()]}
          | :not_delegated

  @doc """
  Checks if a query should be delegated to a sub-zone.

  ## Parameters
  - `zone_name` - The parent zone (e.g., "example.com")
  - `qname` - The query name (e.g., "www.sub.example.com")
  - `qtype` - The query type

  ## Returns
  - `{:delegated, delegation_point, ns_records, glue_records}` if delegated
  - `:not_delegated` if not delegated
  """
  @spec check_delegation(String.t(), String.t(), atom()) :: delegation_result()
  def check_delegation(zone_name, qname, qtype) do
    # Normalize names
    normalized_qname = normalize_name(qname)
    normalized_zone = normalize_name(zone_name)

    # If querying for NS at zone apex, it's not a delegation
    if normalized_qname == normalized_zone and qtype == :NS do
      :not_delegated
    else
      # Find if there's a delegation point between zone and qname
      case find_delegation_point(zone_name, normalized_qname) do
        {:ok, delegation_point} ->
          # Get NS records for the delegation
          case get_ns_records(zone_name, delegation_point) do
            {:ok, ns_records} when ns_records != [] ->
              # Get glue records for in-bailiwick nameservers
              glue_records = get_glue_records(zone_name, delegation_point, ns_records)
              {:delegated, delegation_point, ns_records, glue_records}

            _ ->
              :not_delegated
          end

        :not_found ->
          :not_delegated
      end
    end
  end

  @doc """
  Finds the closest delegation point for a query name.

  Walks up the domain hierarchy from the query name towards the zone apex,
  checking for NS records at each level.

  ## Examples

      iex> find_delegation_point("example.com", "a.b.c.sub.example.com")
      {:ok, "sub.example.com"}  # if sub.example.com has NS records
  """
  @spec find_delegation_point(String.t(), String.t()) :: {:ok, String.t()} | :not_found
  def find_delegation_point(zone_name, qname) do
    normalized_zone = normalize_name(zone_name)
    normalized_qname = normalize_name(qname)

    # Get all possible delegation points from qname to zone
    delegation_points = get_possible_delegation_points(normalized_qname, normalized_zone)

    # Check each delegation point for NS records (closest first)
    Enum.reduce_while(delegation_points, :not_found, fn point, _acc ->
      case has_ns_records?(zone_name, point) do
        true -> {:halt, {:ok, point}}
        false -> {:cont, :not_found}
      end
    end)
  end

  @doc """
  Gets NS records for a delegation point.
  """
  @spec get_ns_records(String.t(), String.t()) :: {:ok, [Zone.Record.t()]} | {:error, term()}
  def get_ns_records(zone_name, delegation_point) do
    normalized_point = normalize_name(delegation_point)

    case Storage.lookup_record(zone_name, normalized_point, :NS) do
      {:ok, records} ->
        # Convert storage records to Zone.Record format
        ns_records =
          Enum.map(records, fn ns_hostname ->
            %Zone.Record{
              owner: delegation_point,
              type: :NS,
              class: :IN,
              ttl: 172_800,
              # 2 days for NS records
              rdata: ns_hostname
            }
          end)

        {:ok, ns_records}

      {:error, :not_found} ->
        {:ok, []}

      error ->
        error
    end
  end

  @doc """
  Gets glue records for in-bailiwick nameservers.

  Glue records are A/AAAA records for nameserver hostnames that are
  within (in-bailiwick of) the delegated sub-zone.

  ## Examples

      # For delegation: sub.example.com NS ns1.sub.example.com
      # ns1.sub.example.com is in-bailiwick (under sub.example.com)
      # Must include glue: ns1.sub.example.com A 192.0.2.1
  """
  @spec get_glue_records(String.t(), String.t(), [Zone.Record.t()]) :: [Zone.Record.t()]
  def get_glue_records(zone_name, delegation_point, ns_records) do
    normalized_delegation = normalize_name(delegation_point)

    Enum.flat_map(ns_records, fn ns_record ->
      ns_hostname = ns_record.rdata
      normalized_ns = normalize_name(ns_hostname)

      # Check if NS hostname is in-bailiwick (under the delegation)
      if in_bailiwick?(normalized_ns, normalized_delegation) do
        # Get A and AAAA records for this nameserver
        a_records = get_address_records(zone_name, ns_hostname, :A)
        aaaa_records = get_address_records(zone_name, ns_hostname, :AAAA)
        a_records ++ aaaa_records
      else
        # Out-of-bailiwick, no glue needed
        []
      end
    end)
  end

  # Private functions

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp normalize_name(name), do: name

  defp get_possible_delegation_points(qname, zone_name) do
    qname_labels = String.split(qname, ".")
    zone_labels = String.split(zone_name, ".")

    # Calculate how many labels to strip from qname to reach zone
    labels_to_keep = length(qname_labels) - length(zone_labels)

    if labels_to_keep > 0 do
      # Generate all possible points from closest to furthest
      1..labels_to_keep
      |> Enum.map(fn depth ->
        qname_labels
        |> Enum.drop(depth)
        |> Enum.join(".")
      end)
    else
      []
    end
  end

  defp has_ns_records?(zone_name, delegation_point) do
    case Storage.lookup_record(zone_name, delegation_point, :NS) do
      {:ok, records} when is_list(records) and records != [] -> true
      _ -> false
    end
  end

  defp in_bailiwick?(ns_hostname, delegation_point) do
    # Check if NS hostname is under the delegation
    ns_hostname == delegation_point or String.ends_with?(ns_hostname, "." <> delegation_point)
  end

  defp get_address_records(zone_name, hostname, type) when type in [:A, :AAAA] do
    case Storage.lookup_record(zone_name, hostname, type) do
      {:ok, addresses} when is_list(addresses) ->
        Enum.map(addresses, fn address ->
          %Zone.Record{
            owner: hostname,
            type: type,
            class: :IN,
            ttl: 172_800,
            # Match NS TTL
            rdata: address
          }
        end)

      _ ->
        []
    end
  end
end
