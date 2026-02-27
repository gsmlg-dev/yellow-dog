defmodule YellowDog.Netman do
  @moduledoc """
  Public API facade for the YellowDog Network Manager.

  Provides wired ethernet management with DHCP and static IP, a desired-state
  reconciliation engine, per-interface connection FSMs, kernel netlink integration,
  and TOML profile management.
  """

  alias YellowDog.Netman.{Connection, ProfileStore, PolicyEngine, ReconciliationEngine}
  alias YellowDog.Netman.Kernel.{LinkMonitor, AddressManager, RouteManager}

  # Supervisor delegation for service startup
  defdelegate start_link(opts), to: YellowDog.Netman.Supervisor
  defdelegate child_spec(opts), to: YellowDog.Netman.Supervisor

  ## Status

  @doc "Returns system status overview."
  @spec status() :: map()
  def status do
    %{
      running: Process.whereis(YellowDog.Netman.Supervisor) != nil,
      interfaces: list_interfaces(),
      connections: list_connections(),
      default_route: default_route()
    }
  end

  ## Interface Operations

  @doc "Lists all known network interfaces."
  @spec list_interfaces() :: [map()]
  def list_interfaces do
    LinkMonitor.list_links()
  end

  @doc "Returns detailed info for a specific interface."
  @spec interface_info(String.t()) :: {:ok, map()} | {:error, :not_found}
  def interface_info(interface) do
    case LinkMonitor.get_link(interface) do
      nil ->
        {:error, :not_found}

      link ->
        addresses = AddressManager.get_addresses(interface)
        routes = RouteManager.get_routes(interface)
        {:ok, Map.merge(link, %{addresses: addresses, routes: routes})}
    end
  end

  ## Connection Operations

  @doc "Lists all connection profiles."
  @spec list_profiles() :: [YellowDog.Netman.Types.Profile.t()]
  def list_profiles do
    ProfileStore.list()
  end

  @doc "Gets a connection profile by ID."
  @spec get_profile(String.t()) ::
          {:ok, YellowDog.Netman.Types.Profile.t()} | {:error, :not_found}
  def get_profile(id) do
    ProfileStore.get(id)
  end

  @doc "Lists active connections."
  @spec list_connections() :: [map()]
  def list_connections do
    Connection.Supervisor.list_connections()
  end

  @doc "Activates a connection profile."
  @spec activate(String.t()) :: :ok | {:error, term()}
  def activate(profile_id) do
    ReconciliationEngine.activate(profile_id)
  end

  @doc "Deactivates a connection."
  @spec deactivate(String.t()) :: :ok | {:error, term()}
  def deactivate(profile_id) do
    ReconciliationEngine.deactivate(profile_id)
  end

  ## Policy

  @doc "Returns the current default route connection."
  @spec default_route() :: {:ok, String.t()} | :none
  def default_route do
    connections = list_connections()
    PolicyEngine.default_route(connections)
  end

  ## Profile Management

  @doc "Imports a TOML profile from a file path."
  @spec import_profile(String.t()) :: {:ok, YellowDog.Netman.Types.Profile.t()} | {:error, term()}
  def import_profile(path) do
    ProfileStore.import_file(path)
  end

  @doc "Deletes a connection profile by ID."
  @spec delete_profile(String.t()) :: :ok | {:error, term()}
  def delete_profile(id) do
    ProfileStore.delete(id)
  end
end
