defmodule YellowDog.Dhcpv4 do
  @moduledoc """
  DHCPv4 server with lease management.

  Provides a public API for interacting with the DHCPv4 service,
  including lease management and service status reporting.

  Pool CRUD operations work both when the server is running (using LeaseManager)
  and when it's stopped (using direct file operations via PoolStore).
  """

  alias YellowDog.Dhcpv4.{LeaseManager, PoolStore, Supervisor}

  @doc """
  Starts the Dhcpv4 supervisor.

  Delegates to `YellowDog.Dhcpv4.Supervisor.start_link/1`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(options), to: Supervisor

  @doc """
  Returns a child specification for the Dhcpv4 supervisor.

  Delegates to `YellowDog.Dhcpv4.Supervisor.child_spec/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: Supervisor

  @doc """
  Gets all active leases.

  ## Returns
  - List of active lease entries with the following structure:
    - `mac_address` - Binary MAC address
    - `ip_address` - IP address tuple (e.g., {192, 168, 1, 100})
    - `pool_name` - Pool name string
    - `state` - Lease state (`:active`, `:offered`, `:released`, `:expired`, `:declined`)
    - `lease_time` - Lease duration in seconds
    - `expires_at` - Unix timestamp when lease expires
    - `hostname` - Optional client hostname
    - `client_id` - Optional DHCP client identifier (option 61)
    - `created_at` - Unix timestamp when lease was created
    - `updated_at` - Unix timestamp when lease was last updated

  ## Examples
      iex> YellowDog.Dhcpv4.list_leases()
      [
        %{
          mac_address: <<0, 17, 34, 51, 68, 85>>,
          ip_address: {192, 168, 1, 100},
          pool_name: "default",
          state: :active,
          lease_time: 86400,
          expires_at: 1735286400,
          hostname: "laptop-01",
          client_id: nil,
          created_at: 1735200000,
          updated_at: 1735200000
        }
      ]
  """
  @spec list_leases() :: [map()]
  defdelegate list_leases(), to: LeaseManager

  @doc """
  Gets a specific lease by MAC address.

  ## Parameters
  - `mac` - MAC address string (e.g., "00:11:22:33:44:55")

  ## Returns
  - `{:ok, lease}` - Lease information
  - `{:error, :not_found}` - No lease found
  """
  @spec get_lease(String.t()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_lease(mac), to: LeaseManager

  @doc """
  Releases a lease by MAC address.

  ## Parameters
  - `mac` - MAC address string

  ## Returns
  - `:ok`
  """
  @spec release_lease(String.t()) :: :ok
  defdelegate release_lease(mac), to: LeaseManager

  @doc """
  Gets lease statistics.

  ## Returns
  - Map with lease statistics including:
    - `total_leases` - Total number of leases in storage
    - `active_leases` - Number of currently active (non-expired) leases
    - `expired_leases` - Number of expired leases
    - `by_state` - Breakdown of leases by state (`:offered`, `:active`, `:released`, `:expired`, `:declined`)

  ## Examples
      iex> YellowDog.Dhcpv4.stats()
      %{
        total_leases: 52,
        active_leases: 45,
        expired_leases: 5,
        by_state: %{
          active: 45,
          offered: 2,
          released: 3,
          expired: 2
        }
      }
  """
  @spec stats() :: map()
  defdelegate stats(), to: LeaseManager

  @doc """
  Gets the status of the DHCPv4 service.

  ## Returns
  - Map with service status information
  """
  @spec status() :: map()
  def status do
    # Supervisor registers with name YellowDog.Dhcpv4, not YellowDog.Dhcpv4.Supervisor
    case Process.whereis(__MODULE__) do
      nil ->
        %{running: false, lease_stats: %{}}

      _pid ->
        %{
          running: true,
          lease_stats: stats()
        }
    end
  end

  @doc """
  Gets statistics for a specific pool.

  ## Parameters
  - `pool_name` - Name of the pool

  ## Returns
  - `{:ok, stats}` - Pool statistics including utilization, available addresses, etc.
  - `{:error, :pool_not_found}` - Pool does not exist

  ## Examples
      iex> YellowDog.Dhcpv4.get_pool_stats("default")
      {:ok, %{
        pool_name: "default",
        total_addresses: 101,
        allocated_addresses: 45,
        available_addresses: 56,
        utilization_percent: 44.55,
        static_reservations: 2,
        leases_by_state: %{active: 40, offered: 3, released: 2}
      }}
  """
  @spec get_pool_stats(String.t()) :: {:ok, map()} | {:error, :pool_not_found}
  defdelegate get_pool_stats(pool_name), to: LeaseManager

  @doc """
  Gets statistics for all pools.

  ## Returns
  - Map with pool names as keys and statistics as values

  ## Examples
      iex> YellowDog.Dhcpv4.get_all_pool_stats()
      %{
        "default" => %{pool_name: "default", total_addresses: 101, ...},
        "office" => %{pool_name: "office", total_addresses: 200, ...}
      }
  """
  @spec get_all_pool_stats() :: map()
  defdelegate get_all_pool_stats(), to: LeaseManager

  @doc """
  Adds a new address pool.

  Works both when the DHCP server is running (via LeaseManager) and when stopped
  (via direct file operations).

  ## Parameters
  - `pool_config` - Pool configuration map with keys:
    - `:name` - Pool name (required)
    - `:range_start` - Start IP address (e.g., "192.168.1.100")
    - `:range_end` - End IP address (e.g., "192.168.1.200")
    - `:network` - Network in CIDR notation (e.g., "192.168.1.0/24") (optional)
    - `:gateway` - Gateway IP address (optional)
    - `:dns_servers` - List of DNS server IPs (optional)
    - `:lease_time` - Lease time in seconds (default: 86400)
    - `:max_leases` - Maximum leases (default: 1000)
  - `opts` - Options:
    - `:persist` - Save to file (default: true)

  ## Returns
  - `{:ok, pool}` - Successfully added pool
  - `{:error, :pool_already_exists}` - Pool with same name exists
  - `{:error, :range_overlap}` - Range overlaps with existing pool
  - `{:error, reason}` - Invalid configuration

  ## Examples
      iex> YellowDog.Dhcpv4.add_pool(%{
      ...>   name: "office",
      ...>   range_start: "192.168.2.100",
      ...>   range_end: "192.168.2.200",
      ...>   gateway: "192.168.2.1",
      ...>   lease_time: 43200
      ...> })
      {:ok, %{name: "office", ...}}
  """
  @spec add_pool(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def add_pool(pool_config, opts \\ []) do
    persist = Keyword.get(opts, :persist, true)

    if server_running?() do
      # Server is running, use LeaseManager
      case LeaseManager.add_pool(pool_config) do
        {:ok, _pool} = success ->
          if persist, do: LeaseManager.persist_pools()
          success

        error ->
          error
      end
    else
      # Server not running, use direct file operations
      add_pool_direct(pool_config, persist)
    end
  end

  @doc """
  Updates an existing address pool.

  Works both when the DHCP server is running (via LeaseManager) and when stopped
  (via direct file operations).

  ## Parameters
  - `pool_name` - Name of the pool to update
  - `pool_config` - New configuration (name cannot be changed)
  - `opts` - Options:
    - `:persist` - Save to file (default: true)

  ## Returns
  - `{:ok, pool}` - Successfully updated pool
  - `{:error, :pool_not_found}` - Pool does not exist
  - `{:error, :range_overlap}` - New range overlaps with other pools
  - `{:error, reason}` - Invalid configuration

  ## Examples
      iex> YellowDog.Dhcpv4.update_pool("office", %{
      ...>   range_start: "192.168.2.50",
      ...>   range_end: "192.168.2.250",
      ...>   lease_time: 86400
      ...> })
      {:ok, %{name: "office", ...}}
  """
  @spec update_pool(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_pool(pool_name, pool_config, opts \\ []) do
    persist = Keyword.get(opts, :persist, true)

    if server_running?() do
      # Server is running, use LeaseManager
      case LeaseManager.update_pool(pool_name, pool_config) do
        {:ok, _pool} = success ->
          if persist, do: LeaseManager.persist_pools()
          success

        error ->
          error
      end
    else
      # Server not running, use direct file operations
      update_pool_direct(pool_name, pool_config, persist)
    end
  end

  @doc """
  Removes an address pool.

  Works both when the DHCP server is running (via LeaseManager) and when stopped
  (via direct file operations). Note: when the server is stopped, the `:force`
  option is ignored since there are no active leases to check.

  ## Parameters
  - `pool_name` - Name of the pool to remove
  - `opts` - Options:
    - `:force` - Remove even with active leases (default: false)
    - `:persist` - Save to file (default: true)

  ## Returns
  - `:ok` - Successfully removed pool
  - `{:error, :pool_not_found}` - Pool does not exist
  - `{:error, :has_active_leases}` - Pool has active leases

  ## Examples
      iex> YellowDog.Dhcpv4.remove_pool("office")
      :ok

      iex> YellowDog.Dhcpv4.remove_pool("active-pool")
      {:error, :has_active_leases}

      iex> YellowDog.Dhcpv4.remove_pool("active-pool", force: true)
      :ok
  """
  @spec remove_pool(String.t(), keyword()) :: :ok | {:error, term()}
  def remove_pool(pool_name, opts \\ []) do
    persist = Keyword.get(opts, :persist, true)
    force = Keyword.get(opts, :force, false)

    if server_running?() do
      # Server is running, use LeaseManager
      case LeaseManager.remove_pool(pool_name, force: force) do
        :ok ->
          if persist, do: LeaseManager.persist_pools()
          :ok

        error ->
          error
      end
    else
      # Server not running, use direct file operations
      remove_pool_direct(pool_name)
    end
  end

  @doc """
  Gets all configured pools.

  Works both when the DHCP server is running (via LeaseManager) and when stopped
  (via direct file operations).

  ## Returns
  - List of pool configurations

  ## Examples
      iex> YellowDog.Dhcpv4.get_pools()
      [%{name: "default", range_start: {192, 168, 1, 100}, ...}]
  """
  @spec get_pools() :: [map()]
  def get_pools do
    if server_running?() do
      LeaseManager.get_pools()
    else
      # Server not running, load from file
      case PoolStore.load_pools() do
        {:ok, pools} -> pools
        {:error, _} -> []
      end
    end
  end

  @doc """
  Gets a specific pool by name.

  Works both when the DHCP server is running and when stopped.

  ## Parameters
  - `pool_name` - Name of the pool

  ## Returns
  - `{:ok, pool}` - Pool configuration
  - `{:error, :pool_not_found}` - Pool does not exist
  """
  @spec get_pool(String.t()) :: {:ok, map()} | {:error, :pool_not_found}
  def get_pool(pool_name) do
    pools = get_pools()

    case Enum.find(pools, fn pool ->
           name = pool[:name] || pool.name
           name == pool_name
         end) do
      nil -> {:error, :pool_not_found}
      pool -> {:ok, pool}
    end
  end

  # Private helper functions

  defp server_running? do
    Process.whereis(LeaseManager) != nil
  end

  # Direct file operations when server is not running

  defp add_pool_direct(pool_config, persist) do
    pool_name = pool_config[:name] || pool_config["name"]

    with :ok <- PoolStore.validate_pool(pool_config) do
      # Check for duplicate name
      case PoolStore.load_pools() do
        {:ok, existing_pools} ->
          if Enum.any?(existing_pools, fn p -> (p[:name] || p.name) == pool_name end) do
            {:error, :pool_already_exists}
          else
            # Normalize the pool config
            normalized = normalize_pool_config(pool_config)

            if persist do
              case PoolStore.save_pool(normalized) do
                :ok -> {:ok, normalized}
                error -> error
              end
            else
              {:ok, normalized}
            end
          end

        {:error, _} ->
          # No existing pools, just add
          normalized = normalize_pool_config(pool_config)

          if persist do
            case PoolStore.save_pool(normalized) do
              :ok -> {:ok, normalized}
              error -> error
            end
          else
            {:ok, normalized}
          end
      end
    end
  end

  defp update_pool_direct(pool_name, pool_config, persist) do
    case PoolStore.load_pools() do
      {:ok, existing_pools} ->
        case Enum.find_index(existing_pools, fn p -> (p[:name] || p.name) == pool_name end) do
          nil ->
            {:error, :pool_not_found}

          index ->
            existing_pool = Enum.at(existing_pools, index)
            # Merge the new config with existing, keeping the name
            updated = Map.merge(existing_pool, pool_config)
            updated = Map.put(updated, :name, pool_name)

            if persist do
              case PoolStore.save_pool(updated) do
                :ok -> {:ok, updated}
                error -> error
              end
            else
              {:ok, updated}
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_pool_direct(pool_name) do
    # When server is not running, just remove from file
    # No need to check for active leases
    PoolStore.remove_pool(pool_name)
  end

  defp normalize_pool_config(config) do
    %{
      name: config[:name] || config["name"],
      network: config[:network] || config["network"],
      range_start: config[:range_start] || config["range_start"],
      range_end: config[:range_end] || config["range_end"],
      subnet_mask: config[:subnet_mask] || config["subnet_mask"] || "255.255.255.0",
      gateway: config[:gateway] || config["gateway"],
      dns_servers: config[:dns_servers] || config["dns_servers"] || [],
      domain_name: config[:domain_name] || config["domain_name"],
      lease_time: get_config_value(config, :lease_time, 86400),
      max_leases: get_config_value(config, :max_leases, 1000),
      enabled: get_config_value(config, :enabled, true)
    }
  end

  # Fetches a config value by atom key then string key, falling back to default.
  # Unlike ||, this correctly handles falsy values (false, 0).
  defp get_config_value(config, key, default) do
    atom_key = key
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(config, atom_key) -> config[atom_key]
      Map.has_key?(config, string_key) -> config[string_key]
      true -> default
    end
  end
end
