defmodule YellowDog.MAC.Compiler do
  @moduledoc """
  Compiles wireshark to the internally used lookup table format.

  An OUI maps to a vendor list for /24 entries, or `{width, prefix_map}`
  for a single longer prefix width. Mixed widths use
  `{:mixed, [{width, prefix_map}, ...]}`, ordered longest first.
  """

  alias YellowDog.MAC.Parser

  def count_entries(table) do
    table
    |> Enum.reduce(0, fn
      {_, {:mixed, groups}}, acc ->
        acc + Enum.reduce(groups, 0, fn {_, map}, count -> count + map_size(map) end)

      {_, {_, map}}, acc ->
        acc + Enum.count(map)

      _, acc ->
        acc + 1
    end)
  end

  def build_lookup_table(mac_database_file) do
    mac_database_file
    |> Parser.parse_file()
    |> Enum.reduce(%{}, fn
      {<<key::bits-size(24), _::bits>> = bit_mac, vendor} = tuple, acc ->
        key_bitsize = bit_size(bit_mac)
        entry = if key_bitsize == 24, do: vendor, else: {key_bitsize, %{bit_mac => vendor}}

        Map.update(acc, key, entry, &update_sub_match_map(&1, tuple))
    end)
  end

  def update_sub_match_map({key_bitsize, map}, {bit_mac, vendor})
      when bit_size(bit_mac) == key_bitsize do
    {key_bitsize, map |> Map.put(bit_mac, vendor)}
  end

  def update_sub_match_map(given, {<<key::bits-size(24), _::bits>>, _} = tuple)
      when is_list(given) do
    case tuple do
      {^key, vendor} -> vendor
      _ -> update_sub_match_map({24, %{key => given}}, tuple)
    end
  end

  def update_sub_match_map({:mixed, groups}, tuple) do
    update_prefix_groups(groups, tuple)
  end

  def update_sub_match_map({key_bitsize, map}, tuple) do
    update_prefix_groups([{key_bitsize, map}], tuple)
  end

  defp update_prefix_groups(groups, {bit_mac, vendor}) do
    groups =
      groups
      |> Map.new()
      |> Map.update(bit_size(bit_mac), %{bit_mac => vendor}, &Map.put(&1, bit_mac, vendor))
      |> Enum.sort_by(fn {width, _} -> width end, :desc)

    {:mixed, groups}
  end
end
