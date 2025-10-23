defmodule YellowDog.Dhcpv4.AddressPool do
  @moduledoc """
  IP address pool management for DHCPv4.

  Manages IP address ranges, allocation, and availability tracking.
  Supports multiple pools, static reservations, and address conflict detection.
  """

  require Logger

  @type ip_address :: {0..255, 0..255, 0..255, 0..255}
  @type mac_address :: binary()
  @type pool_config :: %{
          name: String.t(),
          range_start: ip_address(),
          range_end: ip_address(),
          subnet_mask: ip_address(),
          gateway: ip_address(),
          dns_servers: [ip_address()],
          domain_name: String.t() | nil,
          lease_time: pos_integer()
        }

  @doc """
  Creates a new address pool from configuration.

  ## Parameters
  - `config` - Pool configuration map

  ## Returns
  - `{:ok, pool}` - Successfully created pool
  - `{:error, reason}` - Failed to create pool

  ## Example
      iex> config = %{
      ...>   name: "main",
      ...>   range_start: {192, 168, 1, 100},
      ...>   range_end: {192, 168, 1, 200},
      ...>   subnet_mask: {255, 255, 255, 0},
      ...>   gateway: {192, 168, 1, 1},
      ...>   dns_servers: [{192, 168, 1, 1}],
      ...>   domain_name: "local",
      ...>   lease_time: 86400
      ...> }
      iex> YellowDog.Dhcpv4.AddressPool.new(config)
      {:ok, %{...}}
  """
  @spec new(map()) :: {:ok, pool_config()} | {:error, term()}
  def new(config) do
    with {:ok, validated_config} <- validate_pool_config(config) do
      pool = %{
        name: Map.get(config, :name, "default"),
        range_start: validated_config.range_start,
        range_end: validated_config.range_end,
        subnet_mask: Map.get(config, :subnet_mask, {255, 255, 255, 0}),
        gateway: Map.get(config, :gateway, validated_config.range_start),
        dns_servers: Map.get(config, :dns_servers, [validated_config.range_start]),
        domain_name: Map.get(config, :domain_name),
        lease_time: Map.get(config, :lease_time, 86400),
        static_reservations: Map.get(config, :static_reservations, %{})
      }

      {:ok, pool}
    end
  end

  @doc """
  Validates pool configuration.

  ## Parameters
  - `config` - Pool configuration to validate

  ## Returns
  - `{:ok, config}` - Valid configuration
  - `{:error, reason}` - Invalid configuration
  """
  @spec validate_pool_config(map()) :: {:ok, map()} | {:error, term()}
  def validate_pool_config(config) do
    with {:ok, range_start} <- get_required_ip(config, :range_start),
         {:ok, range_end} <- get_required_ip(config, :range_end),
         :ok <- validate_range_order(range_start, range_end) do
      {:ok, %{range_start: range_start, range_end: range_end}}
    end
  end

  @doc """
  Gets the next available IP address from the pool.

  ## Parameters
  - `pool` - Pool configuration
  - `allocated_ips` - Set of already allocated IP addresses
  - `mac` - MAC address requesting the IP (for static reservation check)

  ## Returns
  - `{:ok, ip}` - Available IP address
  - `{:error, :pool_exhausted}` - No available addresses
  """
  @spec get_available_ip(pool_config(), MapSet.t(ip_address()), mac_address()) ::
          {:ok, ip_address()} | {:error, :pool_exhausted}
  def get_available_ip(pool, allocated_ips, mac) do
    # Check for static reservation first
    case get_static_reservation(pool, mac) do
      {:ok, ip} ->
        {:ok, ip}

      :not_found ->
        # Find next available IP in range
        find_next_available(pool.range_start, pool.range_end, allocated_ips)
    end
  end

  @doc """
  Checks if an IP address is within the pool range.

  ## Parameters
  - `pool` - Pool configuration
  - `ip` - IP address to check

  ## Returns
  - `true` if IP is in range, `false` otherwise
  """
  @spec in_range?(pool_config(), ip_address()) :: boolean()
  def in_range?(pool, ip) do
    ip_to_integer(pool.range_start) <= ip_to_integer(ip) and
      ip_to_integer(ip) <= ip_to_integer(pool.range_end)
  end

  @doc """
  Gets static reservation for a MAC address.

  ## Parameters
  - `pool` - Pool configuration
  - `mac` - MAC address to look up

  ## Returns
  - `{:ok, ip}` - Static IP for this MAC
  - `:not_found` - No static reservation
  """
  @spec get_static_reservation(pool_config(), mac_address()) ::
          {:ok, ip_address()} | :not_found
  def get_static_reservation(pool, mac) do
    case Map.get(pool.static_reservations, format_mac(mac)) do
      nil -> :not_found
      ip -> {:ok, ip}
    end
  end

  @doc """
  Counts total addresses in the pool.

  ## Parameters
  - `pool` - Pool configuration

  ## Returns
  - Total number of addresses in the pool
  """
  @spec pool_size(pool_config()) :: non_neg_integer()
  def pool_size(pool) do
    ip_to_integer(pool.range_end) - ip_to_integer(pool.range_start) + 1
  end

  # Private helper functions

  defp get_required_ip(config, key) do
    case Map.get(config, key) do
      nil ->
        {:error, "Missing required field: #{key}"}

      ip when is_tuple(ip) and tuple_size(ip) == 4 ->
        {:ok, ip}

      ip when is_binary(ip) ->
        parse_ip_string(ip)

      _ ->
        {:error, "Invalid IP address format for #{key}"}
    end
  end

  defp validate_range_order(start_ip, end_ip) do
    if ip_to_integer(start_ip) <= ip_to_integer(end_ip) do
      :ok
    else
      {:error, "range_start must be less than or equal to range_end"}
    end
  end

  defp find_next_available(start_ip, end_ip, allocated_ips) do
    start_int = ip_to_integer(start_ip)
    end_int = ip_to_integer(end_ip)

    result =
      Enum.find(start_int..end_int, fn ip_int ->
        ip = integer_to_ip(ip_int)
        not MapSet.member?(allocated_ips, ip)
      end)

    case result do
      nil ->
        {:error, :pool_exhausted}

      ip_int ->
        {:ok, integer_to_ip(ip_int)}
    end
  end

  defp ip_to_integer({a, b, c, d}) do
    a * 256 * 256 * 256 + b * 256 * 256 + c * 256 + d
  end

  defp integer_to_ip(int) do
    a = div(int, 256 * 256 * 256)
    b = div(rem(int, 256 * 256 * 256), 256 * 256)
    c = div(rem(int, 256 * 256), 256)
    d = rem(int, 256)
    {a, b, c, d}
  end

  defp parse_ip_string(ip_string) do
    case String.split(ip_string, ".") do
      [a, b, c, d] ->
        try do
          {:ok,
           {String.to_integer(a), String.to_integer(b), String.to_integer(c),
            String.to_integer(d)}}
        rescue
          _ -> {:error, "Invalid IP address string: #{ip_string}"}
        end

      _ ->
        {:error, "Invalid IP address string format: #{ip_string}"}
    end
  end

  defp format_mac(<<mac::binary-size(6)>>) do
    mac
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_mac(_), do: "UNKNOWN"
end
