defmodule YellowDog.Management.CloudDns.Records do
  @moduledoc false

  alias YellowDog.Management.DnsRecordText

  @editable ~w(A AAAA CNAME MX TXT PTR NS)

  def editable?(name, {owner, type}), do: type in @editable and {owner, type} != {name, "NS"}

  def local(name, records) do
    records
    |> Enum.group_by(&{&1["name"], &1["type"]})
    |> Map.new(fn {key, [first | _] = group} ->
      {key,
       %{
         ttl: first["ttl"],
         values: group |> Enum.map(&DnsRecordText.format/1) |> Enum.uniq() |> Enum.sort()
       }}
    end)
    |> Map.filter(fn {key, _} -> editable?(name, key) end)
  end

  def remote(%{name: name, rrsets: rrsets}) do
    for {key, %{protected: false} = rrset} <- rrsets, editable?(name, key), into: %{} do
      {key, normalize(key, rrset)}
    end
    |> validate()
  end

  def protected(%{name: name, rrsets: rrsets}) do
    for {key, rrset} <- rrsets,
        rrset.protected or not editable?(name, key),
        into: MapSet.new(),
        do: key
  end

  def apex(%{name: name, rrsets: rrsets} = remote) do
    case {rrsets[{name, "SOA"}], rrsets[{name, "NS"}]} do
      {%{} = soa, %{} = ns} ->
        to_records(%{
          {name, "SOA"} => normalize({name, "SOA"}, soa),
          {name, "NS"} => normalize({name, "NS"}, ns)
        })

      _ ->
        with [primary | _] = servers <- Map.get(remote, :name_servers, []) do
          to_records(%{
            {name, "SOA"} => %{
              ttl: 3600,
              values: [
                Enum.join(
                  [primary, "hostmaster.#{name}", "1", "3600", "600", "86400", "300"],
                  " "
                )
              ]
            },
            {name, "NS"} => %{ttl: 3600, values: servers}
          })
        else
          _ -> {:error, :missing_authority_records}
        end
    end
  end

  def to_records(rrsets) do
    rrsets
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {{name, type}, rrset}, {:ok, records} ->
      case decode_values(name, type, rrset) do
        {:ok, members} -> {:cont, {:ok, Enum.reverse(members, records)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  def dump(rrsets) do
    for {{name, type}, %{ttl: ttl, values: values}} <- Enum.sort(rrsets),
        do: %{"name" => name, "type" => type, "ttl" => ttl, "values" => values}
  end

  def load(records) do
    Map.new(records, fn %{"name" => name, "type" => type, "ttl" => ttl, "values" => values} ->
      {{name, type}, %{ttl: ttl, values: values}}
    end)
  end

  defp validate(rrsets) do
    with {:ok, records} <- to_records(rrsets) do
      canonical =
        Enum.group_by(records, &{&1["name"], &1["type"]}, &DnsRecordText.format/1)

      {:ok,
       Map.new(rrsets, fn {key, rrset} ->
         {key, %{rrset | values: canonical |> Map.fetch!(key) |> Enum.uniq() |> Enum.sort()}}
       end)}
    end
  end

  defp normalize(_key, rrset), do: Map.take(rrset, [:ttl, :values])

  defp decode_values(name, type, %{ttl: ttl, values: [_ | _] = values}) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, records} ->
      case parse(type, value) do
        {:ok, data} ->
          {:cont,
           {:ok, [%{"name" => name, "type" => type, "ttl" => ttl, "data" => data} | records]}}

        :error ->
          {:halt, {:error, {:invalid_cloud_record, name, type}}}
      end
    end)
  end

  defp decode_values(name, type, _), do: {:error, {:invalid_cloud_record, name, type}}

  defp parse(type, value) when type in ~w(A AAAA) do
    size = if type == "A", do: 4, else: 8

    case :inet.parse_strict_address(String.to_charlist(value)) do
      {:ok, ip} when tuple_size(ip) == size -> {:ok, %{"address" => to_string(:inet.ntoa(ip))}}
      _ -> :error
    end
  end

  defp parse("NS", value), do: {:ok, %{"host" => domain(value)}}
  defp parse(type, value) when type in ~w(CNAME PTR), do: {:ok, %{"target" => domain(value)}}

  defp parse("MX", value) do
    with [priority, target] <- String.split(value),
         {priority, ""} <- Integer.parse(priority) do
      {:ok, %{"preference" => priority, "exchange" => domain(target)}}
    else
      _ -> :error
    end
  end

  defp parse("SOA", value) do
    with [mname, rname, serial, refresh, retry, expire, minimum] <- String.split(value),
         numbers = Enum.map([serial, refresh, retry, expire, minimum], &Integer.parse/1),
         [{s, ""}, {f, ""}, {r, ""}, {e, ""}, {m, ""}] <- numbers do
      {:ok,
       %{
         "mname" => domain(mname),
         "rname" => domain(rname),
         "serial" => s,
         "refresh" => f,
         "retry" => r,
         "expire" => e,
         "minimum" => m
       }}
    else
      _ -> :error
    end
  end

  defp parse("TXT", value) do
    with {:ok, strings} <- txt_strings(String.trim(value), []) do
      {:ok, %{"strings" => strings}}
    end
  end

  defp txt_strings("", [_ | _] = strings), do: {:ok, Enum.reverse(strings)}

  defp txt_strings(<<?", rest::binary>>, strings) do
    with {:ok, string, tail} <- txt_string(rest, []) do
      txt_strings(String.trim_leading(tail), [string | strings])
    end
  end

  defp txt_strings(_, _), do: :error

  defp txt_string(<<?", rest::binary>>, bytes) do
    value = bytes |> Enum.reverse() |> IO.iodata_to_binary()
    if String.valid?(value), do: {:ok, value, rest}, else: :error
  end

  defp txt_string(<<?\\, a, b, c, rest::binary>>, bytes)
       when a in ?0..?9 and b in ?0..?9 and c in ?0..?9 do
    byte = (a - ?0) * 100 + (b - ?0) * 10 + c - ?0
    if byte <= 255, do: txt_string(rest, [byte | bytes]), else: :error
  end

  defp txt_string(<<?\\, byte, rest::binary>>, bytes), do: txt_string(rest, [byte | bytes])
  defp txt_string(<<byte, rest::binary>>, bytes), do: txt_string(rest, [byte | bytes])
  defp txt_string("", _bytes), do: :error

  defp domain(value) do
    value |> String.trim() |> String.trim_trailing(".") |> String.downcase() |> Kernel.<>(".")
  end
end
