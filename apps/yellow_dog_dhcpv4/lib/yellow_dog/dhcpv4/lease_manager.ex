defmodule YellowDog.Dhcpv4.LeaseManager do
  @moduledoc """
  Manages DHCP lease allocation and tracking using Mnesia persistent storage.

  Tracks active leases with MAC → IP bindings, handles lease expiration,
  and provides persistence across server restarts. Supports multiple lease
  states (offered, active, released, expired, declined) for full DHCP
  protocol compliance.
  """

  use GenServer
  require Logger

  alias YellowDog.Dhcpv4.AddressPool
  alias YellowDog.Dhcpv4.LeaseStorage

  # Run cleanup every minute
  @cleanup_interval 60_000

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
  def allocate_lease(mac, requested_ip \\ nil, hostname \\ nil, pool_name \\ "default", client_id \\ nil) do
    GenServer.call(__MODULE__, {:allocate_lease, mac, requested_ip, hostname, pool_name, client_id})
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

  # Server Callbacks

  @impl true
  def init(opts) do
    # Initialize Mnesia storage
    storage_type = if Mix.env() == :test, do: :ram_copies, else: :disc_copies

    case LeaseStorage.init(storage_type: storage_type) do
      :ok ->
        Logger.info("Mnesia storage initialized with #{storage_type}")

      {:error, reason} ->
        Logger.error("Failed to initialize Mnesia storage: #{inspect(reason)}")
    end

    # Extract pools from options
    pools = Keyword.get(opts, :pools, [])

    # Parse pools into AddressPool configs
    parsed_pools =
      Enum.map(pools, fn pool_config ->
        case AddressPool.new(pool_config) do
          {:ok, pool} ->
            pool

          {:error, reason} ->
            Logger.error("Failed to create address pool: #{inspect(reason)}")
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    # Schedule periodic cleanup
    schedule_cleanup()

    state = %{
      pools: parsed_pools
    }

    Logger.info("LeaseManager started with #{length(parsed_pools)} pools")

    {:ok, state}
  end

  @impl true
  def handle_call({:allocate_lease, mac, requested_ip, hostname, pool_name, client_id}, _from, state) do
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
        Logger.info("Released lease for MAC #{format_mac_display(mac_key)}")
        {:reply, :ok, state}

      {:error, :not_found} ->
        Logger.warning("Attempted to release non-existent lease for MAC #{format_mac_display(mac_key)}")
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("Failed to release lease: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:decline_ip, ip, mac}, _from, state) do
    mac_key = normalize_mac(mac)

    case LeaseStorage.update_state(mac_key, :declined) do
      {:ok, _lease} ->
        Logger.warning("IP #{inspect(ip)} declined by MAC #{format_mac_display(mac_key)}")
        {:reply, :ok, state}

      {:error, :not_found} ->
        Logger.warning("Attempted to decline non-existent lease for MAC #{format_mac_display(mac_key)}")
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error("Failed to decline IP: #{inspect(reason)}")
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
    case Map.get(state.pools, pool_name) do
      nil ->
        {:reply, {:error, :pool_not_found}, state}

      pool ->
        config = %{
          name: pool.name,
          range_start: pool.range_start,
          range_end: pool.range_end,
          subnet_mask: pool.subnet_mask,
          gateway: pool.gateway,
          dns_servers: pool.dns_servers,
          domain_name: pool.domain_name,
          lease_time: pool.lease_time,
          excluded_ranges: pool.excluded_ranges
        }
        {:reply, {:ok, config}, state}
    end
  end

  @impl true
  def handle_call({:get_static_reservations, pool_name}, _from, state) do
    case Map.get(state.pools, pool_name) do
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
  def handle_info(:cleanup_expired_leases, state) do
    case LeaseStorage.cleanup_expired() do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to cleanup expired leases: #{inspect(reason)}")
    end

    schedule_cleanup()
    {:noreply, state}
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
            Logger.info("Renewed lease for MAC #{format_mac_display(mac_key)}: #{inspect(lease.ip_address)}")
            {:ok, lease}

          {:error, reason} ->
            Logger.error("Failed to renew lease: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, :not_found} ->
        # Allocate new lease
        allocate_new_lease(mac, mac_key, requested_ip, hostname, pool, client_id)
    end
  end

  defp allocate_new_lease(mac, mac_key, requested_ip, hostname, pool, client_id) do
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
          Logger.info("Allocated new lease for MAC #{format_mac_display(mac_key)}: #{inspect(ip)}")

          # Emit telemetry event
          :telemetry.execute(
            [:yellow_dog, :dhcpv4, :lease_allocated],
            %{count: 1},
            %{mac: mac_key, ip: ip, pool: pool.name}
          )

          {:ok, stored_lease}

        {:error, reason} ->
          Logger.error("Failed to store new lease: #{inspect(reason)}")
          {:error, reason}
      end
    else
      Logger.error("Pool exhausted for #{pool.name}")
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

  # Normalize MAC address to consistent binary format
  defp normalize_mac(<<mac::binary-size(6)>>), do: mac

  defp normalize_mac(mac) when is_binary(mac) and byte_size(mac) == 16 do
    # Handle padded MAC address from DHCP message (16 bytes with trailing zeros)
    <<actual_mac::binary-size(6), _rest::binary>> = mac
    actual_mac
  end

  defp normalize_mac(mac) when is_binary(mac), do: mac

  # Format MAC address for display in logs
  defp format_mac_display(<<mac::binary-size(6)>>) do
    mac
    |> :binary.bin_to_list()
    |> Enum.map(&Integer.to_string(&1, 16))
    |> Enum.map(&String.pad_leading(&1, 2, "0"))
    |> Enum.join(":")
    |> String.upcase()
  end

  defp format_mac_display(mac) when is_binary(mac), do: Base.encode16(mac)
  defp format_mac_display(_), do: "UNKNOWN"
end
