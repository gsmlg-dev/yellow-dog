defmodule YellowDog.Dhcpv6 do
  @moduledoc """
  DHCPv6 server with lease management.

  Provides a public API for interacting with the DHCPv6 service,
  including lease management and service status reporting.

  Pool CRUD operations work both when the server is running (using LeaseManager)
  and when it's stopped (using direct file operations via PoolStore).
  """

  alias YellowDog.Dhcpv6.{LeaseManager, PoolStore, Supervisor}

  @doc """
  Starts the Dhcpv6 supervisor.

  Delegates to `YellowDog.Dhcpv6.Supervisor.start_link/1`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(options), to: Supervisor

  @doc """
  Returns a child specification for the Dhcpv6 supervisor.

  Delegates to `YellowDog.Dhcpv6.Supervisor.child_spec/1`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(options), to: Supervisor

  @doc """
  Gets all active leases.

  ## Returns
  - List of active lease entries

  ## Examples
      iex> YellowDog.Dhcpv6.list_leases()
      [%{ip: {0xfd00, 0, 0, 0, 0, 0, 0, 100}, duid: "...", ...}]
  """
  @spec list_leases() :: [map()]
  defdelegate list_leases(), to: LeaseManager

  @doc """
  Gets a specific lease by DUID and IAID.

  ## Parameters
  - `duid` - DHCP Unique Identifier (binary)
  - `iaid` - Identity Association Identifier (integer)

  ## Returns
  - `{:ok, lease}` - Lease information
  - `{:error, :not_found}` - No lease found
  """
  @spec get_lease(binary(), integer()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_lease(duid, iaid), to: LeaseManager

  @doc """
  Releases a lease by DUID and IAID.

  ## Parameters
  - `duid` - DHCP Unique Identifier
  - `iaid` - Identity Association Identifier

  ## Returns
  - `:ok`
  """
  @spec release_lease(binary(), integer()) :: :ok
  defdelegate release_lease(duid, iaid), to: LeaseManager

  @doc """
  Gets lease statistics.

  ## Returns
  - Map with lease statistics

  ## Examples
      iex> YellowDog.Dhcpv6.stats()
      %{
        total_leases: 30,
        active_leases: 25,
        expired_leases: 5,
        pool_utilization: %{"default" => 25}
      }
  """
  @spec stats() :: map()
  defdelegate stats(), to: LeaseManager

  @doc """
  Gets pool statistics for all configured pools.

  ## Returns
  - Map of pool_name => pool_stats

  ## Examples
      iex> YellowDog.Dhcpv6.get_all_pool_stats()
      %{
        "default" => %{total_count: 100, allocated_count: 25, ...}
      }
  """
  @spec get_all_pool_stats() :: %{String.t() => map()}
  defdelegate get_all_pool_stats(), to: LeaseManager

  @doc """
  Gets the list of configured pools.

  Works both when the DHCP server is running (via LeaseManager) and when stopped
  (via direct file operations).

  ## Returns
  - List of pool configurations
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

  @doc """
  Gets the status of the DHCPv6 service.

  ## Returns
  - Map with service status information
  """
  @spec status() :: map()
  def status do
    # Supervisor registers with name YellowDog.Dhcpv6, not YellowDog.Dhcpv6.Supervisor
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
  Adds a new address pool.

  Works both when the DHCP server is running (via LeaseManager) and when stopped
  (via direct file operations).

  ## Parameters
  - `pool_config` - Pool configuration map with keys:
    - `:name` - Pool name (required)
    - `:range_start` - Start IPv6 address (e.g., "2001:db8::100")
    - `:range_end` - End IPv6 address (e.g., "2001:db8::200")
    - `:network` - Network in CIDR notation (e.g., "2001:db8::/64") (optional)
    - `:dns_servers` - List of DNS server IPs (optional)
    - `:preferred_lifetime` - Preferred lifetime in seconds (default: 3600)
    - `:valid_lifetime` - Valid lifetime in seconds (default: 7200)
    - `:max_leases` - Maximum leases (default: 1000)
  - `opts` - Options:
    - `:persist` - Save to file (default: true)

  ## Returns
  - `{:ok, pool}` - Successfully added pool
  - `{:error, :pool_already_exists}` - Pool with same name exists
  - `{:error, :range_overlap}` - Range overlaps with existing pool
  - `{:error, reason}` - Invalid configuration

  ## Examples
      iex> YellowDog.Dhcpv6.add_pool(%{
      ...>   name: "office",
      ...>   range_start: "2001:db8:1::100",
      ...>   range_end: "2001:db8:1::200",
      ...>   preferred_lifetime: 3600,
      ...>   valid_lifetime: 7200
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
      iex> YellowDog.Dhcpv6.update_pool("office", %{
      ...>   range_start: "2001:db8:1::50",
      ...>   range_end: "2001:db8:1::250",
      ...>   valid_lifetime: 14400
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
      iex> YellowDog.Dhcpv6.remove_pool("office")
      :ok

      iex> YellowDog.Dhcpv6.remove_pool("active-pool")
      {:error, :has_active_leases}

      iex> YellowDog.Dhcpv6.remove_pool("active-pool", force: true)
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
      dns_servers: config[:dns_servers] || config["dns_servers"] || [],
      domain_name: config[:domain_name] || config["domain_name"],
      preferred_lifetime: get_config_value(config, :preferred_lifetime, 3600),
      valid_lifetime: get_config_value(config, :valid_lifetime, 7200),
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
