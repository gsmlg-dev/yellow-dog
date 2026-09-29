defmodule YellowDog.Management.DnsZone do
  @moduledoc "Pure validation and immutable snapshot construction for managed DNS zones."

  @types ~w(A AAAA NS SOA CNAME MX TXT)
  @max_rrsets 256
  @max_records 64
  @max_ttl 2_147_483_647
  @max_serial 4_294_967_295

  def next_serial(serial) when is_integer(serial) and serial in 0..@max_serial,
    do: {:ok, rem(serial + 1, @max_serial + 1)}

  def next_serial(_), do: {:error, :invalid_soa_serial}

  def name(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase() |> String.trim_trailing(".")
    labels = String.split(value, ".")

    if byte_size(value) in 1..252 and length(labels) >= 2 and
         Enum.all?(labels, fn label ->
           byte_size(label) in 1..63 and
             Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, label)
         end) do
      {:ok, value <> "."}
    else
      {:error, :invalid_name}
    end
  end

  def name(_), do: {:error, :invalid_name}

  def normalize_rrsets(apex, rrsets) when is_list(rrsets) and length(rrsets) <= @max_rrsets do
    with {:ok, normalized} <- map_all(rrsets, &normalize_rrset(apex, &1)),
         true <-
           length(Enum.uniq_by(normalized, &{&1["owner"], &1["type"]})) ==
             length(normalized),
         :ok <- validate_aliases(apex, normalized),
         :ok <- wire_budget(normalized) do
      {:ok, Enum.sort_by(normalized, &{&1["owner"], &1["type"]})}
    else
      false -> {:error, :duplicate_rrset}
      error -> error
    end
  end

  def normalize_rrsets(_, _), do: {:error, :invalid_rrsets}

  defp wire_budget(rrsets) do
    if YellowDog.Sync.DnsManifest.within_wire_budget?(rrsets), do: :ok, else: {:error, :too_large}
  end

  def validate_complete(apex, rrsets) do
    soa = Enum.find(rrsets, &(&1["owner"] == apex and &1["type"] == "SOA"))
    ns = Enum.find(rrsets, &(&1["owner"] == apex and &1["type"] == "NS"))

    cond do
      not (soa && ns && length(soa["records"]) == 1) -> {:error, :incomplete_zone}
      true -> validate_aliases(apex, rrsets)
    end
  end

  def snapshot(zone, version, serial) do
    rrsets =
      Enum.map(zone["rrsets"], fn
        %{"type" => "SOA", "records" => [soa]} = rrset ->
          %{rrset | "records" => [Map.put(soa, "serial", serial)]}

        rrset ->
          rrset
      end)

    payload = %{
      "zone_id" => zone["id"],
      "apex" => zone["apex"],
      "version" => version,
      "rrsets" => rrsets
    }

    with {:ok, digest} <- YellowDog.Sync.DnsManifest.zone_digest(payload) do
      {:ok, Map.put(payload, "digest", digest)}
    end
  end

  def digest(payload) do
    :crypto.hash(:sha256, Jason.encode!(payload)) |> Base.encode16(case: :lower)
  end

  defp normalize_rrset(
         apex,
         %{
           "owner" => owner,
           "type" => type,
           "ttl" => ttl,
           "records" => records
         } = rrset
       )
       when map_size(rrset) == 4 and type in @types and is_integer(ttl) and ttl in 1..@max_ttl and
              is_list(records) and length(records) in 1..@max_records do
    with {:ok, owner} <- owner_name(owner),
         true <- owner == apex or String.ends_with?(owner, "." <> apex),
         true <- type != "SOA" or owner == apex,
         true <- type != "NS" or owner == apex,
         true <- type != "CNAME" or length(records) == 1,
         {:ok, records} <- map_all(records, &normalize_record(type, &1)) do
      records = Enum.uniq(records) |> Enum.sort_by(&Jason.encode!/1)
      {:ok, %{"owner" => owner, "type" => type, "ttl" => ttl, "records" => records}}
    else
      false -> {:error, :invalid_owner}
      error -> error
    end
  end

  defp normalize_rrset(_, _), do: {:error, :invalid_rrset}

  def owner_name(value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase() |> String.trim_trailing(".")
    labels = String.split(value, ".")

    valid_labels? =
      labels
      |> Enum.with_index()
      |> Enum.all?(fn {label, index} ->
        (index == 0 and label == "*") or
          (byte_size(label) in 1..63 and
             Regex.match?(
               ~r/\A(?:[a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9]|_[a-z0-9][a-z0-9-]*[a-z0-9]|_[a-z0-9])\z/,
               label
             ))
      end)

    if byte_size(value) in 1..252 and length(labels) >= 2 and valid_labels? do
      {:ok, value <> "."}
    else
      {:error, :invalid_name}
    end
  end

  def owner_name(_), do: {:error, :invalid_name}

  defp normalize_record("NS", value), do: name(value)

  defp normalize_record("A", value) when is_binary(value) do
    case :inet.parse_ipv4_address(String.to_charlist(value)) do
      {:ok, {a, b, c, d}} ->
        if value == Enum.join([a, b, c, d], "."),
          do: {:ok, value},
          else: {:error, :invalid_a_record}

      _ ->
        {:error, :invalid_a_record}
    end
  end

  defp normalize_record("AAAA", value) when is_binary(value) do
    with {:ok, {_, _, _, _, _, _, _, _} = address} <-
           :inet.parse_ipv6_address(String.to_charlist(value)),
         canonical when is_list(canonical) <- :inet.ntoa(address) do
      {:ok, List.to_string(canonical) |> String.downcase()}
    else
      _ -> {:error, :invalid_aaaa_record}
    end
  end

  defp normalize_record("CNAME", value), do: name(value)

  defp normalize_record("MX", %{"preference" => preference, "exchange" => exchange} = value)
       when map_size(value) == 2 and is_integer(preference) and preference in 0..65_535 do
    with {:ok, exchange} <- name(exchange) do
      {:ok, %{"preference" => preference, "exchange" => exchange}}
    end
  end

  defp normalize_record("TXT", segments) when is_list(segments) and length(segments) in 1..255 do
    if Enum.all?(segments, &(is_binary(&1) and String.valid?(&1) and byte_size(&1) <= 255)) and
         Enum.reduce(segments, 0, fn segment, total -> total + byte_size(segment) + 1 end) <=
           65_535 do
      {:ok, segments}
    else
      {:error, :invalid_txt_record}
    end
  end

  defp normalize_record("SOA", %{"mname" => mname, "rname" => rname} = value) do
    fields = ~w(refresh retry expire minimum)
    allowed = fields ++ ~w(mname rname serial)

    with {:ok, mname} <- name(mname),
         {:ok, rname} <- name(rname),
         true <- Enum.all?(Map.keys(value), &(&1 in allowed)),
         true <-
           Enum.all?(fields, fn field ->
             integer = value[field]
             is_integer(integer) and integer in 0..@max_ttl
           end) do
      {:ok,
       Map.merge(Map.take(value, fields), %{
         "mname" => mname,
         "rname" => rname,
         "serial" => 0
       })}
    else
      false -> {:error, :invalid_soa}
      error -> error
    end
  end

  defp normalize_record(_, _), do: {:error, :invalid_record}

  defp validate_aliases(apex, rrsets) do
    aliases =
      Map.new(Enum.filter(rrsets, &(&1["type"] == "CNAME")), fn rrset ->
        {rrset["owner"], hd(rrset["records"])}
      end)

    owners = Enum.group_by(rrsets, & &1["owner"], & &1["type"])

    cond do
      Map.has_key?(aliases, apex) ->
        {:error, :cname_at_apex}

      Enum.any?(aliases, fn {owner, _} -> length(owners[owner]) != 1 end) ->
        {:error, :cname_conflict}

      Enum.any?(rrsets, fn rrset ->
        rrset["type"] in ["NS", "MX"] and
            Enum.any?(rrset["records"], fn record ->
              target = if rrset["type"] == "MX", do: record["exchange"], else: record
              Map.has_key?(aliases, target)
            end)
      end) ->
        {:error, :cname_target}

      Enum.any?(Map.keys(aliases), &alias_cycle?(&1, aliases, MapSet.new())) ->
        {:error, :cname_loop}

      true ->
        :ok
    end
  end

  defp alias_cycle?(name, aliases, seen) do
    cond do
      MapSet.member?(seen, name) -> true
      not Map.has_key?(aliases, name) -> false
      true -> alias_cycle?(aliases[name], aliases, MapSet.put(seen, name))
    end
  end

  defp map_all(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end
