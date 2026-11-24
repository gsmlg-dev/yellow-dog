defmodule YellowDog.Management.DnsRecordText do
  @moduledoc false

  def format(%{"type" => "SOA", "data" => data}) do
    Enum.map_join(~w(mname rname serial refresh retry expire minimum), " ", fn field ->
      data |> Map.fetch!(field) |> to_string()
    end)
  end

  def format(%{"type" => "NS", "data" => %{"host" => host}}), do: host

  def format(%{"type" => type, "data" => %{"address" => address}}) when type in ~w(A AAAA),
    do: address

  def format(%{"type" => type, "data" => %{"target" => target}}) when type in ~w(CNAME PTR),
    do: target

  def format(%{"type" => "MX", "data" => %{"preference" => preference, "exchange" => exchange}}),
    do: "#{preference} #{exchange}"

  def format(%{"type" => "TXT", "data" => %{"strings" => strings}}),
    do: Enum.map_join(strings, " ", &quoted_txt/1)

  defp quoted_txt(value) do
    escaped =
      for <<byte <- value>>, into: "" do
        case byte do
          byte when byte in [?", ?\\] -> <<?\\, byte>>
          byte when byte in 32..126 -> <<byte>>
          byte -> "\\" <> String.pad_leading(Integer.to_string(byte), 3, "0")
        end
      end

    "\"" <> escaped <> "\""
  end
end
