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

  @doc "Parses an IPv4 value (string, tuple, or other) into a 4-tuple."
  @spec parse(term()) :: {:ok, ipv4_address()} | {:error, String.t()}
  def parse(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, {_, _, _, _} = ip_tuple} -> {:ok, ip_tuple}
      _ -> {:error, "Invalid IPv4 address: #{ip}"}
    end
  end

  def parse(ip) when is_tuple(ip) and tuple_size(ip) == 4, do: {:ok, ip}
  def parse(_), do: {:error, "Invalid IPv4 format"}

  @doc "Formats an IPv4 address as a dotted-decimal string. Passes through binaries."
  @spec format(ipv4_address() | binary() | nil) :: String.t() | nil
  def format(nil), do: nil
  def format(ip) when is_binary(ip), do: ip
  def format(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
end
