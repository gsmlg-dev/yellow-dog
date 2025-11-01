defmodule YellowDog.Dns.RPZ do
  @moduledoc """
  Response Policy Zone (RPZ) implementation for DNS filtering and policy enforcement.

  RPZ provides a mechanism to override DNS responses based on policy rules,
  commonly used for:
  - Malware domain blocking
  - Parental controls
  - Content filtering
  - DNS firewall
  - Threat intelligence feeds

  ## RPZ Actions

  - **NXDOMAIN** - Return non-existent domain (CNAME .)
  - **NODATA** - Return empty answer (CNAME *.)
  - **PASSTHRU** - Allow the query (rpz-passthru)
  - **DROP** - Drop the query silently (rpz-drop)
  - **TCP-ONLY** - Force TCP for this query (rpz-tcp-only)
  - **Local Data** - Return specific records (A, AAAA, etc.)

  ## RPZ Triggers

  - **QNAME** - Match query name (subdomain.example.com)
  - **Client-IP** - Match client IP address
  - **IP** - Match IP address in response
  - **NSDNAME** - Match nameserver name
  - **NSIP** - Match nameserver IP

  ## Examples

      # Block a malicious domain
      iex> RPZ.check_policy("malware.example.com", :A, client_ip)
      {:block, :nxdomain, []}

      # Allow whitelisted domain
      iex> RPZ.check_policy("trusted.example.com", :A, client_ip)
      :passthru

      # Return custom IP
      iex> RPZ.check_policy("blocked.example.com", :A, client_ip)
      {:rewrite, [{192, 0, 2, 1}], []}
  """

  require Logger
  alias YellowDog.Dns.Zone
  alias YellowDog.Dns.Zone.Storage

  @type policy_action ::
          :nxdomain
          | :nodata
          | :passthru
          | :drop
          | :tcp_only

  @type policy_result ::
          {:block, policy_action(), []}
          | {:rewrite, [Zone.Record.t()], []}
          | :passthru

  @type trigger_type ::
          :qname
          | :client_ip
          | :response_ip
          | :nsdname
          | :nsip

  defmodule Policy do
    @moduledoc """
    Represents an RPZ policy rule.
    """

    @type t :: %__MODULE__{
            trigger: YellowDog.Dns.RPZ.trigger_type(),
            pattern: String.t() | tuple(),
            action: YellowDog.Dns.RPZ.policy_action(),
            local_data: [YellowDog.Dns.Zone.Record.t()],
            priority: non_neg_integer(),
            zone: String.t()
          }

    defstruct [
      :trigger,
      :pattern,
      :action,
      :local_data,
      :priority,
      :zone
    ]
  end

  @doc """
  Checks if a query matches any RPZ policies.

  ## Parameters
  - `qname` - Query name
  - `qtype` - Query type
  - `client_ip` - Client IP address
  - `opts` - Options:
    - `:rpz_zones` - List of RPZ zone names (in priority order)

  ## Returns
  - `{:block, action, []}` - Query blocked by policy
  - `{:rewrite, records, []}` - Query rewritten with local data
  - `:passthru` - No policy match or explicit passthru
  """
  @spec check_policy(String.t(), atom(), tuple(), keyword()) :: policy_result()
  def check_policy(qname, qtype, client_ip, opts \\ []) do
    rpz_zones = Keyword.get(opts, :rpz_zones, get_rpz_zones())

    # Check each RPZ zone in priority order
    Enum.reduce_while(rpz_zones, :passthru, fn zone_name, _acc ->
      case check_zone_policy(zone_name, qname, qtype, client_ip) do
        :passthru -> {:cont, :passthru}
        {:passthru, _} -> {:halt, :passthru}
        result -> {:halt, result}
      end
    end)
  end

  @doc """
  Checks a single RPZ zone for policy matches.

  Checks triggers in order:
  1. QNAME (most specific to least specific)
  2. Client-IP
  3. Response-IP (if available)
  4. NSDNAME
  5. NSIP
  """
  @spec check_zone_policy(String.t(), String.t(), atom(), tuple()) :: policy_result()
  def check_zone_policy(zone_name, qname, qtype, client_ip) do
    # Check QNAME trigger first (most common)
    case check_qname_trigger(zone_name, qname, qtype) do
      :passthru ->
        # Check Client-IP trigger
        check_client_ip_trigger(zone_name, client_ip, qtype)

      result ->
        result
    end
  end

  @doc """
  Checks QNAME trigger for RPZ match.

  Tries to match the query name against RPZ records in the zone.
  Checks from most specific to least specific:
  1. Exact match: malware.example.com
  2. Wildcard match: *.malware.example.com
  3. Parent domains
  """
  @spec check_qname_trigger(String.t(), String.t(), atom()) :: policy_result()
  def check_qname_trigger(zone_name, qname, qtype) do
    normalized_qname = normalize_name(qname)

    # Try exact match first
    case lookup_rpz_record(zone_name, normalized_qname, qtype) do
      {:ok, policy} ->
        apply_policy(policy)

      {:error, :not_found} ->
        # Try wildcard match
        case try_wildcard_match(zone_name, normalized_qname, qtype) do
          {:ok, policy} ->
            apply_policy(policy)

          {:error, :not_found} ->
            :passthru
        end
    end
  end

  @doc """
  Checks Client-IP trigger for RPZ match.

  Matches client IP against IP-based RPZ records.
  """
  @spec check_client_ip_trigger(String.t(), tuple(), atom()) :: policy_result()
  def check_client_ip_trigger(zone_name, client_ip, qtype) do
    # Convert IP to RPZ format: 32.1.2.0.192.rpz-client-ip
    rpz_name = ip_to_rpz_name(client_ip, "rpz-client-ip")

    case lookup_rpz_record(zone_name, rpz_name, qtype) do
      {:ok, policy} -> apply_policy(policy)
      {:error, :not_found} -> :passthru
    end
  end

  @doc """
  Applies an RPZ policy to generate the response.
  """
  @spec apply_policy(map()) :: policy_result()
  def apply_policy(%{action: action, local_data: local_data}) do
    case action do
      :nxdomain ->
        {:block, :nxdomain, []}

      :nodata ->
        {:block, :nodata, []}

      :passthru ->
        {:passthru, []}

      :drop ->
        {:block, :drop, []}

      :tcp_only ->
        {:block, :tcp_only, []}

      :local_data ->
        {:rewrite, local_data, []}
    end
  end

  @doc """
  Looks up an RPZ record in a zone.

  Returns policy information including action and any local data.
  """
  @spec lookup_rpz_record(String.t(), String.t(), atom()) ::
          {:ok, map()} | {:error, :not_found}
  def lookup_rpz_record(zone_name, rpz_name, qtype) do
    case Storage.lookup_record(zone_name, rpz_name, :CNAME) do
      {:ok, [cname_target]} ->
        # Decode RPZ action from CNAME target
        {:ok, decode_rpz_action(cname_target, qtype)}

      {:error, :not_found} ->
        # Check for local data records
        case Storage.lookup_record(zone_name, rpz_name, qtype) do
          {:ok, records} when records != [] ->
            # Local data override
            local_data =
              Enum.map(records, fn rdata ->
                %Zone.Record{
                  owner: rpz_name,
                  type: qtype,
                  class: :IN,
                  ttl: 300,
                  rdata: rdata
                }
              end)

            {:ok, %{action: :local_data, local_data: local_data}}

          _ ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Decodes RPZ action from CNAME target.

  RPZ uses special CNAME targets to indicate actions:
  - "." → NXDOMAIN
  - "*." → NODATA
  - "rpz-passthru." → PASSTHRU
  - "rpz-drop." → DROP
  - "rpz-tcp-only." → TCP-ONLY
  """
  @spec decode_rpz_action(String.t(), atom()) :: map()
  def decode_rpz_action(cname_target, _qtype) do
    normalized = normalize_name(cname_target)

    action =
      case normalized do
        "" -> :nxdomain
        # CNAME .
        "*" -> :nodata
        # CNAME *.
        "rpz-passthru" -> :passthru
        "rpz-drop" -> :drop
        "rpz-tcp-only" -> :tcp_only
        _ -> :nxdomain
      end

    %{action: action, local_data: []}
  end

  # Private functions

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp normalize_name(name), do: name

  defp get_rpz_zones do
    # Get list of RPZ zones from configuration
    # For now, return empty list - will be populated from config
    []
  end

  defp try_wildcard_match(zone_name, qname, qtype) do
    # Try wildcard match: *.example.com
    parts = String.split(qname, ".")

    if length(parts) > 1 do
      wildcard_name = "*." <> Enum.join(tl(parts), ".")
      lookup_rpz_record(zone_name, wildcard_name, qtype)
    else
      {:error, :not_found}
    end
  end

  defp ip_to_rpz_name({a, b, c, d}, suffix) do
    # Convert IPv4 to RPZ format: 32.4.3.2.1.rpz-client-ip
    "32.#{d}.#{c}.#{b}.#{a}.#{suffix}"
  end

  defp ip_to_rpz_name({a, b, c, d, e, f, g, h}, suffix) do
    # Convert IPv6 to RPZ format: 128.h.g.f.e.d.c.b.a.rpz-client-ip
    "128.#{h}.#{g}.#{f}.#{e}.#{d}.#{c}.#{b}.#{a}.#{suffix}"
  end
end
