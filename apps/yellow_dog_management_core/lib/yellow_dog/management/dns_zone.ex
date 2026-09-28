defmodule YellowDog.Management.DnsZone do
  @moduledoc "Pure validation and immutable snapshot construction for managed DNS zones."

  @types ~w(A NS SOA)
  @max_rrsets 256
  @max_records 64
  @max_ttl 2_147_483_647

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
             length(normalized) do
      {:ok, Enum.sort_by(normalized, &{&1["owner"], &1["type"]})}
    else
      false -> {:error, :duplicate_rrset}
      error -> error
    end
  end

  def normalize_rrsets(_, _), do: {:error, :invalid_rrsets}

  def validate_complete(apex, rrsets) do
    soa = Enum.find(rrsets, &(&1["owner"] == apex and &1["type"] == "SOA"))
    ns = Enum.find(rrsets, &(&1["owner"] == apex and &1["type"] == "NS"))

    if soa && ns && length(soa["records"]) == 1 do
      :ok
    else
      {:error, :incomplete_zone}
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

    {:ok, digest} = YellowDog.Sync.DnsManifest.zone_digest(payload)
    Map.put(payload, "digest", digest)
  end

  def digest(payload) do
    :crypto.hash(:sha256, Jason.encode!(payload)) |> Base.encode16(case: :lower)
  end

  defp normalize_rrset(apex, %{
         "owner" => owner,
         "type" => type,
         "ttl" => ttl,
         "records" => records
       })
       when type in @types and is_integer(ttl) and ttl in 1..@max_ttl and
              is_list(records) and length(records) in 1..@max_records do
    with {:ok, owner} <- name(owner),
         true <- owner == apex or String.ends_with?(owner, "." <> apex),
         true <- type != "SOA" or owner == apex,
         true <- type != "NS" or owner == apex,
         {:ok, records} <- map_all(records, &normalize_record(type, &1)) do
      records = Enum.uniq(records) |> Enum.sort_by(&Jason.encode!/1)
      {:ok, %{"owner" => owner, "type" => type, "ttl" => ttl, "records" => records}}
    else
      false -> {:error, :invalid_owner}
      error -> error
    end
  end

  defp normalize_rrset(_, _), do: {:error, :invalid_rrset}

  defp normalize_record("NS", value), do: name(value)

  defp normalize_record("A", value) when is_binary(value) do
    case :inet.parse_ipv4_address(String.to_charlist(value)) do
      {:ok, {a, b, c, d}} -> {:ok, Enum.join([a, b, c, d], ".")}
      _ -> {:error, :invalid_a_record}
    end
  end

  defp normalize_record("SOA", %{"mname" => mname, "rname" => rname} = value) do
    fields = ~w(refresh retry expire minimum)

    with {:ok, mname} <- name(mname),
         {:ok, rname} <- name(rname),
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
