defmodule YellowDog.MAC.Vendor do
  @moduledoc """
  YellowDog.MAC.Vendor provides MAC's manufacturer database.

  """
  alias YellowDog.MAC.Compiler
  alias YellowDog.MAC.Parser

  @source_file Application.app_dir(:yellow_dog_mac, "priv") <> "/manuf.txt"

  @mac_lookup_table File.read!(@source_file) |> Compiler.build_lookup_table()

  @doc false
  def mac_lookup_table, do: @mac_lookup_table

  def entries, do: mac_lookup_table() |> Compiler.count_entries()

  @doc """
  Looks up the longest matching vendor prefix.

  Uses the compiled database by default. Pass a table returned by
  `YellowDog.MAC.Compiler.build_lookup_table/1` to query a custom database.
  """
  @spec lookup(String.t()) :: {:ok, String.t(), String.t()} | :error
  @spec lookup(String.t(), map()) :: {:ok, String.t(), String.t()} | :error
  def lookup(mac, table \\ @mac_lookup_table) when is_binary(mac) do
    vendor =
      case Parser.to_bitstring(mac) do
        <<key::bits-size(24), _::bits-size(24)>> = bit_mac ->
          lookup_entry(table[key], bit_mac)

        _ ->
          nil
      end

    case vendor do
      vendor when is_list(vendor) -> {:ok, Enum.at(vendor, 0), Enum.at(vendor, 1)}
      _ -> :error
    end
  end

  defp lookup_entry(vendor, _) when is_list(vendor), do: vendor

  defp lookup_entry({:mixed, groups}, bit_mac) do
    Enum.find_value(groups, &lookup_entry(&1, bit_mac))
  end

  defp lookup_entry({key_bitsize, %{} = sub_match_map}, bit_mac) do
    <<sub_key::bits-size(key_bitsize), _::bits>> = bit_mac
    sub_match_map[sub_key]
  end

  defp lookup_entry(nil, _), do: nil
end
