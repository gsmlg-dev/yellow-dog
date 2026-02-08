defmodule YellowDog.Dhcpv6.Ipv6Util do
  @moduledoc """
  Shared IPv6 address conversion utilities for DHCPv6 pool modules.

  Provides integer↔tuple conversion and string parsing used by
  AddressPool, PrefixPool, and LeaseManager.
  """

  import Bitwise

  @type ipv6_address ::
          {0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535}

  @doc "Converts an IPv6 8-tuple to a 128-bit integer."
  @spec to_integer(ipv6_address()) :: non_neg_integer()
  def to_integer({a, b, c, d, e, f, g, h}) do
    a * (1 <<< 112) +
      b * (1 <<< 96) +
      c * (1 <<< 80) +
      d * (1 <<< 64) +
      e * (1 <<< 48) +
      f * (1 <<< 32) +
      g * (1 <<< 16) +
      h
  end

  @doc "Converts a 128-bit integer to an IPv6 8-tuple."
  @spec from_integer(non_neg_integer()) :: ipv6_address()
  def from_integer(int) when is_integer(int) do
    {int >>> 112 &&& 0xFFFF, int >>> 96 &&& 0xFFFF, int >>> 80 &&& 0xFFFF,
     int >>> 64 &&& 0xFFFF, int >>> 48 &&& 0xFFFF, int >>> 32 &&& 0xFFFF,
     int >>> 16 &&& 0xFFFF, int &&& 0xFFFF}
  end

  @doc """
  Formats an IPv6 address as a lowercase colon-separated hex string.

  Passes through binaries unchanged and returns `nil` for `nil`.
  """
  @spec format(ipv6_address() | binary() | nil) :: String.t() | nil
  def format(nil), do: nil
  def format(ip) when is_binary(ip), do: ip

  def format(addr) when is_tuple(addr) and tuple_size(addr) == 8 do
    addr
    |> Tuple.to_list()
    |> Enum.map_join(":", &Integer.to_string(&1, 16))
    |> String.downcase()
  end

  @doc "Parses an IPv6 string into an 8-tuple."
  @spec parse_string(String.t()) :: {:ok, ipv6_address()} | {:error, String.t()}
  def parse_string(ip_string) when is_binary(ip_string) do
    case :inet.parse_ipv6_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} -> {:ok, ip_tuple}
      {:error, _} -> {:error, "Invalid IPv6 address string: #{ip_string}"}
    end
  end
end
