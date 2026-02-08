defmodule DHCPv6.IpUtil do
  @moduledoc """
  Shared IPv6 address conversion utilities for the DHCPv6 protocol library.
  """

  import Bitwise

  @spec ip6_to_int(:inet.ip6_address()) :: non_neg_integer()
  def ip6_to_int({a, b, c, d, e, f, g, h}) do
    bsl(a, 112) ||| bsl(b, 96) ||| bsl(c, 80) ||| bsl(d, 64) |||
      bsl(e, 48) ||| bsl(f, 32) ||| bsl(g, 16) ||| h
  end

  @spec int_to_ip6(non_neg_integer()) :: :inet.ip6_address()
  def int_to_ip6(int) do
    {
      bsr(int, 112) &&& 0xFFFF,
      bsr(int, 96) &&& 0xFFFF,
      bsr(int, 80) &&& 0xFFFF,
      bsr(int, 64) &&& 0xFFFF,
      bsr(int, 48) &&& 0xFFFF,
      bsr(int, 32) &&& 0xFFFF,
      bsr(int, 16) &&& 0xFFFF,
      int &&& 0xFFFF
    }
  end

  @spec ip6_to_binary(:inet.ip6_address()) :: <<_::128>>
  def ip6_to_binary({a, b, c, d, e, f, g, h}) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
  end
end
