defmodule YellowDog.Dns.CloudDnsSync do
  @moduledoc """
  Pulls records from a configured Cloud DNS provider into an auth zone.
  """

  alias YellowDog.Dns.ZoneController
  alias YellowDog.Dns.View
  alias YellowDog.Dns.ViewManager
  alias YellowDog.Store.Provider, as: StoreProvider
  alias YellowDog.Store.Zone, as: StoreZone

  require Record

  Record.defrecordp(:xmlElement, Record.extract(:xmlElement, from_lib: "xmerl/include/xmerl.hrl"))
  Record.defrecordp(:xmlText, Record.extract(:xmlText, from_lib: "xmerl/include/xmerl.hrl"))

  @cloudflare_api "https://api.cloudflare.com/client/v4"
  @route53_api "https://route53.amazonaws.com"
  @route53_host "route53.amazonaws.com"
  @route53_service "route53"
  @route53_signing_region "us-east-1"
  @automatic_ttl 300
  @empty_payload_hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  @type sync_result :: %{
          provider: :cloudflare | :route53,
          records_synced: non_neg_integer()
        }

  @spec sync_zone_from_cloud(String.t(), String.t(), keyword()) ::
          {:ok, sync_result()} | {:error, term()}
  def sync_zone_from_cloud(view_name, zone_name, opts \\ [])
      when is_binary(view_name) and is_binary(zone_name) do
    zone_store = Keyword.get(opts, :zone_store, StoreZone)
    provider_store = Keyword.get(opts, :provider_store, StoreProvider)
    zone_controller = Keyword.get(opts, :zone_controller, ZoneController)

    with {:ok, zone} <- zone_store.get_zone(view_name, zone_name),
         {:ok, mirror} <- cloud_mirror(zone),
         {:ok, connector} <- provider_store.get_config(mirror.connector_name),
         :ok <- connector_enabled(connector),
         {:ok, records} <- fetch_records(connector, mirror, zone_name, opts),
         {:ok, changed_count} <-
           replace_and_activate(zone_store, zone_controller, view_name, zone_name, records),
         :ok <- invalidate_zone_cache(view_name, zone_name, opts) do
      {:ok, %{provider: connector_type(connector), records_synced: changed_count}}
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
      :route53 -> fetch_route53_records(connector, mirror, zone_name, opts)
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

  defp fetch_route53_records(connector, mirror, zone_name, opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)

    with {:ok, credentials} <- route53_credentials(connector),
         {:ok, zone_id} <- route53_zone_id(mirror, zone_name, credentials, request_fun, opts),
         {:ok, record_sets} <- route53_record_sets(zone_id, credentials, request_fun, opts) do
      records = Enum.flat_map(record_sets, &route53_record_set_to_store/1)

      {:ok, records}
    end
  end

  defp route53_credentials(connector) do
    credentials = value(connector, :credentials, %{})

    access_key_id =
      credentials
      |> value(:access_key_id, "")
      |> to_string()
      |> String.trim()

    secret_access_key =
      credentials
      |> value(:secret_access_key, "")
      |> to_string()
      |> String.trim()

    session_token =
      credentials
      |> value(:session_token, "")
      |> to_string()
      |> String.trim()

    cond do
      access_key_id == "" ->
        {:error, :route53_access_key_id_missing}

      secret_access_key == "" ->
        {:error, :route53_secret_access_key_missing}

      true ->
        {:ok,
         %{
           access_key_id: access_key_id,
           secret_access_key: secret_access_key,
           region: @route53_signing_region,
           session_token: if(session_token == "", do: nil, else: session_token)
         }}
    end
  end

  defp route53_zone_id(mirror, zone_name, credentials, request_fun, opts) do
    zone_id =
      mirror
      |> value(:zone_id, "")
      |> normalize_route53_zone_id()

    if zone_id == "" do
      route53_zone_id_by_name(zone_name, credentials, request_fun, opts)
    else
      {:ok, zone_id}
    end
  end

  defp route53_zone_id_by_name(zone_name, credentials, request_fun, opts) do
    params = [dnsname: route53_dns_name(zone_name), maxitems: 1]

    with {:ok, doc} <-
           route53_get("/2013-04-01/hostedzonesbyname", params, credentials, request_fun, opts) do
      expected_name = normalize_domain(zone_name)

      doc
      |> xpath_nodes(~c"//HostedZone")
      |> Enum.map(fn zone ->
        %{
          id: zone |> xpath_text(~c"Id") |> normalize_route53_zone_id(),
          name: xpath_text(zone, ~c"Name")
        }
      end)
      |> Enum.find(fn zone -> normalize_domain(zone.name) == expected_name end)
      |> case do
        %{id: id} when id != "" -> {:ok, id}
        _zone -> {:error, :route53_zone_not_found}
      end
    end
  end

  defp route53_record_sets(zone_id, credentials, request_fun, opts) do
    route53_record_sets(zone_id, credentials, request_fun, opts, [maxitems: 100], [])
  end

  defp route53_record_sets(zone_id, credentials, request_fun, opts, params, acc) do
    path = "/2013-04-01/hostedzone/#{aws_uri_encode(zone_id)}/rrset"

    with {:ok, doc} <- route53_get(path, params, credentials, request_fun, opts),
         {:ok, page} <- route53_record_sets_from_xml(doc) do
      acc = acc ++ page.record_sets

      cond do
        not page.truncated? ->
          {:ok, acc}

        page.next_record_name == "" or page.next_record_type == "" ->
          {:error, :route53_invalid_pagination}

        true ->
          route53_record_sets(
            zone_id,
            credentials,
            request_fun,
            opts,
            route53_next_page_params(page),
            acc
          )
      end
    end
  end

  defp route53_next_page_params(page) do
    params = [
      maxitems: 100,
      name: page.next_record_name,
      type: page.next_record_type
    ]

    if page.next_record_identifier == "" do
      params
    else
      Keyword.put(params, :identifier, page.next_record_identifier)
    end
  end

  defp route53_get(path, params, credentials, request_fun, opts) do
    query = canonical_query_string(params)
    url = @route53_api <> path <> if(query == "", do: "", else: "?#{query}")

    request_fun.(
      method: :get,
      url: url,
      headers: route53_signed_headers(path, query, credentials, opts)
    )
    |> normalize_route53_response()
  end

  defp route53_signed_headers(path, query, credentials, opts) do
    amz_date =
      opts
      |> Keyword.get_lazy(:request_time, &DateTime.utc_now/0)
      |> aws_datetime()

    date = String.slice(amz_date, 0, 8)
    credential_scope = "#{date}/#{credentials.region}/#{@route53_service}/aws4_request"

    signed_headers =
      [
        {"host", @route53_host},
        {"x-amz-content-sha256", @empty_payload_hash},
        {"x-amz-date", amz_date}
      ]
      |> maybe_add_security_token(credentials.session_token)
      |> Enum.sort_by(fn {name, _value} -> name end)

    signed_header_names =
      signed_headers
      |> Enum.map(fn {name, _value} -> name end)
      |> Enum.join(";")

    canonical_headers =
      signed_headers
      |> Enum.map(fn {name, value} -> "#{name}:#{canonical_header_value(value)}\n" end)
      |> Enum.join()

    canonical_request =
      ["GET", path, query, canonical_headers, signed_header_names, @empty_payload_hash]
      |> Enum.join("\n")

    string_to_sign =
      [
        "AWS4-HMAC-SHA256",
        amz_date,
        credential_scope,
        sha256_hex(canonical_request)
      ]
      |> Enum.join("\n")

    signature =
      credentials.secret_access_key
      |> route53_signing_key(date, credentials.region)
      |> hmac(string_to_sign)
      |> Base.encode16(case: :lower)

    authorization =
      "AWS4-HMAC-SHA256 " <>
        "Credential=#{credentials.access_key_id}/#{credential_scope}, " <>
        "SignedHeaders=#{signed_header_names}, Signature=#{signature}"

    [{"authorization", authorization}, {"accept", "application/xml"} | signed_headers]
  end

  defp maybe_add_security_token(headers, nil), do: headers
  defp maybe_add_security_token(headers, ""), do: headers
  defp maybe_add_security_token(headers, token), do: [{"x-amz-security-token", token} | headers]

  defp route53_signing_key(secret_access_key, date, region) do
    ("AWS4" <> secret_access_key)
    |> hmac(date)
    |> hmac(region)
    |> hmac(@route53_service)
    |> hmac("aws4_request")
  end

  defp normalize_route53_response({:ok, %{status: status, body: body}})
       when status >= 200 and status < 300 do
    parse_route53_xml(body)
  end

  defp normalize_route53_response({:ok, %{status: status, body: body}}) do
    {:error, {:route53_http_error, status, route53_errors(body)}}
  end

  defp normalize_route53_response({:error, reason}) do
    {:error, {:route53_request_failed, reason}}
  end

  defp route53_errors(body) do
    case parse_route53_xml(body) do
      {:ok, doc} ->
        doc
        |> xpath_nodes(~c"//Message")
        |> Enum.map(&xml_node_text/1)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(3)

      {:error, _reason} ->
        []
    end
  end

  defp parse_route53_xml(body) do
    body
    |> body_to_string()
    |> String.to_charlist()
    |> :xmerl_scan.string(quiet: true)
    |> case do
      {doc, _rest} -> {:ok, doc}
    end
  rescue
    _error -> {:error, :route53_invalid_xml}
  catch
    _kind, _reason -> {:error, :route53_invalid_xml}
  end

  defp route53_record_sets_from_xml(doc) do
    record_sets =
      doc
      |> xpath_nodes(~c"//ResourceRecordSet")
      |> Enum.map(&route53_record_set_from_xml/1)

    {:ok,
     %{
       record_sets: record_sets,
       truncated?: doc |> xpath_text(~c"//IsTruncated") |> route53_truthy?(),
       next_record_name: xpath_text(doc, ~c"//NextRecordName"),
       next_record_type: xpath_text(doc, ~c"//NextRecordType"),
       next_record_identifier: xpath_text(doc, ~c"//NextRecordIdentifier")
     }}
  end

  defp route53_record_set_from_xml(record_set) do
    values =
      record_set
      |> xpath_nodes(~c"ResourceRecords/ResourceRecord/Value")
      |> Enum.map(&xml_node_text/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{
      name: xpath_text(record_set, ~c"Name"),
      type: xpath_text(record_set, ~c"Type"),
      ttl: record_set |> xpath_text(~c"TTL") |> normalize_route53_ttl(),
      values: values
    }
  end

  defp route53_record_set_to_store(%{name: name, type: type, ttl: ttl, values: values}) do
    owner = normalize_domain(name)
    type = type |> to_string() |> String.upcase()

    Enum.flat_map(values, fn value ->
      case route53_record_value_to_store(owner, type, value, ttl) do
        {:ok, record} -> [record]
        :skip -> []
      end
    end)
  end

  defp route53_record_value_to_store(owner, "A", value, ttl) do
    if owner != "" and valid_ip?(value, :inet) do
      {:ok, %{owner: owner, type: :a, rdata: %{address: value, ttl: ttl}}}
    else
      :skip
    end
  end

  defp route53_record_value_to_store(owner, "AAAA", value, ttl) do
    if owner != "" and valid_ip?(value, :inet6) do
      {:ok, %{owner: owner, type: :aaaa, rdata: %{address: value, ttl: ttl}}}
    else
      :skip
    end
  end

  defp route53_record_value_to_store(owner, "NS", value, ttl) do
    route53_domain_record(owner, :ns, :nsdname, value, ttl)
  end

  defp route53_record_value_to_store(owner, "CNAME", value, ttl) do
    route53_domain_record(owner, :cname, :cname, value, ttl)
  end

  defp route53_record_value_to_store(owner, "PTR", value, ttl) do
    route53_domain_record(owner, :ptr, :ptrdname, value, ttl)
  end

  defp route53_record_value_to_store(owner, "MX", value, ttl) do
    case String.split(String.trim(value), ~r/\s+/, parts: 2) do
      [preference, exchange] ->
        {:ok,
         %{
           owner: owner,
           type: :mx,
           rdata: %{
             preference: normalize_integer(preference, 10),
             exchange: normalize_domain(exchange),
             ttl: ttl
           }
         }}

      _parts ->
        :skip
    end
  end

  defp route53_record_value_to_store(owner, "TXT", value, ttl) do
    txtdata = route53_txt_value(value)

    if owner == "" or txtdata == "" do
      :skip
    else
      {:ok, %{owner: owner, type: :txt, rdata: %{txtdata: txtdata, ttl: ttl}}}
    end
  end

  defp route53_record_value_to_store(owner, "SRV", value, ttl) do
    case String.split(String.trim(value), ~r/\s+/, parts: 4) do
      [priority, weight, port, target] ->
        {:ok,
         %{
           owner: owner,
           type: :srv,
           rdata: %{
             priority: normalize_integer(priority, 0),
             weight: normalize_integer(weight, 0),
             port: normalize_integer(port, 0),
             target: normalize_domain(target),
             ttl: ttl
           }
         }}

      _parts ->
        :skip
    end
  end

  defp route53_record_value_to_store(owner, "CAA", value, ttl) do
    case String.split(String.trim(value), ~r/\s+/, parts: 3) do
      [flags, tag, caa_value] ->
        {:ok,
         %{
           owner: owner,
           type: :caa,
           rdata: %{
             flags: normalize_integer(flags, 0),
             tag: tag,
             value: route53_txt_value(caa_value),
             ttl: ttl
           }
         }}

      _parts ->
        :skip
    end
  end

  defp route53_record_value_to_store(_owner, _type, _value, _ttl), do: :skip

  defp route53_domain_record(owner, type, field, value, ttl) do
    target = normalize_domain(value)

    if owner == "" or target == "" do
      :skip
    else
      {:ok, %{owner: owner, type: type, rdata: %{field => target, ttl: ttl}}}
    end
  end

  defp route53_dns_name(zone_name) do
    zone_name = normalize_domain(zone_name)

    if zone_name == "" do
      ""
    else
      zone_name <> "."
    end
  end

  defp normalize_route53_zone_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace_prefix("/hostedzone/", "")
  end

  defp normalize_route53_ttl(value) do
    case normalize_integer(value, @automatic_ttl) do
      ttl when ttl > 0 -> ttl
      _ttl -> @automatic_ttl
    end
  end

  defp route53_truthy?("true"), do: true
  defp route53_truthy?("TRUE"), do: true
  defp route53_truthy?(true), do: true
  defp route53_truthy?(_value), do: false

  defp route53_txt_value(value) do
    value = String.trim(value)

    case Regex.scan(~r/"((?:\\.|[^"])*)"/, value, capture: :all_but_first) do
      [] ->
        value

      chunks ->
        chunks
        |> Enum.map(fn [chunk] -> unescape_route53_quoted(chunk) end)
        |> Enum.join()
    end
  end

  defp unescape_route53_quoted(value) do
    value
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  defp canonical_query_string(params) do
    params
    |> Enum.reject(fn {_key, value} -> is_nil(value) or to_string(value) == "" end)
    |> Enum.map(fn {key, value} -> {aws_uri_encode(key), aws_uri_encode(value)} end)
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)
    |> Enum.join("&")
  end

  defp aws_uri_encode(value) do
    value
    |> to_string()
    |> URI.encode(&aws_unreserved?/1)
  end

  defp aws_unreserved?(char)
       when char in ?A..?Z
       when char in ?a..?z
       when char in ?0..?9
       when char in [?-, ?_, ?., ?~],
       do: true

  defp aws_unreserved?(_char), do: false

  defp canonical_header_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp aws_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_unix(:second)
    |> DateTime.from_unix!()
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp sha256_hex(data) do
    :crypto.hash(:sha256, data)
    |> Base.encode16(case: :lower)
  end

  defp xpath_nodes(node, path), do: :xmerl_xpath.string(path, node)

  defp xpath_text(node, path) do
    node
    |> xpath_nodes(path)
    |> Enum.map(&xml_node_text/1)
    |> Enum.join()
    |> String.trim()
  end

  defp xml_node_text(xmlText(value: value)), do: to_string(value)

  defp xml_node_text(xmlElement(content: content)) do
    Enum.map_join(content, "", &xml_node_text/1)
  end

  defp xml_node_text(_node), do: ""

  defp body_to_string(body) when is_binary(body), do: body
  defp body_to_string(body) when is_list(body), do: to_string(body)
  defp body_to_string(body), do: inspect(body)

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

  defp replace_and_activate(zone_store, zone_controller, view_name, zone_name, records) do
    desired_records =
      records
      |> Enum.group_by(fn record -> {record.owner, record.type} end)
      |> Enum.map(fn {{owner, type}, rrset_records} ->
        %{owner: owner, type: type, rrset: Enum.map(rrset_records, & &1.rdata)}
      end)

    case zone_store.replace_records(view_name, zone_name, desired_records) do
      {:ok, %{previous: previous, changed_count: changed_count}} when is_list(previous) ->
        case reload_running_zone(zone_controller, view_name, zone_name) do
          :ok ->
            {:ok, changed_count}

          {:error, _reason} ->
            restore_replacement(zone_store, zone_controller, view_name, zone_name, previous)
        end

      {:error, {:rollback_failed, _replace_reason, _rollback_reason}} ->
        {:error, :rollback_failed}

      {:error, _reason} ->
        {:error, :apply_failed}

      _unexpected ->
        {:error, :apply_failed}
    end
  end

  defp restore_replacement(zone_store, zone_controller, view_name, zone_name, previous) do
    with {:ok, _restored} <- zone_store.replace_records(view_name, zone_name, previous),
         :ok <- reload_running_zone(zone_controller, view_name, zone_name) do
      {:error, :apply_failed}
    else
      _failure -> {:error, :rollback_failed}
    end
  end

  defp reload_running_zone(zone_controller, view_name, zone_name) do
    case zone_controller.reload_zone(view_name, :auth, zone_name, []) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  catch
    :exit, _reason -> :ok
  end

  defp invalidate_zone_cache(view_name, zone_name, opts) do
    invalidator = Keyword.get(opts, :cache_invalidator, &invalidate_running_view_cache/2)

    case invalidator.(view_name, zone_name) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
      _other -> :ok
    end
  end

  defp invalidate_running_view_cache(view_name, zone_name) do
    case ViewManager.get_view(view_name) do
      {:ok, view_pid} -> View.invalidate_zone_cache(view_pid, zone_name)
      :error -> :ok
    end
  rescue
    _error -> :ok
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
