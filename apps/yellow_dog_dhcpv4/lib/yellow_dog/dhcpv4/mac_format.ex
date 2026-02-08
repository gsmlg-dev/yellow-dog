defmodule YellowDog.Dhcpv4.MacFormat do
  @moduledoc """
  Shared MAC address formatting for DHCPv4 modules.

  Converts 6-byte (or longer) binary MAC addresses to colon-separated hex strings.
  """

  @doc """
  Formats a binary MAC address as a colon-separated hex string.

  For binaries >= 6 bytes, uses the first 6 bytes.
  Returns `nil` for shorter or non-binary inputs.

  ## Options

    * `:case` - `:upper` (default) or `:lower`

  ## Examples

      iex> MacFormat.format(<<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>)
      "AA:BB:CC:DD:EE:FF"

      iex> MacFormat.format(<<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>, case: :lower)
      "aa:bb:cc:dd:ee:ff"
  """
  @spec format(binary(), keyword()) :: String.t() | nil
  def format(mac, opts \\ [])

  def format(<<mac::binary-size(6), _rest::binary>>, opts) do
    hex =
      mac
      |> :binary.bin_to_list()
      |> Enum.map_join(":", fn b -> b |> Integer.to_string(16) |> String.pad_leading(2, "0") end)

    if Keyword.get(opts, :case, :upper) == :lower, do: String.downcase(hex), else: String.upcase(hex)
  end

  def format(_, _opts), do: nil

  @doc """
  Like `format/2` but returns `default` instead of `nil` on failure.

  ## Options

    * `:case` - `:upper` (default) or `:lower`
    * `:default` - fallback string (default `"UNKNOWN"`)

  ## Examples

      iex> MacFormat.format!(<<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>)
      "AA:BB:CC:DD:EE:FF"

      iex> MacFormat.format!(nil)
      "UNKNOWN"

      iex> MacFormat.format!(nil, default: "")
      ""
  """
  @spec format!(term(), keyword()) :: String.t()
  def format!(mac, opts \\ []) do
    {default, format_opts} = Keyword.pop(opts, :default, "UNKNOWN")
    format(mac, format_opts) || default
  end
end
