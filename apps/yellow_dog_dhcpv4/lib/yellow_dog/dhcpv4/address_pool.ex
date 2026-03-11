defmodule YellowDog.Dhcpv4.AddressPool do
  @moduledoc """
  IP address pool management for DHCPv4.

  Manages IP address ranges, allocation, and availability tracking.
  Supports multiple pools, static reservations, and address conflict detection.
  """

  alias YellowDog.Dhcpv4.{Ipv4Util, MacFormat}

  require Logger

  @type ip_address :: {0..255, 0..255, 0..255, 0..255}
  @type mac_address :: binary()
  @type ip_range :: {ip_address(), ip_address()}
  @type pool_config :: %{
          name: String.t(),
          ranges: [ip_range()],
          # Legacy support - converted to ranges
          range_start: ip_address() | nil,
          range_end: ip_address() | nil,
          excluded_ranges: [ip_range()],
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
      # Support both legacy (range_start/range_end) and new (ranges) format
      ranges = build_ranges(config, validated_config)
      excluded_ranges = build_excluded_ranges(config)

      # Get first range for defaults
      {first_range_start, _} = hd(ranges)

      pool = %{
        name: Map.get(config, :name, "default"),
        network: Map.get(config, :network),
        ranges: ranges,
        range_start: validated_config[:range_start],
        range_end: validated_config[:range_end],
        excluded_ranges: excluded_ranges,
        subnet_mask: Map.get(config, :subnet_mask, {255, 255, 255, 0}),
        gateway: Map.get(config, :gateway, first_range_start),
        dns_servers: Map.get(config, :dns_servers, [first_range_start]),
        domain_name: Map.get(config, :domain_name),
        lease_time: Map.get(config, :lease_time, 86400),
        max_leases: Map.get(config, :max_leases, 1000),
        enabled: Map.get(config, :enabled, true),
        static_reservations: Map.get(config, :static_reservations, %{})
      }

      {:ok, pool}
    end
  end

  @doc """
  Validates pool configuration.

  Supports both legacy format (range_start/range_end) and new format (ranges).

  ## Parameters
  - `config` - Pool configuration to validate

  ## Returns
  - `{:ok, config}` - Valid configuration
  - `{:error, reason}` - Invalid configuration
  """
  @spec validate_pool_config(map()) :: {:ok, map()} | {:error, term()}
  def validate_pool_config(config) do
    cond do
      # New format with non-empty ranges list
      Map.has_key?(config, :ranges) && is_list(config.ranges) && config.ranges != [] ->
        validate_ranges_config(config)

      # Legacy format with range_start/range_end
      Map.has_key?(config, :range_start) || Map.has_key?(config, "range_start") ->
        validate_legacy_config(config)

      true ->
        {:error, "Must specify either :ranges or :range_start/:range_end"}
    end
  end

  defp validate_legacy_config(config) do
    with {:ok, range_start} <- get_required_ip(config, :range_start),
         {:ok, range_end} <- get_required_ip(config, :range_end),
         :ok <- validate_range_order(range_start, range_end) do
      {:ok, %{range_start: range_start, range_end: range_end}}
    end
  end

  defp validate_ranges_config(config) do
    ranges = config.ranges

    # Validate each range
    validated_ranges =
      Enum.reduce_while(ranges, {:ok, []}, fn range_config, {:ok, acc} ->
        case validate_single_range(range_config) do
          {:ok, validated_range} ->
            {:cont, {:ok, [validated_range | acc]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case validated_ranges do
      {:ok, ranges_list} ->
        {:ok, %{ranges: Enum.reverse(ranges_list)}}

      error ->
        error
    end
  end

  defp validate_single_range({start_ip, end_ip}) when is_tuple(start_ip) and is_tuple(end_ip) do
    with :ok <- validate_range_order(start_ip, end_ip) do
      {:ok, {start_ip, end_ip}}
    end
  end

  defp validate_single_range(%{start: start, end: end_ip}) do
    with {:ok, start_ip} <- normalize_ip(start),
         {:ok, end_ip_val} <- normalize_ip(end_ip),
         :ok <- validate_range_order(start_ip, end_ip_val) do
      {:ok, {start_ip, end_ip_val}}
    end
  end

  defp validate_single_range(_), do: {:error, "Invalid range format"}

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
        # Guard against allocating a reserved IP that is currently leased to a different
        # client.  This can happen when a reservation is added after another client has
        # already obtained a dynamic lease for the same address.
        if MapSet.member?(allocated_ips, ip) do
          Logger.warning(
            "[DHCPv4] Static reservation #{inspect(ip)} for #{inspect(mac)} is already " <>
              "allocated to another client — cannot assign"
          )

          {:error, :pool_exhausted}
        else
          {:ok, ip}
        end

      :not_found ->
        # Find next available IP across all ranges, excluding excluded ranges
        find_next_available_in_ranges(pool.ranges, pool.excluded_ranges, allocated_ips)
    end
  end

  @doc """
  Checks if an IP address is within any of the pool ranges (and not in excluded ranges).

  ## Parameters
  - `pool` - Pool configuration
  - `ip` - IP address to check

  ## Returns
  - `true` if IP is in range and not excluded, `false` otherwise
  """
  @spec in_range?(pool_config(), ip_address()) :: boolean()
  def in_range?(pool, ip) do
    ip_int = Ipv4Util.to_integer(ip)

    # Check if IP is in any of the allowed ranges
    in_allowed_range =
      Enum.any?(pool.ranges, fn {start_ip, end_ip} ->
        start_int = Ipv4Util.to_integer(start_ip)
        end_int = Ipv4Util.to_integer(end_ip)
        start_int <= ip_int and ip_int <= end_int
      end)

    # If in allowed range, check if it's not in excluded ranges
    if in_allowed_range do
      not in_excluded_range?(pool.excluded_ranges, ip_int)
    else
      false
    end
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
  Counts total addresses in the pool across all ranges, minus excluded ranges.

  ## Parameters
  - `pool` - Pool configuration

  ## Returns
  - Total number of usable addresses in the pool
  """
  @spec pool_size(pool_config()) :: non_neg_integer()
  def pool_size(pool) do
    max(sum_range_sizes(pool.ranges) - sum_range_sizes(pool.excluded_ranges), 0)
  end

  defp sum_range_sizes(ranges) do
    Enum.sum_by(ranges, fn {start_ip, end_ip} ->
      Ipv4Util.to_integer(end_ip) - Ipv4Util.to_integer(start_ip) + 1
    end)
  end

  # Private helper functions

  defp build_ranges(_config, validated_config) do
    cond do
      # New format with multiple ranges
      Map.has_key?(validated_config, :ranges) ->
        validated_config.ranges

      # Legacy format with single range
      Map.has_key?(validated_config, :range_start) ->
        [{validated_config.range_start, validated_config.range_end}]

      true ->
        # Should not happen due to validation
        []
    end
  end

  defp build_excluded_ranges(config) do
    case Map.get(config, :excluded_ranges) do
      nil ->
        []

      excluded when is_list(excluded) ->
        for item <- excluded,
            range = parse_excluded_range(item),
            range != nil,
            do: range

      _ ->
        []
    end
  end

  defp parse_excluded_range({start_ip, end_ip}) when is_tuple(start_ip) and is_tuple(end_ip),
    do: {start_ip, end_ip}

  defp parse_excluded_range(%{start: start, end: end_ip}) do
    {:ok, start_ip} = normalize_ip(start)
    {:ok, end_ip_tuple} = normalize_ip(end_ip)
    {start_ip, end_ip_tuple}
  end

  defp parse_excluded_range(_), do: nil

  defp find_next_available_in_ranges(ranges, excluded_ranges, allocated_ips) do
    # Try each range until we find an available IP
    Enum.reduce_while(ranges, {:error, :pool_exhausted}, fn {start_ip, end_ip}, _acc ->
      case find_next_available(start_ip, end_ip, allocated_ips, excluded_ranges) do
        {:ok, ip} ->
          {:halt, {:ok, ip}}

        {:error, :pool_exhausted} ->
          {:cont, {:error, :pool_exhausted}}
      end
    end)
  end

  defp in_excluded_range?([], _ip_int), do: false

  defp in_excluded_range?(excluded_ranges, ip_int) do
    Enum.any?(excluded_ranges, fn {start_ip, end_ip} ->
      start_int = Ipv4Util.to_integer(start_ip)
      end_int = Ipv4Util.to_integer(end_ip)
      start_int <= ip_int and ip_int <= end_int
    end)
  end

  defp normalize_ip(ip) when is_tuple(ip) and tuple_size(ip) == 4, do: {:ok, ip}
  defp normalize_ip(ip) when is_binary(ip), do: Ipv4Util.parse(ip)
  defp normalize_ip(_), do: {:error, "Invalid IP format"}

  defp get_required_ip(config, key) do
    case Map.get(config, key) do
      nil ->
        {:error, "Missing required field: #{key}"}

      ip when is_tuple(ip) and tuple_size(ip) == 4 ->
        {:ok, ip}

      ip when is_binary(ip) ->
        Ipv4Util.parse(ip)

      _ ->
        {:error, "Invalid IP address format for #{key}"}
    end
  end

  defp validate_range_order(start_ip, end_ip) do
    if Ipv4Util.to_integer(start_ip) <= Ipv4Util.to_integer(end_ip) do
      :ok
    else
      {:error, "range_start must be less than or equal to range_end"}
    end
  end

  defp find_next_available(start_ip, end_ip, allocated_ips, excluded_ranges) do
    start_int = Ipv4Util.to_integer(start_ip)
    end_int = Ipv4Util.to_integer(end_ip)

    result =
      Enum.find(start_int..end_int, fn ip_int ->
        ip = Ipv4Util.from_integer(ip_int)

        not MapSet.member?(allocated_ips, ip) and
          not in_excluded_range?(excluded_ranges, ip_int)
      end)

    case result do
      nil ->
        {:error, :pool_exhausted}

      ip_int ->
        {:ok, Ipv4Util.from_integer(ip_int)}
    end
  end

  defp format_mac(mac), do: MacFormat.format!(mac)
end
