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
  - List of active lease entries

  ## Examples
      iex> YellowDog.Dhcpv4.list_leases()
      [%{ip: {192, 168, 1, 100}, mac: "00:11:22:33:44:55", ...}]
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
  - Map with lease statistics

  ## Examples
      iex> YellowDog.Dhcpv4.stats()
      %{
        total_leases: 50,
        active_leases: 45,
        expired_leases: 5,
        pool_utilization: %{"default" => 45}
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
    case Process.whereis(Supervisor) do
      nil ->
        %{running: false, lease_stats: %{}}

      _pid ->
        %{
          running: true,
          lease_stats: stats()
        }
    end
  end
end
