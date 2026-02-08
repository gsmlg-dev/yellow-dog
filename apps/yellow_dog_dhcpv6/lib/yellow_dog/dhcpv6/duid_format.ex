defmodule YellowDog.Dhcpv6.DuidFormat do
  @moduledoc """
  Shared DUID (DHCP Unique Identifier) formatting for DHCPv6 modules.

  Converts binary DUIDs to hex strings with configurable separator and case.
  """

  @doc """
  Formats a binary DUID as a hex string.

  ## Options
  - `:separator` - separator between bytes (default: `":"`)
  - `:case` - `:upper` or `:lower` (default: `:upper`)

  Returns `nil` for non-binary or empty inputs.
  """
  @spec format(binary(), keyword()) :: String.t() | nil
  def format(duid, opts \\ [])

  def format(duid, opts) when is_binary(duid) and byte_size(duid) > 0 do
    separator = Keyword.get(opts, :separator, ":")
    hex_case = Keyword.get(opts, :case, :upper)

    hex =
      duid
      |> :binary.bin_to_list()
      |> Enum.map_join(separator, fn b ->
        b |> Integer.to_string(16) |> String.pad_leading(2, "0")
      end)

    if hex_case == :lower, do: String.downcase(hex), else: String.upcase(hex)
  end

  def format(_, _opts), do: nil

  @doc """
  Like `format/2` but returns `"UNKNOWN"` instead of `nil`.
  """
  @spec format!(binary(), keyword()) :: String.t()
  def format!(duid, opts \\ []), do: format(duid, opts) || "UNKNOWN"
end
