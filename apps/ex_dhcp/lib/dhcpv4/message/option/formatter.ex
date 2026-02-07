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
        "#{name}: #{Enum.map_join(value, ", ", fn ip -> :inet.ntoa(ip) end)}"

      :ip_mask_list ->
        "#{name}: #{Enum.map_join(value, ", ", fn {ip, mask} -> "#{:inet.ntoa(ip)}/#{:inet.ntoa(mask)}" end)}"

      :network_mask_router_list ->
        "#{name}: #{Enum.map_join(value, ", ", fn {network, mask, router} -> "#{:inet.ntoa(network)}/#{mask} via #{:inet.ntoa(router)}" end)}"

      :int_list ->
        "#{name}: #{Enum.map_join(value, ", ", &to_string/1)}"

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
