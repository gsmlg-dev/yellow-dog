defmodule YellowDog.Sync.DnsManifest do
  @moduledoc "Canonical, bounded DNS desired state independent of service configuration."

  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Digest

  @max_zones 100
  @max_rrsets 1_000
  @max_bytes 1_048_576
  # Conservative uncompressed zone RR budget below the DNS TCP message limit.
  # Wildcard owners count as a maximum-length synthesized query name so an
  # accepted wildcard answer cannot grow past this budget at query time.
  # The remaining 5,535 bytes cover header, question and authority data.
  @max_zone_wire_bytes 60_000
  @types ~w(A AAAA NS SOA CNAME MX TXT)

  @spec zone_digest(map()) :: {:ok, String.t()} | {:error, :invalid_manifest}
  def zone_digest(zone) do
    with true <- valid_zone_shape?(zone),
         {:ok, value} <-
           Digest.calculate(%{
             "schema_version" => 1,
             "zone_id" => zone["zone_id"],
             "apex" => zone["apex"],
             "version" => zone["version"],
             "rrsets" => zone["rrsets"]
           }) do
      {:ok, value}
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  @spec digest(map()) :: {:ok, String.t()} | {:error, :invalid_manifest}
  def digest(manifest) do
    with :ok <- validate_content(manifest),
         {:ok, encoded} <- Codec.encode(manifest),
         true <- byte_size(encoded) <= @max_bytes do
      {:ok, :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)}
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  @spec validate(map(), String.t()) :: {:ok, String.t()} | {:error, :invalid_manifest}
  def validate(manifest, server_id) when is_map(manifest) and is_binary(server_id) do
    with ^server_id <- manifest["server_id"],
         {:ok, digest} <- digest(manifest) do
      {:ok, digest}
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  def validate(_, _), do: {:error, :invalid_manifest}

  @doc "Checks the wire budget for already validated canonical RRsets."
  def within_wire_budget?(rrsets) do
    Enum.reduce(rrsets, 0, fn rrset, total ->
      owner_bytes =
        if String.starts_with?(rrset["owner"], "*."),
          do: 255,
          else: byte_size(rrset["owner"]) + 1

      total +
        Enum.reduce(rrset["records"], 0, fn record, rrset_total ->
          rrset_total + owner_bytes + 10 + rdata_wire_bytes(rrset["type"], record)
        end)
    end) <= @max_zone_wire_bytes
  end

  defp validate_content(
         %{
           "schema_version" => 1,
           "server_id" => server_id,
           "generation" => generation,
           "zones" => zones
         } = manifest
       )
       when map_size(manifest) == 4 and is_binary(server_id) and byte_size(server_id) in 1..128 and
              is_integer(generation) and generation > 0 and
              generation <= 9_223_372_036_854_775_807 and
              is_list(zones) and length(zones) <= @max_zones do
    if Enum.all?(zones, fn zone ->
         valid_zone?(zone) and zone_digest(zone) == {:ok, zone["digest"]}
       end) and
         unique?(Enum.map(zones, & &1["zone_id"])) and
         unique?(Enum.map(zones, & &1["apex"])) do
      :ok
    else
      {:error, :invalid_manifest}
    end
  end

  defp validate_content(_), do: {:error, :invalid_manifest}

  defp valid_zone?(
         %{
           "zone_id" => zone_id,
           "apex" => apex,
           "version" => version,
           "digest" => digest,
           "rrsets" => rrsets
         } = zone
       )
       when map_size(zone) == 5 and is_binary(zone_id) and byte_size(zone_id) in 1..128 and
              is_binary(apex) and byte_size(apex) in 2..255 and is_integer(version) and
              version > 0 and
              is_list(rrsets) and length(rrsets) <= @max_rrsets do
    match?({:ok, _}, Digest.validate(digest)) and
      canonical_name?(apex) and
      Enum.all?(rrsets, &valid_rrset?(&1, apex)) and
      unique?(Enum.map(rrsets, &{&1["owner"], &1["type"]})) and
      valid_zone_semantics?(apex, rrsets) and within_wire_budget?(rrsets)
  end

  defp valid_zone?(_), do: false

  defp valid_zone_shape?(%{"zone_id" => _, "apex" => _, "version" => _, "rrsets" => _} = zone),
    do: valid_zone?(Map.put(zone, "digest", String.duplicate("0", 64)))

  defp valid_zone_shape?(_), do: false

  defp valid_rrset?(
         %{"owner" => owner, "type" => type, "ttl" => ttl, "records" => records} = rrset,
         apex
       )
       when map_size(rrset) == 4 and is_binary(owner) and byte_size(owner) in 2..255 and
              type in @types and is_integer(ttl) and ttl > 0 and ttl <= 2_147_483_647 and
              is_list(records) and records != [] and length(records) <= 100 do
    canonical_owner?(owner) and (owner == apex or String.ends_with?(owner, "." <> apex)) and
      (type not in ["NS", "SOA"] or owner == apex) and
      (type != "CNAME" or length(records) == 1) and
      Enum.all?(records, &valid_record?(type, &1))
  end

  defp valid_rrset?(_, _), do: false

  defp valid_record?("A", value) when is_binary(value) do
    case :inet.parse_ipv4_address(String.to_charlist(value)) do
      {:ok, {a, b, c, d}} -> value == Enum.join([a, b, c, d], ".")
      _ -> false
    end
  end

  defp valid_record?("NS", value) when is_binary(value),
    do: canonical_name?(value)

  defp valid_record?("AAAA", value) when is_binary(value) do
    case :inet.parse_ipv6_address(String.to_charlist(value)) do
      {:ok, {_, _, _, _, _, _, _, _} = address} ->
        String.downcase(value) == address |> :inet.ntoa() |> List.to_string() |> String.downcase()

      _ ->
        false
    end
  end

  defp valid_record?("CNAME", value), do: canonical_name?(value)

  defp valid_record?("MX", %{"preference" => preference, "exchange" => exchange} = value)
       when map_size(value) == 2,
       do: is_integer(preference) and preference in 0..65_535 and canonical_name?(exchange)

  defp valid_record?("TXT", segments) when is_list(segments) and length(segments) in 1..255 do
    Enum.all?(segments, &(is_binary(&1) and String.valid?(&1) and byte_size(&1) <= 255)) and
      Enum.reduce(segments, 0, fn segment, total -> total + byte_size(segment) + 1 end) <= 65_535
  end

  defp valid_record?("SOA", %{"mname" => mname, "rname" => rname} = value)
       when map_size(value) == 7 and is_binary(mname) and is_binary(rname) do
    canonical_name?(mname) and canonical_name?(rname) and
      Enum.all?(~w(serial refresh retry expire minimum), fn key ->
        number = value[key]
        is_integer(number) and number >= 0 and number <= 4_294_967_295
      end)
  end

  defp valid_record?(_, _), do: false

  defp rdata_wire_bytes("A", _), do: 4
  defp rdata_wire_bytes("AAAA", _), do: 16
  defp rdata_wire_bytes(type, name) when type in ["NS", "CNAME"], do: byte_size(name) + 1

  defp rdata_wire_bytes("MX", record),
    do: 2 + byte_size(record["exchange"]) + 1

  defp rdata_wire_bytes("TXT", segments),
    do: Enum.reduce(segments, 0, fn segment, size -> size + byte_size(segment) + 1 end)

  defp rdata_wire_bytes("SOA", record),
    do: byte_size(record["mname"]) + byte_size(record["rname"]) + 2 + 20

  defp valid_zone_semantics?(apex, rrsets) do
    soa = Enum.find(rrsets, &(&1["owner"] == apex and &1["type"] == "SOA"))
    ns = Enum.find(rrsets, &(&1["owner"] == apex and &1["type"] == "NS"))

    aliases =
      Map.new(Enum.filter(rrsets, &(&1["type"] == "CNAME")), &{&1["owner"], hd(&1["records"])})

    owners = Enum.group_by(rrsets, & &1["owner"], & &1["type"])

    not is_nil(soa) and not is_nil(ns) and length(soa["records"]) == 1 and
      not Map.has_key?(aliases, apex) and
      Enum.all?(aliases, fn {owner, _} -> length(owners[owner]) == 1 end) and
      Enum.all?(Map.keys(aliases), &(not alias_cycle?(&1, aliases, MapSet.new()))) and
      Enum.all?(rrsets, fn rrset ->
        rrset["type"] not in ["NS", "MX"] or
          Enum.all?(rrset["records"], fn record ->
            target = if rrset["type"] == "MX", do: record["exchange"], else: record
            not Map.has_key?(aliases, target)
          end)
      end)
  end

  defp alias_cycle?(name, aliases, seen) do
    cond do
      MapSet.member?(seen, name) -> true
      not Map.has_key?(aliases, name) -> false
      true -> alias_cycle?(aliases[name], aliases, MapSet.put(seen, name))
    end
  end

  defp canonical_owner?(value) when is_binary(value) and byte_size(value) in 3..254 do
    labels = value |> String.trim_trailing(".") |> String.split(".")

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

    value == String.downcase(value) and String.ends_with?(value, ".") and
      not String.ends_with?(value, "..") and valid_labels?
  end

  defp canonical_owner?(_), do: false

  defp canonical_name?(value) when is_binary(value) and byte_size(value) in 3..254 do
    labels = value |> String.trim_trailing(".") |> String.split(".")

    value == String.downcase(value) and String.ends_with?(value, ".") and
      not String.ends_with?(value, "..") and
      Enum.all?(labels, fn label ->
        byte_size(label) in 1..63 and
          Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, label)
      end)
  end

  defp canonical_name?(_), do: false

  defp unique?(values), do: length(values) == length(Enum.uniq(values))
end
