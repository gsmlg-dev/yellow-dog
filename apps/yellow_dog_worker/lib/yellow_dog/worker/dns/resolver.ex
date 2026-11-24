defmodule YellowDog.Worker.Dns.Resolver do
  @moduledoc false

  alias DNS.Message
  alias DNS.Message.{Domain, EDNS0, Record}
  alias DNS.Message.Record.Data
  alias DNS.ResourceRecordType
  alias YellowDog.Worker.Dns.{Acl, Cache, Forwarder, Recursor, Views}

  @types %{
    "A" => 1,
    "NS" => 2,
    "CNAME" => 5,
    "SOA" => 6,
    "PTR" => 12,
    "MX" => 15,
    "TXT" => 16,
    "AAAA" => 28
  }
  @max_cname_hops 16
  @max_udp 1232

  def build(resources) when is_list(resources) do
    Enum.reduce_while(resources, {:ok, %{}}, fn resource, {:ok, zones} ->
      case build_zone(resource) do
        {:ok, name, zone} when not is_map_key(zones, name) ->
          {:cont, {:ok, Map.put(zones, name, zone)}}

        {:ok, name, _} ->
          {:halt, {:error, {:duplicate_zone, name}}}

        error ->
          {:halt, error}
      end
    end)
  end

  def build(_), do: {:error, :invalid_resources}

  @doc """
  Builds the per-service query context: authoritative zones, compiled client policy,
  forward zones (longest name first, names lowercase without the trailing dot)
  and the shared answer cache handle. `recursor_opts` are extra `Recursor.resolve/3`
  options (e.g. `root_hints`/`port` from the adapter's `:recursor_opts` start option,
  used by tests); the context cache is added at query time.
  """
  def build_context(service, resources, cache, recursor_opts \\ [])

  def build_context(%{"config" => config}, resources, cache, recursor_opts)
      when is_map(config) and is_list(recursor_opts) do
    with {:ok, zones} <- build(resources),
         {:ok, query_policy} <- query_policy(config),
         {:ok, forward_zones} <- forward_zones(Map.get(config, "forward_zones", [])) do
      {:ok,
       %{
         zones: zones,
         query_policy: query_policy,
         forward_zones: forward_zones,
         cache: cache,
         recursor_opts: recursor_opts
       }}
    end
  end

  def build_context(_, _, _, _), do: {:error, :invalid_service}

  def update_context(service, resources, old) do
    with {:ok, context} <- build_context(service, resources, old.cache, old.recursor_opts) do
      if context.forward_zones == old.forward_zones and context.query_policy == old.query_policy do
        {:ok, context}
      else
        cache = Cache.new()
        Cache.delete(old.cache)
        {:ok, %{context | cache: cache}}
      end
    end
  end

  @doc """
  Answers one wire query in the calling process. Upstream work (forwarding,
  recursion) happens here, never in the adapter process.
  """
  def reply(packet, context, transport, client_ip) when is_binary(packet) do
    try do
      query = Message.from_iodata(packet)

      case query do
        %Message{header: %{qr: 0}, qdlist: [question]} ->
          respond(query, question, context, transport, client_ip)

        _ ->
          nil
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp respond(query, question, context, transport, client_ip) do
    policy = select_policy(context.query_policy, client_ip)

    result =
      cond do
        query.header.opcode.value != <<0::4>> ->
          {4, 0, 0, [], []}

        policy == nil or question.class.value != <<1::16>> ->
          {5, 0, 0, [], []}

        true ->
          query
          |> resolve(question, context, policy)
          |> recursion_available(policy)
      end

    encode(query, question, result, transport)
  end

  defp resolve(query, question, context, policy) do
    name = question.name |> to_string() |> String.downcase()
    key = String.trim_trailing(name, ".")
    <<type::16>> = question.type.value

    cond do
      zone = matching_zone(name, context.zones) ->
        authoritative(zone, name, question.type.value, context.zones, @max_cname_hops)

      servers = forward_servers(key, context.forward_zones) ->
        cache = Cache.scoped(context.cache, {:forward, policy.scope})

        upstream(cache, key, type, fn ->
          with {:ok, message} <- Forwarder.resolve(servers, key, type, []) do
            <<code::4>> = message.header.rcode.value
            {:ok, %{rcode: code, answers: message.anlist, authority: message.nslist}}
          end
        end)

      policy.recursion and query.header.rd == 1 ->
        cache = Cache.scoped(context.cache, {:recursion, policy.scope})

        upstream(cache, key, type, fn ->
          Recursor.resolve(key, type, Keyword.put(context.recursor_opts, :cache, cache))
        end)

      true ->
        {5, 0, 0, [], []}
    end
  end

  defp recursion_available(result, %{scope: :legacy}), do: result

  defp recursion_available({rcode, aa, _ra, answers, authority}, %{recursion: recursion}) do
    {rcode, aa, if(recursion, do: 1, else: 0), answers, authority}
  end

  defp query_policy(%{"views" => views}) do
    with {:ok, compiled} <- Views.compile(views), do: {:ok, {:views, compiled}}
  end

  defp query_policy(config) do
    with {:ok, acl} <- acl(Map.get(config, "allow_query", [])) do
      {:ok, {:legacy, acl, config["recursion"] == true}}
    end
  end

  defp select_policy({:views, views}, ip), do: Views.select(views, ip)

  defp select_policy({:legacy, acl, recursion}, ip) do
    if Acl.allowed?(acl, ip), do: %{scope: :legacy, recursion: recursion}
  end

  defp authoritative(_zone, _name, _type, _zones, 0), do: {2, 1, 0, [], []}

  defp authoritative(zone, name, type, zones, hops) do
    {records, name_exists?} = records_at(zone, name)

    case records do
      [] ->
        {if(name_exists?, do: 0, else: 3), 1, 0, [], negative_soa(zone.soa)}

      [%{type: %{value: <<5::16>>}, data: %{data: target}} = cname]
      when type not in [<<5::16>>, <<255::16>>] ->
        target = to_string(target)

        case matching_zone(target, zones) do
          nil ->
            {0, 1, 0, [cname], []}

          target_zone ->
            {rcode, aa, ra, answers, authority} =
              authoritative(target_zone, target, type, zones, hops - 1)

            {rcode, aa, ra, if(rcode == 2, do: [], else: [cname | answers]), authority}
        end

      records ->
        matching = Enum.filter(records, &(&1.type.value == type or type == <<255::16>>))
        authority = if matching == [], do: negative_soa(zone.soa), else: []
        {0, 1, 0, matching, authority}
    end
  end

  defp records_at(zone, name) do
    if MapSet.member?(zone.nodes, name) do
      {Map.get(zone.by_name, name, []), true}
    else
      encloser = name |> ancestors() |> Enum.find(&MapSet.member?(zone.nodes, &1))
      wildcard_records = Map.get(zone.by_name, "*." <> to_string(encloser), [])
      {Enum.map(wildcard_records, &%{&1 | name: Domain.new(name)}), wildcard_records != []}
    end
  end

  defp ancestors(name) do
    case String.split(name, ".", parts: 2) do
      [_label, "" = root] -> [root]
      [_label, parent] -> [parent | ancestors(parent)]
    end
  end

  # Forwarded and recursive answers: cache first, then the resolver; any failure
  # is SERVFAIL. Only NOERROR/NXDOMAIN results are cached.
  defp upstream(cache, key, type, resolve) do
    result =
      case cache_get(cache, key, type) do
        {:ok, cached} ->
          {:ok, cached}

        :miss ->
          with {:ok, %{rcode: rcode} = fresh} <- resolve.() do
            if rcode in [0, 3], do: cache_put(cache, key, type, fresh)
            {:ok, fresh}
          end
      end

    case result do
      {:ok, %{rcode: rcode, answers: answers, authority: authority}} ->
        {rcode, 0, 1, answers, authority}

      _ ->
        {2, 0, 1, [], []}
    end
  end

  # The cache table may be deleted by an adapter update while a handler still
  # holds the previous context; treat that as a miss / no-op.
  defp cache_get(nil, _key, _type), do: :miss

  defp cache_get(cache, key, type) do
    Cache.get(cache, key, type)
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(nil, _key, _type, _result), do: :ok

  defp cache_put(cache, key, type, result) do
    Cache.put(cache, key, type, result)
  rescue
    ArgumentError -> :ok
  end

  defp encode(query, question, {rcode, aa, ra, answers, authority}, transport) do
    opt = Enum.find(query.arlist, &(&1.type.value == <<41::16>>))

    header = %{
      query.header
      | qr: 1,
        aa: aa,
        tc: 0,
        ra: ra,
        ad: 0,
        rcode: DNS.Message.RCode.new(rcode),
        qdcount: 1,
        ancount: length(answers),
        nscount: length(authority),
        arcount: if(opt, do: 1, else: 0)
    }

    edns = if opt, do: DNS.to_iodata(EDNS0.new({@max_udp, 0, 0, 0, 0, []})), else: <<>>
    message = %Message{header: header, qdlist: [question], anlist: answers, nslist: authority}
    wire = DNS.to_iodata(message) <> edns

    limit = if transport == :udp, do: udp_limit(opt), else: 65_535

    if byte_size(wire) > limit do
      header = %{header | tc: 1, ancount: 0, nscount: 0}
      DNS.to_iodata(%Message{header: header, qdlist: [question]}) <> edns
    else
      wire
    end
  end

  defp udp_limit(nil), do: 512
  defp udp_limit(%{class: %{value: <<size::16>>}}), do: size |> max(512) |> min(@max_udp)

  defp forward_servers(key, forward_zones) do
    Enum.find_value(forward_zones, fn {zone, servers} ->
      if zone == "" or key == zone or String.ends_with?(key, "." <> zone), do: servers
    end)
  end

  defp acl(cidrs) when is_list(cidrs) do
    Acl.compile(cidrs)
  rescue
    _ -> {:error, :invalid_allow_query}
  end

  defp acl(_), do: {:error, :invalid_allow_query}

  defp forward_zones(zones) when is_list(zones) do
    Enum.reduce_while(zones, {:ok, []}, fn
      %{"name" => name, "forwarders" => [_ | _] = forwarders}, {:ok, acc} when is_binary(name) ->
        case forwarders(forwarders) do
          {:ok, servers} ->
            {:cont,
             {:ok, [{name |> String.downcase() |> String.trim_trailing("."), servers} | acc]}}

          error ->
            {:halt, error}
        end

      _, _ ->
        {:halt, {:error, :invalid_forward_zone}}
    end)
    |> case do
      {:ok, zones} -> {:ok, Enum.sort_by(zones, fn {zone, _} -> byte_size(zone) end, :desc)}
      error -> error
    end
  end

  defp forward_zones(_), do: {:error, :invalid_forward_zone}

  defp forwarders(forwarders) do
    Enum.reduce_while(forwarders, {:ok, []}, fn
      %{"address" => address} = forwarder, {:ok, acc} when is_binary(address) ->
        port = Map.get(forwarder, "port", 53)

        case :inet.parse_strict_address(String.to_charlist(address)) do
          {:ok, ip} when is_integer(port) and port in 1..65_535 ->
            {:cont, {:ok, [{ip, port} | acc]}}

          _ ->
            {:halt, {:error, :invalid_forwarder}}
        end

      _, _ ->
        {:halt, {:error, :invalid_forwarder}}
    end)
    |> case do
      {:ok, servers} -> {:ok, Enum.reverse(servers)}
      error -> error
    end
  end

  defp negative_soa(records) do
    Enum.map(records, fn record ->
      {_mname, _rname, _serial, _refresh, _retry, _expire, minimum} = record.data.data
      %{record | ttl: min(record.ttl, minimum)}
    end)
  end

  defp matching_zone(name, zones) do
    zones
    |> Enum.filter(fn {zone_name, _} ->
      name == zone_name or String.ends_with?(name, "." <> zone_name)
    end)
    |> Enum.max_by(fn {zone_name, _} -> byte_size(zone_name) end, fn -> nil end)
    |> case do
      nil -> nil
      {_, zone} -> zone
    end
  end

  defp build_zone(%{"type" => "dns_zone", "content" => %{"name" => name, "records" => records}})
       when is_binary(name) and is_list(records) do
    with {:ok, rr} <- build_records(records) do
      by_name = Enum.group_by(rr, &(&1.name |> to_string() |> String.downcase()))
      soa = Enum.filter(Map.get(by_name, name, []), &(&1.type.value == <<6::16>>))

      delegation? = Enum.any?(rr, &(&1.type.value == <<2::16>> and to_string(&1.name) != name))

      if delegation? do
        {:error, {:unsupported_delegation, name}}
      else
        if length(soa) == 1 do
          nodes = Map.keys(by_name) |> Enum.flat_map(&[&1 | ancestors(&1)]) |> MapSet.new()
          {:ok, name, %{by_name: by_name, nodes: nodes, soa: soa}}
        else
          {:error, {:invalid_soa, name}}
        end
      end
    end
  end

  defp build_zone(_), do: {:error, :unsupported_resource}

  defp build_records(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, acc} ->
      case build_record(record) do
        {:ok, rr} -> {:cont, {:ok, [rr | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, rr} -> {:ok, Enum.reverse(rr)}
      error -> error
    end
  end

  defp build_record(%{"name" => name, "type" => type, "ttl" => ttl, "data" => data})
       when is_binary(name) and is_integer(ttl) and ttl >= 0 and ttl <= 4_294_967_295 do
    with {:ok, code} <- Map.fetch(@types, type),
         {:ok, rdata} <- build_data(type, data) do
      {:ok,
       %Record{
         name: Domain.new(name),
         type: ResourceRecordType.new(code),
         class: DNS.Class.new(1),
         ttl: ttl,
         rdlength: rdata.rdlength,
         data: rdata
       }}
    else
      _ -> {:error, {:unsupported_record, type}}
    end
  end

  defp build_record(_), do: {:error, :invalid_record}

  defp build_data("A", %{"address" => address}) do
    case :inet.parse_ipv4_address(String.to_charlist(address)) do
      {:ok, ip} -> {:ok, Data.A.new(ip)}
      _ -> {:error, :invalid_address}
    end
  end

  defp build_data("NS", %{"host" => host}), do: {:ok, Data.NS.new(host)}
  defp build_data("CNAME", %{"target" => target}), do: {:ok, Data.CNAME.new(target)}
  defp build_data("PTR", %{"target" => target}), do: {:ok, Data.PTR.new(target)}

  defp build_data("MX", %{"preference" => preference, "exchange" => exchange}),
    do: {:ok, Data.MX.new({preference, exchange})}

  defp build_data("TXT", %{"strings" => strings}), do: {:ok, Data.TXT.new(strings)}

  defp build_data("AAAA", %{"address" => address}) do
    case :inet.parse_strict_address(String.to_charlist(address)) do
      {:ok, ip} when tuple_size(ip) == 8 -> {:ok, Data.AAAA.new(ip)}
      _ -> {:error, :invalid_address}
    end
  end

  defp build_data("SOA", %{
         "mname" => mname,
         "rname" => rname,
         "serial" => serial,
         "refresh" => refresh,
         "retry" => retry,
         "expire" => expire,
         "minimum" => minimum
       }) do
    {:ok,
     Data.SOA.new({Domain.new(mname), Domain.new(rname), serial, refresh, retry, expire, minimum})}
  end

  defp build_data(_, _), do: {:error, :invalid_record_data}
end
