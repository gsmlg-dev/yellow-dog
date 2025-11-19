defmodule YellowDog.Console.Validators do
  @moduledoc """
  Validation functions for configuration values.
  Provides reusable validators for IP addresses, ports, ranges, etc.
  """

  import Bitwise

  alias YellowDog.Console.Settings.AddressPool

  @doc """
  Validates an IP address for a specific protocol.

  ## Parameters
    - address: IP address string
    - protocol: `:ipv4` or `:ipv6`

  ## Returns
    - `:ok` if valid
    - `{:error, message}` if invalid

  ## Examples

      iex> YellowDog.Console.Validators.validate_ip("192.168.1.1", :ipv4)
      :ok

      iex> YellowDog.Console.Validators.validate_ip("256.1.1.1", :ipv4)
      {:error, "Invalid IP address format"}

      iex> YellowDog.Console.Validators.validate_ip("::1", :ipv6)
      :ok
  """
  @spec validate_ip(String.t(), :ipv4 | :ipv6) :: :ok | {:error, String.t()}
  def validate_ip(address, protocol) when is_binary(address) do
    case :inet.parse_address(to_charlist(address)) do
      {:ok, {a, b, c, d}} when protocol == :ipv4 ->
        # Verify format to catch incomplete addresses like "192.168.1"
        expected = "#{a}.#{b}.#{c}.#{d}"
        if address == expected, do: :ok, else: {:error, "must be a valid IPv4 address"}

      {:ok, {_, _, _, _}} when protocol == :ipv6 ->
        {:error, "must be a valid IPv6 address"}

      {:ok, {_, _, _, _, _, _, _, _}} when protocol == :ipv6 ->
        :ok

      {:ok, {_, _, _, _, _, _, _, _}} when protocol == :ipv4 ->
        {:error, "must be a valid IPv4 address"}

      {:error, :einval} ->
        {:error, "must be a valid #{protocol} address"}
    end
  end

  @doc """
  Validates a port number.

  ## Parameters
    - port: Port number (integer)

  ## Returns
    - `:ok` if valid (1-65535)
    - `{:error, message}` if invalid

  ## Examples

      iex> YellowDog.Console.Validators.validate_port(53)
      :ok

      iex> YellowDog.Console.Validators.validate_port(99999)
      {:error, "Port must be between 1 and 65535"}
  """
  @spec validate_port(integer()) :: :ok | {:error, String.t()}
  def validate_port(port) when is_integer(port) do
    if port >= 1 and port <= 65535 do
      :ok
    else
      {:error, "Port must be between 1 and 65535"}
    end
  end

  @doc """
  Validates an IP address range.

  Checks that:
  - Both IPs are valid for the protocol
  - Start IP < End IP

  ## Parameters
    - start_ip: Starting IP address string
    - end_ip: Ending IP address string
    - protocol: `:ipv4` or `:ipv6`

  ## Returns
    - `:ok` if valid
    - `{:error, message}` if invalid

  ## Examples

      iex> YellowDog.Console.Validators.validate_pool_range("192.168.1.100", "192.168.1.200", :ipv4)
      :ok

      iex> YellowDog.Console.Validators.validate_pool_range("192.168.1.200", "192.168.1.100", :ipv4)
      {:error, "Range start must be less than range end"}
  """
  @spec validate_pool_range(String.t(), String.t(), :ipv4 | :ipv6) ::
          :ok | {:error, String.t()}
  def validate_pool_range(start_ip, end_ip, protocol)
      when is_binary(start_ip) and is_binary(end_ip) do
    with :ok <- validate_ip(start_ip, protocol),
         :ok <- validate_ip(end_ip, protocol),
         {:ok, start_tuple} <- :inet.parse_address(to_charlist(start_ip)),
         {:ok, end_tuple} <- :inet.parse_address(to_charlist(end_ip)),
         :ok <- compare_ip_addresses(start_tuple, end_tuple) do
      :ok
    end
  end

  @doc """
  Checks for overlapping address pools.

  ## Parameters
    - pools: List of AddressPool structs
    - protocol: `:ipv4` or `:ipv6`

  ## Returns
    - `:ok` if no overlaps
    - `{:error, message}` if overlaps detected

  ## Examples

      iex> pool1 = %{name: "Pool1", range_start: "192.168.1.100", range_end: "192.168.1.150"}
      iex> pool2 = %{name: "Pool2", range_start: "192.168.1.200", range_end: "192.168.1.250"}
      iex> YellowDog.Console.Validators.check_overlapping_pools([pool1, pool2], :ipv4)
      :ok
  """
  @spec check_overlapping_pools([AddressPool.t()], :ipv4 | :ipv6) ::
          :ok | {:error, String.t()}
  def check_overlapping_pools(pools, _protocol) when is_list(pools) do
    pool_ranges =
      pools
      |> Enum.map(fn pool ->
        {:ok, start_tuple} = :inet.parse_address(to_charlist(pool.range_start))
        {:ok, end_tuple} = :inet.parse_address(to_charlist(pool.range_end))
        {pool.name, ip_to_integer(start_tuple), ip_to_integer(end_tuple)}
      end)
      |> Enum.sort_by(fn {_name, start, _end} -> start end)

    case find_overlapping_ranges(pool_ranges) do
      nil -> :ok
      {pool1, pool2} -> {:error, "Pool '#{pool1}' overlaps with pool '#{pool2}'"}
    end
  end

  # Private Functions

  defp compare_ip_addresses(start_tuple, end_tuple) do
    if ip_to_integer(start_tuple) < ip_to_integer(end_tuple) do
      :ok
    else
      {:error, "Range start must be less than range end"}
    end
  end

  defp ip_to_integer({a, b, c, d}) do
    (a <<< 24) + (b <<< 16) + (c <<< 8) + d
  end

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    (a <<< 112) + (b <<< 96) + (c <<< 80) + (d <<< 64) +
      (e <<< 48) + (f <<< 32) + (g <<< 16) + h
  end

  defp find_overlapping_ranges([]), do: nil
  defp find_overlapping_ranges([_]), do: nil

  defp find_overlapping_ranges([{name1, _start1, end1}, {name2, start2, end2} | rest]) do
    if end1 >= start2 do
      {name1, name2}
    else
      find_overlapping_ranges([{name2, start2, end2} | rest])
    end
  end
end
