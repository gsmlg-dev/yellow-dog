defmodule YellowDog.ManagementUI.DnsRecordExports do
  @moduledoc "Read-only CSV and BIND formatting for canonical SOA, NS and A records."

  def csv(records) do
    rows =
      Enum.map_join(records, "", fn record ->
        [record["name"], record["type"], to_string(record["ttl"]), rdata(record)]
        |> Enum.map_join(",", &csv_cell/1)
        |> Kernel.<>("\r\n")
      end)

    "Name,Type,TTL,Data\r\n" <> rows
  end

  def bind(zone) do
    records =
      Enum.map_join(zone["records"], "", fn record ->
        "#{record["name"]} #{record["ttl"]} IN #{record["type"]} #{rdata(record)}\n"
      end)

    "$ORIGIN #{zone["name"]}\n" <> records
  end

  defp rdata(%{"type" => "SOA", "data" => data}) do
    Enum.map_join(~w(mname rname serial refresh retry expire minimum), " ", fn field ->
      data |> Map.fetch!(field) |> to_string()
    end)
  end

  defp rdata(%{"type" => "NS", "data" => %{"host" => host}}), do: host
  defp rdata(%{"type" => "A", "data" => %{"address" => address}}), do: address

  defp csv_cell(value) do
    safe =
      if Regex.match?(~r/\A(?:[\t\r\n]|\s*[=+@-])/u, value), do: "'" <> value, else: value

    if String.contains?(safe, [",", "\"", "\r", "\n"]),
      do: "\"" <> String.replace(safe, "\"", "\"\"") <> "\"",
      else: safe
  end
end
