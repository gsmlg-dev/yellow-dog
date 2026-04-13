defmodule YellowDog.DnsProvider.Provider.Gcp do
  @moduledoc """
  Google Cloud DNS provider.

  Pulls and pushes DNS zone data via the Cloud DNS REST API v1.
  Auth is via a Bearer access token passed as `access_token` in credentials.

  ## Config

      %{project_id: "my-project", access_token: "ya29.…"}

  An optional `:req` key can inject a pre-built `Req.Request` for testing.
  """

  @behaviour YellowDog.DnsProvider.Provider

  @api_base "https://dns.googleapis.com/dns/v1"

  # -------------------------------------------------------------------
  # Provider callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(%{project_id: project_id} = config) when is_binary(project_id) do
    access_token = Map.get(config, :access_token, "")

    req =
      Map.get_lazy(config, :req, fn ->
        Req.new(
          base_url: @api_base,
          headers: [{"authorization", "Bearer #{access_token}"}]
        )
      end)

    {:ok, %{req: req, project_id: project_id}}
  end

  def init(_config), do: {:error, :missing_project_id}

  @impl true
  def list_zones(state) do
    case Req.get(state.req, url: "/projects/#{state.project_id}/managedZones") do
      {:ok, %{status: 200, body: %{"managedZones" => zones}}} ->
        parsed = parse_zones(zones)
        {:ok, parsed, state}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def get_records(%{id: zone_id}, state) do
    case Req.get(state.req,
           url: "/projects/#{state.project_id}/managedZones/#{zone_id}/rrsets"
         ) do
      {:ok, %{status: 200, body: %{"rrsets" => rrsets}}} ->
        records = parse_rrsets(rrsets)
        {:ok, records, state}

      {:ok, %{status: 200, body: _body}} ->
        # No rrsets key means empty
        {:ok, [], state}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def apply_changeset(%{id: zone_id}, changeset, state) do
    additions = group_by_rrset(Map.get(changeset, :additions, []))
    deletions = group_by_rrset(Map.get(changeset, :deletions, []))

    body = %{"additions" => additions, "deletions" => deletions}

    case Req.post(state.req,
           url: "/projects/#{state.project_id}/managedZones/#{zone_id}/changes",
           json: body
         ) do
      {:ok, %{status: status}} when status in [200, 201] ->
        {:ok, state}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def zone_serial(%{id: zone_id}, state) do
    case get_records(%{id: zone_id}, state) do
      {:ok, records, new_state} ->
        soa = Enum.find(records, fn r -> r.type == "SOA" end)

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
  @spec parse_zones([map()]) :: [map()]
  def parse_zones(zones) do
    Enum.map(zones, fn z ->
      %{
        name: ensure_trailing_dot(z["dnsName"]),
        id: z["name"]
      }
    end)
  end

  @doc false
  @spec parse_rrsets([map()]) :: [map()]
  def parse_rrsets(rrsets) do
    Enum.flat_map(rrsets, fn rrset ->
      name = ensure_trailing_dot(rrset["name"])
      type = rrset["type"]
      ttl = rrset["ttl"] || 0

      rrdatas = Map.get(rrset, "rrdatas", [])

      Enum.map(rrdatas, fn rdata ->
        %{owner: name, type: type, ttl: ttl, rdata: rdata}
      end)
    end)
  end

  @doc false
  @spec group_by_rrset([map()]) :: [map()]
  def group_by_rrset(records) do
    records
    |> Enum.group_by(fn r -> {r.owner, r.type, r.ttl} end)
    |> Enum.map(fn {{name, type, ttl}, recs} ->
      %{
        "name" => ensure_trailing_dot(name),
        "type" => type,
        "ttl" => ttl,
        "rrdatas" => Enum.map(recs, fn r -> to_string(r.rdata) end)
      }
    end)
  end

  @doc false
  @spec parse_soa_serial(String.t()) :: non_neg_integer()
  def parse_soa_serial(rdata) when is_binary(rdata) do
    # SOA rdata: "ns1.example.com. admin.example.com. 2024010100 3600 900 1209600 86400"
    parts = String.split(rdata)
    serial_str = Enum.at(parts, 2, "0")
    String.to_integer(serial_str)
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp ensure_trailing_dot(name) when is_binary(name) do
    if String.ends_with?(name, "."), do: name, else: name <> "."
  end
end
