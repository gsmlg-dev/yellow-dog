defmodule YellowDog.Management.CloudDns.Route53 do
  @moduledoc false

  @host "route53.amazonaws.com"
  @version "2013-04-01"
  @namespace "https://route53.amazonaws.com/doc/#{@version}/"
  @hostedzone_path "/#{@version}/hostedzone"
  @hostedzonesbyname_path "/#{@version}/hostedzonesbyname"
  @max_pages 200
  @max_body 4_000_000
  @editable_types ~w(A AAAA CNAME MX TXT PTR NS)
  @route_fields ~w(SetIdentifier Weight Region GeoLocation Failover MultiValueAnswer AliasTarget HealthCheckId TrafficPolicyInstanceId CidrRoutingConfig GeoProximityLocation)

  def fetch(zone_id, credentials, request \\ &http_request/4) do
    with {:ok, path} <- zone_path(zone_id),
         {:ok, zone} <- get_zone(request, credentials, path),
         {:ok, rrsets} <- records(request, credentials, path <> "/rrset", zone, [], %{}, 0) do
      {:ok, %{name: zone, rrsets: rrsets}}
    end
  end

  def create_zone(name, credentials, request_id, request \\ &http_request/4)

  def create_zone(name, credentials, request_id, request)
      when is_binary(name) and is_binary(request_id) and byte_size(request_id) in 1..256 do
    zone = canonical_name(name)
    reference = "yellow-dog-" <> sha256(zone <> ":" <> request_id)

    with :ok <- validate_zone_name(zone),
         {:ok, current} <- existing_zone(zone, reference, credentials, request) do
      case current do
        nil -> create_public_zone(zone, reference, credentials, request)
        created_id -> {:ok, created_id}
      end
    end
  end

  def create_zone(_name, _credentials, _request_id, _request),
    do: {:error, :invalid_route53_create_request}

  def apply(zone_id, credentials, changes, request \\ &http_request/4)

  def apply(_zone_id, _credentials, [], _request), do: :ok

  def apply(zone_id, credentials, changes, request) do
    with {:ok, path} <- zone_path(zone_id),
         {:ok, zone} <- get_zone(request, credentials, path),
         :ok <- validate_batch(changes, zone),
         {:ok, response} <-
           call(request, credentials, "POST", path <> "/rrset", [], change_batch(changes)) do
      with {:ok, change_info} <- element(response, "ChangeInfo"),
           {:ok, status} when status in ["PENDING", "INSYNC"] <- element(change_info, "Status") do
        :ok
      else
        _ -> {:error, :route53_write_unconfirmed}
      end
    end
  end

  defp zone_path(zone_id) do
    with {:ok, id} <- normalize_zone_id(zone_id), do: {:ok, @hostedzone_path <> "/" <> id}
  end

  defp normalize_zone_id(zone_id) when is_binary(zone_id) do
    id = String.replace_prefix(zone_id, "/hostedzone/", "")

    if Regex.match?(~r/\AZ[A-Z0-9]{1,63}\z/, id),
      do: {:ok, id},
      else: {:error, :invalid_hosted_zone_id}
  end

  defp normalize_zone_id(_zone_id), do: {:error, :invalid_hosted_zone_id}

  defp validate_zone_name(name) do
    labels = name |> String.trim_trailing(".") |> String.split(".")

    if byte_size(name) <= 254 and
         Enum.all?(labels, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1)),
       do: :ok,
       else: {:error, :invalid_route53_zone_name}
  end

  defp existing_zone(zone, reference, credentials, request) do
    query = [{"dnsname", zone}, {"maxitems", "100"}]

    with {:ok, matches} <- hosted_zone_matches(request, credentials, zone, query, [], 0) do
      case matches do
        [] -> {:ok, nil}
        [%{id: id, reference: ^reference}] -> {:ok, id}
        _ -> {:error, :remote_zone_exists}
      end
    end
  end

  defp hosted_zone_matches(_request, _credentials, _zone, _query, _matches, @max_pages),
    do: {:error, :route53_zone_search_too_large}

  defp hosted_zone_matches(request, credentials, zone, query, matches, page) do
    with {:ok, response} <- call(request, credentials, "GET", @hostedzonesbyname_path, query, ""),
         {:ok, hosted_zones} <- container(response, "HostedZones"),
         {:ok, found} <- matching_zone_entries(hosted_zones, zone),
         {:ok, next} <- hosted_zone_next_page(response, zone) do
      case next do
        [] ->
          {:ok, Enum.reverse(found, matches)}

        ^query ->
          {:error, :invalid_route53_pagination}

        _ ->
          hosted_zone_matches(
            request,
            credentials,
            zone,
            next,
            Enum.reverse(found, matches),
            page + 1
          )
      end
    end
  end

  defp matching_zone_entries(xml, zone) do
    entry = ~r/<HostedZone>(.*?)<\/HostedZone>/s

    if String.trim(Regex.replace(entry, xml, "")) == "" do
      entry
      |> Regex.scan(xml, capture: :all_but_first)
      |> Enum.reduce_while({:ok, []}, fn [hosted_zone], {:ok, acc} ->
        case hosted_zone_entry(hosted_zone) do
          {:ok, %{name: ^zone} = match} -> {:cont, {:ok, [match | acc]}}
          {:ok, _other_zone} -> {:cont, {:ok, acc}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    else
      {:error, :invalid_route53_response}
    end
  end

  defp hosted_zone_entry(xml) do
    with {:ok, name} when name != "" <- unescaped_element(xml, "Name"),
         {:ok, id} <- unescaped_element(xml, "Id"),
         {:ok, id} <- normalize_zone_id(id),
         {:ok, reference} <- unescaped_element(xml, "CallerReference") do
      {:ok, %{id: id, name: canonical_name(name), reference: reference}}
    else
      _ -> {:error, :invalid_route53_response}
    end
  end

  defp hosted_zone_next_page(response, zone) do
    case element(response, "IsTruncated") do
      {:ok, "false"} ->
        {:ok, []}

      {:ok, "true"} ->
        with {:ok, name} when name != "" <- unescaped_element(response, "NextDNSName"),
             {:ok, id} <- unescaped_element(response, "NextHostedZoneId"),
             {:ok, id} <- normalize_zone_id(id) do
          if canonical_name(name) == zone,
            do: {:ok, [{"dnsname", name}, {"hostedzoneid", id}, {"maxitems", "100"}]},
            else: {:ok, []}
        else
          _ -> {:error, :invalid_route53_pagination}
        end

      _ ->
        {:error, :invalid_route53_pagination}
    end
  end

  defp create_public_zone(zone, reference, credentials, request) do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <CreateHostedZoneRequest xmlns="#{@namespace}">
      <Name>#{escape(zone)}</Name><CallerReference>#{reference}</CallerReference>
    </CreateHostedZoneRequest>
    """

    result =
      with {:ok, response} <- call(request, credentials, "POST", @hostedzone_path, [], xml, 201),
           {:ok, hosted_zone} <- element(response, "HostedZone"),
           {:ok, %{id: id, name: ^zone, reference: ^reference}} <- hosted_zone_entry(hosted_zone) do
        {:ok, id}
      else
        {:error, reason} when reason in [:route53_access_denied, :route53_change_rejected] ->
          {:error, reason}

        _ ->
          {:error, :route53_write_unconfirmed}
      end

    case result do
      {:ok, id} ->
        {:ok, id}

      {:error, reason} when reason in [:route53_write_unconfirmed, :route53_change_rejected] ->
        case existing_zone(zone, reference, credentials, request) do
          {:ok, recovered} when is_binary(recovered) -> {:ok, recovered}
          {:error, :remote_zone_exists} = conflict -> conflict
          _ -> result
        end

      error ->
        error
    end
  end

  defp get_zone(request, credentials, path) do
    with {:ok, response} <- call(request, credentials, "GET", path, [], ""),
         {:ok, hosted_zone} <- element(response, "HostedZone"),
         {:ok, name} <- element(hosted_zone, "Name"),
         {:ok, name} <- unescape(name),
         true <- name != "" do
      {:ok, canonical_name(name)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_route53_response}
    end
  end

  defp records(_request, _credentials, _path, _zone, _query, _sets, @max_pages),
    do: {:error, :route53_zone_too_large}

  defp records(request, credentials, path, zone, query, sets, page) do
    with {:ok, response} <- call(request, credentials, "GET", path, query, ""),
         {:ok, rrsets} <- container(response, "ResourceRecordSets"),
         {:ok, sets} <- merge_page(rrsets, zone, sets),
         {:ok, next} <- next_page(response) do
      case next do
        [] -> {:ok, sets}
        ^query -> {:error, :invalid_route53_pagination}
        _ -> records(request, credentials, path, zone, next, sets, page + 1)
      end
    end
  end

  defp next_page(response) do
    case element(response, "IsTruncated") do
      {:ok, "false"} ->
        {:ok, []}

      {:ok, "true"} ->
        with {:ok, name} <- unescaped_element(response, "NextRecordName"),
             {:ok, type} <- unescaped_element(response, "NextRecordType"),
             true <- name != "" and type != "" do
          query = [{"name", name}, {"type", type}]

          case unescaped_element(response, "NextRecordIdentifier") do
            {:ok, identifier} -> {:ok, [{"identifier", identifier} | query]}
            {:error, :missing_element} -> {:ok, query}
            {:error, _} = error -> error
          end
        else
          _ -> {:error, :invalid_route53_pagination}
        end

      _ ->
        {:error, :invalid_route53_pagination}
    end
  end

  defp merge_page(xml, zone, sets) do
    rrsets = ~r/<ResourceRecordSet>(.*?)<\/ResourceRecordSet>/s
    entries = Regex.scan(rrsets, xml, capture: :all_but_first)

    if String.trim(Regex.replace(rrsets, xml, "")) == "" do
      Enum.reduce_while(entries, {:ok, sets}, fn [entry], {:ok, acc} ->
        case parse_set(entry, zone) do
          {:ok, key, rrset} ->
            {:cont, {:ok, Map.update(acc, key, rrset, &merge_sets(&1, rrset))}}

          {:error, _} = error ->
            {:halt, error}
        end
      end)
    else
      {:error, :invalid_route53_response}
    end
  end

  defp parse_set(xml, zone) do
    with {:ok, name} <- unescaped_element(xml, "Name"),
         {:ok, type} <- unescaped_element(xml, "Type"),
         {:ok, ttl} <- ttl(xml),
         {:ok, values} <- values(xml),
         true <- name != "" and type != "" do
      name = canonical_name(name)
      routed? = Enum.any?(@route_fields, &String.contains?(xml, "<#{&1}>"))
      protected? = routed? or not mutable_key?({name, type}, zone)

      set = %{ttl: ttl, values: values, protected: protected?}
      set = if routed?, do: Map.put(set, :provider_details, [sha256(xml)]), else: set

      {:ok, {name, type}, set}
    else
      _ -> {:error, :invalid_route53_response}
    end
  end

  defp ttl(xml) do
    case element(xml, "TTL") do
      {:ok, value} ->
        case Integer.parse(value) do
          {ttl, ""} when ttl >= 0 -> {:ok, ttl}
          _ -> {:error, :invalid_route53_response}
        end

      {:error, :missing_element} ->
        # Alias records have no TTL or resource records.
        if String.contains?(xml, "<AliasTarget>"),
          do: {:ok, 0},
          else: {:error, :invalid_route53_response}

      {:error, _} = error ->
        error
    end
  end

  defp values(xml) do
    case element(xml, "ResourceRecords") do
      {:ok, section} ->
        records = ~r/<ResourceRecord>\s*<Value>([^<]*)<\/Value>\s*<\/ResourceRecord>/s

        if String.trim(Regex.replace(records, section, "")) == "" do
          records
          |> Regex.scan(section, capture: :all_but_first)
          |> Enum.reduce_while({:ok, []}, fn [value], {:ok, acc} ->
            case unescape(value) do
              {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
              {:error, _} = error -> {:halt, error}
            end
          end)
          |> case do
            {:ok, [_ | _] = list} -> {:ok, Enum.sort(list)}
            _ -> {:error, :invalid_route53_response}
          end
        else
          {:error, :invalid_route53_response}
        end

      {:error, :missing_element} ->
        if String.contains?(xml, "<AliasTarget>"),
          do: {:ok, []},
          else: {:error, :invalid_route53_response}

      {:error, _} = error ->
        error
    end
  end

  defp merge_sets(left, right) do
    %{
      ttl: min(left.ttl, right.ttl),
      values: Enum.sort(Enum.uniq(left.values ++ right.values)),
      protected: true,
      provider_details:
        Enum.sort(Map.get(left, :provider_details, []) ++ Map.get(right, :provider_details, []))
    }
  end

  defp mutable_key?({name, type}, zone) do
    type in @editable_types and (name != zone or type != "NS") and
      (name == zone or String.ends_with?(name, "." <> zone))
  end

  defp validate_batch(changes, zone) when is_list(changes) do
    with true <- Enum.all?(changes, &valid_change?(&1, zone)),
         true <- Enum.uniq_by(changes, & &1.key) == changes,
         true <- Enum.sum(Enum.map(changes, &change_size/1)) <= 1000 do
      :ok
    else
      _ -> {:error, :invalid_route53_change_batch}
    end
  end

  defp validate_batch(_, _zone), do: {:error, :invalid_route53_change_batch}

  defp valid_change?(%{key: {name, type} = key, before: before, after: next}, zone)
       when is_binary(name) and is_binary(type) do
    name == canonical_name(name) and mutable_key?(key, zone) and
      (before != nil or next != nil) and valid_set?(before) and valid_set?(next)
  end

  defp valid_change?(_, _zone), do: false

  defp valid_set?(nil), do: true

  defp valid_set?(%{protected: false, ttl: ttl, values: [_ | _] = values})
       when is_integer(ttl) and ttl >= 0,
       do: Enum.all?(values, &is_binary/1)

  defp valid_set?(_), do: false

  defp change_size(%{before: before, after: next}) do
    [before, next]
    |> Enum.reject(&is_nil/1)
    |> Enum.sum_by(&length(&1.values))
  end

  defp change_batch(changes) do
    # Route 53 validates DELETE against the exact existing set. Pairing DELETE
    # and CREATE preserves that check for edits and keeps the batch atomic.
    deletes =
      for %{key: key, before: before} <- changes, before, do: xml_set("DELETE", key, before)

    creates = for %{key: key, after: next} <- changes, next, do: xml_set("CREATE", key, next)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ChangeResourceRecordSetsRequest xmlns="#{@namespace}">
      <ChangeBatch><Changes>#{Enum.join(deletes ++ creates)}</Changes></ChangeBatch>
    </ChangeResourceRecordSetsRequest>
    """
  end

  defp xml_set(action, {name, type}, set) do
    records =
      Enum.map_join(set.values, fn value ->
        "<ResourceRecord><Value>#{escape(value)}</Value></ResourceRecord>"
      end)

    """
    <Change><Action>#{action}</Action><ResourceRecordSet>
    <Name>#{escape(name)}</Name><Type>#{type}</Type><TTL>#{set.ttl}</TTL>
    <ResourceRecords>#{records}</ResourceRecords>
    </ResourceRecordSet></Change>
    """
  end

  defp container(xml, tag) do
    case element(xml, tag) do
      {:error, :missing_element} -> {:error, :invalid_route53_response}
      result -> result
    end
  end

  defp unescaped_element(xml, tag) do
    with {:ok, value} <- element(xml, tag), do: unescape(value)
  end

  defp element(xml, tag) do
    # Only fixed AWS response tags are matched. Do not expand XML entities or DTDs.
    case Regex.run(~r/<#{tag}>(.*?)<\/#{tag}>|<#{tag}\s*\/>/s, xml) do
      [_match, value] -> {:ok, value}
      [_match] -> {:ok, ""}
      nil -> {:error, :missing_element}
    end
  end

  defp canonical_name(name), do: String.downcase(String.trim_trailing(name, ".")) <> "."

  defp escape(value) do
    String.replace(value, ["&", "<", ">", "\"", "'"], fn
      "&" -> "&amp;"
      "<" -> "&lt;"
      ">" -> "&gt;"
      "\"" -> "&quot;"
      "'" -> "&apos;"
    end)
  end

  defp unescape(value) do
    entity = ~r/&(?:amp|lt|gt|quot|apos|#[0-9]{1,7}|#x[0-9a-fA-F]{1,6});/

    if String.contains?(Regex.replace(entity, value, ""), ["&", "<"]) do
      {:error, :invalid_route53_response}
    else
      try do
        {:ok, Regex.replace(entity, value, &decode_entity/1)}
      catch
        :invalid_xml_character -> {:error, :invalid_route53_response}
      end
    end
  end

  defp decode_entity("&amp;"), do: "&"
  defp decode_entity("&lt;"), do: "<"
  defp decode_entity("&gt;"), do: ">"
  defp decode_entity("&quot;"), do: "\""
  defp decode_entity("&apos;"), do: "'"
  defp decode_entity("&#x" <> hex), do: decode_character(hex, 16)
  defp decode_entity("&#" <> decimal), do: decode_character(decimal, 10)

  defp decode_character(digits, base) do
    {value, ";"} = Integer.parse(digits, base)

    if value in [9, 10, 13] or value in 32..0xD7FF or value in 0xE000..0xFFFD or
         value in 0x10000..0x10FFFF,
       do: <<value::utf8>>,
       else: throw(:invalid_xml_character)
  end

  defp call(request, credentials, method, path, query, body, expected_status \\ 200) do
    query = canonical_query(query)

    with {:ok, headers} <-
           signed_headers(credentials, method, path, query, body, DateTime.utc_now()) do
      case request.(method, target(path, query), headers, body) do
        {:ok, ^expected_status, response} when is_binary(response) ->
          if byte_size(response) <= @max_body and String.valid?(response) and
               not String.contains?(response, ["<!DOCTYPE", "<!ENTITY"]),
             do: {:ok, response},
             else: {:error, :invalid_route53_response}

        {:ok, status, _response} when status in [401, 403] ->
          {:error, :route53_access_denied}

        {:ok, 404, _response} ->
          {:error, :route53_zone_not_found}

        {:ok, 400, _response} when method == "POST" ->
          {:error, :route53_change_rejected}

        _ ->
          if method == "POST",
            do: {:error, :route53_write_unconfirmed},
            else: {:error, :route53_unavailable}
      end
    end
  end

  defp target(path, ""), do: "https://#{@host}#{path}"
  defp target(path, query), do: "https://#{@host}#{path}?#{query}"

  defp canonical_query(query) do
    query
    |> Enum.map(fn {key, value} -> {encode(key), encode(value)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {key, value} -> key <> "=" <> value end)
  end

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  @doc false
  def signed_headers(
        %{"access_key_id" => key, "secret_access_key" => secret} = credentials,
        method,
        path,
        query,
        body,
        now
      )
      when is_binary(key) and is_binary(secret) do
    token = Map.get(credentials, "session_token")

    if Regex.match?(~r/\A[A-Z0-9]{8,128}\z/, key) and secret != "" and valid_token?(token) do
      date = Calendar.strftime(now, "%Y%m%d")
      timestamp = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
      payload_hash = sha256(body)

      headers = [
        {"host", @host},
        {"x-amz-content-sha256", payload_hash},
        {"x-amz-date", timestamp}
      ]

      headers =
        if token in ["", nil], do: headers, else: headers ++ [{"x-amz-security-token", token}]

      header_names = Enum.map_join(headers, ";", &elem(&1, 0))

      canonical_headers =
        Enum.map_join(headers, fn {name, value} -> name <> ":" <> value <> "\n" end)

      canonical =
        Enum.join([method, path, query, canonical_headers, header_names, payload_hash], "\n")

      scope = date <> "/us-east-1/route53/aws4_request"
      to_sign = Enum.join(["AWS4-HMAC-SHA256", timestamp, scope, sha256(canonical)], "\n")

      signing_key =
        Enum.reduce([date, "us-east-1", "route53", "aws4_request"], "AWS4" <> secret, fn value,
                                                                                         acc ->
          hmac(acc, value)
        end)

      signature = signing_key |> hmac(to_sign) |> Base.encode16(case: :lower)

      authorization =
        "AWS4-HMAC-SHA256 Credential=#{key}/#{scope}, SignedHeaders=#{header_names}, Signature=#{signature}"

      {:ok, [{"authorization", authorization} | headers]}
    else
      {:error, :invalid_route53_credentials}
    end
  end

  def signed_headers(_credentials, _method, _path, _query, _body, _now),
    do: {:error, :invalid_route53_credentials}

  defp valid_token?(nil), do: true
  defp valid_token?(token) when is_binary(token), do: Regex.match?(~r/\A[!-~]*\z/, token)
  defp valid_token?(_), do: false

  defp hmac(key, value), do: :crypto.mac(:hmac, :sha256, key, value)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp http_request(method, url, headers, body) do
    options = [
      method: method,
      headers: headers,
      timeout: 8_000,
      connect_timeout: 4_000,
      max_decoded_body_size: @max_body,
      redirect: :error,
      retry: false,
      http_version: :http1,
      stream_response: false,
      telemetry: false
    ]

    options =
      if method == "POST",
        do: Keyword.merge(options, body: body, content_type: "application/xml"),
        else: options

    case url |> HTTP.fetch(options) |> HTTP.Promise.await() do
      %HTTP.Response{status: status} = response -> {:ok, status, HTTP.Response.text(response)}
      {:error, _} -> {:error, :route53_unavailable}
    end
  end
end
