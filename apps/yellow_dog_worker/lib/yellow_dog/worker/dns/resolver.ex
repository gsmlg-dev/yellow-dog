defmodule YellowDog.Worker.Dns.Resolver do
  @moduledoc false

  alias DNS.Message
  alias DNS.Message.{Domain, Record}
  alias DNS.Message.Record.Data
  alias DNS.ResourceRecordType

  @types %{"A" => 1, "NS" => 2, "SOA" => 6}

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

  def reply(packet, zones, transport) when is_binary(packet) do
    try do
      query = Message.from_iodata(packet)

      case query do
        %Message{header: %{qr: 0}, qdlist: [question]} ->
          respond(query, question, zones, transport)

        _ ->
          nil
      end
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  defp respond(query, question, zones, transport) do
    name = question.name |> to_string() |> String.downcase()
    type = question.type.value
    class = question.class.value
    zone = matching_zone(name, zones)

    {rcode, authoritative, answers, authority} =
      cond do
        query.header.opcode.value != <<0::4>> ->
          {4, 0, [], []}

        class != <<1::16>> or is_nil(zone) ->
          {5, 0, [], []}

        true ->
          records = Map.get(zone.by_name, name, [])

          cond do
            records == [] ->
              descendant? = Enum.any?(Map.keys(zone.by_name), &String.ends_with?(&1, "." <> name))
              {if(descendant?, do: 0, else: 3), 1, [], zone.soa}

            true ->
              matching = Enum.filter(records, &(&1.type.value == type or type == <<255::16>>))
              authority = if matching == [], do: zone.soa, else: []
              {0, 1, matching, authority}
          end
      end

    header = %{
      query.header
      | qr: 1,
        aa: authoritative,
        tc: 0,
        ra: 0,
        rcode: DNS.Message.RCode.new(rcode),
        ancount: length(answers),
        nscount: length(authority),
        arcount: 0
    }

    response = %Message{header: header, qdlist: [question], anlist: answers, nslist: authority}
    wire = DNS.to_iodata(response)

    limit = if transport == :udp, do: 512, else: 65_535

    if byte_size(wire) > limit do
      header = %{header | tc: 1, ancount: 0, nscount: 0}
      DNS.to_iodata(%Message{header: header, qdlist: [question]})
    else
      wire
    end
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
          {:ok, name, %{by_name: by_name, soa: soa}}
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
