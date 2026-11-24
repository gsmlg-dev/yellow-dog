defmodule YellowDog.Management.CloudDns.Cloudflare do
  @moduledoc "Cloudflare DNS zone inventory and reviewed batch changes."

  @base_url "https://api.cloudflare.com/client/v4"
  @editable ~w(A AAAA CNAME MX NS PTR TXT)
  @domain_types ~w(CNAME NS PTR)
  @page_size 100
  @zone_page_size 25
  @max_pages 500

  @doc "Fetch a zone and all of its records using a zone-scoped API token."
  def fetch(zone_id, credentials, request \\ &http/4) do
    with {:ok, path, token} <- connection(zone_id, credentials),
         {:ok, zone} <- fetch_zone(path, token, request),
         {:ok, records} <- fetch_records(path, token, request, 1, nil, []),
         {:ok, rrsets} <- group_records(records, zone.name) do
      {:ok, Map.put(zone, :rrsets, rrsets)}
    end
  end

  @doc """
  Create a full zone in the configured account after an exact-name lookup.

  Cloudflare does not accept the caller's request ID as an idempotency key.
  After an uncertain result, check the account and link the zone through cloud
  import if creation succeeded. Review the records separately before any push.
  """
  def create_zone(name, credentials, request_id, request \\ &http/4)

  def create_zone(name, %{"account_id" => account_id} = credentials, _request_id, request) do
    with {:ok, token} <- api_token(credentials),
         true <- valid_id?(account_id),
         name when is_binary(name) <- canonical_name(name),
         false <- String.contains?(name, ["*", "_"]),
         account_id = String.downcase(account_id),
         :ok <- zone_absent(name, account_id, token, request, 1, nil) do
      post_zone(name, account_id, token, request)
    else
      {:error, _} = error -> error
      _ -> {:error, :cloudflare_invalid_configuration}
    end
  end

  def create_zone(_name, _credentials, _request_id, _request),
    do: {:error, :cloudflare_invalid_configuration}

  @doc "Apply reviewed changes in one Cloudflare DNS records batch."
  def apply(zone_id, credentials, changes, request \\ &http/4)

  def apply(zone_id, credentials, [], _request) do
    with {:ok, _path, _token} <- connection(zone_id, credentials), do: :ok
  end

  def apply(zone_id, credentials, changes, request) when is_list(changes) do
    with {:ok, path, token} <- connection(zone_id, credentials),
         {:ok, zone} <- fetch_zone(path, token, request),
         {:ok, batch} <- build_batch(changes, zone.name) do
      if Enum.all?(batch, fn {_, ops} -> ops == [] end) do
        :ok
      else
        case call(request, :post, path <> "/dns_records/batch", token, batch) do
          {:ok, %{"result" => result}} when is_map(result) -> :ok
          {:ok, _} -> {:error, :cloudflare_invalid_response}
          {:error, _} = error -> error
        end
      end
    end
  end

  def apply(_zone_id, _credentials, _changes, _request),
    do: {:error, :cloudflare_invalid_changes}

  defp connection(zone_id, credentials) do
    with {:ok, token} <- api_token(credentials),
         true <- valid_id?(zone_id) do
      {:ok, "/zones/" <> String.downcase(zone_id), token}
    else
      _ -> {:error, :cloudflare_invalid_configuration}
    end
  end

  defp api_token(%{"api_token" => token})
       when is_binary(token) and byte_size(token) in 1..4096 do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, token),
      do: {:ok, token},
      else: {:error, :cloudflare_invalid_configuration}
  end

  defp api_token(_credentials), do: {:error, :cloudflare_invalid_configuration}

  defp zone_absent(name, account_id, token, request, page, expected) do
    query =
      URI.encode_query([
        {"account.id", account_id},
        {"name", undot(name)},
        {"match", "all"},
        {"type", "full,partial,secondary,internal"},
        {"page", page},
        {"per_page", @zone_page_size}
      ])

    with {:ok, %{"result" => zones, "result_info" => info}} when is_list(zones) <-
           call(request, :get, "/zones?" <> query, token),
         {:ok, pages} <- page_count(info, page, expected, zones),
         true <- Enum.all?(zones, &valid_zone_identifier?/1) do
      cond do
        Enum.any?(zones, &zone_matches?(&1, name, account_id)) ->
          {:error, :remote_zone_exists}

        page < pages ->
          zone_absent(name, account_id, token, request, page + 1, pages)

        true ->
          :ok
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :cloudflare_invalid_response}
    end
  end

  defp post_zone(name, account_id, token, request) do
    body = %{account: %{id: account_id}, name: undot(name), type: "full"}

    case call(request, :post, "/zones", token, body) do
      {:ok, %{"result" => zone}} ->
        if valid_zone_identifier?(zone) and zone_matches?(zone, name, account_id),
          do: {:ok, String.downcase(zone["id"])},
          else: {:error, :cloudflare_invalid_response}

      {:ok, _} ->
        {:error, :cloudflare_invalid_response}

      {:error, :cloudflare_api_failed} = error ->
        # An account administrator may have created the zone after the first lookup.
        # A second read can detect that case without repeating the write.
        case zone_absent(name, account_id, token, request, 1, nil) do
          {:error, :remote_zone_exists} = conflict -> conflict
          _ -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp valid_zone_identifier?(%{"id" => id, "name" => name, "account" => %{"id" => account}}),
    do: valid_id?(id) and is_binary(canonical_name(name)) and valid_id?(account)

  defp valid_zone_identifier?(_zone), do: false

  defp zone_matches?(
         %{"name" => name, "account" => %{"id" => account}},
         expected_name,
         account_id
       ),
       do: canonical_name(name) == expected_name and String.downcase(account) == account_id

  defp fetch_zone(path, token, request) do
    with {:ok, %{"result" => zone}} when is_map(zone) <- call(request, :get, path, token),
         true <- valid_id?(zone["id"]) and path == "/zones/" <> zone["id"],
         name when is_binary(name) <- canonical_name(zone["name"]),
         nameservers when is_list(nameservers) <- Map.get(zone, "name_servers", []),
         nameservers = Enum.map(nameservers, &canonical_name/1),
         true <- Enum.all?(nameservers, &is_binary/1) do
      {:ok, %{name: name, name_servers: Enum.sort(Enum.uniq(nameservers))}}
    else
      {:error, _} = error -> error
      _ -> {:error, :cloudflare_invalid_response}
    end
  end

  defp fetch_records(path, token, request, page, expected, acc) do
    query = URI.encode_query(page: page, per_page: @page_size, include_shadow_metadata: true)

    with {:ok, %{"result" => records, "result_info" => info}} when is_list(records) <-
           call(request, :get, path <> "/dns_records?" <> query, token),
         {:ok, pages} <- page_count(info, page, expected, records) do
      acc = [records | acc]

      if page < pages,
        do: fetch_records(path, token, request, page + 1, pages, acc),
        else: {:ok, acc |> Enum.reverse() |> Enum.concat()}
    else
      {:error, _} = error -> error
      _ -> {:error, :cloudflare_invalid_response}
    end
  end

  defp page_count(%{"page" => 1, "total_pages" => 0}, 1, nil, []), do: {:ok, 1}

  defp page_count(%{"page" => page, "total_pages" => pages}, page, expected, records)
       when is_integer(pages) and pages >= page and pages <= @max_pages and
              expected in [nil, pages] and length(records) <= @page_size do
    if page == pages or records != [],
      do: {:ok, pages},
      else: {:error, :cloudflare_invalid_response}
  end

  defp page_count(
         %{"page" => page, "total_count" => total, "per_page" => size},
         page,
         expected,
         records
       )
       when is_integer(total) and total >= 0 and is_integer(size) and size > 0 do
    pages = max(1, div(total + size - 1, size))
    page_count(%{"page" => page, "total_pages" => pages}, page, expected, records)
  end

  defp page_count(_info, _page, _expected, _records), do: {:error, :cloudflare_invalid_response}

  defp group_records(records, zone) do
    Enum.reduce_while(records, {:ok, %{}, MapSet.new()}, fn record, {:ok, sets, ids} ->
      with {:ok, key, data} <- read_record(record, zone),
           false <- MapSet.member?(ids, data.id) do
        {:cont, {:ok, Map.update(sets, key, [data], &[data | &1]), MapSet.put(ids, data.id)}}
      else
        _ -> {:halt, {:error, :cloudflare_invalid_response}}
      end
    end)
    |> case do
      {:ok, sets, _ids} -> {:ok, Map.new(sets, fn {key, records} -> {key, rrset(records)} end)}
      {:error, _} = error -> error
    end
  end

  defp read_record(%{"id" => id, "name" => name, "type" => type, "ttl" => ttl} = record, zone)
       when is_binary(type) and is_integer(ttl) and ttl >= 0 do
    with true <- valid_id?(id),
         name when is_binary(name) <- canonical_name(name),
         true <- in_zone?(name, zone),
         value when is_binary(value) <- read_value(type, record) do
      protected = protected_type?({name, type}, zone) or provider_metadata?(record)
      {:ok, {name, type}, %{id: id, ttl: ttl, value: value, protected: protected}}
    else
      _ -> {:error, :cloudflare_invalid_response}
    end
  end

  defp read_record(_record, _zone), do: {:error, :cloudflare_invalid_response}

  defp rrset(records) do
    sorted = Enum.sort_by(records, &{&1.value, &1.id})
    values = sorted |> Enum.map(& &1.value) |> Enum.uniq()
    ttls = sorted |> Enum.map(& &1.ttl) |> Enum.uniq() |> Enum.sort()

    protected =
      Enum.any?(sorted, & &1.protected) or length(ttls) > 1 or length(values) < length(sorted)

    %{
      ttl: hd(ttls),
      values: values,
      protected: protected,
      records: Enum.map(sorted, &Map.take(&1, [:id, :ttl, :value]))
    }
  end

  defp provider_metadata?(record) do
    record["proxied"] == true or record["locked"] == true or
      record["comment"] not in [nil, ""] or record["tags"] not in [nil, []] or
      active_metadata?(record["meta"]) or active_metadata?(record["settings"])
  end

  defp active_metadata?(nil), do: false

  defp active_metadata?(map) when is_map(map),
    do: Enum.any?(map, fn {_, v} -> v not in [nil, false, "", [], %{}] end)

  defp active_metadata?(_), do: true

  defp protected_type?({name, type}, zone),
    do: type not in @editable or (name == zone and type in ~w(NS CNAME))

  defp read_value("MX", %{"priority" => priority, "content" => target})
       when is_integer(priority) and priority in 0..65_535 do
    case canonical_target(target) do
      nil -> nil
      name -> "#{priority} #{name}"
    end
  end

  defp read_value(type, %{"content" => content}) when type in @domain_types,
    do: canonical_target(content)

  defp read_value(type, %{"content" => content}) when type in ~w(A AAAA),
    do: canonical_address(type, content)

  defp read_value("TXT", %{"content" => "\"" <> _ = content}), do: content

  defp read_value("TXT", %{"content" => content}) when is_binary(content),
    do: "\"" <> String.replace(content, ["\\", "\""], &("\\" <> &1)) <> "\""

  defp read_value(type, %{"content" => content})
       when type not in @editable and is_binary(content),
       do: content

  defp read_value(type, %{"data" => data}) when type not in @editable and is_map(data),
    do: Jason.encode!(data)

  defp read_value(_type, _record), do: nil

  defp build_batch(changes, zone) do
    empty = %{deletes: [], patches: [], posts: []}

    changes
    |> Enum.reduce_while({:ok, empty, MapSet.new()}, fn change, {:ok, acc, seen} ->
      with %{key: key} <- change,
           false <- MapSet.member?(seen, key),
           {:ok, operations} <- change_operations(change, zone) do
        next =
          Map.merge(acc, operations, fn _, accumulated, new -> Enum.reverse(new, accumulated) end)

        {:cont, {:ok, next, MapSet.put(seen, key)}}
      else
        {:error, _} = error -> {:halt, error}
        _ -> {:halt, {:error, :cloudflare_invalid_changes}}
      end
    end)
    |> case do
      {:ok, batch, _seen} -> {:ok, Map.new(batch, fn {key, ops} -> {key, Enum.reverse(ops)} end)}
      {:error, _} = error -> error
    end
  end

  defp change_operations(%{key: {name, type} = key, before: before, after: desired}, zone)
       when is_binary(name) and is_binary(type) do
    cond do
      protected_type?(key, zone) or match?(%{protected: true}, before) ->
        {:error, :cloudflare_protected_record}

      canonical_name(name) != name or not in_zone?(name, zone) ->
        {:error, :cloudflare_invalid_changes}

      true ->
        with {:ok, old} <- before_records(before),
             {:ok, new} <- desired_records(name, type, desired) do
          {:ok, diff_records(old, new)}
        end
    end
  end

  defp change_operations(_change, _zone), do: {:error, :cloudflare_invalid_changes}

  defp before_records(nil), do: {:ok, []}

  defp before_records(%{protected: false, records: [_ | _] = records}) do
    if Enum.all?(records, &valid_prior_record?/1) and
         length(Enum.uniq_by(records, & &1.id)) == length(records) and
         length(Enum.uniq_by(records, & &1.value)) == length(records) do
      {:ok, records}
    else
      {:error, :cloudflare_invalid_changes}
    end
  end

  defp before_records(_), do: {:error, :cloudflare_invalid_changes}

  defp valid_prior_record?(%{id: id, ttl: ttl, value: value}),
    do: valid_id?(id) and is_integer(ttl) and is_binary(value)

  defp valid_prior_record?(_), do: false

  defp desired_records(_name, _type, nil), do: {:ok, %{}}

  defp desired_records(name, type, %{ttl: ttl, values: [_ | _] = values})
       when is_integer(ttl) and ttl in 1..86_400 do
    Enum.reduce_while(values, {:ok, %{}}, fn value, {:ok, acc} ->
      with {:ok, canonical, fields} <- write_value(type, value),
           false <- Map.has_key?(acc, canonical) do
        body = Map.merge(fields, %{type: type, name: undot(name), ttl: ttl})
        {:cont, {:ok, Map.put(acc, canonical, body)}}
      else
        _ -> {:halt, {:error, :cloudflare_invalid_changes}}
      end
    end)
  end

  defp desired_records(_name, _type, _desired), do: {:error, :cloudflare_invalid_changes}

  defp write_value("MX", value) when is_binary(value) do
    with [priority, host] <- String.split(value),
         {number, ""} when number in 0..65_535 <- Integer.parse(priority),
         target when is_binary(target) <- canonical_target(host) do
      {:ok, "#{number} #{target}", %{content: undot(target), priority: number}}
    end
  end

  defp write_value(type, value) when type in @domain_types and is_binary(value) do
    with target when is_binary(target) <- canonical_target(value),
         do: {:ok, target, %{content: undot(target)}}
  end

  defp write_value(type, value) when type in ~w(A AAAA) and is_binary(value) do
    with ip when is_binary(ip) <- canonical_address(type, value),
         do: {:ok, ip, %{content: ip}}
  end

  defp write_value("TXT", "\"" <> _ = value), do: {:ok, value, %{content: value}}
  defp write_value(_type, _value), do: {:error, :cloudflare_invalid_changes}

  defp diff_records(old, new) do
    {retained, removed} = Enum.split_with(old, &Map.has_key?(new, &1.value))

    added =
      new |> Map.drop(Enum.map(retained, & &1.value)) |> Enum.sort() |> Enum.map(&elem(&1, 1))

    paired = Enum.zip(removed, added)
    paired_count = length(paired)

    ttl_updates =
      for record <- retained,
          body = Map.fetch!(new, record.value),
          body.ttl != record.ttl,
          do: Map.put(body, :id, record.id)

    %{
      patches:
        ttl_updates ++ Enum.map(paired, fn {record, body} -> Map.put(body, :id, record.id) end),
      deletes: removed |> Enum.drop(paired_count) |> Enum.map(&%{id: &1.id}),
      posts: added |> Enum.drop(paired_count) |> Enum.map(&dns_only/1)
    }
  end

  defp dns_only(%{type: type} = body) when type in ~w(A AAAA CNAME),
    do: Map.put(body, :proxied, false)

  defp dns_only(body), do: body

  defp canonical_address(type, address) when is_binary(address) do
    size = if type == "A", do: 4, else: 8

    case :inet.parse_strict_address(String.to_charlist(address)) do
      {:ok, ip} when tuple_size(ip) == size -> ip |> :inet.ntoa() |> List.to_string()
      _ -> nil
    end
  end

  defp canonical_address(_type, _address), do: nil

  defp canonical_name(name) when is_binary(name) and byte_size(name) in 1..254 do
    normalized = name |> String.trim_trailing(".") |> String.downcase()

    if Regex.match?(~r/\A(?:\*\.)?[a-z0-9_-]{1,63}(?:\.[a-z0-9_-]{1,63})*\z/, normalized),
      do: normalized <> "."
  end

  defp canonical_name(_name), do: nil
  defp canonical_target("."), do: "."
  defp canonical_target(name), do: canonical_name(name)
  defp undot("."), do: "."
  defp undot(name), do: String.trim_trailing(name, ".")
  defp in_zone?(name, zone), do: name == zone or String.ends_with?(name, "." <> zone)

  defp valid_id?(id) when is_binary(id), do: Regex.match?(~r/\A[0-9a-fA-F]{32}\z/, id)
  defp valid_id?(_id), do: false

  defp call(request, method, path, token, body \\ nil) do
    case request.(method, path, token, body) do
      {:ok, status, %{"success" => true} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, status, _response} when status in [401, 403] ->
        {:error, :cloudflare_auth_failed}

      {:ok, 404, _response} ->
        {:error, :cloudflare_not_found}

      {:ok, 429, _response} ->
        {:error, :cloudflare_rate_limited}

      {:ok, status, response} when status in 200..299 and not is_map(response) ->
        {:error, :cloudflare_invalid_response}

      {:ok, _status, _response} ->
        {:error, :cloudflare_api_failed}

      {:error, _reason} ->
        {:error, :cloudflare_transport_failed}
    end
  end

  defp http(method, path, token, body) do
    options = [
      method: method,
      headers: [{"authorization", "Bearer " <> token}, {"accept", "application/json"}],
      redirect: :error,
      http_version: :http1,
      connect_timeout: 5_000,
      timeout: 15_000,
      telemetry: false,
      max_decoded_body_size: 8_000_000
    ]

    options =
      if body,
        do: options ++ [body: Jason.encode!(body), content_type: "application/json"],
        else: options

    case (@base_url <> path) |> HTTP.fetch(options) |> HTTP.Promise.await() do
      %HTTP.Response{status: status} = response ->
        {_, envelope} = HTTP.Response.json(response)
        {:ok, status, envelope}

      {:error, _reason} = error ->
        error
    end
  end
end
