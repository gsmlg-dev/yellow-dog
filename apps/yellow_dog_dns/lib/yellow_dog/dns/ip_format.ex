defmodule YellowDog.Dns.IpFormat do
  @moduledoc """
  Shared IP address formatting and parsing utilities for the DNS subsystem.
  """

  @doc """
  Formats an IP address tuple to a human-readable string.

  Returns the string as-is if already a binary, or `inspect/1` for other types.
  """
  @spec format(term()) :: String.t()
  def format(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  def format(ip) when is_binary(ip), do: ip
  def format(other), do: inspect(other)

  @doc "Parses an IP address string (v4 or v6) into a tuple."
  @spec parse(String.t() | tuple()) :: {:ok, tuple()} | {:error, :invalid_ip}
  def parse(ip) when is_tuple(ip), do: {:ok, ip}

  def parse(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:error, :invalid_ip}
    end
  end

  def parse(_), do: {:error, :invalid_ip}

  @doc "Parses an IPv4 address. Returns the tuple or nil."
  @spec parse_v4(term()) :: :inet.ip4_address() | nil
  def parse_v4(addr) when is_tuple(addr) and tuple_size(addr) == 4, do: addr

  def parse_v4(addr) when is_binary(addr) do
    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, ip} when tuple_size(ip) == 4 -> ip
      _ -> nil
    end
  end

  def parse_v4(_), do: nil

  @doc "Parses an IPv6 address. Returns the tuple or nil."
  @spec parse_v6(term()) :: :inet.ip6_address() | nil
  def parse_v6(addr) when is_tuple(addr) and tuple_size(addr) == 8, do: addr

  def parse_v6(addr) when is_binary(addr) do
    case :inet.parse_address(String.to_charlist(addr)) do
      {:ok, ip} when tuple_size(ip) == 8 -> ip
      _ -> nil
    end
  end

  def parse_v6(_), do: nil
end
