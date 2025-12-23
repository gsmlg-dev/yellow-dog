defmodule YellowDog.Dhcpv6.LeaseManager do
  @moduledoc """
  Manages DHCPv6 lease allocation and tracking using hybrid ETS+Mnesia storage.

  Uses ETS for fast lookups (hot cache) and Mnesia for durability (persistent storage).
  Tracks active leases with DUID → IPv6 bindings, handles lease expiration,
  and provides persistence across server restarts.
  """

  use GenServer

  alias YellowDog.Dhcpv6.{AddressPool, LeaseStorage}

  @table_name :dhcpv6_leases_cache
  @ets_options [:named_table, :public, :set, read_concurrency: true]
  # Run cleanup every minute
  @cleanup_interval 60_000

  @type ipv6_address :: AddressPool.ipv6_address()
  @type duid :: AddressPool.duid()
  @type lease :: %{
          ip: ipv6_address(),
          duid: duid(),
          iaid: non_neg_integer(),
          preferred_lifetime: pos_integer(),
          valid_lifetime: pos_integer(),
          expires_at: integer(),
          pool_name: String.t()
        }

  # Client API

  @doc """
  Starts the LeaseManager GenServer.

  ## Options
  - `pools` - List of address pool configurations

  ## Returns
  - `{:ok, pid}` - Successfully started
  - `{:error, reason}` - Failed to start
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Allocates or renews a lease for a DUID.

  ## Parameters
  - `duid` - Client DUID (DHCP Unique Identifier)
  - `iaid` - Identity Association Identifier
  - `requested_ip` - Optional requested IP address
  - `pool_name` - Pool name to allocate from (default: "default")

  ## Returns
  - `{:ok, lease}` - Successfully allocated/renewed lease
  - `{:error, reason}` - Failed to allocate lease
  """
  @spec allocate_lease(duid(), non_neg_integer(), ipv6_address() | nil, String.t()) ::
          {:ok, lease()} | {:error, term()}
  def allocate_lease(duid, iaid, requested_ip \\ nil, pool_name \\ "default") do
    GenServer.call(__MODULE__, {:allocate_lease, duid, iaid, requested_ip, pool_name})
  end

  @doc """
  Releases a lease for a DUID.

  ## Parameters
  - `duid` - Client DUID
  - `iaid` - Identity Association Identifier

  ## Returns
  - `:ok` - Lease released
  """
  @spec release_lease(duid(), non_neg_integer()) :: :ok
  def release_lease(duid, iaid) do
    GenServer.call(__MODULE__, {:release_lease, duid, iaid})
  end

  @doc """
  Declines an IP address (marks it as unavailable for a period).

  ## Parameters
  - `ip` - IP address to decline
  - `duid` - Client DUID that declined

  ## Returns
  - `:ok` - IP declined
  """
  @spec decline_ip(ipv6_address(), duid()) :: :ok
  def decline_ip(ip, duid) do
    GenServer.call(__MODULE__, {:decline_ip, ip, duid})
  end

  @doc """
  Gets the current lease for a DUID and IAID.

  ## Parameters
  - `duid` - Client DUID
  - `iaid` - Identity Association Identifier

  ## Returns
  - `{:ok, lease}` - Active lease found
  - `{:error, :not_found}` - No active lease
  """
  @spec get_lease(duid(), non_neg_integer()) :: {:ok, lease()} | {:error, :not_found}
  def get_lease(duid, iaid) do
    lease_key = make_lease_key(duid, iaid)

    case :ets.lookup(@table_name, lease_key) do
      [{^lease_key, lease}] ->
        # Check if lease is expired
        if lease.expires_at > System.system_time(:second) do
          {:ok, lease}
        else
          {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets all active leases.

  ## Returns
  - List of active leases
  """
  @spec list_leases() :: [lease()]
  def list_leases do
    now = System.system_time(:second)

    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_key, lease} -> lease end)
    |> Enum.filter(fn lease -> lease.expires_at > now end)
  end

  @doc """
  Gets all allocated IP addresses.

  ## Returns
  - MapSet of allocated IP addresses
  """
  @spec get_allocated_ips() :: MapSet.t(ipv6_address())
  def get_allocated_ips do
    list_leases()
    |> Enum.map(& &1.ip)
    |> MapSet.new()
  end

  @doc """
  Gets lease statistics.

  ## Returns
  - Map with lease statistics
  """
  @spec stats() :: map()
  def stats do
    now = System.system_time(:second)
    all_entries = :ets.tab2list(@table_name) |> Enum.map(fn {_key, lease} -> lease end)
    active_leases = Enum.filter(all_entries, fn lease -> lease.expires_at > now end)
    expired_leases = Enum.filter(all_entries, fn lease -> lease.expires_at <= now end)

    # Group by state
    by_state =
      all_entries
      |> Enum.group_by(& &1.state)
      |> Enum.map(fn {state, leases} -> {state, length(leases)} end)
      |> Map.new()

    # Group by IA type
    by_ia_type =
      all_entries
      |> Enum.group_by(& &1.ia_type)
      |> Enum.map(fn {ia_type, leases} -> {ia_type, length(leases)} end)
      |> Map.new()

    %{
      total_leases: length(all_entries),
      active_leases: length(active_leases),
      expired_leases: length(expired_leases),
      by_state: by_state,
      by_ia_type: by_ia_type
    }
  end

  @doc """
  Gets pool statistics for all configured pools.

  ## Returns
  - Map of pool_name => pool_stats
  """
  @spec get_all_pool_stats() :: %{String.t() => map()}
  def get_all_pool_stats do
    GenServer.call(__MODULE__, :get_all_pool_stats)
  end

  @doc """
  Gets the list of configured pools.

  ## Returns
  - List of pool structs
  """
  @spec get_pools() :: [map()]
  def get_pools do
    GenServer.call(__MODULE__, :get_pools)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # Initialize ETS table for hot cache
    init_table()

    # Initialize Mnesia storage for persistence
    storage_type = Keyword.get(opts, :storage_type, :disc_copies)

    case LeaseStorage.init(storage_type: storage_type) do
      :ok ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_manager, :storage_initialized],
          %{count: 1},
          %{storage_type: storage_type}
        )

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_manager, :storage_init_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )
    end

    # Load existing leases from Mnesia into ETS cache
    load_leases_from_storage()

    # Extract pools from options
    pools = Keyword.get(opts, :pools, [])

    # Parse pools into AddressPool configs
    parsed_pools =
      Enum.map(pools, fn pool_config ->
        case AddressPool.new(pool_config) do
          {:ok, pool} ->
            pool

          {:error, reason} ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :lease_manager, :pool_create_failed],
              %{count: 1},
              %{reason: inspect(reason)}
            )

            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Schedule periodic cleanup
    schedule_cleanup()

    state = %{
      pools: parsed_pools
    }

    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :lease_manager, :started],
      %{count: 1, pool_count: length(parsed_pools)},
      %{}
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:allocate_lease, duid, iaid, requested_ip, pool_name}, _from, state) do
    # Find the pool
    pool = Enum.find(state.pools, fn p -> p.name == pool_name end)

    if pool do
      result = do_allocate_lease(duid, iaid, requested_ip, pool)
      {:reply, result, state}
    else
      {:reply, {:error, :pool_not_found}, state}
    end
  end

  @impl true
  def handle_call({:release_lease, duid, iaid}, _from, state) do
    lease_key = make_lease_key(duid, iaid)

    # Delete from ETS cache
    :ets.delete(@table_name, lease_key)

    # Update state in Mnesia (mark as released instead of deleting)
    case LeaseStorage.update_state(duid, iaid, :released) do
      {:ok, _lease} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_manager, :lease_released],
          %{count: 1},
          %{duid: format_duid(duid), iaid: iaid}
        )

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_manager, :release_failed],
          %{count: 1},
          %{duid: format_duid(duid), iaid: iaid, reason: inspect(reason)}
        )
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:decline_ip, ip, duid}, _from, state) do
    # For now, just release any lease with this IP
    # In production, mark IP as temporarily unavailable
    leases = list_leases()

    Enum.each(leases, fn lease ->
      if lease.ip == ip do
        lease_key = make_lease_key(lease.duid, lease.iaid)
        :ets.delete(@table_name, lease_key)
      end
    end)

    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :lease_manager, :ip_declined],
      %{count: 1},
      %{ip: inspect(ip), duid: format_duid(duid)}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_all_pool_stats, _from, state) do
    pool_stats =
      state.pools
      |> Enum.map(fn pool ->
        stats = calculate_pool_stats(pool)
        {pool.name, stats}
      end)
      |> Map.new()

    {:reply, pool_stats, state}
  end

  @impl true
  def handle_call(:get_pools, _from, state) do
    {:reply, state.pools, state}
  end

  @impl true
  def handle_info(:cleanup_expired_leases, state) do
    cleanup_expired_leases()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private helper functions

  defp init_table do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, @ets_options)
    end

    :ok
  end

  defp make_lease_key(duid, iaid) do
    "#{format_duid(duid)}:#{iaid}"
  end

  defp do_allocate_lease(duid, iaid, requested_ip, pool) do
    lease_key = make_lease_key(duid, iaid)

    # Check for existing lease in ETS cache first
    case :ets.lookup(@table_name, lease_key) do
      [{^lease_key, existing_lease}] ->
        # Renew existing lease
        renewed_lease = renew_lease(existing_lease)

        # Update in ETS cache
        :ets.insert(@table_name, {lease_key, renewed_lease})

        # Update in Mnesia
        store_lease_to_mnesia(renewed_lease)

        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_manager, :lease_renewed],
          %{count: 1},
          %{duid: format_duid(duid), iaid: iaid, ip: inspect(renewed_lease.ip)}
        )

        {:ok, renewed_lease}

      [] ->
        # Check Mnesia for existing lease (may not be in ETS cache)
        case LeaseStorage.get(duid, iaid) do
          {:ok, stored_lease} ->
            # Lease exists in Mnesia but not in cache, renew it
            renewed_lease = renew_lease(stored_lease)
            :ets.insert(@table_name, {lease_key, renewed_lease})
            store_lease_to_mnesia(renewed_lease)

            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :lease_manager, :lease_renewed_from_storage],
              %{count: 1},
              %{duid: format_duid(duid), iaid: iaid, ip: inspect(renewed_lease.ip)}
            )

            {:ok, renewed_lease}

          {:error, :not_found} ->
            # Allocate new lease
            allocate_new_lease(duid, iaid, lease_key, requested_ip, pool)
        end
    end
  end

  defp allocate_new_lease(duid, iaid, lease_key, requested_ip, pool) do
    allocated_ips = get_allocated_ips()

    # Try to honor requested IP if provided and available
    ip =
      cond do
        requested_ip && AddressPool.in_range?(pool, requested_ip) &&
            not MapSet.member?(allocated_ips, requested_ip) ->
          requested_ip

        true ->
          case AddressPool.get_available_ip(pool, allocated_ips, duid) do
            {:ok, available_ip} -> available_ip
            {:error, :pool_exhausted} -> nil
          end
      end

    if ip do
      lease = %{
        duid: duid,
        iaid: iaid,
        ip_address: ip,
        # Legacy compatibility
        ip: ip,
        pool_name: pool.name,
        ia_type: :ia_na,
        state: :active,
        preferred_lifetime: pool.preferred_lifetime,
        valid_lifetime: pool.valid_lifetime,
        expires_at: System.system_time(:second) + pool.valid_lifetime
      }

      # Store in ETS cache
      :ets.insert(@table_name, {lease_key, lease})

      # Store in Mnesia for persistence
      store_lease_to_mnesia(lease)

      :telemetry.execute(
        [:yellow_dog, :dhcpv6, :lease_manager, :lease_allocated],
        %{count: 1},
        %{duid: format_duid(duid), iaid: iaid, ip: ip, pool: pool.name}
      )

      {:ok, lease}
    else
      :telemetry.execute(
        [:yellow_dog, :dhcpv6, :lease_manager, :pool_exhausted],
        %{count: 1},
        %{pool_name: pool.name}
      )

      {:error, :pool_exhausted}
    end
  end

  defp renew_lease(lease) do
    %{lease | expires_at: System.system_time(:second) + lease.valid_lifetime}
  end

  defp cleanup_expired_leases do
    now = System.system_time(:second)

    # Clean up ETS cache
    expired_leases =
      @table_name
      |> :ets.tab2list()
      |> Enum.filter(fn {_key, lease} -> lease.expires_at <= now end)

    Enum.each(expired_leases, fn {key, _lease} ->
      :ets.delete(@table_name, key)
    end)

    ets_expired_count = length(expired_leases)

    # Clean up Mnesia (mark as expired)
    case LeaseStorage.cleanup_expired() do
      {:ok, mnesia_expired_count} ->
        if ets_expired_count > 0 || mnesia_expired_count > 0 do
          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :lease_manager, :cleanup_completed],
            %{ets_expired: ets_expired_count, mnesia_expired: mnesia_expired_count},
            %{}
          )
        end

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_manager, :cleanup_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired_leases, @cleanup_interval)
  end

  defp store_lease_to_mnesia(lease) do
    case LeaseStorage.put(lease) do
      {:ok, _stored_lease} ->
        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_manager, :store_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        :error
    end
  end

  defp load_leases_from_storage do
    # Load all active leases from Mnesia into ETS cache
    active_leases = LeaseStorage.list_active()

    loaded_count =
      Enum.reduce(active_leases, 0, fn lease, count ->
        lease_key = make_lease_key(lease.duid, lease.iaid)

        # Ensure lease has both ip and ip_address for compatibility
        lease_with_compat =
          lease
          |> Map.put(:ip, lease[:ip_address] || lease[:ip])
          |> Map.put(:ip_address, lease[:ip_address] || lease[:ip])

        :ets.insert(@table_name, {lease_key, lease_with_compat})
        count + 1
      end)

    if loaded_count > 0 do
      :telemetry.execute(
        [:yellow_dog, :dhcpv6, :lease_manager, :leases_loaded],
        %{count: loaded_count},
        %{}
      )
    end

    :ok
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

  defp calculate_pool_stats(pool) do
    # Get all leases for this pool
    all_leases = list_leases() |> Enum.filter(fn l -> l.pool_name == pool.name end)
    now = System.system_time(:second)
    active_leases = Enum.filter(all_leases, fn l -> l.expires_at > now end)

    # Group leases by state
    leases_by_state =
      all_leases
      |> Enum.group_by(& &1.state)
      |> Enum.map(fn {state, leases} -> {state, length(leases)} end)
      |> Map.new()

    # Calculate pool size based on pool type
    total_count =
      cond do
        # Address pool (has range_start/range_end or ranges)
        Map.has_key?(pool, :range_start) ->
          AddressPool.pool_size(pool)

        # Prefix delegation pool (has prefix/prefix_length)
        Map.has_key?(pool, :prefix) ->
          # Calculate prefix pool size
          prefix_bits = pool.delegated_length - pool.prefix_length
          :math.pow(2, prefix_bits) |> trunc()

        true ->
          0
      end

    allocated_count = length(active_leases)
    available_count = max(0, total_count - allocated_count)

    utilization_percent =
      if total_count > 0 do
        allocated_count / total_count * 100.0
      else
        0.0
      end

    # Count static reservations
    static_count =
      cond do
        Map.has_key?(pool, :static_reservations) and is_map(pool.static_reservations) ->
          map_size(pool.static_reservations)

        Map.has_key?(pool, :static_reservations) and is_list(pool.static_reservations) ->
          length(pool.static_reservations)

        true ->
          0
      end

    %{
      total_count: total_count,
      allocated_count: allocated_count,
      available_count: available_count,
      utilization_percent: utilization_percent,
      leases_by_state: leases_by_state,
      static_reservations: static_count
    }
  end
end
