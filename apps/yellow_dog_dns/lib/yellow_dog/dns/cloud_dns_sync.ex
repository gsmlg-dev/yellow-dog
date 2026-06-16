defmodule YellowDog.Dns.CloudDnsSync do
  @moduledoc """
  Pulls records from a configured Cloud DNS provider into an auth zone.
  """

  alias YellowDog.Dns.ZoneController
  alias YellowDog.Store.Provider, as: StoreProvider
  alias YellowDog.Store.Zone, as: StoreZone

  @cloudflare_api "https://api.cloudflare.com/client/v4"
  @automatic_ttl 300

  @type sync_result :: %{
          provider: :cloudflare,
          records_synced: non_neg_integer()
        }

  @spec sync_zone_from_cloud(String.t(), String.t(), keyword()) ::
          {:ok, sync_result()} | {:error, term()}
  def sync_zone_from_cloud(view_name, zone_name, opts \\ [])
      when is_binary(view_name) and is_binary(zone_name) do
    with {:ok, zone} <- StoreZone.get_zone(view_name, zone_name),
         {:ok, mirror} <- cloud_mirror(zone),
         {:ok, connector} <- StoreProvider.get_config(mirror.connector_name),
         :ok <- connector_enabled(connector),
         {:ok, records} <- fetch_records(connector, mirror, zone_name, opts),
         :ok <- persist_records(view_name, zone_name, records),
         :ok <- reload_running_zone(view_name, zone_name) do
      {:ok, %{provider: connector_type(connector), records_synced: length(records)}}
    end
  end

  defp cloud_mirror(zone) do
    case value(zone, :cloud_mirror) do
      mirror when is_map(mirror) ->
        enabled? = truthy?(value(mirror, :enabled, false))
        connector_name = mirror |> value(:connector_name, "") |> to_string() |> String.trim()

        cond do
          not enabled? ->
            {:error, :cloud_sync_disabled}

          connector_name == "" ->
            {:error, :cloud_dns_connector_not_configured}

          true ->
            {:ok,
             %{
               connector_name: connector_name,
               zone_id: mirror |> value(:zone_id, "") |> to_string() |> String.trim()
             }}
        end

      _ ->
        {:error, :cloud_sync_disabled}
    end
  end

  defp connector_enabled(connector) do
    if truthy?(value(connector, :enabled, true)) do
      :ok
    else
      {:error, :cloud_dns_connector_disabled}
    end
  end

  defp fetch_records(connector, mirror, zone_name, opts) do
    case connector_type(connector) do
      :cloudflare -> fetch_cloudflare_records(connector, mirror, zone_name, opts)
      provider -> {:error, {:unsupported_provider, provider}}
    end
  end

  defp connector_type(connector) do
    connector
    |> value(:type)
    |> normalize_provider()
  end

  defp normalize_provider(provider) when is_atom(provider), do: provider

  defp normalize_provider(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :unknown
  end

  defp normalize_provider(_provider), do: :unknown

  defp fetch_cloudflare_records(connector, mirror, zone_name, opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)

    with {:ok, token} <- cloudflare_api_token(connector),
         {:ok, zone_id} <- cloudflare_zone_id(mirror, zone_name, token, request_fun),
         {:ok, cloud_records} <- cloudflare_dns_records(zone_id, token, request_fun) do
      records =
        cloud_records
        |> Enum.flat_map(fn record ->
          case cloudflare_record_to_store(record) do
            {:ok, converted} -> [converted]
            :skip -> []
          end
        end)

      {:ok, records}
    end
  end

  defp cloudflare_api_token(connector) do
    token =
      connector
      |> value(:credentials, %{})
      |> value(:api_token, "")
      |> to_string()
      |> String.trim()

    if token == "", do: {:error, :cloudflare_api_token_missing}, else: {:ok, token}
  end

  defp cloudflare_zone_id(%{zone_id: zone_id}, _zone_name, _token, _request_fun)
       when is_binary(zone_id) and zone_id != "" do
    {:ok, zone_id}
  end

  defp cloudflare_zone_id(_mirror, zone_name, token, request_fun) do
    case cloudflare_get("/zones", token, request_fun, name: zone_name, per_page: 1) do
      {:ok, %{"result" => [%{"id" => zone_id} | _]}} when is_binary(zone_id) ->
        {:ok, zone_id}

      {:ok, %{result: [%{id: zone_id} | _]}} when is_binary(zone_id) ->
        {:ok, zone_id}

      {:ok, _body} ->
        {:error, :cloudflare_zone_not_found}

      {:error, _reason} = error ->
        error
    end
  end

  defp cloudflare_dns_records(zone_id, token, request_fun) do
    cloudflare_dns_records(zone_id, token, request_fun, 1, [])
  end

  defp cloudflare_dns_records(zone_id, token, request_fun, page, acc) do
    path = "/zones/#{URI.encode(zone_id)}/dns_records"

    with {:ok, body} <- cloudflare_get(path, token, request_fun, per_page: 100, page: page) do
      records = value(body, :result, [])
      info = value(body, :result_info, %{})
      total_pages = info |> value(:total_pages, 1) |> normalize_positive_integer(1)
      acc = acc ++ records

      if page < total_pages do
        cloudflare_dns_records(zone_id, token, request_fun, page + 1, acc)
      else
        {:ok, acc}
      end
    end
  end

  defp cloudflare_get(path, token, request_fun, params) do
    request_fun.(
      method: :get,
      url: @cloudflare_api <> path,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/json"}
      ],
      params: params
    )
    |> normalize_cloudflare_response()
  end

  defp normalize_cloudflare_response({:ok, %{status: status, body: body}})
       when status >= 200 and status < 300 do
    if value(body, :success, false) == true do
      {:ok, body}
    else
      {:error, {:cloudflare_api_error, cloudflare_errors(body)}}
    end
  end

  defp normalize_cloudflare_response({:ok, %{status: status, body: body}}) do
    {:error, {:cloudflare_http_error, status, cloudflare_errors(body)}}
  end

  defp normalize_cloudflare_response({:error, reason}) do
    {:error, {:cloudflare_request_failed, reason}}
  end

  defp cloudflare_errors(body) do
    body
    |> value(:errors, [])
    |> Enum.map(fn
      error when is_map(error) -> value(error, :message, inspect(error))
      error -> inspect(error)
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(3)
  end

  defp cloudflare_record_to_store(record) when is_map(record) do
    type = record |> value(:type, "") |> to_string() |> String.upcase()
    owner = record |> value(:name, "") |> normalize_domain()
    ttl = record |> value(:ttl, @automatic_ttl) |> normalize_ttl()
    content = record |> value(:content, "") |> to_string() |> String.trim()
    data = value(record, :data, %{})

    cond do
      owner == "" ->
        :skip

      type == "A" and valid_ip?(content, :inet) ->
        {:ok, %{owner: owner, type: :a, rdata: %{address: content, ttl: ttl}}}

      type == "AAAA" and valid_ip?(content, :inet6) ->
        {:ok, %{owner: owner, type: :aaaa, rdata: %{address: content, ttl: ttl}}}

      type == "NS" and content != "" ->
        {:ok, %{owner: owner, type: :ns, rdata: %{nsdname: normalize_domain(content), ttl: ttl}}}

      type == "CNAME" and content != "" ->
        {:ok, %{owner: owner, type: :cname, rdata: %{cname: normalize_domain(content), ttl: ttl}}}

      type == "MX" and content != "" ->
        {:ok,
         %{
           owner: owner,
           type: :mx,
           rdata: %{
             preference:
               record |> value(:priority, value(data, :priority, 10)) |> normalize_integer(10),
             exchange: normalize_domain(content),
             ttl: ttl
           }
         }}

      type == "TXT" and content != "" ->
        {:ok, %{owner: owner, type: :txt, rdata: %{txtdata: content, ttl: ttl}}}

      type == "SRV" ->
        srv_record(owner, data, ttl)

      type == "PTR" and content != "" ->
        {:ok,
         %{owner: owner, type: :ptr, rdata: %{ptrdname: normalize_domain(content), ttl: ttl}}}

      type == "CAA" ->
        caa_record(owner, data, ttl)

      true ->
        :skip
    end
  end

  defp cloudflare_record_to_store(_record), do: :skip

  defp srv_record(owner, data, ttl) when is_map(data) do
    target = data |> value(:target, "") |> to_string() |> String.trim()

    if target == "" do
      :skip
    else
      {:ok,
       %{
         owner: owner,
         type: :srv,
         rdata: %{
           priority: data |> value(:priority, 0) |> normalize_integer(0),
           weight: data |> value(:weight, 0) |> normalize_integer(0),
           port: data |> value(:port, 0) |> normalize_integer(0),
           target: normalize_domain(target),
           ttl: ttl
         }
       }}
    end
  end

  defp srv_record(_owner, _data, _ttl), do: :skip

  defp caa_record(owner, data, ttl) when is_map(data) do
    tag = data |> value(:tag, "") |> to_string() |> String.trim()
    caa_value = data |> value(:value, "") |> to_string() |> String.trim()

    if tag == "" or caa_value == "" do
      :skip
    else
      {:ok,
       %{
         owner: owner,
         type: :caa,
         rdata: %{
           flags: data |> value(:flags, 0) |> normalize_integer(0),
           tag: tag,
           value: caa_value,
           ttl: ttl
         }
       }}
    end
  end

  defp caa_record(_owner, _data, _ttl), do: :skip

  defp persist_records(view_name, zone_name, records) do
    records
    |> Enum.group_by(fn record -> {record.owner, record.type} end)
    |> Enum.reduce_while(:ok, fn {{owner, type}, rrset_records}, :ok ->
      rrset = Enum.map(rrset_records, & &1.rdata)

      case StoreZone.put_rrset(view_name, zone_name, owner, type, rrset) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp reload_running_zone(view_name, zone_name) do
    case ZoneController.reload_zone(view_name, :auth, zone_name, []) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  catch
    :exit, _reason -> :ok
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(_map, _key, default), do: default

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_value), do: false

  defp normalize_domain(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_trailing(".")
  end

  defp normalize_ttl(1), do: @automatic_ttl
  defp normalize_ttl("1"), do: @automatic_ttl

  defp normalize_ttl(value) do
    case normalize_integer(value, @automatic_ttl) do
      ttl when ttl > 1 -> ttl
      _ -> @automatic_ttl
    end
  end

  defp normalize_positive_integer(value, default) do
    case normalize_integer(value, default) do
      int when int > 0 -> int
      _ -> default
    end
  end

  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp valid_ip?(value, family) do
    match?({:ok, _}, value |> String.to_charlist() |> parse_ip(family))
  end

  defp parse_ip(value, :inet), do: :inet.parse_ipv4_address(value)
  defp parse_ip(value, :inet6), do: :inet.parse_ipv6_address(value)
end
