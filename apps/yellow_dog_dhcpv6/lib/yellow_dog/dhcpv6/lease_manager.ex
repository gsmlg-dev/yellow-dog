defmodule YellowDog.Dhcpv6.LeaseManager do
  @moduledoc """
  Manages DHCPv6 lease allocation and tracking using hybrid ETS+Mnesia storage.

  Uses ETS for fast lookups (hot cache) and Mnesia for durability (persistent storage).
  Tracks active leases with DUID → IPv6 bindings, handles lease expiration,
  and provides persistence across server restarts.

  ## Persistence Strategy

  Uses dual storage:
  - **Mnesia**: Primary runtime storage with transactional support
  - **ETS**: Hot cache for fast lookups
  - **TOML files**: Human-readable backup, loaded on startup, flushed periodically

  Leases are flushed to TOML files:
  - Every 30 seconds (configurable via :lease_flush_interval_ms)
  - On graceful shutdown via terminate/2
  """

  use GenServer

  import YellowDog.ConfigHelpers, only: [get_value: 3]

  alias YellowDog.Dhcpv6.{AddressPool, DuidFormat, Ipv6Util, LeaseStorage, PoolStore}

  @table_name :dhcpv6_leases_cache
  @ets_options [:named_table, :public, :set, read_concurrency: true]
  # Run cleanup every minute
  @cleanup_interval 60_000
  # Default lease flush interval (30 seconds)
  @default_flush_interval 30_000

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

    for {_key, lease} <- :ets.tab2list(@table_name),
        lease.expires_at > now,
        do: lease
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
    all_entries = for {_key, lease} <- :ets.tab2list(@table_name), do: lease
    active_leases = Enum.filter(all_entries, fn lease -> lease.expires_at > now end)
    expired_leases = Enum.filter(all_entries, fn lease -> lease.expires_at <= now end)

    # Group by state
    by_state =
      all_entries
      |> Enum.group_by(& &1.state)
      |> Map.new(fn {state, leases} -> {state, length(leases)} end)

    # Group by IA type
    by_ia_type =
      all_entries
      |> Enum.group_by(& &1.ia_type)
      |> Map.new(fn {ia_type, leases} -> {ia_type, length(leases)} end)

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

  @doc """
  Adds a new address pool to the LeaseManager.

  ## Parameters
  - `pool_config` - Pool configuration map with keys like :name, :range_start, :range_end, etc.

  ## Returns
  - `{:ok, pool}` - Successfully added pool
  - `{:error, :pool_already_exists}` - Pool with same name already exists
  - `{:error, :range_overlap}` - Range overlaps with existing pool
  - `{:error, reason}` - Invalid pool configuration
  """
  @spec add_pool(map()) :: {:ok, map()} | {:error, term()}
  def add_pool(pool_config) do
    GenServer.call(__MODULE__, {:add_pool, pool_config})
  end

  @doc """
  Updates an existing address pool.

  ## Parameters
  - `pool_name` - Name of the pool to update
  - `pool_config` - New pool configuration (name cannot be changed)

  ## Returns
  - `{:ok, pool}` - Successfully updated pool
  - `{:error, :pool_not_found}` - Pool does not exist
  - `{:error, :range_overlap}` - New range overlaps with other pools
  - `{:error, reason}` - Invalid pool configuration
  """
  @spec update_pool(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_pool(pool_name, pool_config) do
    GenServer.call(__MODULE__, {:update_pool, pool_name, pool_config})
  end

  @doc """
  Removes an address pool.

  ## Parameters
  - `pool_name` - Name of the pool to remove
  - `opts` - Options
    - `:force` - If true, removes pool even if it has active leases (default: false)

  ## Returns
  - `:ok` - Successfully removed pool
  - `{:error, :pool_not_found}` - Pool does not exist
  - `{:error, :has_active_leases}` - Pool has active leases (use force: true to override)
  """
  @spec remove_pool(String.t(), keyword()) :: :ok | {:error, term()}
  def remove_pool(pool_name, opts \\ []) do
    GenServer.call(__MODULE__, {:remove_pool, pool_name, opts})
  end

  @doc """
  Persists current pools to the pools.toml file.

  ## Parameters
  - `file_path` - Optional file path (defaults to data/dhcpv6/pools.toml)

  ## Returns
  - `:ok` - Successfully saved
  - `{:error, reason}` - Failed to save
  """
  @spec persist_pools(String.t() | nil) :: :ok | {:error, term()}
  def persist_pools(file_path \\ nil) do
    GenServer.call(__MODULE__, {:persist_pools, file_path})
  end

  @doc """
  Manually triggers a flush of all leases to TOML files.

  This is useful for ensuring lease data is persisted before a planned
  maintenance window or when you want to guarantee durability.

  ## Returns
  - `:ok` - Successfully flushed
  """
  @spec flush_leases() :: :ok
  def flush_leases do
    GenServer.call(__MODULE__, :flush_leases)
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

    # Extract pools from options or load from storage
    pools_from_opts = Keyword.get(opts, :pools, [])

    pools =
      if pools_from_opts == [] do
        # No pools in options - try loading from storage
        case PoolStore.load_pools() do
          {:ok, loaded_pools} ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :pool_store, :pools_loaded_on_init],
              %{count: length(loaded_pools)},
              %{}
            )

            loaded_pools

          {:error, reason} ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :pool_store, :load_failed_on_init],
              %{count: 1},
              %{reason: inspect(reason)}
            )

            []
        end
      else
        pools_from_opts
      end

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

    # Load leases from TOML files for each pool
    load_leases_from_toml(parsed_pools)

    # Schedule periodic cleanup
    schedule_cleanup()

    # Schedule periodic lease flush to TOML
    flush_interval = Keyword.get(opts, :lease_flush_interval_ms, @default_flush_interval)
    schedule_lease_flush(flush_interval)

    state = %{
      pools: parsed_pools,
      flush_interval: flush_interval,
      last_flush_at: System.system_time(:second)
    }

    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :lease_manager, :started],
      %{count: 1, pool_count: length(parsed_pools)},
      %{flush_interval_ms: flush_interval}
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
          %{duid: DuidFormat.format!(duid), iaid: iaid}
        )

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv6, :lease_manager, :release_failed],
          %{count: 1},
          %{duid: DuidFormat.format!(duid), iaid: iaid, reason: inspect(reason)}
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
      %{ip: inspect(ip), duid: DuidFormat.format!(duid)}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_all_pool_stats, _from, state) do
    pool_stats =
      Map.new(state.pools, fn pool ->
        stats = calculate_pool_stats(pool)
        {pool.name, stats}
      end)

    {:reply, pool_stats, state}
  end

  @impl true
  def handle_call(:get_pools, _from, state) do
    {:reply, state.pools, state}
  end

  @impl true
  def handle_call({:add_pool, pool_config}, _from, state) do
    # Check if pool with same name already exists
    pool_name = get_value(pool_config, :name, "default")

    if Enum.any?(state.pools, fn p -> p.name == pool_name end) do
      {:reply, {:error, :pool_already_exists}, state}
    else
      # Validate and create the pool
      case AddressPool.new(pool_config) do
        {:ok, new_pool} ->
          # Check for range overlap with existing pools
          case check_range_overlap(new_pool, state.pools) do
            :ok ->
              updated_pools = state.pools ++ [new_pool]

              # Persist to storage
              pool_to_save = pool_struct_to_config(new_pool)
              PoolStore.save_pool(pool_to_save)

              :telemetry.execute(
                [:yellow_dog, :dhcpv6, :pool, :added],
                %{count: 1},
                %{pool_name: pool_name}
              )

              {:reply, {:ok, new_pool}, %{state | pools: updated_pools}}

            {:error, :range_overlap} = error ->
              {:reply, error, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:update_pool, pool_name, pool_config}, _from, state) do
    case Enum.find_index(state.pools, fn p -> p.name == pool_name end) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      index ->
        existing_pool = Enum.at(state.pools, index)

        # Merge updates with existing pool config, preserving the name
        updated_config = Map.merge(existing_pool, pool_config) |> Map.put(:name, pool_name)

        case AddressPool.new(updated_config) do
          {:ok, updated_pool} ->
            # Check for range overlap (excluding the pool being updated)
            other_pools = List.delete_at(state.pools, index)

            case check_range_overlap(updated_pool, other_pools) do
              :ok ->
                updated_pools = List.replace_at(state.pools, index, updated_pool)

                # Persist to storage
                pool_to_save = pool_struct_to_config(updated_pool)
                PoolStore.save_pool(pool_to_save)

                :telemetry.execute(
                  [:yellow_dog, :dhcpv6, :pool, :updated],
                  %{count: 1},
                  %{pool_name: pool_name}
                )

                {:reply, {:ok, updated_pool}, %{state | pools: updated_pools}}

              {:error, :range_overlap} = error ->
                {:reply, error, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  @impl true
  def handle_call({:remove_pool, pool_name, opts}, _from, state) do
    force = Keyword.get(opts, :force, false)

    case Enum.find_index(state.pools, fn p -> p.name == pool_name end) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      index ->
        # Check for active leases unless force is true
        if force do
          updated_pools = List.delete_at(state.pools, index)

          # Remove from storage
          PoolStore.remove_pool(pool_name)

          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :pool, :removed],
            %{count: 1},
            %{pool_name: pool_name, forced: true}
          )

          {:reply, :ok, %{state | pools: updated_pools}}
        else
          active_lease_count = count_pool_leases(pool_name)

          if active_lease_count > 0 do
            {:reply, {:error, :has_active_leases}, state}
          else
            updated_pools = List.delete_at(state.pools, index)

            # Remove from storage
            PoolStore.remove_pool(pool_name)

            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :pool, :removed],
              %{count: 1},
              %{pool_name: pool_name, forced: false}
            )

            {:reply, :ok, %{state | pools: updated_pools}}
          end
        end
    end
  end

  @impl true
  def handle_call({:persist_pools, _file_path}, _from, state) do
    # Convert pool structs to serializable format
    pool_configs =
      Enum.map(state.pools, fn pool ->
        pool_struct_to_config(pool)
      end)

    case PoolStore.save_all_pools(pool_configs) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:flush_leases, _from, state) do
    flush_all_leases_to_toml(state.pools)

    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :lease_manager, :manual_flush],
      %{count: 1, pool_count: length(state.pools)},
      %{}
    )

    {:reply, :ok, %{state | last_flush_at: System.system_time(:second)}}
  end

  @impl true
  def handle_info(:cleanup_expired_leases, state) do
    cleanup_expired_leases()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush_leases, state) do
    flush_all_leases_to_toml(state.pools)

    :telemetry.execute(
      [:yellow_dog, :dhcpv6, :lease_manager, :periodic_flush],
      %{count: 1, pool_count: length(state.pools)},
      %{}
    )

    # Schedule next flush
    schedule_lease_flush(state.flush_interval)

    {:noreply, %{state | last_flush_at: System.system_time(:second)}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    # Flush leases to TOML on graceful shutdown
    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason) do
      flush_all_leases_to_toml(state.pools)

      :telemetry.execute(
        [:yellow_dog, :dhcpv6, :lease_manager, :shutdown_flush],
        %{count: 1, pool_count: length(state.pools)},
        %{reason: inspect(reason)}
      )
    end

    :ok
  end

  # Private helper functions

  defp init_table do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, @ets_options)
    end

    :ok
  end

  defp make_lease_key(duid, iaid) do
    "#{DuidFormat.format!(duid)}:#{iaid}"
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
          %{duid: DuidFormat.format!(duid), iaid: iaid, ip: inspect(renewed_lease.ip)}
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
              %{duid: DuidFormat.format!(duid), iaid: iaid, ip: inspect(renewed_lease.ip)}
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
        %{duid: DuidFormat.format!(duid), iaid: iaid, ip: ip, pool: pool.name}
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

  # Schedule periodic lease flush to TOML files
  defp schedule_lease_flush(interval) do
    Process.send_after(self(), :flush_leases, interval)
  end

  # Load leases from TOML files into Mnesia and ETS storage
  defp load_leases_from_toml(pools) do
    Enum.each(pools, fn pool ->
      case PoolStore.load_leases(pool.name) do
        {:ok, leases} when leases != [] ->
          loaded =
            Enum.reduce(leases, 0, fn lease_data, count ->
              # Convert TOML lease to storage format
              lease = convert_toml_lease_to_storage(lease_data, pool)

              # Store in Mnesia
              case LeaseStorage.put(lease) do
                {:ok, _} ->
                  # Also store in ETS cache
                  lease_key = make_lease_key(lease.duid, lease.iaid)
                  :ets.insert(@table_name, {lease_key, lease})
                  count + 1

                {:error, _} ->
                  count
              end
            end)

          if loaded > 0 do
            :telemetry.execute(
              [:yellow_dog, :dhcpv6, :lease_manager, :leases_loaded_from_toml],
              %{count: loaded},
              %{pool_name: pool.name}
            )
          end

        {:ok, []} ->
          :ok

        {:error, reason} ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :lease_manager, :toml_load_failed],
            %{count: 1},
            %{pool_name: pool.name, reason: inspect(reason)}
          )
      end
    end)
  end

  # Convert a lease from TOML format to storage format
  defp convert_toml_lease_to_storage(lease_data, pool) do
    now = System.system_time(:second)

    # Parse IPv6 address if it's a string
    ip =
      case lease_data.ip do
        ip when is_tuple(ip) -> ip
        ip when is_binary(ip) -> parse_ipv6(ip)
      end

    # Calculate expires_at from valid_until (DateTime or unix timestamp)
    expires_at =
      case lease_data.valid_until do
        %DateTime{} = dt -> DateTime.to_unix(dt)
        unix when is_integer(unix) -> unix
        _ -> now + pool.valid_lifetime
      end

    %{
      duid: lease_data.duid,
      iaid: lease_data.iaid,
      ip_address: ip,
      ip: ip,
      pool_name: pool.name,
      ia_type: :ia_na,
      state: lease_data.state || :active,
      preferred_lifetime: pool.preferred_lifetime,
      valid_lifetime: pool.valid_lifetime,
      expires_at: expires_at
    }
  end

  # Parse IPv6 address string to tuple
  defp parse_ipv6(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} -> ip_tuple
      {:error, _} -> nil
    end
  end

  # Flush all leases to TOML files
  defp flush_all_leases_to_toml(pools) do
    Enum.each(pools, fn pool ->
      # Get active leases for this pool from ETS
      leases =
        list_leases()
        |> Enum.filter(fn l -> l.pool_name == pool.name end)

      # Convert to TOML format (Lease struct)
      # Calculate timestamps from expires_at and lifetimes
      toml_leases =
        Enum.map(leases, fn lease ->
          # Calculate preferred_until from expires_at and lifetimes
          valid_until = DateTime.from_unix!(lease.expires_at)
          preferred_diff = lease.valid_lifetime - lease.preferred_lifetime
          preferred_until = DateTime.add(valid_until, -preferred_diff, :second)

          # Estimate starts_at (lease_time ago from expires_at)
          starts_at = DateTime.add(valid_until, -lease.valid_lifetime, :second)

          %YellowDog.Dhcpv6.Lease{
            ip: lease.ip || lease.ip_address,
            duid: lease.duid,
            iaid: lease.iaid,
            pool_name: pool.name,
            hostname: Map.get(lease, :hostname),
            starts_at: starts_at,
            preferred_until: preferred_until,
            valid_until: valid_until,
            state: lease.state
          }
        end)

      case PoolStore.save_leases(pool.name, toml_leases) do
        :ok ->
          :ok

        {:error, reason} ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv6, :lease_manager, :flush_failed],
            %{count: 1},
            %{pool_name: pool.name, reason: inspect(reason)}
          )
      end
    end)
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

        {:error, reason}
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

  defp calculate_pool_stats(pool) do
    # Get all leases for this pool
    all_leases = list_leases() |> Enum.filter(fn l -> l.pool_name == pool.name end)
    now = System.system_time(:second)
    active_leases = Enum.filter(all_leases, fn l -> l.expires_at > now end)

    # Group leases by state
    leases_by_state =
      all_leases
      |> Enum.group_by(& &1.state)
      |> Map.new(fn {state, leases} -> {state, length(leases)} end)

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

  # Count active leases for a pool
  defp count_pool_leases(pool_name) do
    list_leases()
    |> Enum.filter(fn l -> l.pool_name == pool_name end)
    |> length()
  end

  # Check if a new pool's range overlaps with any existing pools
  defp check_range_overlap(new_pool, existing_pools) do
    # Skip overlap check if pools don't have ranges defined
    if Map.get(new_pool, :ranges) do
      overlaps =
        Enum.any?(existing_pools, fn existing ->
          if Map.get(existing, :ranges) do
            ranges_overlap?(new_pool.ranges, existing.ranges)
          else
            false
          end
        end)

      if overlaps do
        {:error, :range_overlap}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp ranges_overlap?(ranges1, ranges2) do
    Enum.any?(ranges1, fn range1 ->
      {start1, end1} = extract_range_bounds(range1)

      Enum.any?(ranges2, fn range2 ->
        {start2, end2} = extract_range_bounds(range2)
        range_intersects?(start1, end1, start2, end2)
      end)
    end)
  end

  # Extract start/end from both map and tuple formats
  defp extract_range_bounds(%{start: start_addr, end: end_addr}), do: {start_addr, end_addr}
  defp extract_range_bounds({start_addr, end_addr}), do: {start_addr, end_addr}

  defp range_intersects?(start1, end1, start2, end2) do
    start1_int = Ipv6Util.to_integer(start1)
    end1_int = Ipv6Util.to_integer(end1)
    start2_int = Ipv6Util.to_integer(start2)
    end2_int = Ipv6Util.to_integer(end2)

    # Ranges overlap if one starts before the other ends and vice versa
    start1_int <= end2_int and start2_int <= end1_int
  end

  defp format_ipv6(addr), do: YellowDog.Dhcpv6.Ipv6Util.format(addr)

  # Convert a pool struct to a config map suitable for PoolStore
  defp pool_struct_to_config(pool) do
    %{
      name: pool.name,
      network: Map.get(pool, :network),
      range_start: format_ipv6(pool.range_start),
      range_end: format_ipv6(pool.range_end),
      dns_servers: Enum.map(pool.dns_servers || [], &format_ipv6/1),
      domain_name: pool.domain_name,
      preferred_lifetime: pool.preferred_lifetime,
      valid_lifetime: pool.valid_lifetime,
      max_leases: Map.get(pool, :max_leases, 1000),
      enabled: Map.get(pool, :enabled, true)
    }
  end
end
