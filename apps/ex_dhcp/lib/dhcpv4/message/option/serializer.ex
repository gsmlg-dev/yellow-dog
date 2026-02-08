defmodule DHCPv4.Message.Option.Serializer do
  @moduledoc """
  DHCPv4 option serialization logic.

  This module provides functions to serialize DHCP options to binary format
  for network transmission.
  """

  alias DHCP.Parameter
  alias DHCPv4.Message.Option.Helpers

  @magic_cookie Helpers.magic_cookie()
  @end_option Helpers.end_option()

  @doc """
  Convert a list of DHCP options to binary format.

  Includes the magic cookie and end option.
  """
  def to_dhcp_binary(options) do
    iodata_options = Enum.map(options, &Parameter.to_iodata/1)

    [@magic_cookie, iodata_options, @end_option]
    |> IO.iodata_to_binary()
  end
end
