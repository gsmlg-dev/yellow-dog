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
  @spec status() :: %{
          running: boolean(),
          interfaces: [map()],
          connections: [map()],
          default_route: {:ok, String.t()} | :none
        }
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
  @spec list_interfaces() :: [LinkMonitor.link()]
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

  @doc "Lists lifecycle state for every profile with one namespace revision snapshot."
  @spec list_profile_states() :: {[map()], String.t()}
  def list_profile_states do
    ProfileStore.list_states()
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
    activate(profile_id, ReconciliationEngine)
  end

  @doc false
  @spec activate(String.t(), module()) :: :ok | {:error, term()}
  def activate(profile_id, reconciliation_engine) when is_atom(reconciliation_engine) do
    with {:ok, %{desired_revision: desired_revision}} <- ProfileStore.state(profile_id),
         :ok <- activate_and_wait(reconciliation_engine, profile_id),
         :ok <- ProfileStore.mark_active(profile_id, desired_revision) do
      :ok
    end
  end

  @doc "Activates every connection selected by a profile and returns their terminal states."
  @spec activate_with_results(String.t()) :: {:ok, [map()]} | {:error, term()}
  def activate_with_results(profile_id) do
    with {:ok, %{desired_revision: desired_revision}} <- ProfileStore.state(profile_id),
         {:ok, connections} <- ReconciliationEngine.activate_and_wait(profile_id),
         :ok <- ProfileStore.mark_active(profile_id, desired_revision) do
      {:ok, connections}
    end
  end

  defp activate_and_wait(ReconciliationEngine, profile_id) do
    case ReconciliationEngine.activate_and_wait(profile_id) do
      {:ok, _connections} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp activate_and_wait(reconciliation_engine, profile_id) do
    reconciliation_engine.activate(profile_id)
  end

  @doc "Deactivates a connection."
  @spec deactivate(String.t()) :: :ok | {:error, term()}
  def deactivate(profile_id) do
    ReconciliationEngine.deactivate(profile_id)
  end

  @doc "Activates one profile/interface connection and waits for convergence."
  @spec activate_connection(String.t(), String.t()) :: :ok | {:error, term()}
  def activate_connection(profile_id, interface) do
    case ReconciliationEngine.activate_connection_and_wait(profile_id, interface) do
      {:ok, [_connection]} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Deactivates one profile/interface connection and waits for cleanup."
  @spec deactivate_connection(String.t(), String.t()) :: :ok | {:error, term()}
  def deactivate_connection(profile_id, interface) do
    case ReconciliationEngine.deactivate_connection_and_wait(profile_id, interface) do
      {:ok, _connection} -> :ok
      {:error, _reason} = error -> error
    end
  end

  ## Policy

  @doc "Returns the current default route connection."
  @spec default_route() :: {:ok, String.t()} | :none
  def default_route do
    connections = list_connections()
    PolicyEngine.default_route(connections)
  end

  ## Profile Management

  @doc "Creates or updates a durable connection profile."
  @spec put_profile(String.t(), YellowDog.Netman.Types.Profile.t()) :: :ok | {:error, term()}
  def put_profile(id, profile) do
    ProfileStore.put(id, profile)
  end

  @doc "Creates or updates a durable connection profile with optimistic concurrency."
  @spec put_profile(String.t(), YellowDog.Netman.Types.Profile.t(), keyword()) ::
          :ok | {:error, term()}
  def put_profile(id, profile, opts) do
    ProfileStore.put(id, profile, opts)
  end

  @doc "Returns the canonical revision for a connection profile."
  @spec profile_revision(String.t()) :: {:ok, String.t()} | {:error, :not_found | :invalid_id}
  def profile_revision(id) do
    ProfileStore.revision(id)
  end

  @doc "Returns a profile together with its desired and active revisions."
  @spec profile_state(String.t()) :: {:ok, map()} | {:error, term()}
  def profile_state(id) do
    ProfileStore.state(id)
  end

  @doc "Lists immutable revisions for a connection profile."
  @spec profile_history(String.t()) :: {:ok, [map()]} | {:error, term()}
  def profile_history(id) do
    ProfileStore.history(id)
  end

  @doc "Returns the deterministic revision of the full profile namespace."
  @spec profiles_revision() :: {:ok, String.t()}
  def profiles_revision do
    ProfileStore.namespace_revision()
  end

  @doc false
  @spec profiles_snapshot() :: {[YellowDog.Netman.Types.Profile.t()], String.t()}
  def profiles_snapshot do
    ProfileStore.namespace_snapshot()
  end

  @doc "Restores an immutable revision as the desired profile."
  @spec rollback_profile(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def rollback_profile(id, target_revision, opts \\ []) do
    ProfileStore.rollback(id, target_revision, opts)
  end

  @doc "Replaces the complete runtime profile namespace."
  @spec replace_profiles([YellowDog.Netman.Types.Profile.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def replace_profiles(profiles, opts \\ []) do
    ProfileStore.replace(profiles, opts)
  end

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

  @doc "Deletes a connection profile with optimistic concurrency."
  @spec delete_profile(String.t(), keyword()) :: :ok | {:error, term()}
  def delete_profile(id, opts) do
    ProfileStore.delete(id, opts)
  end
end
