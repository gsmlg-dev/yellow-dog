defmodule YellowDog.DnsProvider do
  @moduledoc """
  Public API for DNS zone provider management and synchronization.

  Provides CRUD operations for provider configs, on-demand sync
  triggers, and conflict resolution. All persistent state flows
  through `YellowDog.Store.Provider`; runtime engines are managed
  via `SyncSupervisor`.
  """

  alias YellowDog.DnsProvider.{Config, SyncEngine, SyncSupervisor}
  alias YellowDog.Store.Provider, as: StoreProvider

  # -------------------------------------------------------------------
  # Provider management
  # -------------------------------------------------------------------

  @doc "Add a new provider from an attribute map."
  @spec add_provider(map()) :: :ok | {:error, term()}
  def add_provider(attrs) do
    with {:ok, config} <- Config.new(attrs) do
      StoreProvider.put_config(Config.to_map(config))
    end
  end

  @doc "Update an existing provider, merging `changes` into stored config."
  @spec update_provider(String.t(), map()) :: :ok | {:error, term()}
  def update_provider(name, changes) do
    with {:ok, existing} <- StoreProvider.get_config(name),
         merged = Map.merge(existing, changes),
         {:ok, config} <- Config.from_map(merged) do
      StoreProvider.put_config(Config.to_map(config))
    end
  end

  @doc "Remove a provider, stopping its engine if running."
  @spec remove_provider(String.t()) :: :ok | {:error, term()}
  def remove_provider(name) do
    SyncSupervisor.stop_engine(name)
    StoreProvider.delete_config(name)
  end

  @doc "List all providers with their runtime status."
  @spec list_providers() :: [map()]
  def list_providers do
    case StoreProvider.list_configs() do
      {:ok, configs} ->
        Enum.map(configs, fn config ->
          name = Map.get(config, :name)

          %{
            name: name,
            type: Map.get(config, :type),
            enabled: Map.get(config, :enabled, true),
            status: engine_status(name)
          }
        end)

      _ ->
        []
    end
  end

  @doc "Enable a provider (persists and triggers engine start via ConfigWatcher)."
  @spec start_provider(String.t()) :: :ok | {:error, term()}
  def start_provider(name) do
    update_provider(name, %{enabled: true})
  end

  @doc "Disable a provider, stopping its engine immediately."
  @spec stop_provider(String.t()) :: :ok | {:error, term()}
  def stop_provider(name) do
    SyncSupervisor.stop_engine(name)
    update_provider(name, %{enabled: false})
  end

  # -------------------------------------------------------------------
  # Sync operations
  # -------------------------------------------------------------------

  @doc "Trigger an immediate sync of all zones for a provider."
  @spec sync_now(String.t()) :: :ok | {:error, :not_found}
  def sync_now(provider_name) do
    case lookup_engine(provider_name) do
      {:ok, pid} -> SyncEngine.sync_now(pid)
      :error -> {:error, :not_found}
    end
  end

  @doc "Trigger an immediate sync of a specific zone for a provider."
  @spec sync_now(String.t(), String.t()) :: :ok | {:error, :not_found}
  def sync_now(provider_name, zone) do
    case lookup_engine(provider_name) do
      {:ok, pid} -> SyncEngine.sync_now(pid, zone)
      :error -> {:error, :not_found}
    end
  end

  @doc "Get the current sync status for a provider engine."
  @spec sync_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def sync_status(provider_name) do
    case lookup_engine(provider_name) do
      {:ok, pid} -> {:ok, SyncEngine.status(pid)}
      :error -> {:error, :not_found}
    end
  end

  # -------------------------------------------------------------------
  # Conflict management
  # -------------------------------------------------------------------

  @doc "List all conflicts across all providers."
  @spec list_conflicts() :: [map()]
  def list_conflicts do
    case StoreProvider.list_configs() do
      {:ok, configs} ->
        Enum.flat_map(configs, fn config ->
          name = Map.get(config, :name)

          case StoreProvider.list_conflicts(name) do
            {:ok, conflicts} -> conflicts
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  @doc "List conflicts for a specific provider."
  @spec list_conflicts(String.t()) :: [map()]
  def list_conflicts(provider_name) do
    case StoreProvider.list_conflicts(provider_name) do
      {:ok, conflicts} -> conflicts
      _ -> []
    end
  end

  @doc "Resolve a single conflict by keeping local or remote records."
  @spec resolve_conflict(String.t(), String.t(), :keep_local | :keep_remote) ::
          :ok | {:error, term()}
  def resolve_conflict(provider_name, conflict_id, resolution)
      when resolution in [:keep_local, :keep_remote] do
    StoreProvider.delete_conflict(provider_name, conflict_id)
  end

  @doc "Resolve all conflicts for a provider with the given strategy."
  @spec resolve_all_conflicts(String.t(), :keep_local | :keep_remote) :: :ok
  def resolve_all_conflicts(provider_name, resolution) do
    case StoreProvider.list_conflicts(provider_name) do
      {:ok, conflicts} ->
        Enum.each(conflicts, fn conflict ->
          resolve_conflict(provider_name, Map.get(conflict, :id), resolution)
        end)

      _ ->
        :ok
    end
  end

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp lookup_engine(name) do
    case Registry.lookup(YellowDog.DnsProvider.Registry, name) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp engine_status(name) do
    case lookup_engine(name) do
      {:ok, _pid} -> :running
      :error -> :stopped
    end
  end
end
