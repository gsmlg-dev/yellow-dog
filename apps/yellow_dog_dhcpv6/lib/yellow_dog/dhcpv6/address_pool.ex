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
      reservations =
        case Map.get(config, :static_reservations, %{}) do
          list when is_list(list) ->
            # Convert list format to map
            Enum.reduce(list, %{}, fn reservation, acc ->
              case reservation do
                %{duid: duid, address: address} when is_binary(address) ->
                  case parse_ipv6_string(address) do
                    {:ok, ip_tuple} ->
                      Map.put(acc, format_duid(duid), ip_tuple)

                    _ ->
                      acc
                  end

                %{duid: duid, address: address} when is_tuple(address) ->
                  Map.put(acc, format_duid(duid), address)

                _ ->
                  acc
              end
            end)

          map when is_map(map) ->
            map

          _ ->
            %{}
        end

      # Parse exclude addresses
      exclude_addresses =
        config
        |> Map.get(:exclude_addresses, [])
        |> Enum.flat_map(fn
          addr when is_binary(addr) ->
            case parse_ipv6_string(addr) do
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
        ranges: validated_config.ranges,
        range_start: validated_config[:range_start],
        range_end: validated_config[:range_end],
        exclude_addresses: exclude_addresses,
        prefix_length: Map.get(config, :prefix_length, 64),
        dns_servers: parse_dns_servers(Map.get(config, :dns_servers, [])),
        domain_name: Map.get(config, :domain_name),
        preferred_lifetime: Map.get(config, :preferred_lifetime, 3600),
        valid_lifetime: Map.get(config, :valid_lifetime, 7200),
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
      # New format: multiple ranges
      Map.has_key?(config, :ranges) && is_list(config.ranges) ->
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
        parse_ipv6_string(ip)

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
    ip_int = ipv6_to_integer(ip)

    Enum.any?(pool.ranges, fn range ->
      start_int = ipv6_to_integer(range.start)
      end_int = ipv6_to_integer(range.end)
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
        start_int = ipv6_to_integer(range.start)
        end_int = ipv6_to_integer(range.end)
        acc + (end_int - start_int + 1)
      end)

    # Subtract excluded addresses
    total_size - MapSet.size(pool.exclude_addresses)
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

  defp parse_dns_servers(dns_servers) when is_list(dns_servers) do
    Enum.flat_map(dns_servers, fn
      server when is_binary(server) ->
        case parse_ipv6_string(server) do
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
