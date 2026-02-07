defmodule YellowDog.Dhcpv4.PoolStats do
  @moduledoc """
  Per-pool statistics and utilization tracking for DHCPv4.

  Provides detailed metrics for each address pool including:
  - Total capacity and available addresses
  - Utilization percentage
  - Lease distribution by state
  - Allocation rates and trends
  """

  alias YellowDog.Dhcpv4.{AddressPool, LeaseStorage}

  @type pool_stats :: %{
          pool_name: String.t(),
          total_addresses: non_neg_integer(),
          allocated_addresses: non_neg_integer(),
          available_addresses: non_neg_integer(),
          utilization_percent: float(),
          static_reservations: non_neg_integer(),
          leases_by_state: %{atom() => non_neg_integer()},
          ranges: [AddressPool.ip_range()],
          excluded_ranges: [AddressPool.ip_range()]
        }

  @doc """
  Gets comprehensive statistics for a specific pool.

  ## Parameters
  - `pool` - Pool configuration
  - `opts` - Optional keyword list of options

  ## Returns
  - Map with detailed pool statistics

  ## Examples
      iex> pool = %{name: "default", ranges: [...], ...}
      iex> YellowDog.Dhcpv4.PoolStats.get_pool_stats(pool)
      %{
        pool_name: "default",
        total_addresses: 101,
        allocated_addresses: 45,
        available_addresses: 56,
        utilization_percent: 44.55,
        static_reservations: 2,
        leases_by_state: %{active: 40, offered: 3, released: 2},
        ranges: [{{192, 168, 1, 100}, {192, 168, 1, 200}}],
        excluded_ranges: []
      }
  """
  @spec get_pool_stats(AddressPool.pool_config(), keyword()) :: pool_stats()
  def get_pool_stats(pool, _opts \\ []) do
    total_addresses = AddressPool.pool_size(pool)
    static_reservations = map_size(pool.static_reservations || %{})

    # Get all leases for this pool
    pool_leases = LeaseStorage.list(pool_name: pool.name)

    # Count leases by state
    leases_by_state = count_leases_by_state(pool_leases)

    # Count allocated (active + offered) addresses
    allocated_addresses =
      Map.get(leases_by_state, :active, 0) +
        Map.get(leases_by_state, :offered, 0)

    available_addresses = max(total_addresses - allocated_addresses, 0)

    utilization_percent =
      if total_addresses > 0 do
        Float.round(allocated_addresses * 100.0 / total_addresses, 2)
      else
        0.0
      end

    %{
      pool_name: pool.name,
      total_addresses: total_addresses,
      allocated_addresses: allocated_addresses,
      available_addresses: available_addresses,
      utilization_percent: utilization_percent,
      static_reservations: static_reservations,
      leases_by_state: leases_by_state,
      ranges: pool.ranges,
      excluded_ranges: pool.excluded_ranges
    }
  end

  @doc """
  Gets statistics for all pools.

  ## Parameters
  - `pools` - List of pool configurations

  ## Returns
  - Map with pool names as keys and statistics as values
  """
  @spec get_all_pool_stats([AddressPool.pool_config()]) :: %{String.t() => pool_stats()}
  def get_all_pool_stats(pools) do
    Map.new(pools, fn pool ->
      {pool.name, get_pool_stats(pool)}
    end)
  end

  @doc """
  Gets a summary of utilization across all pools.

  ## Parameters
  - `pools` - List of pool configurations

  ## Returns
  - Map with aggregated statistics
  """
  @spec get_global_utilization([AddressPool.pool_config()]) :: map()
  def get_global_utilization(pools) do
    pool_stats = get_all_pool_stats(pools)

    total_addresses =
      pool_stats
      |> Map.values()
      |> Enum.map(& &1.total_addresses)
      |> Enum.sum()

    total_allocated =
      pool_stats
      |> Map.values()
      |> Enum.map(& &1.allocated_addresses)
      |> Enum.sum()

    total_available =
      pool_stats
      |> Map.values()
      |> Enum.map(& &1.available_addresses)
      |> Enum.sum()

    global_utilization =
      if total_addresses > 0 do
        Float.round(total_allocated * 100.0 / total_addresses, 2)
      else
        0.0
      end

    %{
      total_pools: length(pools),
      total_addresses: total_addresses,
      total_allocated: total_allocated,
      total_available: total_available,
      global_utilization_percent: global_utilization,
      pool_stats: pool_stats
    }
  end

  @doc """
  Checks if a pool is approaching exhaustion.

  ## Parameters
  - `pool` - Pool configuration
  - `threshold` - Warning threshold percentage (default: 90.0)

  ## Returns
  - `{:warning, percent}` if utilization exceeds threshold
  - `:ok` if utilization is below threshold
  """
  @spec check_pool_utilization(AddressPool.pool_config(), float()) ::
          :ok | {:warning, float()}
  def check_pool_utilization(pool, threshold \\ 90.0) do
    stats = get_pool_stats(pool)

    if stats.utilization_percent >= threshold do
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :pool, :high_utilization],
        %{
          count: 1,
          utilization_percent: stats.utilization_percent,
          available_addresses: stats.available_addresses
        },
        %{pool_name: pool.name}
      )

      {:warning, stats.utilization_percent}
    else
      :ok
    end
  end

  @doc """
  Gets lease distribution statistics for a pool.

  Shows how leases are distributed across different time ranges
  (e.g., expiring soon, recently allocated).

  ## Parameters
  - `pool` - Pool configuration

  ## Returns
  - Map with lease distribution information
  """
  @spec get_lease_distribution(AddressPool.pool_config()) :: map()
  def get_lease_distribution(pool) do
    now = System.system_time(:second)

    pool_leases = LeaseStorage.list(pool_name: pool.name, active_only: true)

    # Classify leases by remaining time
    {expiring_soon, expiring_later} =
      Enum.split_with(pool_leases, fn lease ->
        remaining = lease.expires_at - now
        remaining < 3600
      end)

    # Less than 1 hour remaining

    {recently_allocated, older} =
      Enum.split_with(pool_leases, fn lease ->
        age = now - lease.created_at
        age < 3600
      end)

    # Less than 1 hour old

    %{
      total_active_leases: length(pool_leases),
      expiring_soon: length(expiring_soon),
      expiring_later: length(expiring_later),
      recently_allocated: length(recently_allocated),
      older_leases: length(older)
    }
  end

  @doc """
  Formats pool statistics for human-readable display.

  ## Parameters
  - `pool_stats` - Pool statistics map

  ## Returns
  - Formatted string
  """
  @spec format_pool_stats(pool_stats()) :: String.t()
  def format_pool_stats(stats) do
    """
    Pool: #{stats.pool_name}
      Total Addresses: #{stats.total_addresses}
      Allocated: #{stats.allocated_addresses}
      Available: #{stats.available_addresses}
      Utilization: #{stats.utilization_percent}%
      Static Reservations: #{stats.static_reservations}
      Leases by State:
    #{format_leases_by_state(stats.leases_by_state)}
      Ranges: #{format_ranges(stats.ranges)}
      Excluded: #{format_ranges(stats.excluded_ranges)}
    """
  end

  # Private helper functions

  defp count_leases_by_state(leases) do
    leases
    |> Enum.group_by(& &1.state)
    |> Map.new(fn {state, state_leases} -> {state, length(state_leases)} end)
  end

  defp format_leases_by_state(leases_by_state) do
    Enum.map_join(leases_by_state, "\n", fn {state, count} ->
      "        #{state}: #{count}"
    end)
  end

  defp format_ranges([]), do: "none"

  defp format_ranges(ranges) do
    Enum.map_join(ranges, ", ", fn {start_ip, end_ip} ->
      "#{format_ip(start_ip)} - #{format_ip(end_ip)}"
    end)
  end

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
end
