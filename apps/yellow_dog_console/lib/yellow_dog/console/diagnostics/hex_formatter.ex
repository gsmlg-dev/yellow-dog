defmodule YellowDog.Console.Diagnostics.HexFormatter do
  @moduledoc """
  Formats binary data as xxd-style hex dump.

  Produces output in the format:
      00000000: 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f  ................
      00000010: 10 11 12 13                                       ....
  """

  @bytes_per_line 16

  @doc """
  Formats binary data as xxd-style hex dump with offset, hex bytes, and ASCII sidebar.

  ## Examples

      iex> HexFormatter.format(<<0, 1, 2, 3>>)
      "00000000: 00 01 02 03                                       ...."

      iex> HexFormatter.format(<<>>)
      ""
  """
  @spec format(binary()) :: String.t()
  def format(<<>>), do: ""

  def format(binary) when is_binary(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.chunk_every(@bytes_per_line)
    |> Enum.with_index()
    |> Enum.map_join("\n", &format_line/1)
  end

  @doc """
  Formats binary as space-separated hex bytes (for short values).

  ## Examples

      iex> HexFormatter.format_inline(<<192, 168, 1, 1>>)
      "c0 a8 01 01"

      iex> HexFormatter.format_inline(<<>>)
      ""
  """
  @spec format_inline(binary()) :: String.t()
  def format_inline(<<>>), do: ""

  def format_inline(binary) when is_binary(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.map_join(" ", &format_byte/1)
  end

  @doc """
  Formats a single byte as two-character lowercase hex.

  ## Examples

      iex> HexFormatter.format_byte(255)
      "ff"

      iex> HexFormatter.format_byte(0)
      "00"
  """
  @spec format_byte(byte()) :: String.t()
  def format_byte(byte) when byte >= 0 and byte <= 255 do
    byte
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(2, "0")
  end

  # Private functions

  defp format_line({bytes, index}) do
    offset = format_offset(index * @bytes_per_line)
    hex_part = format_hex_part(bytes)
    ascii_part = format_ascii_part(bytes)

    "#{offset}: #{hex_part}  #{ascii_part}"
  end

  defp format_offset(offset) do
    offset
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end

  defp format_hex_part(bytes) do
    hex = Enum.map_join(bytes, " ", &format_byte/1)

    # Pad to full line width (16 bytes * 3 chars - 1 space = 47 chars)
    String.pad_trailing(hex, 47)
  end

  defp format_ascii_part(bytes) do
    Enum.map_join(bytes, &byte_to_ascii_char/1)
  end

  defp byte_to_ascii_char(byte) when byte >= 32 and byte <= 126 do
    <<byte>>
  end

  defp byte_to_ascii_char(_byte), do: "."
end
