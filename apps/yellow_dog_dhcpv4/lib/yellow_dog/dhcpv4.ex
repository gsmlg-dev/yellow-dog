defmodule YellowDog.Dhcpv4 do
  @moduledoc """
  DHCPv4 server with lease management.

  Provides a public API for interacting with the DHCPv4 service,
  including lease management and service status reporting.
  """

  alias YellowDog.Dhcpv4.{LeaseManager, Supervisor}

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
end
