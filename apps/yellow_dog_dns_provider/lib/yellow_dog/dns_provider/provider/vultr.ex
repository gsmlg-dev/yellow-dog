defmodule YellowDog.DnsProvider.Provider.Vultr do
  @moduledoc """
  Vultr DNS provider.

  Pulls and pushes DNS zone data via the Vultr REST API v2.
  Auth is via a Bearer API key passed as `api_key` in credentials.

  ## Config

      %{api_key: "vultr-api-key-..."}

  An optional `:req` key can inject a pre-built `Req.Request` for testing.
  """

  @behaviour YellowDog.DnsProvider.Provider

  @api_base "https://api.vultr.com/v2"

  # -------------------------------------------------------------------
  # Provider callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(%{api_key: api_key} = config) when is_binary(api_key) do
    req =
      Map.get_lazy(config, :req, fn ->
        Req.new(
          base_url: @api_base,
          headers: [{"authorization", "Bearer #{api_key}"}]
        )
      end)

    {:ok, %{req: req}}
  end

  def init(_config), do: {:error, :missing_api_key}

  @impl true
  def list_zones(state) do
    case Req.get(state.req, url: "/domains") do
      {:ok, %{status: 200, body: %{"domains" => domains}}} ->
        zones = parse_domains(domains)
        {:ok, zones, state}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def get_records(%{name: zone_name}, state) do
    domain = strip_trailing_dot(zone_name)

    case Req.get(state.req, url: "/domains/#{domain}/records") do
      {:ok, %{status: 200, body: %{"records" => records}}} ->
        parsed = parse_records(records, zone_name)
        {:ok, parsed, state}

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl true
  def apply_changeset(%{name: zone_name}, changeset, state) do
    domain = strip_trailing_dot(zone_name)

    with :ok <- apply_deletions(state.req, domain, zone_name, Map.get(changeset, :deletions, [])),
         :ok <- apply_additions(state.req, domain, Map.get(changeset, :additions, [])) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  @impl true
  def zone_serial(%{name: zone_name}, state) do
    domain = strip_trailing_dot(zone_name)

    case Req.get(state.req, url: "/domains/#{domain}/soa") do
      {:ok, %{status: 200, body: %{"dns_soa" => %{"nserial" => serial}}}} ->
        {:ok, serial, state}

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
  @spec parse_domains([map()]) :: [map()]
  def parse_domains(domains) do
    Enum.map(domains, fn d ->
      domain = d["domain"]
      %{name: ensure_trailing_dot(domain), id: domain}
    end)
  end

  @doc false
  @spec parse_records([map()], String.t()) :: [map()]
  def parse_records(records, zone_name) do
    Enum.map(records, fn r ->
      %{
        owner: vultr_name_to_owner(r["name"], zone_name),
        type: r["type"],
        ttl: r["ttl"] || 0,
        rdata: r["data"]
      }
    end)
  end

  @doc false
  @spec vultr_name_to_owner(String.t(), String.t()) :: String.t()
  def vultr_name_to_owner("", zone_name), do: ensure_trailing_dot(strip_trailing_dot(zone_name))

  def vultr_name_to_owner(name, zone_name) do
    ensure_trailing_dot("#{name}.#{strip_trailing_dot(zone_name)}")
  end

  @doc false
  @spec owner_to_vultr_name(String.t(), String.t()) :: String.t()
  def owner_to_vultr_name(owner, zone_name) do
    zone_bare = strip_trailing_dot(zone_name)
    owner_bare = strip_trailing_dot(owner)

    cond do
      owner_bare == zone_bare ->
        ""

      String.ends_with?(owner_bare, ".#{zone_bare}") ->
        String.trim_trailing(owner_bare, ".#{zone_bare}")

      owner_bare == "@" ->
        ""

      true ->
        owner_bare
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp apply_additions(_req, _domain, []), do: :ok

  defp apply_additions(req, domain, [record | rest]) do
    body = %{
      "type" => record.type,
      "name" => owner_to_vultr_name(record.owner, domain <> "."),
      "data" => to_string(record.rdata),
      "ttl" => record.ttl
    }

    case Req.post(req, url: "/domains/#{domain}/records", json: body) do
      {:ok, %{status: status}} when status in [200, 201] ->
        apply_additions(req, domain, rest)

      {:ok, %{status: status, body: resp}} ->
        {:error, {:api_error, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_deletions(_req, _domain, _zone_name, []), do: :ok

  defp apply_deletions(req, domain, zone_name, [record | rest]) do
    # Fetch records to find matching ID
    case Req.get(req, url: "/domains/#{domain}/records") do
      {:ok, %{status: 200, body: %{"records" => records}}} ->
        vultr_name = owner_to_vultr_name(record.owner, zone_name)

        matching =
          Enum.find(records, fn r ->
            r["type"] == record.type and
              r["name"] == vultr_name and
              r["data"] == to_string(record.rdata)
          end)

        case matching do
          nil ->
            # Record not found, skip deletion
            apply_deletions(req, domain, zone_name, rest)

          %{"id" => record_id} ->
            case Req.delete(req, url: "/domains/#{domain}/records/#{record_id}") do
              {:ok, %{status: status}} when status in [200, 204] ->
                apply_deletions(req, domain, zone_name, rest)

              {:ok, %{status: status, body: body}} ->
                {:error, {:api_error, status, body}}

              {:error, reason} ->
                {:error, reason}
            end
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_trailing_dot(name) when is_binary(name) do
    if String.ends_with?(name, "."), do: name, else: name <> "."
  end

  defp strip_trailing_dot(name) when is_binary(name) do
    String.trim_trailing(name, ".")
  end
end
