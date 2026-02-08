defmodule YellowDog.Dhcpv6.AddressPool do
  @moduledoc """
  IPv6 address pool management for DHCPv6.

  Manages IPv6 address ranges, allocation, and availability tracking.
  Supports multiple pools, static reservations, and prefix delegation.
  """

  alias YellowDog.Dhcpv6.Ipv6Util

  @type ipv6_address ::
          {0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535}
  @type duid :: binary()
  @type address_range :: %{
          start: ipv6_address(),
          end: ipv6_address()
        }

  @type pool_config :: %{
          name: String.t(),
          ranges: [address_range()],
          # Legacy single range support
          range_start: ipv6_address() | nil,
          range_end: ipv6_address() | nil,
          exclude_addresses: [ipv6_address()],
          prefix_length: pos_integer(),
          dns_servers: [ipv6_address()],
          domain_name: String.t() | nil,
          preferred_lifetime: pos_integer(),
          valid_lifetime: pos_integer(),
          static_reservations: %{String.t() => ipv6_address()}
        }

  @doc """
  Creates a new IPv6 address pool from configuration.

  ## Parameters
  - `config` - Pool configuration map with either:
    - `ranges` - List of %{start: ip, end: ip} maps (new format)
    - `range_start` and `range_end` - Single range (legacy format)

  ## Returns
  - `{:ok, pool}` - Successfully created pool
  - `{:error, reason}` - Failed to create pool
  """
  @spec new(map()) :: {:ok, pool_config()} | {:error, term()}
  def new(config) do
    with {:ok, validated_config} <- validate_pool_config(config) do
      # Parse static reservations
      reservations = parse_static_reservations(Map.get(config, :static_reservations, %{}))

      # Parse exclude addresses
      exclude_addresses =
        config
        |> Map.get(:exclude_addresses, [])
        |> Enum.flat_map(fn
          addr when is_binary(addr) ->
            case Ipv6Util.parse_string(addr) do
              {:ok, ip_tuple} -> [ip_tuple]
              _ -> []
            end

          addr when is_tuple(addr) ->
            [addr]

          _ ->
            []
        end)
        |> MapSet.new()

      pool = %{
        name: Map.get(config, :name, "default"),
        network: Map.get(config, :network),
        ranges: validated_config.ranges,
        range_start: validated_config[:range_start],
        range_end: validated_config[:range_end],
        exclude_addresses: exclude_addresses,
        prefix_length: Map.get(config, :prefix_length, 64),
        dns_servers: parse_dns_servers(Map.get(config, :dns_servers, [])),
        domain_name: Map.get(config, :domain_name),
        preferred_lifetime: Map.get(config, :preferred_lifetime, 3600),
        valid_lifetime: Map.get(config, :valid_lifetime, 7200),
        max_leases: Map.get(config, :max_leases, 1000),
        enabled: Map.get(config, :enabled, true),
        static_reservations: reservations
      }

      {:ok, pool}
    end
  end

  @doc """
  Validates pool configuration.

  Supports both legacy format (range_start/range_end) and new format (ranges list).
  """
  @spec validate_pool_config(map()) :: {:ok, map()} | {:error, term()}
  def validate_pool_config(config) do
    cond do
      # New format: non-empty ranges list
      Map.has_key?(config, :ranges) && is_list(config.ranges) && config.ranges != [] ->
        validate_ranges_config(config.ranges)

      # Legacy format: single range
      Map.has_key?(config, :range_start) && Map.has_key?(config, :range_end) ->
        with {:ok, range_start} <- get_required_ipv6(config, :range_start),
             {:ok, range_end} <- get_required_ipv6(config, :range_end),
             :ok <- validate_range_order(range_start, range_end) do
          {:ok,
           %{
             ranges: [%{start: range_start, end: range_end}],
             range_start: range_start,
             range_end: range_end
           }}
        end

      true ->
        {:error, "Pool configuration must have either 'ranges' or 'range_start'/'range_end'"}
    end
  end

  defp validate_ranges_config(ranges) do
    validated_ranges =
      Enum.reduce_while(ranges, [], fn range, acc ->
        case validate_single_range(range) do
          {:ok, validated_range} -> {:cont, [validated_range | acc]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case validated_ranges do
      {:error, reason} ->
        {:error, reason}

      validated when is_list(validated) ->
        # Take first range as primary for backward compatibility
        first_range = List.first(validated)

        {:ok,
         %{
           ranges: Enum.reverse(validated),
           range_start: first_range.start,
           range_end: first_range.end
         }}
    end
  end

  defp validate_single_range(range) do
    with {:ok, start_ip} <- parse_range_ip(range, :start),
         {:ok, end_ip} <- parse_range_ip(range, :end),
         :ok <- validate_range_order(start_ip, end_ip) do
      {:ok, %{start: start_ip, end: end_ip}}
    end
  end

  defp parse_range_ip(range, key) do
    case Map.get(range, key) do
      nil ->
        {:error, "Missing required field in range: #{key}"}

      ip when is_tuple(ip) and tuple_size(ip) == 8 ->
        {:ok, ip}

      ip when is_binary(ip) ->
        Ipv6Util.parse_string(ip)

      _ ->
        {:error, "Invalid IPv6 address format for range #{key}"}
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
        # Combine allocated IPs with excluded addresses
        unavailable_ips = MapSet.union(allocated_ips, pool.exclude_addresses)

        # Try to find available IP from any range
        find_available_in_ranges(pool.ranges, unavailable_ips)
    end
  end

  defp find_available_in_ranges([], _unavailable_ips) do
    {:error, :pool_exhausted}
  end

  defp find_available_in_ranges([range | rest], unavailable_ips) do
    case find_next_available(range.start, range.end, unavailable_ips) do
      {:ok, ip} -> {:ok, ip}
      {:error, :pool_exhausted} -> find_available_in_ranges(rest, unavailable_ips)
    end
  end

  @doc """
  Checks if an IPv6 address is within any of the pool ranges.
  """
  @spec in_range?(pool_config(), ipv6_address()) :: boolean()
  def in_range?(pool, ip) do
    ip_int = Ipv6Util.to_integer(ip)

    Enum.any?(pool.ranges, fn range ->
      start_int = Ipv6Util.to_integer(range.start)
      end_int = Ipv6Util.to_integer(range.end)
      start_int <= ip_int and ip_int <= end_int
    end)
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
  Counts total addresses in the pool (across all ranges, minus exclusions).
  """
  @spec pool_size(pool_config()) :: non_neg_integer()
  def pool_size(pool) do
    total_size =
      Enum.reduce(pool.ranges, 0, fn range, acc ->
        start_int = Ipv6Util.to_integer(range.start)
        end_int = Ipv6Util.to_integer(range.end)
        acc + (end_int - start_int + 1)
      end)

    # Subtract excluded addresses
    total_size - MapSet.size(pool.exclude_addresses)
  end

  # Private helper functions

  defp parse_static_reservations(list) when is_list(list) do
    Enum.reduce(list, %{}, fn reservation, acc ->
      case parse_reservation(reservation) do
        {:ok, duid, ip} -> Map.put(acc, duid, ip)
        :skip -> acc
      end
    end)
  end

  defp parse_static_reservations(map) when is_map(map), do: map
  defp parse_static_reservations(_), do: %{}

  defp parse_reservation(%{duid: duid, address: address}) when is_binary(address) do
    case Ipv6Util.parse_string(address) do
      {:ok, ip_tuple} -> {:ok, format_duid(duid), ip_tuple}
      _ -> :skip
    end
  end

  defp parse_reservation(%{duid: duid, address: address}) when is_tuple(address) do
    {:ok, format_duid(duid), address}
  end

  defp parse_reservation(_), do: :skip

  defp get_required_ipv6(config, key) do
    case Map.get(config, key) do
      nil ->
        {:error, "Missing required field: #{key}"}

      ip when is_tuple(ip) and tuple_size(ip) == 8 ->
        {:ok, ip}

      ip when is_binary(ip) ->
        Ipv6Util.parse_string(ip)

      _ ->
        {:error, "Invalid IPv6 address format for #{key}"}
    end
  end

  defp validate_range_order(start_ip, end_ip) do
    if Ipv6Util.to_integer(start_ip) <= Ipv6Util.to_integer(end_ip) do
      :ok
    else
      {:error, "range_start must be less than or equal to range_end"}
    end
  end

  defp find_next_available(start_ip, end_ip, unavailable_ips) do
    start_int = Ipv6Util.to_integer(start_ip)
    end_int = Ipv6Util.to_integer(end_ip)

    # For large IPv6 ranges, we can't iterate through all addresses
    # Instead, use a random approach with collision detection
    max_attempts = 100

    result =
      Enum.reduce_while(1..max_attempts, nil, fn _attempt, _acc ->
        # Generate a random offset within the range
        offset = :rand.uniform(end_int - start_int + 1) - 1
        ip_int = start_int + offset
        ip = Ipv6Util.from_integer(ip_int)

        if not MapSet.member?(unavailable_ips, ip) do
          {:halt, {:ok, ip}}
        else
          {:cont, nil}
        end
      end)

    case result do
      nil -> {:error, :pool_exhausted}
      {:ok, ip} -> {:ok, ip}
    end
  end

  defp parse_dns_servers(dns_servers) when is_list(dns_servers) do
    Enum.flat_map(dns_servers, fn
      server when is_binary(server) ->
        case Ipv6Util.parse_string(server) do
          {:ok, ip_tuple} -> [ip_tuple]
          _ -> []
        end

      server when is_tuple(server) and tuple_size(server) == 8 ->
        [server]

      _ ->
        []
    end)
  end

  defp parse_dns_servers(_), do: []

  defp format_duid(duid), do: YellowDog.Dhcpv6.DuidFormat.format(duid) || "UNKNOWN"
end
