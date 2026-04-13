defmodule YellowDog.DnsProvider.Provider.Aws do
  @moduledoc """
  AWS Route 53 DNS provider.

  Pulls and pushes DNS zone data via the Route 53 REST API.
  Auth uses AWS Signature V4 (stubbed — only the date header is added;
  full SigV4 signing is out of scope for this iteration).

  ## Config

      %{access_key_id: "AKIA...", secret_access_key: "..."}

  An optional `:req` key can inject a pre-built `Req.Request` for testing.
  """

  @behaviour YellowDog.DnsProvider.Provider

  @api_base "https://route53.amazonaws.com/2013-04-01"

  # -------------------------------------------------------------------
  # Provider callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(%{access_key_id: key, secret_access_key: secret} = config)
      when is_binary(key) and is_binary(secret) do
    req =
      Map.get_lazy(config, :req, fn ->
        Req.new(
          base_url: @api_base,
          headers: [
            {"x-amz-date", amz_date()},
            {"content-type", "text/xml"}
          ]
        )
      end)

    {:ok, %{req: req, access_key_id: key, secret_access_key: secret}}
  end

  def init(_config), do: {:error, :missing_credentials}

  @impl true
  def list_zones(state) do
    case Req.get(state.req, url: "/hostedzone") do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        zones = parse_hosted_zones_xml(body)
        {:ok, zones, state}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def get_records(%{id: zone_id}, state) do
    case Req.get(state.req, url: "/hostedzone/#{zone_id}/rrset") do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        records = parse_rrsets_xml(body)
        {:ok, records, state}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def apply_changeset(%{id: zone_id}, changeset, state) do
    xml = build_change_batch_xml(changeset)

    case Req.post(state.req, url: "/hostedzone/#{zone_id}/rrset", body: xml) do
      {:ok, %{status: 200}} -> {:ok, state}
      {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def zone_serial(%{id: zone_id}, state) do
    case get_records(%{id: zone_id}, state) do
      {:ok, records, new_state} ->
        soa =
          Enum.find(records, fn r -> r.type == "SOA" end)

        case soa do
          nil -> {:error, :no_soa, new_state}
          %{rdata: rdata} -> {:ok, parse_soa_serial(rdata), new_state}
        end

      error ->
        error
    end
  end

  # -------------------------------------------------------------------
  # Public helpers (testable, @doc false)
  # -------------------------------------------------------------------

  @doc false
  @spec parse_hosted_zones_xml(String.t()) :: [map()]
  def parse_hosted_zones_xml(xml) do
    ~r/<HostedZone>.*?<Id>\/hostedzone\/([^<]+)<\/Id>.*?<Name>([^<]+)<\/Name>.*?<\/HostedZone>/s
    |> Regex.scan(xml)
    |> Enum.map(fn [_full, id, name] ->
      %{name: ensure_trailing_dot(name), id: id}
    end)
  end

  @doc false
  @spec parse_rrsets_xml(String.t()) :: [map()]
  def parse_rrsets_xml(xml) do
    ~r/<ResourceRecordSet>.*?<\/ResourceRecordSet>/s
    |> Regex.scan(xml)
    |> Enum.flat_map(fn [rrset_xml] ->
      name = extract_xml_tag(rrset_xml, "Name")
      type = extract_xml_tag(rrset_xml, "Type")
      ttl_str = extract_xml_tag(rrset_xml, "TTL")
      ttl = if ttl_str, do: String.to_integer(ttl_str), else: 0

      # Extract all <Value> elements within <ResourceRecord> elements
      ~r/<ResourceRecord>\s*<Value>([^<]+)<\/Value>\s*<\/ResourceRecord>/s
      |> Regex.scan(rrset_xml)
      |> Enum.map(fn [_full, value] ->
        %{
          owner: ensure_trailing_dot(name || ""),
          type: type || "",
          ttl: ttl,
          rdata: value
        }
      end)
    end)
  end

  @doc false
  @spec build_change_batch_xml(map()) :: String.t()
  def build_change_batch_xml(changeset) do
    changes =
      build_changes("DELETE", Map.get(changeset, :deletions, [])) ++
        build_changes("CREATE", Map.get(changeset, :additions, []))

    changes_xml = Enum.join(changes, "\n")

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ChangeResourceRecordSetsRequest xmlns="https://route53.amazonaws.com/doc/2013-04-01/">
      <ChangeBatch>
        <Changes>
    #{changes_xml}
        </Changes>
      </ChangeBatch>
    </ChangeResourceRecordSetsRequest>
    """
    |> String.trim()
  end

  @doc false
  @spec parse_soa_serial(String.t()) :: non_neg_integer()
  def parse_soa_serial(rdata) when is_binary(rdata) do
    parts = String.split(rdata)
    serial_str = Enum.at(parts, 2, "0")
    String.to_integer(serial_str)
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp build_changes(_action, []), do: []

  defp build_changes(action, records) do
    # Group records by {owner, type, ttl} to form proper RRSets
    records
    |> Enum.group_by(fn r -> {r.owner, r.type, r.ttl} end)
    |> Enum.map(fn {{owner, type, ttl}, recs} ->
      name = ensure_trailing_dot(owner)

      resource_records =
        recs
        |> Enum.map(fn r ->
          "          <ResourceRecord><Value>#{escape_xml(to_string(r.rdata))}</Value></ResourceRecord>"
        end)
        |> Enum.join("\n")

      """
            <Change>
              <Action>#{action}</Action>
              <ResourceRecordSet>
                <Name>#{escape_xml(name)}</Name>
                <Type>#{escape_xml(type)}</Type>
                <TTL>#{ttl}</TTL>
                <ResourceRecords>
      #{resource_records}
                </ResourceRecords>
              </ResourceRecordSet>
            </Change>\
      """
    end)
  end

  defp extract_xml_tag(xml, tag) do
    case Regex.run(~r/<#{tag}>([^<]*)<\/#{tag}>/, xml) do
      [_full, value] -> value
      _ -> nil
    end
  end

  defp escape_xml(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp ensure_trailing_dot(name) when is_binary(name) do
    if String.ends_with?(name, "."), do: name, else: name <> "."
  end

  defp amz_date do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
