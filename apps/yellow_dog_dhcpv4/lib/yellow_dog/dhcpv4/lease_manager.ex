defmodule YellowDog.Dhcpv4.LeaseManager do
  @moduledoc """
  Manages DHCP lease allocation and tracking using Mnesia persistent storage.

  Tracks active leases with MAC → IP bindings, handles lease expiration,
  and provides persistence across server restarts. Supports multiple lease
  states (offered, active, released, expired, declined) for full DHCP
  protocol compliance.

  ## Persistence Strategy

  Uses dual storage:
  - **Mnesia**: Primary runtime storage with transactional support
  - **TOML files**: Human-readable backup, loaded on startup, flushed periodically

  Leases are flushed to TOML files:
  - Every 30 seconds (configurable via :lease_flush_interval_ms)
  - On graceful shutdown via terminate/2
  """

  use GenServer

  require Logger

  # Capture Mix.env() at compile time (Mix is not available in releases)
  @compile_env Mix.env()

  alias YellowDog.Dhcpv4.AddressPool
  alias YellowDog.Dhcpv4.LeaseStorage
  alias YellowDog.Dhcpv4.PoolStore

  # Run cleanup every minute
  @cleanup_interval 60_000

  # Default lease flush interval (30 seconds)
  @default_flush_interval 30_000

  @type ip_address :: AddressPool.ip_address()
  @type mac_address :: binary()
  @type lease :: LeaseStorage.lease()

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
  Allocates or renews a lease for a MAC address.

  ## Parameters
  - `mac` - Client MAC address (6 bytes binary)
  - `requested_ip` - Optional requested IP address
  - `hostname` - Optional client hostname
  - `pool_name` - Pool name to allocate from (default: "default")
  - `client_id` - Optional client identifier (option 61)

  ## Returns
  - `{:ok, lease}` - Successfully allocated/renewed lease
  - `{:error, reason}` - Failed to allocate lease
  """
  @spec allocate_lease(
          mac_address(),
          ip_address() | nil,
          String.t() | nil,
          String.t(),
          binary() | nil
        ) ::
          {:ok, lease()} | {:error, term()}
  def allocate_lease(
        mac,
        requested_ip \\ nil,
        hostname \\ nil,
        pool_name \\ "default",
        client_id \\ nil
      ) do
    GenServer.call(
      __MODULE__,
      {:allocate_lease, mac, requested_ip, hostname, pool_name, client_id}
    )
  end

  @doc """
  Releases a lease for a MAC address.

  ## Parameters
  - `mac` - Client MAC address

  ## Returns
  - `:ok` - Lease released
  """
  @spec release_lease(mac_address()) :: :ok
  def release_lease(mac) do
    GenServer.call(__MODULE__, {:release_lease, mac})
  end

  @doc """
  Declines an IP address (marks it as unavailable for a period).

  ## Parameters
  - `ip` - IP address to decline
  - `mac` - Client MAC address that declined

  ## Returns
  - `:ok` - IP declined
  """
  @spec decline_ip(ip_address(), mac_address()) :: :ok
  def decline_ip(ip, mac) do
    GenServer.call(__MODULE__, {:decline_ip, ip, mac})
  end

  @doc """
  Gets the current lease for a MAC address.

  ## Parameters
  - `mac` - Client MAC address

  ## Returns
  - `{:ok, lease}` - Active lease found
  - `{:error, :not_found}` - No active lease
  """
  @spec get_lease(mac_address()) :: {:ok, lease()} | {:error, :not_found}
  def get_lease(mac) do
    mac_key = normalize_mac(mac)

    case LeaseStorage.get(mac_key) do
      {:ok, lease} ->
        # Check if lease is active and not expired
        if lease.state == :active && lease.expires_at > System.system_time(:second) do
          {:ok, lease}
        else
          {:error, :not_found}
        end

      {:error, :not_found} ->
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
    LeaseStorage.list_active()
  end

  @doc """
  Gets all allocated IP addresses.

  ## Returns
  - MapSet of allocated IP addresses
  """
  @spec get_allocated_ips() :: MapSet.t(ip_address())
  def get_allocated_ips do
    LeaseStorage.get_allocated_ips()
  end

  @doc """
  Gets lease statistics.

  ## Returns
  - Map with lease statistics
  """
  @spec stats() :: map()
  def stats do
    LeaseStorage.stats()
  end

  @doc """
  Gets all configured pools.

  ## Returns
  - List of pool configurations
  """
  @spec get_pools() :: [AddressPool.pool_config()]
  def get_pools do
    GenServer.call(__MODULE__, :get_pools)
  end

  @doc """
  Gets statistics for a specific pool.

  ## Parameters
  - `pool_name` - Name of the pool

  ## Returns
  - `{:ok, stats}` - Pool statistics
  - `{:error, :pool_not_found}` - Pool does not exist
  """
  @spec get_pool_stats(String.t()) :: {:ok, map()} | {:error, :pool_not_found}
  def get_pool_stats(pool_name) do
    GenServer.call(__MODULE__, {:get_pool_stats, pool_name})
  end

  @doc """
  Gets statistics for all pools.

  ## Returns
  - Map with pool names as keys and statistics as values
  """
  @spec get_all_pool_stats() :: map()
  def get_all_pool_stats do
    GenServer.call(__MODULE__, :get_all_pool_stats)
  end

  @doc """
  Gets the configuration for a specific pool.

  ## Parameters
  - `pool_name` - Name of the pool

  ## Returns
  - `{:ok, config}` - Pool configuration
  - `{:error, :pool_not_found}` - Pool does not exist
  """
  @spec get_pool_config(String.t()) :: {:ok, map()} | {:error, :pool_not_found}
  def get_pool_config(pool_name) do
    GenServer.call(__MODULE__, {:get_pool_config, pool_name})
  end

  @doc """
  Gets static reservations for a specific pool.

  ## Parameters
  - `pool_name` - Name of the pool

  ## Returns
  - List of static reservations
  """
  @spec get_static_reservations(String.t()) :: [map()]
  def get_static_reservations(pool_name) do
    GenServer.call(__MODULE__, {:get_static_reservations, pool_name})
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
  - `file_path` - Optional file path (defaults to data/dhcpv4/pools.toml)

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
    # Initialize Mnesia storage
    storage_type = if @compile_env == :test, do: :ram_copies, else: :disc_copies

    case LeaseStorage.init(storage_type: storage_type) do
      :ok ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :storage, :initialized],
          %{count: 1},
          %{storage_type: storage_type}
        )

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :storage, :init_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )
    end

    # Extract pools from options or load from storage
    pools_from_opts = Keyword.get(opts, :pools, [])

    pools =
      if pools_from_opts == [] do
        # No pools in options - try loading from storage
        case PoolStore.load_pools() do
          {:ok, loaded_pools} ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv4, :pool_store, :pools_loaded_on_init],
              %{count: length(loaded_pools)},
              %{}
            )

            loaded_pools

          {:error, reason} ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv4, :pool_store, :load_failed_on_init],
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
              [:yellow_dog, :dhcpv4, :pool, :creation_failed],
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
      [:yellow_dog, :dhcpv4, :lease_manager, :started],
      %{count: 1, pool_count: length(parsed_pools)},
      %{flush_interval_ms: flush_interval}
    )

    {:ok, state}
  end

  @impl true
  def handle_call(
        {:allocate_lease, mac, requested_ip, hostname, pool_name, client_id},
        _from,
        state
      ) do
    # Find the pool
    pool = Enum.find(state.pools, fn p -> p.name == pool_name end)

    if pool do
      result = do_allocate_lease(mac, requested_ip, hostname, pool, client_id)
      {:reply, result, state}
    else
      {:reply, {:error, :pool_not_found}, state}
    end
  end

  @impl true
  def handle_call({:release_lease, mac}, _from, state) do
    mac_key = normalize_mac(mac)

    case LeaseStorage.update_state(mac_key, :released) do
      {:ok, _lease} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease, :release_completed],
          %{count: 1},
          %{client_mac: mac_key}
        )

        {:reply, :ok, state}

      {:error, :not_found} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease, :release_not_found],
          %{count: 1},
          %{client_mac: mac_key}
        )

        {:reply, :ok, state}

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease, :release_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:decline_ip, ip, mac}, _from, state) do
    mac_key = normalize_mac(mac)

    case LeaseStorage.update_state(mac_key, :declined) do
      {:ok, _lease} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease, :decline_completed],
          %{count: 1},
          %{client_mac: mac_key, declined_ip: ip}
        )

        {:reply, :ok, state}

      {:error, :not_found} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease, :decline_not_found],
          %{count: 1},
          %{client_mac: mac_key}
        )

        {:reply, :ok, state}

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease, :decline_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_pools, _from, state) do
    {:reply, state.pools, state}
  end

  @impl true
  def handle_call({:get_pool_stats, pool_name}, _from, state) do
    pool = Enum.find(state.pools, fn p -> p.name == pool_name end)

    if pool do
      stats = YellowDog.Dhcpv4.PoolStats.get_pool_stats(pool)
      {:reply, {:ok, stats}, state}
    else
      {:reply, {:error, :pool_not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_all_pool_stats, _from, state) do
    stats = YellowDog.Dhcpv4.PoolStats.get_all_pool_stats(state.pools)
    {:reply, stats, state}
  end

  @impl true
  def handle_call({:get_pool_config, pool_name}, _from, state) do
    case Enum.find(state.pools, fn pool -> pool.name == pool_name end) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool ->
        # Return the full pool struct for use with AddressPool functions
        {:reply, {:ok, pool}, state}
    end
  end

  @impl true
  def handle_call({:get_static_reservations, pool_name}, _from, state) do
    case Enum.find(state.pools, fn pool -> pool.name == pool_name end) do
      nil ->
        {:reply, [], state}

      pool ->
        reservations =
          pool.static_reservations
          |> Enum.map(fn {mac, ip} ->
            %{
              mac_address: mac,
              ip_address: ip,
              description: nil
            }
          end)

        {:reply, reservations, state}
    end
  end

  @impl true
  def handle_call({:add_pool, pool_config}, _from, state) do
    # Check if pool with same name already exists
    pool_name = Map.get(pool_config, :name) || Map.get(pool_config, "name") || "default"

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
                [:yellow_dog, :dhcpv4, :pool, :added],
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
                  [:yellow_dog, :dhcpv4, :pool, :updated],
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
            [:yellow_dog, :dhcpv4, :pool, :removed],
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
              [:yellow_dog, :dhcpv4, :pool, :removed],
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
        %{
          name: pool.name,
          range_start: format_ip(pool.range_start),
          range_end: format_ip(pool.range_end),
          subnet_mask: format_ip(pool.subnet_mask),
          gateway: format_ip(pool.gateway),
          dns_servers: Enum.map(pool.dns_servers, &format_ip/1),
          domain_name: pool.domain_name,
          lease_time: pool.lease_time,
          max_leases: Map.get(pool, :max_leases, 1000),
          enabled: true
        }
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
      [:yellow_dog, :dhcpv4, :lease_manager, :manual_flush],
      %{count: 1, pool_count: length(state.pools)},
      %{}
    )

    {:reply, :ok, %{state | last_flush_at: System.system_time(:second)}}
  end

  @impl true
  def handle_info(:cleanup_expired_leases, state) do
    case LeaseStorage.cleanup_expired() do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        :telemetry.execute(
          [:yellow_dog, :dhcpv4, :lease, :cleanup_failed],
          %{count: 1},
          %{reason: inspect(reason)}
        )
    end

    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush_leases, state) do
    flush_all_leases_to_toml(state.pools)

    :telemetry.execute(
      [:yellow_dog, :dhcpv4, :lease_manager, :periodic_flush],
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
        [:yellow_dog, :dhcpv4, :lease_manager, :shutdown_flush],
        %{count: 1, pool_count: length(state.pools)},
        %{reason: inspect(reason)}
      )
    end

    :ok
  end

  # Private helper functions

  defp do_allocate_lease(mac, requested_ip, hostname, pool, client_id) do
    mac_key = normalize_mac(mac)

    # Check for existing lease
    case LeaseStorage.get(mac_key) do
      {:ok, existing_lease} ->
        # Renew existing lease
        renewed_lease = renew_lease(existing_lease, hostname, client_id)

        case LeaseStorage.put(renewed_lease) do
          {:ok, lease} ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv4, :lease, :renewed],
              %{count: 1},
              %{client_mac: mac_key, ip_address: lease.ip_address}
            )

            {:ok, lease}

          {:error, reason} ->
            :telemetry.execute(
              [:yellow_dog, :dhcpv4, :lease, :renew_failed],
              %{count: 1},
              %{reason: inspect(reason)}
            )

            {:error, reason}
        end

      {:error, :not_found} ->
        # Allocate new lease
        allocate_new_lease(mac, mac_key, requested_ip, hostname, pool, client_id)
    end
  end

  defp allocate_new_lease(mac, mac_key, requested_ip, hostname, pool, client_id) do
    # Check max_leases limit before allocation (PRD FR1.6)
    max_leases = Map.get(pool, :max_leases, 1000)
    current_lease_count = count_pool_leases(pool.name)

    if current_lease_count >= max_leases do
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :pool, :limit_exceeded],
        %{count: 1, current: current_lease_count, max: max_leases},
        %{pool_name: pool.name}
      )

      {:error, :pool_limit_exceeded}
    else
      do_allocate_new_lease(mac, mac_key, requested_ip, hostname, pool, client_id)
    end
  end

  defp do_allocate_new_lease(mac, mac_key, requested_ip, hostname, pool, client_id) do
    allocated_ips = get_allocated_ips()

    # Try to honor requested IP if provided and available
    ip =
      cond do
        requested_ip && AddressPool.in_range?(pool, requested_ip) &&
            not MapSet.member?(allocated_ips, requested_ip) ->
          requested_ip

        true ->
          case AddressPool.get_available_ip(pool, allocated_ips, mac) do
            {:ok, available_ip} -> available_ip
            {:error, :pool_exhausted} -> nil
          end
      end

    if ip do
      now = System.system_time(:second)

      lease = %{
        mac_address: mac_key,
        ip_address: ip,
        pool_name: pool.name,
        state: :active,
        lease_time: pool.lease_time,
        expires_at: now + pool.lease_time,
        hostname: hostname,
        client_id: client_id,
        created_at: now,
        updated_at: now
      }

      case LeaseStorage.put(lease) do
        {:ok, stored_lease} ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv4, :lease, :allocated],
            %{count: 1},
            %{client_mac: mac_key, ip_address: ip, pool_name: pool.name}
          )

          {:ok, stored_lease}

        {:error, reason} ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv4, :lease, :store_failed],
            %{count: 1},
            %{reason: inspect(reason)}
          )

          {:error, reason}
      end
    else
      :telemetry.execute(
        [:yellow_dog, :dhcpv4, :pool, :exhausted],
        %{count: 1},
        %{pool_name: pool.name}
      )

      {:error, :pool_exhausted}
    end
  end

  defp renew_lease(lease, hostname, client_id) do
    now = System.system_time(:second)

    %{
      lease
      | state: :active,
        expires_at: now + lease.lease_time,
        hostname: hostname || lease.hostname,
        client_id: client_id || lease.client_id,
        updated_at: now
    }
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired_leases, @cleanup_interval)
  end

  # Schedule periodic lease flush to TOML files
  defp schedule_lease_flush(interval) do
    Process.send_after(self(), :flush_leases, interval)
  end

  # Load leases from TOML files into Mnesia storage
  defp load_leases_from_toml(pools) do
    Enum.each(pools, fn pool ->
      case PoolStore.load_leases(pool.name) do
        {:ok, leases} when leases != [] ->
          loaded =
            Enum.reduce(leases, 0, fn lease_data, count ->
              # Convert TOML lease to Mnesia format
              lease = convert_toml_lease_to_storage(lease_data, pool.name)

              case LeaseStorage.put(lease) do
                {:ok, _} -> count + 1
                {:error, _} -> count
              end
            end)

          if loaded > 0 do
            :telemetry.execute(
              [:yellow_dog, :dhcpv4, :lease_manager, :leases_loaded_from_toml],
              %{count: loaded},
              %{pool_name: pool.name}
            )
          end

        {:ok, []} ->
          :ok

        {:error, reason} ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv4, :lease_manager, :toml_load_failed],
            %{count: 1},
            %{pool_name: pool.name, reason: inspect(reason)}
          )
      end
    end)
  end

  # Convert a lease from TOML format to LeaseStorage format
  defp convert_toml_lease_to_storage(lease_data, pool_name) do
    now = System.system_time(:second)

    # Parse IP address if it's a string
    ip =
      case lease_data.ip do
        ip when is_tuple(ip) -> ip
        ip when is_binary(ip) -> parse_ip(ip)
      end

    # Parse MAC address
    mac =
      case lease_data.mac do
        mac when is_binary(mac) and byte_size(mac) == 6 -> mac
        mac when is_binary(mac) -> parse_mac(mac)
      end

    %{
      mac_address: mac,
      ip_address: ip,
      pool_name: pool_name,
      state: lease_data.state || :active,
      lease_time: lease_data.lease_time || 3600,
      expires_at: lease_data.expires_at || now + 3600,
      hostname: lease_data.hostname,
      client_id: lease_data.client_id,
      created_at: lease_data.starts_at || now,
      updated_at: now
    }
  end

  # Parse IP address string to tuple
  defp parse_ip(ip_string) when is_binary(ip_string) do
    case :inet.parse_address(String.to_charlist(ip_string)) do
      {:ok, ip_tuple} -> ip_tuple
      {:error, _} -> nil
    end
  end

  # Parse MAC address from various formats
  defp parse_mac(mac_string) when is_binary(mac_string) do
    # Handle formats like "00:11:22:33:44:55" or "00-11-22-33-44-55"
    mac_string
    |> String.replace(~r/[:-]/, "")
    |> String.downcase()
    |> Base.decode16!(case: :lower)
  rescue
    _ -> mac_string
  end

  # Flush all leases to TOML files
  defp flush_all_leases_to_toml(pools) do
    Enum.each(pools, fn pool ->
      # Get active leases for this pool from Mnesia
      leases = LeaseStorage.list(pool_name: pool.name, active_only: true)

      # Convert to TOML format
      toml_leases =
        Enum.map(leases, fn lease ->
          %YellowDog.Dhcpv4.Lease{
            ip: lease.ip_address,
            mac: lease.mac_address,
            pool_name: pool.name,
            hostname: lease.hostname,
            client_id: lease.client_id,
            starts_at: lease.created_at,
            expires_at: lease.expires_at,
            state: lease.state
          }
        end)

      case PoolStore.save_leases(pool.name, toml_leases) do
        :ok ->
          :ok

        {:error, reason} ->
          :telemetry.execute(
            [:yellow_dog, :dhcpv4, :lease_manager, :flush_failed],
            %{count: 1},
            %{pool_name: pool.name, reason: inspect(reason)}
          )
      end
    end)
  end

  # Count active leases for a pool (PRD FR1.6)
  defp count_pool_leases(pool_name) do
    LeaseStorage.list(pool_name: pool_name, active_only: true)
    |> length()
  end

  # Normalize MAC address to consistent binary format
  defp normalize_mac(<<mac::binary-size(6)>>), do: mac

  defp normalize_mac(mac) when is_binary(mac) and byte_size(mac) == 16 do
    # Handle padded MAC address from DHCP message (16 bytes with trailing zeros)
    <<actual_mac::binary-size(6), _rest::binary>> = mac
    actual_mac
  end

  defp normalize_mac(mac) when is_binary(mac), do: mac

  # Check if a new pool's range overlaps with any existing pools
  defp check_range_overlap(new_pool, existing_pools) do
    overlaps =
      Enum.any?(existing_pools, fn existing ->
        ranges_overlap?(new_pool.ranges, existing.ranges)
      end)

    if overlaps do
      {:error, :range_overlap}
    else
      :ok
    end
  end

  defp ranges_overlap?(ranges1, ranges2) do
    Enum.any?(ranges1, fn {start1, end1} ->
      Enum.any?(ranges2, fn {start2, end2} ->
        range_intersects?(start1, end1, start2, end2)
      end)
    end)
  end

  defp range_intersects?(start1, end1, start2, end2) do
    start1_int = ip_to_integer(start1)
    end1_int = ip_to_integer(end1)
    start2_int = ip_to_integer(start2)
    end2_int = ip_to_integer(end2)

    # Ranges overlap if one starts before the other ends and vice versa
    start1_int <= end2_int and start2_int <= end1_int
  end

  defp ip_to_integer({a, b, c, d}) do
    a * 256 * 256 * 256 + b * 256 * 256 + c * 256 + d
  end

  defp format_ip(nil), do: nil

  defp format_ip({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp format_ip(ip) when is_binary(ip), do: ip

  # Convert a pool struct to a config map suitable for PoolStore
  defp pool_struct_to_config(pool) do
    %{
      name: pool.name,
      network: Map.get(pool, :network),
      range_start: format_ip(pool.range_start),
      range_end: format_ip(pool.range_end),
      subnet_mask: format_ip(pool.subnet_mask),
      gateway: format_ip(pool.gateway),
      dns_servers: Enum.map(pool.dns_servers || [], &format_ip/1),
      domain_name: pool.domain_name,
      lease_time: pool.lease_time,
      max_leases: Map.get(pool, :max_leases, 1000),
      enabled: Map.get(pool, :enabled, true)
    }
  end
end
