defmodule YellowDog.Sync.DnsManifest do
  @moduledoc "Canonical, bounded DNS desired state independent of service configuration."

  alias YellowDog.Sync.Codec
  alias YellowDog.Sync.Digest

  @max_zones 100
  @max_rrsets 1_000
  @max_bytes 1_048_576

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
      String.ends_with?(apex, ".") and
      Enum.all?(rrsets, &valid_rrset?/1)
  end

  defp valid_zone?(_), do: false

  defp valid_zone_shape?(%{"zone_id" => _, "apex" => _, "version" => _, "rrsets" => _} = zone),
    do: valid_zone?(Map.put(zone, "digest", String.duplicate("0", 64)))

  defp valid_zone_shape?(_), do: false

  defp valid_rrset?(
         %{"owner" => owner, "type" => type, "ttl" => ttl, "records" => records} = rrset
       )
       when map_size(rrset) == 4 and is_binary(owner) and byte_size(owner) in 2..255 and
              type in ["A", "NS", "SOA"] and is_integer(ttl) and ttl > 0 and
              is_list(records) and records != [] and length(records) <= 100 do
    String.ends_with?(owner, ".") and Enum.all?(records, &valid_record?(type, &1))
  end

  defp valid_rrset?(_), do: false

  defp valid_record?("A", value) when is_binary(value),
    do: match?({:ok, {_, _, _, _}}, :inet.parse_ipv4_address(String.to_charlist(value)))

  defp valid_record?("NS", value) when is_binary(value),
    do: byte_size(value) in 2..255 and String.ends_with?(value, ".")

  defp valid_record?("SOA", %{"mname" => mname, "rname" => rname} = value)
       when map_size(value) == 7 and is_binary(mname) and is_binary(rname) do
    String.ends_with?(mname, ".") and String.ends_with?(rname, ".") and
      Enum.all?(~w(serial refresh retry expire minimum), fn key ->
        number = value[key]
        is_integer(number) and number >= 0 and number <= 4_294_967_295
      end)
  end

  defp valid_record?(_, _), do: false

  defp unique?(values), do: length(values) == length(Enum.uniq(values))
end
