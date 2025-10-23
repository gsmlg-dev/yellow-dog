defmodule DHCP.SecureRandom do
  @moduledoc """
  Secure random number generation for DHCP operations.

  This module provides cryptographically secure random number generation
  for DHCP transaction IDs and other security-sensitive operations.
  Uses Erlang's :crypto module for cryptographically strong random numbers.
  """

  @doc """
  Generate a secure random 32-bit integer for DHCPv4 transaction IDs.

  Returns a value between 0 and 0xFFFFFFFF (4294967295).
  """
  @spec generate_dhcpv4_xid() :: non_neg_integer()
  def generate_dhcpv4_xid do
    <<xid::32>> = :crypto.strong_rand_bytes(4)
    xid
  end

  @doc """
  Generate a secure random 24-bit integer for DHCPv6 transaction IDs.

  Returns a value between 0 and 0xFFFFFF (16777215).
  """
  @spec generate_dhcpv6_transaction_id() :: non_neg_integer()
  def generate_dhcpv6_transaction_id do
    <<tid::24>> = :crypto.strong_rand_bytes(3)

    
    tid
  end

  @doc """
  Generate a secure random 32-bit integer for IA IDs.

  Returns a value between 0 and 0xFFFFFFFF (4294967295).
  """
  @spec generate_ia_id() :: non_neg_integer()
  def generate_ia_id do
    <<iaid::32>> = :crypto.strong_rand_bytes(4)
    iaid
  end

  @doc """
  Generate cryptographically secure random bytes.

  ## Parameters

    * `count` - Number of bytes to generate

  ## Returns

    Binary with the specified number of random bytes.
  """
  @spec generate_bytes(pos_integer()) :: binary()
  def generate_bytes(count) when count > 0 do
    :crypto.strong_rand_bytes(count)
  end

  @doc """
  Generate a secure random integer in the specified range.

  ## Parameters

    * `min` - Minimum value (inclusive)
    * `max` - Maximum value (inclusive)

  ## Returns

    Random integer between min and max.

  ## Examples

      iex> DHCP.SecureRandom.uniform(1, 10)
      7
  """
  @spec uniform(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def uniform(min, max) when min <= max and min >= 0 and max >= 0 do
    range = max - min + 1
    bits_needed = range |> :math.log2() |> math_ceil() |> max(1)

    bytes_needed = math_ceil(bits_needed / 8)
    <<random::size(bits_needed)>> = :crypto.strong_rand_bytes(bytes_needed)
    min + rem(random, range)
  end

  defp math_ceil(float), do: :math.ceil(float)
end
