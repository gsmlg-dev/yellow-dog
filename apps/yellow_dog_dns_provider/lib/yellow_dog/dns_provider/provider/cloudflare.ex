defmodule YellowDog.DnsProvider.Provider.Cloudflare do
  @moduledoc """
  Cloudflare DNS API v4 provider.

  Pulls and pushes DNS zone data via the Cloudflare REST API.
  Auth is via a Bearer API token passed as `api_token` in credentials.

  ## Config

      %{api_token: "cf-token-..."}

  An optional `:req` key can inject a pre-built `Req.Request` for testing.
  """

  @behaviour YellowDog.DnsProvider.Provider

  @api_base "https://api.cloudflare.com/client/v4"

  # -------------------------------------------------------------------
  # Provider callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(%{api_token: api_token} = config) when is_binary(api_token) do
    req =
      Map.get_lazy(config, :req, fn ->
        Req.new(
          base_url: @api_base,
          headers: [{"authorization", "Bearer #{api_token}"}]
        )
      end)

    {:ok, %{req: req}}
  end

  def init(_config), do: {:error, :missing_api_token}

  @impl true
  def list_zones(state) do
    case Req.get(state.req, url: "/zones") do
      {:ok, %{status: 200, body: %{"result" => results}}} ->
        zones =
          Enum.map(results, fn z ->
            %{name: ensure_trailing_dot(z["name"]), id: z["id"]}
          end)

        {:ok, zones, state}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def get_records(%{id: zone_id}, state) do
    fetch_all_records(state.req, zone_id, 1, [])
    |> case do
      {:ok, records} -> {:ok, records, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def apply_changeset(%{id: zone_id}, changeset, state) do
    with :ok <- apply_deletions(state.req, zone_id, changeset.deletions),
         :ok <- apply_additions(state.req, zone_id, changeset.additions) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def zone_serial(%{id: zone_id}, state) do
    case Req.get(state.req,
           url: "/zones/#{zone_id}/dns_records",
           params: [type: "SOA", per_page: 1]
         ) do
      {:ok, %{status: 200, body: %{"result" => [soa | _]}}} ->
        serial = parse_soa_serial(soa["content"])
        {:ok, serial, state}

      {:ok, %{status: 200, body: %{"result" => []}}} ->
        {:error, :no_soa, state}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # -------------------------------------------------------------------
  # Public helpers (testable, @doc false)
  # -------------------------------------------------------------------

  @doc false
  @spec parse_dns_records([map()]) :: [map()]
  def parse_dns_records(results) do
    Enum.map(results, fn r ->
      %{
        owner: ensure_trailing_dot(r["name"]),
        type: r["type"],
        ttl: r["ttl"],
        rdata: parse_rdata(r["type"], r)
      }
    end)
  end

  @doc false
  @spec build_create_body(map()) :: map()
  def build_create_body(record) do
    body = %{
      "type" => record.type,
      "name" => String.trim_trailing(record.owner, "."),
      "ttl" => record.ttl
    }

    case record.type do
      "MX" ->
        {priority, target} = parse_mx_rdata(record.rdata)
        Map.merge(body, %{"content" => target, "priority" => priority})

      "SRV" ->
        build_srv_body(body, record)

      _ ->
        Map.put(body, "content", to_string(record.rdata))
    end
  end

  @doc false
  @spec parse_soa_serial(String.t()) :: non_neg_integer()
  def parse_soa_serial(content) when is_binary(content) do
    # SOA content: "ns1.example.com admin.example.com 2024010100 3600 900 1209600 86400"
    parts = String.split(content)
    serial_str = Enum.at(parts, 2, "0")
    String.to_integer(serial_str)
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp fetch_all_records(req, zone_id, page, acc) do
    case Req.get(req,
           url: "/zones/#{zone_id}/dns_records",
           params: [per_page: 100, page: page]
         ) do
      {:ok, %{status: 200, body: %{"result" => results, "result_info" => info}}} ->
        parsed = parse_dns_records(results)
        all = acc ++ parsed

        total_pages = Map.get(info, "total_pages", 1)

        if page < total_pages do
          fetch_all_records(req, zone_id, page + 1, all)
        else
          {:ok, all}
        end

      {:ok, %{status: 200, body: %{"result" => results}}} ->
        {:ok, acc ++ parse_dns_records(results)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_deletions(_req, _zone_id, []), do: :ok

  defp apply_deletions(req, zone_id, [record | rest]) do
    name = String.trim_trailing(record.owner, ".")

    case Req.get(req,
           url: "/zones/#{zone_id}/dns_records",
           params: [type: record.type, name: name]
         ) do
      {:ok, %{status: 200, body: %{"result" => results}}} ->
        # Find matching record by content
        content = to_string(record.rdata)

        matching =
          Enum.find(results, fn r ->
            r["content"] == content
          end)

        case matching do
          nil ->
            # Record not found, skip deletion
            apply_deletions(req, zone_id, rest)

          %{"id" => record_id} ->
            case Req.delete(req, url: "/zones/#{zone_id}/dns_records/#{record_id}") do
              {:ok, %{status: 200}} -> apply_deletions(req, zone_id, rest)
              {:ok, %{status: status, body: body}} -> {:error, {:api_error, status, body}}
              {:error, reason} -> {:error, reason}
            end
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_additions(_req, _zone_id, []), do: :ok

  defp apply_additions(req, zone_id, [record | rest]) do
    body = build_create_body(record)

    case Req.post(req, url: "/zones/#{zone_id}/dns_records", json: body) do
      {:ok, %{status: 200}} -> apply_additions(req, zone_id, rest)
      {:ok, %{status: status, body: resp}} -> {:error, {:api_error, status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_rdata("MX", record) do
    priority = Map.get(record, "priority", 0)
    "#{priority} #{record["content"]}"
  end

  defp parse_rdata(_type, record), do: record["content"]

  defp parse_mx_rdata(rdata) when is_binary(rdata) do
    case String.split(rdata, " ", parts: 2) do
      [priority, target] -> {String.to_integer(priority), target}
      _ -> {0, rdata}
    end
  end

  defp build_srv_body(body, record) do
    # SRV rdata: "priority weight port target"
    case String.split(to_string(record.rdata)) do
      [_pri, weight, port, target] ->
        Map.merge(body, %{
          "data" => %{
            "weight" => String.to_integer(weight),
            "port" => String.to_integer(port),
            "target" => target
          }
        })

      _ ->
        Map.put(body, "content", to_string(record.rdata))
    end
  end

  defp ensure_trailing_dot(name) when is_binary(name) do
    if String.ends_with?(name, "."), do: name, else: name <> "."
  end
end
