defmodule DHCPv4.Message.Option.Formatter do
  @moduledoc """
  DHCPv4 option display formatting logic.

  This module provides functions to format DHCP options for display
  and debugging purposes.
  """

  alias DHCPv4.Message.Option.Decoder

  @doc """
  Format a DHCP option struct for display.

  Returns a formatted string representation.
  """
  def format(option) do
    decoded_value = Decoder.decode_option_value(option.type, option.length, option.value)

    """
    Option(#{option.type}): #{parse_decoded_value(decoded_value)}
    """
  end

  @doc """
  Parse and format a decoded option value for display.
  """
  @spec parse_decoded_value(
          {any(),
           :binary
           | :bool
           | :int
           | :int_list
           | :ip
           | :ip_list
           | :ip_mask_list
           | :network_mask_router_list
           | :raw, any()}
        ) :: <<_::16, _::_*8>>
  def parse_decoded_value({name, type, value}) do
    case type do
      :ip ->
        "#{name}: #{value |> :inet.ntoa()}"

      :ip_list ->
        "#{name}: #{value |> Enum.map(fn ip -> ip |> :inet.ntoa() end) |> Enum.join(", ")}"

      :ip_mask_list ->
        "#{name}: #{value |> Enum.map(fn {ip, mask} -> "#{ip |> :inet.ntoa()}/#{mask |> :inet.ntoa()}" end) |> Enum.join(", ")}"

      :network_mask_router_list ->
        "#{name}: #{value |> Enum.map(fn {network, mask, router} -> "#{network |> :inet.ntoa()}/#{mask} via #{router |> :inet.ntoa()}" end) |> Enum.join(", ")}"

      :int_list ->
        "#{name}: #{value |> Enum.map(fn int -> "#{int}" end) |> Enum.join(", ")}"

      :int ->
        "#{name}: #{value}"

      :bool ->
        "#{name}: #{value}"

      :binary ->
        "#{name}: #{value |> inspect()}"

      :type_identifier ->
        {type, identifier} = value
        "#{name}: #{type} #{identifier |> inspect()}"

      :raw ->
        "#{name}: #{value |> inspect()}"
    end
  end
end
