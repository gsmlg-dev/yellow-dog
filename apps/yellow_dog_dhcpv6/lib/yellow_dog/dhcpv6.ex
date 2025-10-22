defmodule YellowDog.Dhcpv6 do
  @moduledoc """
  DHCPv6 server with lease management.

  Provides a public API for interacting with the DHCPv6 service,
  including lease management and service status reporting.
  """

  alias YellowDog.Dhcpv6.{LeaseManager, Supervisor}

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
  Gets the status of the DHCPv6 service.

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
