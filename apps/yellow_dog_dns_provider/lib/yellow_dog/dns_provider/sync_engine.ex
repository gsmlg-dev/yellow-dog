defmodule YellowDog.DnsProvider.SyncEngine do
  @moduledoc """
  GenServer that synchronises DNS records between a remote provider
  and the local Store.

  One SyncEngine instance runs per configured provider. It registers
  itself via `{:via, Registry, {YellowDog.DnsProvider.Registry, name}}`
  so callers can address it by the provider config name.

  ## Sync cycle

  For each zone the engine:

  1. Fetches remote records via the provider module
  2. Reads local records from `Store.Zone`
  3. Computes a bidirectional diff (`Diff.compute/2`)
  4. Resolves conflicts per the config's `conflict_strategy`
  5. Stores any manual conflicts via `Store.Provider`
  6. Applies local changeset (put/delete RRsets)
  7. Pushes remote changeset via the provider (unless read-only)
  8. Emits telemetry and updates status
  """

  use GenServer

  require Logger

  alias YellowDog.DnsProvider.{Diff, SyncConflict}

  @registry YellowDog.DnsProvider.Registry

  # Default view for Store.Zone operations
  @default_view "default"

  # -------------------------------------------------------------------
  # Client API
  # -------------------------------------------------------------------

  @doc "Start the SyncEngine for a provider config."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    name = {:via, Registry, {@registry, config.name}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Trigger an immediate sync of all zones."
  @spec sync_now(GenServer.server()) :: :ok
  def sync_now(server) do
    GenServer.cast(server, :sync_now)
  end

  @doc "Trigger an immediate sync of a specific zone."
  @spec sync_now(GenServer.server(), String.t()) :: :ok
  def sync_now(server, zone) do
    GenServer.cast(server, {:sync_now, zone})
  end

  @doc "Get the current status of the engine."
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc "Synchronously apply the local side of one stored conflict to the provider."
  @spec resolve_conflict(GenServer.server() | String.t(), map(), timeout()) ::
          :ok | {:error, term()}
  def resolve_conflict(provider_name, conflict, timeout) when is_binary(provider_name) do
    resolve_conflict({:via, Registry, {@registry, provider_name}}, conflict, timeout)
  end

  def resolve_conflict(server, conflict, timeout) when is_map(conflict) and is_integer(timeout) do
    GenServer.call(server, {:resolve_conflict, conflict}, timeout)
  catch
    :exit, _reason -> {:error, :apply_failed}
  end

  # -------------------------------------------------------------------
  # Server callbacks
  # -------------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    provider_module = Keyword.fetch!(opts, :provider_module)

    case provider_module.init(config.credentials || %{}) do
      {:ok, provider_state} ->
        interval_ms = (config.sync_interval || 300) * 1_000
        schedule_sync(interval_ms)

        state = %{
          config: config,
          provider_module: provider_module,
          provider_state: provider_state,
          interval_ms: interval_ms,
          sync_count: 0,
          last_sync: nil,
          last_error: nil
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:provider_init_failed, reason}}
    end
  end

  @impl true
  def handle_cast(:sync_now, state) do
    new_state = run_sync_all_zones(state)
    {:noreply, new_state}
  end

  def handle_cast({:sync_now, zone}, state) do
    new_state = run_sync_zone(state, zone)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      provider: state.config.name,
      zones: state.config.zones,
      interval: state.interval_ms,
      sync_count: state.sync_count,
      last_sync: state.last_sync,
      last_error: state.last_error
    }

    {:reply, status, state}
  end

  def handle_call({:resolve_conflict, conflict}, _from, state) do
    case resolve_remote_conflict(conflict, state) do
      {:ok, provider_state} ->
        {:reply, :ok, %{state | provider_state: provider_state}}

      {:error, reason, provider_state} ->
        {:reply, {:error, reason}, %{state | provider_state: provider_state}}
    end
  end

  @impl true
  def handle_info(:sync, state) do
    new_state = run_sync_all_zones(state)
    schedule_sync(new_state.interval_ms)
    {:noreply, new_state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -------------------------------------------------------------------
  # Sync logic
  # -------------------------------------------------------------------

  defp run_sync_all_zones(state) do
    Enum.reduce(state.config.zones, state, fn zone, acc ->
      run_sync_zone(acc, zone)
    end)
  end

  defp run_sync_zone(state, zone_name) do
    zone_ref = %{name: zone_name, id: nil}
    start_time = System.monotonic_time()

    with {:ok, remote_records, provider_state} <-
           state.provider_module.get_records(zone_ref, state.provider_state) do
      state = %{state | provider_state: provider_state}
      local_records = fetch_local_records(zone_name)

      diff = Diff.compute(local_records, remote_records)
      resolved = Diff.resolve(diff, state.config.conflict_strategy)

      store_conflicts(state.config.name, zone_name, resolved.conflicts)
      apply_local_changes(zone_name, resolved.apply_to_local)

      state = push_remote_changes(state, zone_ref, resolved.push_to_remote)

      emit_sync_telemetry(state.config.name, zone_name, start_time, resolved)
      update_store_status(state.config.name, zone_name)

      %{
        state
        | sync_count: state.sync_count + 1,
          last_sync: System.system_time(:second),
          last_error: nil
      }
    else
      {:error, reason, provider_state} ->
        Logger.warning(
          "SyncEngine[#{state.config.name}] zone=#{zone_name} error: #{inspect(reason)}"
        )

        %{
          state
          | provider_state: provider_state,
            last_error: reason
        }
    end
  end

  # -------------------------------------------------------------------
  # Store interactions (wrapped for resilience)
  # -------------------------------------------------------------------

  defp fetch_local_records(zone_name) do
    case safe_call(YellowDog.Store.Zone, :list_records, [@default_view, zone_name]) do
      {:ok, records} ->
        Enum.map(records, fn r ->
          %{
            owner: r[:owner] || "",
            type: to_string(r[:type] || ""),
            ttl: List.first(r[:rrset] || [])[:ttl] || 0,
            rdata: List.first(r[:rrset] || [])[:rdata] || ""
          }
        end)

      _ ->
        []
    end
  end

  defp apply_local_changes(zone_name, changeset) do
    Enum.each(changeset.additions, fn record ->
      rrset = [%{ttl: record.ttl, rdata: record.rdata}]

      safe_call(YellowDog.Store.Zone, :put_rrset, [
        @default_view,
        zone_name,
        record.owner,
        record.type,
        rrset
      ])
    end)

    Enum.each(changeset.deletions, fn record ->
      safe_call(YellowDog.Store.Zone, :delete_rrset, [
        @default_view,
        zone_name,
        record.owner,
        record.type
      ])
    end)
  end

  defp push_remote_changes(state, zone_ref, changeset) do
    if changeset.additions == [] and changeset.deletions == [] do
      state
    else
      case state.provider_module.apply_changeset(
             zone_ref,
             changeset,
             state.provider_state
           ) do
        {:ok, provider_state} ->
          %{state | provider_state: provider_state}

        {:error, :read_only, provider_state} ->
          %{state | provider_state: provider_state}

        {:error, reason, provider_state} ->
          Logger.warning("SyncEngine[#{state.config.name}] push failed: #{inspect(reason)}")

          %{state | provider_state: provider_state, last_error: reason}
      end
    end
  end

  defp store_conflicts(provider_name, zone_name, conflicts) do
    Enum.each(conflicts, fn conflict ->
      sync_conflict =
        SyncConflict.new(%{
          provider_name: provider_name,
          zone: zone_name,
          owner: conflict.owner,
          type: conflict.type,
          local_records: [conflict.local],
          remote_records: [conflict.remote]
        })

      safe_call(YellowDog.Store.Provider, :put_conflict, [sync_conflict])
    end)
  end

  defp update_store_status(provider_name, zone_name) do
    status = %{
      last_sync: System.system_time(:second),
      last_zone: zone_name,
      state: :synced
    }

    safe_call(YellowDog.Store.Provider, :put_status, [provider_name, status])
  end

  defp resolve_remote_conflict(conflict, state) do
    with {:ok, target} <- conflict_target(conflict),
         {:ok, zones, provider_state} <-
           state.provider_module.list_zones(state.provider_state),
         {:ok, zone_ref} <- resolve_zone_ref(zones, target.zone),
         {:ok, remote_records, provider_state} <-
           state.provider_module.get_records(zone_ref, provider_state),
         {:ok, changeset} <- reconcile_conflict(remote_records, target) do
      apply_remote_changes(state.provider_module, zone_ref, changeset, provider_state)
    else
      :error ->
        {:error, :invalid, state.provider_state}

      {:error, reason} ->
        {:error, reason, state.provider_state}

      {:error, reason, provider_state} ->
        {:error, provider_error(reason), provider_state}
    end
  end

  defp conflict_target(conflict) do
    with zone when is_binary(zone) <- conflict_field(conflict, :zone),
         local_records when is_list(local_records) <- conflict_field(conflict, :local_records),
         remote_records when is_list(remote_records) <- conflict_field(conflict, :remote_records),
         {:ok, local_records} <- canonical_records(local_records),
         {:ok, remote_records} <- canonical_records(remote_records) do
      {:ok,
       %{
         zone: canonical_zone(zone),
         local_records: local_records,
         remote_records: remote_records
       }}
    else
      _invalid -> :error
    end
  end

  defp conflict_field(conflict, key) do
    Map.get(conflict, key, Map.get(conflict, Atom.to_string(key)))
  end

  defp resolve_zone_ref(zones, zone_name) when is_list(zones) do
    matches =
      Enum.filter(zones, fn
        %{name: name} when is_binary(name) -> canonical_zone(name) == zone_name
        _invalid -> false
      end)

    case matches do
      [%{id: id} = zone_ref] when is_binary(id) and id != "" -> {:ok, zone_ref}
      [_invalid] -> {:error, :unsupported}
      [] -> {:error, :not_found}
      [_first | _rest] -> {:error, :conflict}
    end
  end

  defp resolve_zone_ref(_zones, _zone_name), do: {:error, :unsupported}

  defp reconcile_conflict(remote_records, target) when is_list(remote_records) do
    with {:ok, remote_records} <- canonical_records(remote_records) do
      remote_keys = MapSet.new(remote_records, &record_key/1)

      deletions =
        Enum.filter(target.remote_records, fn record ->
          MapSet.member?(remote_keys, record_key(record))
        end)

      additions =
        Enum.reject(target.local_records, fn record ->
          MapSet.member?(remote_keys, record_key(record))
        end)

      {:ok, %{additions: additions, deletions: deletions}}
    end
  end

  defp reconcile_conflict(_remote_records, _target), do: :error

  defp apply_remote_changes(
         _provider,
         _zone_ref,
         %{additions: [], deletions: []},
         provider_state
       ),
       do: {:ok, provider_state}

  defp apply_remote_changes(provider, zone_ref, changeset, provider_state) do
    case provider.apply_changeset(zone_ref, changeset, provider_state) do
      {:ok, provider_state} -> {:ok, provider_state}
      {:error, reason, provider_state} -> {:error, provider_error(reason), provider_state}
    end
  end

  defp canonical_records(records) do
    records
    |> Enum.reduce_while({:ok, []}, fn record, {:ok, canonical} ->
      case canonical_record(record) do
        {:ok, record} -> {:cont, {:ok, [record | canonical]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, canonical} -> {:ok, canonical |> Enum.uniq_by(&record_key/1) |> Enum.reverse()}
      :error -> :error
    end
  end

  defp canonical_record(record) when is_map(record) do
    with owner when is_binary(owner) <- conflict_field(record, :owner),
         type when is_binary(type) <- conflict_field(record, :type),
         ttl when is_integer(ttl) and ttl >= 0 <- conflict_field(record, :ttl),
         rdata when not is_nil(rdata) <- conflict_field(record, :rdata) do
      {:ok,
       %{
         owner: owner,
         type: type,
         ttl: ttl,
         rdata: rdata
       }}
    else
      _invalid -> :error
    end
  end

  defp canonical_record(_record), do: :error

  defp record_key(record) do
    {canonical_owner(record.owner), String.upcase(record.type), record.ttl, record.rdata}
  end

  defp canonical_owner(owner), do: owner |> String.downcase() |> ensure_trailing_dot()
  defp canonical_zone(zone), do: zone |> String.downcase() |> String.trim_trailing(".")
  defp ensure_trailing_dot(value), do: String.trim_trailing(value, ".") <> "."

  defp provider_error(reason) when reason in [:not_found, :conflict, :unsupported, :invalid],
    do: reason

  defp provider_error(_reason), do: :apply_failed

  # -------------------------------------------------------------------
  # Helpers
  # -------------------------------------------------------------------

  defp schedule_sync(interval_ms) do
    Process.send_after(self(), :sync, interval_ms)
  end

  defp emit_sync_telemetry(provider_name, zone_name, start_time, resolved) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:yellow_dog, :dns_provider, :sync, :stop],
      %{duration: duration},
      %{
        provider: provider_name,
        zone: zone_name,
        local_additions: length(resolved.apply_to_local.additions),
        local_deletions: length(resolved.apply_to_local.deletions),
        remote_additions: length(resolved.push_to_remote.additions),
        remote_deletions: length(resolved.push_to_remote.deletions),
        conflicts: length(resolved.conflicts)
      }
    )
  end

  @doc false
  def safe_call(module, function, args) do
    apply(module, function, args)
  rescue
    e ->
      Logger.debug("SyncEngine safe_call #{module}.#{function} failed: #{Exception.message(e)}")

      :error
  end
end
