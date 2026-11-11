defmodule YellowDog.MAC.Parser do
  @doc "Returns a list of tuples with {bitstring-mac (or part), company}"
  def parse_file(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(fn line -> String.trim(line) end)
    |> Enum.filter(fn
      "#" <> _ -> false
      "" -> false
      _ -> true
    end)
    |> Enum.map(&parse_line/1)
    |> Enum.filter(fn x -> not is_nil(x) end)
  end

  @doc "Returns a tuple with {bitstring-mac (or part), company}"
  def parse_line(line, min_bit_size \\ 24) do
    case String.split(line, ~r/\t/) do
      [mac | names] -> {mac |> to_bitstring, names}
      _ -> nil
    end
    |> case do
      {<<_::bits>> = bit_mac, _} = result
      when bit_size(bit_mac) >= min_bit_size ->
        result

      _ ->
        nil
    end
  end

  @doc "Returns a bitstring or nil"
  def to_bitstring(mac) do
    filtered_mac = mac |> String.replace(~r([^a-fA-F\d/]), "") |> String.upcase()

    case Regex.run(~r[(\w*)/?(\w*)], filtered_mac) do
      [_, hex_mac, ""] -> hex_to_bitstring(hex_mac)
      [_, hex_mac, mask] -> hex_to_bitstring(hex_mac, mask |> String.to_integer())
    end
  end

  defp hex_to_bitstring(hex, take \\ nil) do
    take = take || String.length(hex) * 4

    case Base.decode16(hex) do
      {:ok, <<val::bits-size(take), _::bits>>} -> val
      _ -> nil
    end
  end
end
