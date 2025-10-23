defmodule YellowDog.Dhcpv6.AddressPool do
  @moduledoc """
  IPv6 address pool management for DHCPv6.

  Manages IPv6 address ranges, allocation, and availability tracking.
  Supports multiple pools, static reservations, and prefix delegation.
  """

  require Logger
  import Bitwise

  @type ipv6_address ::
          {0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535}
  @type duid :: binary()
  @type pool_config :: %{
          name: String.t(),
          range_start: ipv6_address(),
          range_end: ipv6_address(),
          prefix_length: pos_integer(),
          dns_servers: [ipv6_address()],
          domain_name: String.t() | nil,
          preferred_lifetime: pos_integer(),
          valid_lifetime: pos_integer()
        }

  @doc """
  Creates a new IPv6 address pool from configuration.

  ## Parameters
  - `config` - Pool configuration map

  ## Returns
  - `{:ok, pool}` - Successfully created pool
  - `{:error, reason}` - Failed to create pool
  """
  @spec new(map()) :: {:ok, pool_config()} | {:error, term()}
  def new(config) do
    with {:ok, validated_config} <- validate_pool_config(config) do
      pool = %{
        name: Map.get(config, :name, "default"),
        range_start: validated_config.range_start,
        range_end: validated_config.range_end,
        prefix_length: Map.get(config, :prefix_length, 64),
        dns_servers: Map.get(config, :dns_servers, []),
        domain_name: Map.get(config, :domain_name),
        preferred_lifetime: Map.get(config, :preferred_lifetime, 3600),
        valid_lifetime: Map.get(config, :valid_lifetime, 7200),
        static_reservations: Map.get(config, :static_reservations, %{})
      }

      {:ok, pool}
    end
  end

  @doc """
  Validates pool configuration.
  """
  @spec validate_pool_config(map()) :: {:ok, map()} | {:error, term()}
  def validate_pool_config(config) do
    with {:ok, range_start} <- get_required_ipv6(config, :range_start),
         {:ok, range_end} <- get_required_ipv6(config, :range_end),
         :ok <- validate_range_order(range_start, range_end) do
      {:ok, %{range_start: range_start, range_end: range_end}}
    end
  end

  @doc """
  Gets the next available IPv6 address from the pool.

  ## Parameters
  - `pool` - Pool configuration
  - `allocated_ips` - Set of already allocated IP addresses
  - `duid` - DUID requesting the IP (for static reservation check)

  ## Returns
  - `{:ok, ip}` - Available IP address
  - `{:error, :pool_exhausted}` - No available addresses
  """
  @spec get_available_ip(pool_config(), MapSet.t(ipv6_address()), duid()) ::
          {:ok, ipv6_address()} | {:error, :pool_exhausted}
  def get_available_ip(pool, allocated_ips, duid) do
    # Check for static reservation first
    case get_static_reservation(pool, duid) do
      {:ok, ip} ->
        {:ok, ip}

      :not_found ->
        # Find next available IP in range
        find_next_available(pool.range_start, pool.range_end, allocated_ips)
    end
  end

  @doc """
  Checks if an IPv6 address is within the pool range.
  """
  @spec in_range?(pool_config(), ipv6_address()) :: boolean()
  def in_range?(pool, ip) do
    ipv6_to_integer(pool.range_start) <= ipv6_to_integer(ip) and
      ipv6_to_integer(ip) <= ipv6_to_integer(pool.range_end)
  end

  @doc """
  Gets static reservation for a DUID.
  """
  @spec get_static_reservation(pool_config(), duid()) ::
          {:ok, ipv6_address()} | :not_found
  def get_static_reservation(pool, duid) do
    case Map.get(pool.static_reservations, format_duid(duid)) do
      nil -> :not_found
      ip -> {:ok, ip}
    end
  end

  @doc """
  Counts total addresses in the pool.
  """
  @spec pool_size(pool_config()) :: non_neg_integer()
  def pool_size(pool) do
    start_int = ipv6_to_integer(pool.range_start)
    end_int = ipv6_to_integer(pool.range_end)
    end_int - start_int + 1
  end

  # Private helper functions

  defp get_required_ipv6(config, key) do
    case Map.get(config, key) do
      nil ->
        {:error, "Missing required field: #{key}"}

      ip when is_tuple(ip) and tuple_size(ip) == 8 ->
        {:ok, ip}

      ip when is_binary(ip) ->
        parse_ipv6_string(ip)

      _ ->
        {:error, "Invalid IPv6 address format for #{key}"}
    end
  end

  defp validate_range_order(start_ip, end_ip) do
    if ipv6_to_integer(start_ip) <= ipv6_to_integer(end_ip) do
      :ok
    else
      {:error, "range_start must be less than or equal to range_end"}
    end
  end

  defp find_next_available(start_ip, end_ip, allocated_ips) do
    start_int = ipv6_to_integer(start_ip)
    end_int = ipv6_to_integer(end_ip)

    # For large IPv6 ranges, we can't iterate through all addresses
    # Instead, use a random approach with collision detection
    max_attempts = 100

    result =
      Enum.find(1..max_attempts, fn _attempt ->
        # Generate a random offset within the range
        offset = :rand.uniform(end_int - start_int + 1) - 1
        ip_int = start_int + offset
        ip = integer_to_ipv6(ip_int)
        not MapSet.member?(allocated_ips, ip)
      end)

    case result do
      nil ->
        {:error, :pool_exhausted}

      _attempt ->
        offset = :rand.uniform(end_int - start_int + 1) - 1
        {:ok, integer_to_ipv6(start_int + offset)}
    end
  end

  defp ipv6_to_integer({a, b, c, d, e, f, g, h}) do
    a * (1 <<< 112) +
      b * (1 <<< 96) +
      c * (1 <<< 80) +
      d * (1 <<< 64) +
      e * (1 <<< 48) +
      f * (1 <<< 32) +
      g * (1 <<< 16) +
      h
  end

  defp integer_to_ipv6(int) do
    a = int >>> 112 &&& 0xFFFF
    b = int >>> 96 &&& 0xFFFF
    c = int >>> 80 &&& 0xFFFF
    d = int >>> 64 &&& 0xFFFF
    e = int >>> 48 &&& 0xFFFF
    f = int >>> 32 &&& 0xFFFF
    g = int >>> 16 &&& 0xFFFF
    h = int &&& 0xFFFF
    {a, b, c, d, e, f, g, h}
  end

  defp parse_ipv6_string(ip_string) do
    case :inet.parse_ipv6_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} -> {:ok, ip_tuple}
      {:error, _} -> {:error, "Invalid IPv6 address string: #{ip_string}"}
    end
  end

  defp format_duid(duid) when is_binary(duid) do
    duid
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_duid(_), do: "UNKNOWN"
end
