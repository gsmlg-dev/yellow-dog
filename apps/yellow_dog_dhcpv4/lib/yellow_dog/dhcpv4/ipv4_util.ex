defmodule YellowDog.Dhcpv4.Ipv4Util do
  @moduledoc """
  Shared IPv4 address conversion utilities for DHCPv4 pool modules.

  Provides integer<->tuple conversion used by AddressPool, Pool,
  LeaseManager, and Handler.
  """

  import Bitwise

  @type ipv4_address :: {0..255, 0..255, 0..255, 0..255}

  @doc "Converts an IPv4 4-tuple to a 32-bit integer."
  @spec to_integer(ipv4_address()) :: non_neg_integer()
  def to_integer({a, b, c, d}) do
    a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  end

  @doc "Converts a 32-bit integer to an IPv4 4-tuple."
  @spec from_integer(non_neg_integer()) :: ipv4_address()
  def from_integer(int) when is_integer(int) do
    {int >>> 24 &&& 0xFF, int >>> 16 &&& 0xFF, int >>> 8 &&& 0xFF, int &&& 0xFF}
  end
end
