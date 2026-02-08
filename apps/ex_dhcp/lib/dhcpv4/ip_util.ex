defmodule DHCPv4.IpUtil do
  @moduledoc """
  Shared IPv4 address conversion utilities for the DHCPv4 protocol library.
  """

  import Bitwise

  @spec ip_to_int(:inet.ip4_address()) :: non_neg_integer()
  def ip_to_int({a, b, c, d}), do: bsl(a, 24) ||| bsl(b, 16) ||| bsl(c, 8) ||| d

  @spec int_to_ip(non_neg_integer()) :: :inet.ip4_address()
  def int_to_ip(int),
    do: {bsr(int, 24) &&& 0xFF, bsr(int, 16) &&& 0xFF, bsr(int, 8) &&& 0xFF, int &&& 0xFF}

  @spec ip_to_binary(:inet.ip4_address()) :: <<_::32>>
  def ip_to_binary({a, b, c, d}), do: <<a, b, c, d>>

  @spec binary_to_ip(<<_::32>>) :: :inet.ip4_address()
  def binary_to_ip(<<a, b, c, d>>), do: {a, b, c, d}
end
