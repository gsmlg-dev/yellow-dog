defmodule YellowDog.Dhcpv6.PrefixPool do
  @moduledoc """
  IPv6 prefix delegation pool management for DHCPv6 IA_PD.

  Manages delegated prefixes for router clients, allowing them to request
  and receive IPv6 prefix blocks for their downstream networks.

  ## Prefix Delegation

  - Routers request prefixes via IA_PD (Identity Association for Prefix Delegation)
  - Server allocates a portion of a larger prefix to each router
  - Example: From a /48, delegate /56 prefixes to routers
  - Each router gets a unique /56 that they can subdivide for their networks

  ## Configuration Example

  ```elixir
  %{
    name: "customer-prefixes",
    prefix: {0x2001, 0x0DB8, 0x1000, 0, 0, 0, 0, 0},
    prefix_length: 48,
    delegated_length: 56,
    exclude_prefixes: []
  }
  ```

  This would allocate /56 prefixes from the 2001:db8:1000::/48 block.
  """

  import Bitwise

  @type ipv6_address ::
          {0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535, 0..65535}
  @type duid :: binary()
  @type prefix :: {ipv6_address(), pos_integer()}

  @type prefix_pool_config :: %{
          name: String.t(),
          prefix: ipv6_address(),
          prefix_length: pos_integer(),
          delegated_length: pos_integer(),
          exclude_prefixes: [prefix()],
          static_reservations: %{String.t() => prefix()}
        }

  @doc """
  Creates a new prefix delegation pool from configuration.

  ## Parameters
  - `config` - Pool configuration map with:
    - `prefix` - Base IPv6 prefix (e.g., "2001:db8::/32")
    - `prefix_length` - Length of base prefix (e.g., 32)
    - `delegated_length` - Length of delegated prefixes (e.g., 48)
    - `exclude_prefixes` - List of prefixes to exclude (optional)
    - `static_reservations` - DUID → prefix mappings (optional)

  ## Returns
  - `{:ok, pool}` - Successfully created pool
  - `{:error, reason}` - Failed to create pool
  """
  @spec new(map()) :: {:ok, prefix_pool_config()} | {:error, term()}
  def new(config) do
    with {:ok, prefix} <- parse_prefix(config),
         {:ok, prefix_length} <- validate_prefix_length(config, :prefix_length),
         {:ok, delegated_length} <- validate_prefix_length(config, :delegated_length),
         :ok <- validate_delegation_range(prefix_length, delegated_length) do
      # Parse exclude prefixes
      exclude_prefixes =
        config
        |> Map.get(:exclude_prefixes, [])
        |> parse_prefix_list()

      # Parse static reservations
      reservations = parse_reservations(Map.get(config, :static_reservations, []))

      pool = %{
        name: Map.get(config, :name, "default-pd"),
        prefix: prefix,
        prefix_length: prefix_length,
        delegated_length: delegated_length,
        exclude_prefixes: exclude_prefixes,
        static_reservations: reservations
      }

      {:ok, pool}
    end
  end

  @doc """
  Allocates a delegated prefix from the pool.

  ## Parameters
  - `pool` - Prefix pool configuration
  - `allocated_prefixes` - Set of already allocated prefixes
  - `duid` - DUID requesting the prefix (for static reservation check)

  ## Returns
  - `{:ok, {prefix, prefix_length}}` - Allocated prefix
  - `{:error, :pool_exhausted}` - No available prefixes
  """
  @spec allocate_prefix(prefix_pool_config(), MapSet.t(prefix()), duid()) ::
          {:ok, prefix()} | {:error, :pool_exhausted}
  def allocate_prefix(pool, allocated_prefixes, duid) do
    # Check for static reservation first
    case get_static_reservation(pool, duid) do
      {:ok, prefix} ->
        {:ok, prefix}

      :not_found ->
        # Combine allocated prefixes with excluded prefixes
        unavailable = MapSet.union(allocated_prefixes, MapSet.new(pool.exclude_prefixes))

        # Calculate next available prefix
        find_available_prefix(pool, unavailable)
    end
  end

  @doc """
  Checks if a prefix is within the pool's delegation range.

  ## Parameters
  - `pool` - Prefix pool configuration
  - `prefix` - Prefix tuple {address, prefix_length}

  ## Returns
  - `true` if prefix is in range, `false` otherwise
  """
  @spec in_range?(prefix_pool_config(), prefix()) :: boolean()
  def in_range?(pool, {prefix_addr, prefix_len}) do
    if prefix_len != pool.delegated_length do
      false
    else
      # Check if prefix falls within the pool's base prefix
      pool_int = ipv6_to_integer(pool.prefix)
      prefix_int = ipv6_to_integer(prefix_addr)

      # Create mask for the pool's prefix length
      mask = create_prefix_mask(pool.prefix_length)

      # Compare masked values
      (pool_int &&& mask) == (prefix_int &&& mask)
    end
  end

  @doc """
  Gets static reservation for a DUID.

  ## Parameters
  - `pool` - Prefix pool configuration
  - `duid` - Client DUID

  ## Returns
  - `{:ok, prefix}` if reservation exists
  - `:not_found` otherwise
  """
  @spec get_static_reservation(prefix_pool_config(), duid()) :: {:ok, prefix()} | :not_found
  def get_static_reservation(pool, duid) do
    formatted_duid = format_duid(duid)

    case Map.get(pool.static_reservations, formatted_duid) do
      nil -> :not_found
      prefix -> {:ok, prefix}
    end
  end

  @doc """
  Calculates the total number of delegatable prefixes in the pool.

  ## Parameters
  - `pool` - Prefix pool configuration

  ## Returns
  - Number of prefixes that can be delegated
  """
  @spec pool_size(prefix_pool_config()) :: non_neg_integer()
  def pool_size(pool) do
    # Number of prefixes = 2^(delegated_length - prefix_length)
    prefix_bits = pool.delegated_length - pool.prefix_length

    if prefix_bits > 0 and prefix_bits < 64 do
      total = 1 <<< prefix_bits
      # Subtract excluded prefixes
      total - length(pool.exclude_prefixes)
    else
      0
    end
  end

  ## Private Functions

  defp parse_prefix(config) do
    case Map.get(config, :prefix) do
      nil ->
        {:error, "Missing required field: prefix"}

      prefix when is_tuple(prefix) and tuple_size(prefix) == 8 ->
        {:ok, prefix}

      prefix when is_binary(prefix) ->
        parse_ipv6_string(prefix)

      _ ->
        {:error, "Invalid IPv6 prefix format"}
    end
  end

  defp validate_prefix_length(config, key) do
    case Map.get(config, key) do
      nil ->
        {:error, "Missing required field: #{key}"}

      length when is_integer(length) and length > 0 and length <= 128 ->
        {:ok, length}

      _ ->
        {:error, "Invalid prefix length for #{key}"}
    end
  end

  defp validate_delegation_range(prefix_length, delegated_length) do
    cond do
      delegated_length <= prefix_length ->
        {:error, "Delegated length must be greater than prefix length"}

      delegated_length - prefix_length > 32 ->
        {:error, "Delegation range too large (> 32 bits)"}

      true ->
        :ok
    end
  end

  defp parse_prefix_list(prefixes) when is_list(prefixes) do
    Enum.flat_map(prefixes, fn
      # String format: "2001:db8::/48"
      prefix_str when is_binary(prefix_str) ->
        case String.split(prefix_str, "/") do
          [addr_str, len_str] ->
            with {:ok, addr} <- parse_ipv6_string(addr_str),
                 {len, ""} <- Integer.parse(len_str) do
              [{addr, len}]
            else
              _ -> []
            end

          _ ->
            []
        end

      # Tuple format: {{addr}, length}
      {addr, len} when is_tuple(addr) and is_integer(len) ->
        [{addr, len}]

      _ ->
        []
    end)
  end

  defp parse_prefix_list(_), do: []

  defp parse_reservations(reservations) when is_list(reservations) do
    Enum.reduce(reservations, %{}, fn
      %{duid: duid, prefix: prefix_str, prefix_length: len}, acc
      when is_binary(prefix_str) and is_integer(len) ->
        case parse_ipv6_string(prefix_str) do
          {:ok, prefix_addr} ->
            Map.put(acc, format_duid(duid), {prefix_addr, len})

          _ ->
            acc
        end

      %{duid: duid, prefix: prefix_addr, prefix_length: len}, acc
      when is_tuple(prefix_addr) and is_integer(len) ->
        Map.put(acc, format_duid(duid), {prefix_addr, len})

      _, acc ->
        acc
    end)
  end

  defp parse_reservations(_), do: %{}

  defp find_available_prefix(pool, unavailable_prefixes) do
    max_prefixes = pool_size(pool)

    if max_prefixes == 0 do
      {:error, :pool_exhausted}
    else
      # Try to find an available prefix
      # For large pools, use random search to avoid scanning all possibilities
      max_attempts = min(100, max_prefixes)

      result =
        Enum.find_value(1..max_attempts, fn _attempt ->
          offset = :rand.uniform(max_prefixes) - 1
          candidate = calculate_delegated_prefix(pool, offset)

          if not MapSet.member?(unavailable_prefixes, candidate) do
            candidate
          else
            nil
          end
        end)

      case result do
        nil -> {:error, :pool_exhausted}
        prefix -> {:ok, prefix}
      end
    end
  end

  defp calculate_delegated_prefix(pool, offset) do
    # Calculate the prefix at the given offset
    pool_int = ipv6_to_integer(pool.prefix)

    # Shift offset by the number of bits in each delegated prefix
    shift_amount = 128 - pool.delegated_length

    # Add offset to the base prefix
    delegated_int = pool_int + (offset <<< shift_amount)

    # Mask to ensure we stay within bounds
    mask = create_prefix_mask(pool.delegated_length)
    final_int = delegated_int &&& (mask ||| (1 <<< (128 - pool.delegated_length)) - 1)

    prefix_addr = integer_to_ipv6(final_int)
    {prefix_addr, pool.delegated_length}
  end

  defp create_prefix_mask(prefix_length) do
    if prefix_length == 0 do
      0
    else
      # Create a mask with 'prefix_length' ones, followed by zeros
      ((1 <<< prefix_length) - 1) <<< (128 - prefix_length)
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
    |> Enum.map_join(":", fn b -> b |> Integer.to_string(16) |> String.pad_leading(2, "0") end)
    |> String.upcase()
  end

  defp format_duid(_), do: "UNKNOWN"
end
