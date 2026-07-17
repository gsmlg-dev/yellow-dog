defmodule YellowDog.DnsProvider do
  @moduledoc """
  Public API for DNS zone provider management and synchronization.

  Provides CRUD operations for provider configs, on-demand sync
  triggers, and conflict resolution. All persistent state flows
  through `YellowDog.Store.Provider`; runtime engines are managed
  via `SyncSupervisor`.
  """

  alias YellowDog.DnsProvider.{Config, ConfigWatcher, SyncEngine}
  alias YellowDog.Store.Provider, as: StoreProvider

  @default_view "default"
  @conflict_resolution_timeout 5_000

  # -------------------------------------------------------------------
  # Provider management
  # -------------------------------------------------------------------

  @doc "Add a new provider from an attribute map."
  @spec add_provider(map()) :: :ok | {:error, term()}
  def add_provider(attrs) do
    with {:ok, config} <- Config.new(attrs),
         :ok <- store_provider().put_config(Config.to_map(config)) do
      case config_watcher().reconcile(config.name) do
        :ok -> :ok
        {:error, _reason} -> compensate_create(config.name)
      end
    end
  end

  @doc "Fetches one provider config without reducing owner errors to a list projection."
  @spec fetch_provider(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_provider(name), do: store_provider().get_config(name)

  @doc "Update an existing provider, merging `changes` into stored config."
  @spec update_provider(String.t(), map()) :: :ok | {:error, term()}
  def update_provider(name, changes) do
    with {:ok, existing} <- fetch_provider(name),
         merged = Map.merge(existing, changes),
         {:ok, config} <- Config.from_map(merged) do
      candidate = Config.to_map(config)

      with :ok <- store_provider().put_config(candidate) do
        case config_watcher().reconcile(name) do
          :ok -> :ok
          {:error, _reason} -> compensate_update(name, existing)
        end
      end
    end
  end

  @doc "Remove a provider, stopping its engine if running."
  @spec remove_provider(String.t()) :: :ok | {:error, term()}
  def remove_provider(name) do
    with {:ok, existing} <- fetch_provider(name),
         :ok <- store_provider().delete_config(name) do
      case config_watcher().reconcile(name) do
        :ok -> :ok
        {:error, _reason} -> compensate_update(name, existing)
      end
    end
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

  @doc "Fetch one persisted conflict by its globally unique ID."
  @spec fetch_conflict(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_conflict(conflict_id) when is_binary(conflict_id) do
    with {:ok, configs} <- store_provider().list_configs() do
      configs
      |> Enum.reduce_while({:ok, []}, fn config, {:ok, matches} ->
        with name when is_binary(name) <- Map.get(config, :name),
             {:ok, conflicts} <- store_provider().list_conflicts(name) do
          matching = Enum.filter(conflicts, &(Map.get(&1, :id) == conflict_id))
          {:cont, {:ok, matching ++ matches}}
        else
          {:error, _reason} = error -> {:halt, error}
          _invalid -> {:halt, {:error, :apply_failed}}
        end
      end)
      |> case do
        {:ok, [conflict]} -> {:ok, conflict}
        {:ok, []} -> {:error, :not_found}
        {:ok, [_first | _rest]} -> {:error, :conflict}
        {:error, _reason} = error -> error
      end
    end
  end

  def fetch_conflict(_conflict_id), do: {:error, :not_found}

  @doc "Resolve one conflict by its global ID and apply the selected side."
  @spec resolve_conflict(String.t(), :use_local | :use_cloud) :: :ok | {:error, term()}
  def resolve_conflict(conflict_id, resolution)
      when is_binary(conflict_id) and resolution in [:use_local, :use_cloud] do
    with {:ok, conflict} <- fetch_conflict(conflict_id),
         {:ok, context} <- conflict_context(conflict) do
      case resolution do
        :use_cloud -> resolve_use_cloud(context)
        :use_local -> resolve_use_local(context)
      end
    end
  end

  def resolve_conflict(_conflict_id, _resolution), do: {:error, :invalid}

  @doc "Resolve a single conflict by keeping local or remote records."
  @spec resolve_conflict(String.t(), String.t(), :keep_local | :keep_remote) ::
          :ok | {:error, term()}
  def resolve_conflict(provider_name, conflict_id, resolution)
      when resolution in [:keep_local, :keep_remote] do
    with {:ok, conflict} <- fetch_conflict(conflict_id),
         true <- field(conflict, :provider_name) == provider_name do
      resolve_conflict(conflict_id, compatibility_resolution(resolution))
    else
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
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

  defp compatibility_resolution(:keep_local), do: :use_local
  defp compatibility_resolution(:keep_remote), do: :use_cloud

  defp conflict_context(conflict) do
    with provider_name when is_binary(provider_name) <- field(conflict, :provider_name),
         zone when is_binary(zone) <- canonical_name(field(conflict, :zone)),
         true <- zone != "",
         owner when is_binary(owner) <- canonical_owner(field(conflict, :owner)),
         true <- owner != "",
         {:ok, type} <- conflict_record_type(field(conflict, :type)),
         {:ok, config} <- store_provider().get_config(provider_name),
         true <- field(config, :name) == provider_name,
         true <- field(config, :enabled, true),
         {:ok, provider_type} <- conflict_provider_type(field(config, :type)),
         {:ok, zone_record} <- fetch_authoritative_zone(zone) do
      {:ok,
       %{
         conflict: conflict,
         provider_name: provider_name,
         provider_type: provider_type,
         zone: zone,
         owner: owner,
         type: type,
         zone_record: zone_record
       }}
    else
      false -> {:error, :unsupported}
      {:error, :invalid} -> {:error, :invalid}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :unsupported} -> {:error, :unsupported}
      {:error, _reason} -> {:error, :apply_failed}
      :error -> {:error, :unsupported}
      _invalid -> {:error, :invalid}
    end
  end

  defp resolve_use_cloud(context) do
    with {:ok, remote_rrset} <- conflict_rrset(context.conflict, :remote_records, context),
         {:ok, old_rrset} <- fetch_rrset(context),
         :ok <- persist_rrset(context, remote_rrset) do
      case reload_zone(context) do
        :ok -> delete_marker(context)
        {:error, :reload_failed} -> rollback_local_rrset(context, old_rrset)
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp resolve_use_local(%{provider_type: :cloudflare} = context) do
    case sync_engine().resolve_conflict(
           context.provider_name,
           context.conflict,
           @conflict_resolution_timeout
         ) do
      :ok -> delete_marker(context)
      _failure -> {:error, :apply_failed}
    end
  end

  defp resolve_use_local(%{provider_type: :route53}), do: {:error, :unsupported}

  defp fetch_authoritative_zone(zone) do
    case zone_store().get_zone(@default_view, zone) do
      {:ok, zone_record} when is_map(zone_record) ->
        if authoritative_zone?(field(zone_record, :zone_type)),
          do: {:ok, zone_record},
          else: {:error, :unsupported}

      {:error, :not_found} ->
        {:error, :not_found}

      _failure ->
        {:error, :apply_failed}
    end
  end

  defp fetch_rrset(context) do
    case zone_store().get_rrset(@default_view, context.zone, context.owner, context.type) do
      {:ok, %{rrset: rrset}} when is_list(rrset) -> {:ok, rrset}
      {:error, :not_found} -> {:ok, :missing}
      _failure -> {:error, :apply_failed}
    end
  end

  defp conflict_rrset(conflict, key, context) do
    case field(conflict, key) do
      [] ->
        {:ok, :missing}

      records when is_list(records) ->
        records
        |> Enum.reduce_while({:ok, []}, fn record, {:ok, rrset} ->
          with owner when is_binary(owner) <- canonical_owner(field(record, :owner)),
               true <- owner == context.owner,
               {:ok, type} <- conflict_record_type(field(record, :type)),
               true <- type == context.type,
               ttl when is_integer(ttl) and ttl >= 0 <- field(record, :ttl),
               rdata when not is_nil(rdata) <- field(record, :rdata) do
            {:cont, {:ok, [%{ttl: ttl, rdata: rdata} | rrset]}}
          else
            _invalid -> {:halt, {:error, :invalid}}
          end
        end)
        |> case do
          {:ok, rrset} -> {:ok, Enum.reverse(rrset)}
          {:error, _reason} = error -> error
        end

      _invalid ->
        {:error, :invalid}
    end
  end

  defp persist_rrset(context, :missing) do
    store_result(
      zone_store().delete_rrset(@default_view, context.zone, context.owner, context.type)
    )
  end

  defp persist_rrset(context, rrset) do
    store_result(
      zone_store().put_rrset(@default_view, context.zone, context.owner, context.type, rrset)
    )
  end

  defp rollback_local_rrset(context, old_rrset) do
    with :ok <- persist_rrset(context, old_rrset),
         :ok <- reload_zone(context) do
      {:error, :apply_failed}
    else
      _failure -> {:error, :rollback_failed}
    end
  end

  defp reload_zone(context) do
    case zone_controller().reload_zone(@default_view, :auth, context.zone, []) do
      :ok -> :ok
      _failure -> {:error, :reload_failed}
    end
  end

  defp delete_marker(context) do
    case store_provider().delete_conflict(context.provider_name, field(context.conflict, :id)) do
      :ok -> :ok
      _failure -> {:error, :apply_failed}
    end
  end

  defp store_result(:ok), do: :ok
  defp store_result(_failure), do: {:error, :apply_failed}

  defp authoritative_zone?(type), do: type in [:auth, :authoritative, "auth", "authoritative"]

  defp conflict_provider_type(type) when type in [:cloudflare, "cloudflare"],
    do: {:ok, :cloudflare}

  defp conflict_provider_type(type) when type in [:route53, :aws, "route53", "aws"],
    do: {:ok, :route53}

  defp conflict_provider_type(_type), do: :error

  for {wire_type, store_type} <- [
        {"A", :a},
        {"AAAA", :aaaa},
        {"CNAME", :cname},
        {"MX", :mx},
        {"NS", :ns},
        {"PTR", :ptr},
        {"SRV", :srv},
        {"TXT", :txt}
      ] do
    defp conflict_record_type(unquote(wire_type)), do: {:ok, unquote(store_type)}
  end

  defp conflict_record_type(_type), do: {:error, :invalid}

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(_map, _key, default), do: default

  defp canonical_owner("@"), do: "@"
  defp canonical_owner(owner) when is_binary(owner), do: canonical_name(owner)
  defp canonical_owner(_owner), do: nil

  defp canonical_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp canonical_name(_name), do: nil

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

  defp compensate_create(name) do
    with :ok <- store_provider().delete_config(name),
         :ok <- config_watcher().reconcile(name) do
      {:error, :apply_failed}
    else
      _ -> {:error, :rollback_failed}
    end
  end

  defp compensate_update(name, existing) do
    with :ok <- store_provider().put_config(existing),
         :ok <- config_watcher().reconcile(name) do
      {:error, :apply_failed}
    else
      _ -> {:error, :rollback_failed}
    end
  end

  if Mix.env() == :test do
    defp store_provider do
      Application.get_env(:yellow_dog_dns_provider, __MODULE__, [])
      |> Keyword.get(:provider_store, StoreProvider)
    end

    defp config_watcher do
      Application.get_env(:yellow_dog_dns_provider, __MODULE__, [])
      |> Keyword.get(:config_watcher, ConfigWatcher)
    end

    defp zone_store do
      Application.get_env(:yellow_dog_dns_provider, __MODULE__, [])
      |> Keyword.get(:zone_store, YellowDog.Store.Zone)
    end

    defp zone_controller do
      Application.get_env(:yellow_dog_dns_provider, __MODULE__, [])
      |> Keyword.get(:zone_controller, YellowDog.Dns.ZoneController)
    end

    defp sync_engine do
      Application.get_env(:yellow_dog_dns_provider, __MODULE__, [])
      |> Keyword.get(:sync_engine, SyncEngine)
    end
  else
    defp store_provider, do: StoreProvider
    defp config_watcher, do: ConfigWatcher
    defp zone_store, do: YellowDog.Store.Zone
    defp zone_controller, do: YellowDog.Dns.ZoneController
    defp sync_engine, do: SyncEngine
  end
end
