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
