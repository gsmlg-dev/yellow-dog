defmodule YellowDog.Store.Zone do
  @moduledoc """
  DNS zone data facade over the Store backend.

  Manages zone metadata and resource record sets (RRsets) for all zone types:
  auth, forward, and stub. All zones are scoped to views (split-horizon DNS).

  Zone creation uses CAS (`expected: nil`) to prevent duplicates. RRset writes
  use upsert semantics (last-writer-wins). SOA serial auto-increment uses CAS
  with bounded retries to prevent lost updates.

  Key patterns (via `YellowDog.Store.Key`):
  - Zone metadata: `dns:view:{view_name}:zone:{zone_name}`
  - Resource records (auth only): `dns:view:{view_name}:zone:{zone_name}:rr:{owner}:{type}`
  """

  import Bitwise, only: [&&&: 2, |||: 2]

  alias YellowDog.Store.{Backend, EventBridge, Key}
  alias YellowDog.Store.Zone.{Recovery, Replacement}

  @max_batch_size 500
  @max_cas_retries 10

  @doc false
  def max_replacement_transaction_bytes, do: Replacement.max_transaction_bytes()

  @doc false
  def recover_pending_replacements, do: recover_all_replacements()

  @type zone_id :: String.t()
  @type view_name :: String.t()
  @type zone_name :: String.t()
  @type owner :: String.t()
  @type rr_type :: atom()
  @type record :: %{
          required(:owner) => owner(),
          required(:type) => rr_type(),
          required(:rrset) => [map()]
        }
  @type soa :: %{
          mname: String.t(),
          rname: String.t(),
          serial: non_neg_integer(),
          refresh: pos_integer(),
          retry: pos_integer(),
          expire: pos_integer(),
          minimum: pos_integer()
        }
  @type cloud_mirror :: %{
          enabled: true,
          connector_name: String.t(),
          provider: :cloudflare | :route53,
          zone_id: String.t(),
          direction: :pull_from_cloud | :push_to_cloud | :bidirectional,
          conflict_strategy: :local_wins | :cloud_wins | :manual
        }

  # -------------------------------------------------------------------
  # Auth zone metadata
  # -------------------------------------------------------------------

  @doc """
  Create an auth zone. Fails if the zone already exists (CAS with `expected: nil`).

  ## Options

    * `:default_ttl` - default TTL for records (default `3600`)
    * `:authoritative` - whether this node is authoritative (default `true`)
    * `:allow_dynamic_update` - accept RFC 2136 dynamic updates (default `false`)
    * `:serial_strategy` - `:date_serial` or `:increment` (default `:date_serial`)
    * `:cloud_mirror` - cloud DNS mirror binding metadata (default `nil`)
  """
  @spec create_zone(view_name(), zone_name(), soa(), keyword()) ::
          :ok | {:error, :already_exists | term()}
  def create_zone(view_name, name, soa, opts \\ []) do
    with {:ok, {view_name, name}} <- Key.canonical_zone_scope(view_name, name) do
      with_zone_lock(view_name, name, fn ->
        with_recovery(view_name, name, fn backend ->
          create_zone_locked(backend, view_name, name, soa, opts)
        end)
      end)
    end
  end

  defp create_zone_locked(backend, view_name, name, soa, opts) do
    key = Key.zone(view_name, name)
    now = System.system_time(:second)

    value = %{
      id: generate_uuid(),
      zone_type: :auth,
      origin: name,
      soa: soa,
      default_ttl: Keyword.get(opts, :default_ttl, 3600),
      authoritative: Keyword.get(opts, :authoritative, true),
      allow_dynamic_update: Keyword.get(opts, :allow_dynamic_update, false),
      serial_strategy: Keyword.get(opts, :serial_strategy, :date_serial),
      cloud_mirror: Keyword.get(opts, :cloud_mirror),
      created_at: now,
      updated_at: now
    }

    start_time = System.monotonic_time()

    case backend.put_if(key, value, expected: nil) do
      :ok ->
        emit_operation_telemetry(start_time, :zone, :put, key, :strong)
        EventBridge.notify(:put, key, value)
        :ok

      {:error, :condition_failed} ->
        {:error, :already_exists}

      {:error, _} = error ->
        error
    end
  end

  # -------------------------------------------------------------------
  # Forward zone
  # -------------------------------------------------------------------

  @doc """
  Create a forward zone. Stores config only (no zone data).

  ## Options

    * `:forward_mode` - `:only` or `:first` (default `:only`)
    * `:timeout_ms` - forwarding timeout in ms (default `5000`)
    * `:max_retries` - max retry count (default `2`)
  """
  @spec create_forward_zone(view_name(), zone_name(), [map()], keyword()) ::
          :ok | {:error, :already_exists | term()}
  def create_forward_zone(view_name, name, forwarders, opts \\ []) do
    with {:ok, {view_name, name}} <- Key.canonical_zone_scope(view_name, name) do
      with_zone_lock(view_name, name, fn ->
        with_recovery(view_name, name, fn backend ->
          create_forward_zone_locked(backend, view_name, name, forwarders, opts)
        end)
      end)
    end
  end

  defp create_forward_zone_locked(backend, view_name, name, forwarders, opts) do
    key = Key.zone(view_name, name)
    now = System.system_time(:second)

    value = %{
      id: generate_uuid(),
      zone_type: :forward,
      origin: name,
      forwarders: forwarders,
      forward_mode: Keyword.get(opts, :forward_mode, :only),
      timeout_ms: Keyword.get(opts, :timeout_ms, 5000),
      max_retries: Keyword.get(opts, :max_retries, 2),
      created_at: now,
      updated_at: now
    }

    start_time = System.monotonic_time()

    case backend.put_if(key, value, expected: nil) do
      :ok ->
        emit_operation_telemetry(start_time, :zone, :put, key, :strong)
        EventBridge.notify(:put, key, value)
        :ok

      {:error, :condition_failed} ->
        {:error, :already_exists}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Update a forward zone's configuration. CAS update.
  """
  @spec update_forward_zone(view_name(), zone_name(), map()) :: :ok | {:error, term()}
  def update_forward_zone(view_name, name, attrs) do
    update_zone(view_name, name, attrs)
  end

  # -------------------------------------------------------------------
  # Stub zone
  # -------------------------------------------------------------------

  @doc """
  Create a stub zone. Stores config only (NS/glue are runtime cache).

  ## Options

    * `:refresh_interval` - how often to re-query primaries in seconds (default `3600`)
  """
  @spec create_stub_zone(view_name(), zone_name(), [map()], keyword()) ::
          :ok | {:error, :already_exists | term()}
  def create_stub_zone(view_name, name, primaries, opts \\ []) do
    with {:ok, {view_name, name}} <- Key.canonical_zone_scope(view_name, name) do
      with_zone_lock(view_name, name, fn ->
        with_recovery(view_name, name, fn backend ->
          create_stub_zone_locked(backend, view_name, name, primaries, opts)
        end)
      end)
    end
  end

  defp create_stub_zone_locked(backend, view_name, name, primaries, opts) do
    key = Key.zone(view_name, name)
    now = System.system_time(:second)

    value = %{
      id: generate_uuid(),
      zone_type: :stub,
      origin: name,
      primaries: primaries,
      refresh_interval: Keyword.get(opts, :refresh_interval, 3600),
      created_at: now,
      updated_at: now
    }

    start_time = System.monotonic_time()

    case backend.put_if(key, value, expected: nil) do
      :ok ->
        emit_operation_telemetry(start_time, :zone, :put, key, :strong)
        EventBridge.notify(:put, key, value)
        :ok

      {:error, :condition_failed} ->
        {:error, :already_exists}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Update a stub zone's configuration. CAS update.
  """
  @spec update_stub_zone(view_name(), zone_name(), map()) :: :ok | {:error, term()}
  def update_stub_zone(view_name, name, attrs) do
    update_zone(view_name, name, attrs)
  end

  # -------------------------------------------------------------------
  # Generic zone operations (all types)
  # -------------------------------------------------------------------

  @doc """
  Delete a zone and all its resource records (for auth zones).
  Works for all zone types.
  """
  @spec delete_zone(view_name(), zone_name()) :: :ok | {:error, term()}
  def delete_zone(view_name, name) do
    with {:ok, {view_name, name}} <- Key.canonical_zone_scope(view_name, name) do
      with_zone_lock(view_name, name, fn ->
        with_recovery(view_name, name, fn backend ->
          delete_zone_locked(backend, view_name, name)
        end)
      end)
    end
  end

  defp delete_zone_locked(backend, view_name, name) do
    zone_key = Key.zone(view_name, name)
    start_time = System.monotonic_time()

    case backend.delete(zone_key) do
      :ok ->
        emit_operation_telemetry(start_time, :zone, :delete, zone_key, :strong)
        EventBridge.notify(:delete, zone_key, nil)

        # Best-effort cleanup of RR entries for auth zones
        rr_prefix = Key.zone_rr_prefix(view_name, name)

        case backend.prefix_scan(rr_prefix, consistency: :strong) do
          {:ok, rr_entries} ->
            failed =
              Enum.count(rr_entries, fn {rr_key, _value} ->
                backend.delete(rr_key) != :ok
              end)

            if failed > 0 do
              require Logger

              Logger.warning(
                "Zone #{name}: #{failed}/#{length(rr_entries)} RR keys failed to delete"
              )
            end

          {:error, scan_error} ->
            require Logger
            Logger.warning("Zone #{name}: RR cleanup scan failed: #{inspect(scan_error)}")
        end

        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Get zone metadata. Uses `:eventual` consistency.
  """
  @spec get_zone(view_name(), zone_name()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_zone(view_name, name) do
    with {:ok, {view_name, name}} <- Key.canonical_zone_scope(view_name, name) do
      with_zone_lock(view_name, name, fn ->
        with_recovery(view_name, name, fn backend ->
          key = Key.zone(view_name, name)
          start_time = System.monotonic_time()
          result = backend.get(key, consistency: :eventual)
          emit_operation_telemetry(start_time, :zone, :get, key, :eventual)
          result
        end)
      end)
    end
  end

  @doc """
  Get zone metadata by persisted UUID.

  This scans zone metadata records. Zone counts are expected to be small; a
  secondary index can be added later if this becomes hot.
  """
  @spec get_zone_by_id(zone_id()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_zone_by_id(id) when is_binary(id) do
    case list_zones() do
      {:ok, zones} ->
        case Enum.find(zones, &(&1[:id] == id)) do
          nil -> {:error, :not_found}
          zone -> {:ok, zone}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Update zone metadata (any zone type). Merges `attrs` into existing metadata.
  Uses CAS to prevent lost updates.
  """
  @max_update_retries 5

  @spec update_zone(view_name(), zone_name(), map()) :: :ok | {:error, term()}
  def update_zone(view_name, name, attrs) do
    with {:ok, {view_name, name}} <- Key.canonical_zone_scope(view_name, name) do
      with_zone_lock(view_name, name, fn ->
        with_recovery(view_name, name, fn backend ->
          do_update_zone_locked(backend, view_name, name, attrs, @max_update_retries)
        end)
      end)
    end
  end

  defp do_update_zone_locked(_backend, _view_name, _name, _attrs, 0),
    do: {:error, :conflict}

  defp do_update_zone_locked(backend, view_name, name, attrs, retries) do
    key = Key.zone(view_name, name)

    case backend.get(key, consistency: :strong) do
      {:ok, zone_meta} ->
        now = System.system_time(:second)

        updated_meta =
          zone_meta
          |> Map.merge(attrs)
          |> Map.put(:updated_at, now)

        case backend.put_if(key, updated_meta, condition: fn old -> old == zone_meta end) do
          :ok ->
            EventBridge.notify(:put, key, updated_meta)
            :ok

          {:error, :condition_failed} ->
            do_update_zone_locked(backend, view_name, name, attrs, retries - 1)

          {:error, _} = error ->
            error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  List all zones across all views. Returns a list of zone metadata maps.
  """
  @spec list_zones() :: {:ok, [map()]} | {:error, term()}
  def list_zones do
    prefix = Key.all_views_prefix()
    start_time = System.monotonic_time()

    with :ok <- recover_all_replacements() do
      case Backend.active().prefix_scan(prefix, consistency: :eventual) do
        {:ok, entries} ->
          zones =
            entries
            |> Enum.filter(fn {key, _value} -> zone_metadata_key?(key) end)
            |> Enum.map(fn {key, value} ->
              # Inject view_name from key: dns:view:{view_name}:zone:{zone_name}
              view_name = extract_view_name_from_key(key)
              ensure_zone_id(key, Map.put(value, :view_name, view_name))
            end)

          emit_operation_telemetry(start_time, :zone, :list, prefix, :eventual)
          {:ok, zones}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  List all zones in a specific view.
  """
  @spec list_zones_for_view(view_name()) :: {:ok, [map()]} | {:error, term()}
  def list_zones_for_view(view_name) do
    with {:ok, view_name} <- canonical_view_name(view_name) do
      prefix = Key.zone_prefix(view_name)
      start_time = System.monotonic_time()

      with :ok <- recover_all_replacements(view_name) do
        case Backend.active().prefix_scan(prefix, consistency: :eventual) do
          {:ok, entries} ->
            zones =
              entries
              |> Enum.filter(fn {key, _value} -> zone_metadata_key?(key) end)
              |> Enum.map(fn {key, value} ->
                ensure_zone_id(key, Map.put(value, :view_name, view_name))
              end)

            emit_operation_telemetry(start_time, :zone, :list, prefix, :eventual)
            {:ok, zones}

          {:error, _} = error ->
            error
        end
      end
    end
  end

  @doc """
  List all zones of a specific type across all views.
  """
  @spec list_zones_by_type(atom()) :: {:ok, [map()]} | {:error, term()}
  def list_zones_by_type(zone_type) do
    case list_zones() do
      {:ok, zones} ->
        filtered = Enum.filter(zones, fn z -> z[:zone_type] == zone_type end)
        {:ok, filtered}

      {:error, _} = error ->
        error
    end
  end

  # -------------------------------------------------------------------
  # Resource records (auth zones only)
  # -------------------------------------------------------------------

  @doc """
  Create or update an RRset. Auto-increments the SOA serial on success.
  """
  @spec put_rrset(view_name(), zone_name(), owner(), rr_type(), list(map())) ::
          :ok | {:error, term()}
  def put_rrset(view_name, zone, owner, type, rrset) do
    with {:ok, {view_name, zone}} <- Key.canonical_zone_scope(view_name, zone),
         {:ok, owner} <- Key.canonical_owner(owner),
         :ok <- validate_rr_type(type) do
      with_zone_lock(view_name, zone, fn ->
        with_recovery(view_name, zone, fn backend ->
          put_rrset_locked(backend, view_name, zone, owner, type, rrset)
        end)
      end)
    end
  end

  defp put_rrset_locked(backend, view_name, zone, owner, type, rrset) do
    key = Key.zone_rr(view_name, zone, owner, type)
    now = System.system_time(:second)

    value = %{
      rrset: rrset,
      owner: owner,
      type: type,
      zone: zone,
      class: :in,
      source: :api,
      updated_at: now
    }

    start_time = System.monotonic_time()

    result = backend.put(key, value)

    case result do
      :ok ->
        emit_operation_telemetry(start_time, :zone, :put, key, :strong)
        emit_rr_changed(zone, owner, type, :put)
        EventBridge.notify(:put, key, value)
        do_increment_serial_locked(backend, view_name, zone, @max_cas_retries)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Replace all RRsets in an existing authoritative zone.

  The complete desired set is validated before any write. Changed replacements
  increment the SOA serial once and publish RR events only after the records and
  serial are committed. Partial failures restore the exact prior RRset content.
  """
  @spec replace_records(view_name(), zone_name(), [record()]) ::
          {:ok, %{previous: [map()], changed_count: non_neg_integer()}}
          | {:error, {:replace_failed, term()}}
          | {:error, {:rollback_failed, term(), term()}}
  def replace_records(view_name, zone, records) do
    with {:ok, {view_name, zone}} <- Key.canonical_zone_scope(view_name, zone),
         {:ok, desired_records} <-
           validate_desired_records(view_name, zone, records) do
      case with_zone_lock(view_name, zone, fn ->
             with_recovery(view_name, zone, fn backend ->
               do_replace_records(backend, view_name, zone, desired_records)
             end)
           end) do
        {:error, {:lock_failed, reason}} ->
          {:error, {:replace_failed, {:lock_failed, reason}}}

        result ->
          result
      end
    else
      {:error, reason} -> {:error, {:replace_failed, reason}}
    end
  end

  @doc """
  Lookup a specific RRset. Uses `:eventual` consistency.
  """
  @spec get_rrset(view_name(), zone_name(), owner(), rr_type()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def get_rrset(view_name, zone, owner, type) do
    with {:ok, {view_name, zone}} <- Key.canonical_zone_scope(view_name, zone),
         {:ok, owner} <- Key.canonical_owner(owner),
         :ok <- validate_rr_type(type) do
      with_zone_lock(view_name, zone, fn ->
        with_recovery(view_name, zone, fn backend ->
          key = Key.zone_rr(view_name, zone, owner, type)
          start_time = System.monotonic_time()
          result = backend.get(key, consistency: :eventual)
          emit_operation_telemetry(start_time, :zone, :get, key, :eventual)
          result
        end)
      end)
    end
  end

  @doc """
  Remove an RRset. Auto-increments the SOA serial on success.
  """
  @spec delete_rrset(view_name(), zone_name(), owner(), rr_type()) :: :ok | {:error, term()}
  def delete_rrset(view_name, zone, owner, type) do
    with {:ok, {view_name, zone}} <- Key.canonical_zone_scope(view_name, zone),
         {:ok, owner} <- Key.canonical_owner(owner),
         :ok <- validate_rr_type(type) do
      with_zone_lock(view_name, zone, fn ->
        with_recovery(view_name, zone, fn backend ->
          delete_rrset_locked(backend, view_name, zone, owner, type)
        end)
      end)
    end
  end

  defp delete_rrset_locked(backend, view_name, zone, owner, type) do
    key = Key.zone_rr(view_name, zone, owner, type)
    start_time = System.monotonic_time()

    case backend.delete(key) do
      :ok ->
        emit_operation_telemetry(start_time, :zone, :delete, key, :strong)
        emit_rr_changed(zone, owner, type, :delete)
        EventBridge.notify(:delete, key, nil)
        do_increment_serial_locked(backend, view_name, zone, @max_cas_retries)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  List all RRsets in a zone via prefix scan.
  """
  @spec list_records(view_name(), zone_name()) :: {:ok, [map()]} | {:error, term()}
  def list_records(view_name, zone) do
    with {:ok, {view_name, zone}} <- Key.canonical_zone_scope(view_name, zone) do
      with_zone_lock(view_name, zone, fn ->
        with_recovery(view_name, zone, fn backend ->
          prefix = Key.zone_rr_prefix(view_name, zone)
          start_time = System.monotonic_time()

          case backend.prefix_scan(prefix, consistency: :eventual) do
            {:ok, entries} ->
              records = Enum.map(entries, fn {_key, value} -> value end)
              emit_operation_telemetry(start_time, :zone, :list, prefix, :eventual)
              {:ok, records}

            {:error, _} = error ->
              error
          end
        end)
      end)
    end
  end

  @doc """
  List all RRsets for a specific owner name in a zone.
  """
  @spec list_records(view_name(), zone_name(), owner()) :: {:ok, [map()]} | {:error, term()}
  def list_records(view_name, zone, owner) do
    with {:ok, {view_name, zone}} <- Key.canonical_zone_scope(view_name, zone),
         {:ok, owner} <- Key.canonical_owner(owner) do
      with_zone_lock(view_name, zone, fn ->
        with_recovery(view_name, zone, fn backend ->
          prefix = Key.zone_rr_owner_prefix(view_name, zone, owner)
          start_time = System.monotonic_time()

          case backend.prefix_scan(prefix, consistency: :eventual) do
            {:ok, entries} ->
              records = Enum.map(entries, fn {_key, value} -> value end)
              emit_operation_telemetry(start_time, :zone, :list, prefix, :eventual)
              {:ok, records}

            {:error, _} = error ->
              error
          end
        end)
      end)
    end
  end

  # -------------------------------------------------------------------
  # Import / Export
  # -------------------------------------------------------------------

  @doc """
  Import pre-parsed records into an auth zone.
  """
  @spec import_zone(view_name(), zone_name(), list(map())) :: :ok | {:error, term()}
  def import_zone(view_name, name, records) when is_list(records) do
    with {:ok, {view_name, name}} <- Key.canonical_zone_scope(view_name, name),
         {:ok, records} <- canonicalize_import_records(records) do
      with_zone_lock(view_name, name, fn ->
        with_recovery(view_name, name, fn backend ->
          import_zone_locked(backend, view_name, name, records)
        end)
      end)
    end
  end

  defp import_zone_locked(backend, view_name, name, records) do
    soa =
      records
      |> Enum.find(fn r -> r[:type] == :soa end)
      |> case do
        %{rrset: [soa_data | _]} -> soa_data
        _ -> default_soa(name)
      end

    with result when result in [:ok, {:error, :already_exists}] <-
           create_zone_locked(backend, view_name, name, soa, []) do
      now = System.system_time(:second)

      Enum.each(records, fn record ->
        key = Key.zone_rr(view_name, name, record.owner, record.type)

        value = %{
          rrset: record.rrset,
          owner: record.owner,
          type: record.type,
          zone: name,
          class: :in,
          source: :import,
          updated_at: now
        }

        backend.put(key, value, consistency: :strong)
      end)

      :telemetry.execute(
        [:yellow_dog, :store, :zone, :imported],
        %{},
        %{zone: name, record_count: length(records)}
      )

      :ok
    end
  end

  @doc """
  Export all records in a zone as a list of maps.
  """
  @spec export_zone(view_name(), zone_name()) :: {:ok, [map()]} | {:error, term()}
  def export_zone(view_name, name) do
    list_records(view_name, name)
  end

  # -------------------------------------------------------------------
  # SOA serial management
  # -------------------------------------------------------------------

  @doc """
  Increment the SOA serial in the zone metadata. Uses CAS to prevent lost updates.
  """
  @spec increment_serial(view_name(), zone_name()) :: :ok | {:error, term()}
  def increment_serial(view_name, name) do
    with {:ok, {view_name, name}} <- Key.canonical_zone_scope(view_name, name) do
      with_zone_lock(view_name, name, fn ->
        with_recovery(view_name, name, fn backend ->
          do_increment_serial_locked(backend, view_name, name, @max_cas_retries)
        end)
      end)
    end
  end

  defp do_increment_serial_locked(_backend, _view_name, _name, 0),
    do: {:error, :max_retries}

  defp do_increment_serial_locked(backend, view_name, name, retries) do
    key = Key.zone(view_name, name)

    case backend.get(key, consistency: :strong) do
      {:ok, %{zone_type: :auth} = zone_meta} ->
        old_serial = zone_meta.soa.serial
        strategy = Map.get(zone_meta, :serial_strategy, :date_serial)
        new_serial = next_serial(old_serial, strategy)

        updated_soa = Map.put(zone_meta.soa, :serial, new_serial)
        now = System.system_time(:second)

        updated_meta =
          zone_meta
          |> Map.put(:soa, updated_soa)
          |> Map.put(:updated_at, now)

        case backend.put_if(key, updated_meta, condition: fn old -> old == zone_meta end) do
          :ok ->
            :telemetry.execute(
              [:yellow_dog, :store, :zone, :serial_incremented],
              %{},
              %{zone: name, old_serial: old_serial, new_serial: new_serial}
            )

            :ok

          {:error, :condition_failed} ->
            do_increment_serial_locked(backend, view_name, name, retries - 1)

          {:error, _} = error ->
            error
        end

      {:ok, _non_auth} ->
        # Non-auth zones don't have SOA serials
        :ok

      {:error, :not_found} ->
        {:error, :zone_not_found}

      {:error, _} = error ->
        error
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

  defp with_recovery(view_name, zone, fun) when is_function(fun, 1) do
    backend = Backend.active()

    with :ok <- Recovery.recover(backend, view_name, zone) do
      fun.(backend)
    end
  end

  defp recover_all_replacements(view_name \\ nil) do
    backend = Backend.active()

    case backend.prefix_scan(Key.zone_replacement_header_prefix(), consistency: :strong) do
      {:ok, entries} ->
        Enum.reduce_while(entries, :ok, fn
          {_key, %{view_name: intent_view, zone: zone}}, :ok
          when is_binary(intent_view) and is_binary(zone) ->
            if is_nil(view_name) or view_name == intent_view do
              case with_zone_lock(intent_view, zone, fn ->
                     Recovery.recover(backend, intent_view, zone)
                   end) do
                :ok -> {:cont, :ok}
                {:error, _reason} = error -> {:halt, error}
              end
            else
              {:cont, :ok}
            end

          _entry, :ok ->
            {:halt, {:error, {:recovery_failed, :invalid_header}}}
        end)

      {:error, reason} ->
        {:error, {:recovery_failed, {:header_scan_failed, reason}}}
    end
  end

  defp with_zone_lock(view_name, zone, fun) when is_function(fun, 0) do
    lock_id = {{__MODULE__, :zone, view_name, zone}, self()}

    case :global.trans(lock_id, fun) do
      :aborted -> {:error, {:lock_failed, :aborted}}
      {:aborted, reason} -> {:error, {:lock_failed, reason}}
      result -> result
    end
  end

  defp canonical_view_name(view_name) do
    case Key.canonical_zone_scope(view_name, ".") do
      {:ok, {view_name, "."}} -> {:ok, view_name}
      {:error, :invalid_scope} = error -> error
    end
  end

  defp validate_desired_records(view_name, zone, records) when is_list(records) do
    records
    |> Enum.reduce_while({:ok, {[], MapSet.new()}}, fn record, {:ok, {validated, keys}} ->
      with {:ok, record} <- canonicalize_record(record) do
        record_key = Key.zone_rr(view_name, zone, record.owner, record.type)

        if MapSet.member?(keys, record_key),
          do: {:halt, {:error, :duplicate_record}},
          else: {:cont, {:ok, {[record | validated], MapSet.put(keys, record_key)}}}
      else
        {:error, _reason} -> {:halt, {:error, :invalid_record}}
      end
    end)
    |> case do
      {:ok, {validated, _keys}} -> {:ok, Enum.reverse(validated)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_desired_records(_view_name, _zone, _records), do: {:error, :invalid_records}

  defp canonicalize_import_records(records) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, canonical} ->
      case canonicalize_record(record) do
        {:ok, record} -> {:cont, {:ok, [record | canonical]}}
        {:error, _reason} -> {:halt, {:error, :invalid_record}}
      end
    end)
    |> case do
      {:ok, canonical} -> {:ok, Enum.reverse(canonical)}
      {:error, _reason} = error -> error
    end
  end

  defp canonicalize_record(%{owner: owner, type: type, rrset: rrset} = record) do
    with {:ok, owner} <- Key.canonical_owner(owner),
         :ok <- validate_rr_type(type),
         true <- valid_rrset?(rrset) do
      {:ok, Map.put(record, :owner, owner)}
    else
      _error -> {:error, :invalid_record}
    end
  end

  defp canonicalize_record(_record), do: {:error, :invalid_record}

  defp validate_rr_type(type) do
    if Key.valid_rr_type?(type), do: :ok, else: {:error, :invalid_type}
  end

  defp valid_rrset?(rrset) when is_list(rrset) and rrset != [],
    do: Enum.all?(rrset, &is_map/1)

  defp valid_rrset?(_rrset), do: false

  defp do_replace_records(backend, view_name, zone, desired_records) do
    zone_key = Key.zone(view_name, zone)

    case backend.get(zone_key, consistency: :strong) do
      {:ok, %{zone_type: :auth, authoritative: true} = base_zone} ->
        replace_from_snapshot(backend, view_name, zone, base_zone, desired_records)

      {:ok, _zone} ->
        {:error, {:replace_failed, :not_authoritative}}

      {:error, :not_found} ->
        {:error, {:replace_failed, :zone_not_found}}

      {:error, reason} ->
        {:error, {:replace_failed, {:zone_read_failed, reason}}}
    end
  end

  defp replace_from_snapshot(backend, view_name, zone, base_zone, desired_records) do
    prefix = Key.zone_rr_prefix(view_name, zone)

    case backend.prefix_scan(prefix, consistency: :strong) do
      {:ok, entries} ->
        case validate_snapshot(entries, view_name, zone) do
          {:ok, previous_entries} ->
            previous = Enum.map(previous_entries, &elem(&1, 1))
            plan = replacement_plan(view_name, zone, desired_records, previous_entries)

            if plan.changed_count == 0 do
              {:ok, %{previous: previous, changed_count: 0}}
            else
              apply_replacement(
                backend,
                view_name,
                zone,
                base_zone,
                previous_entries,
                previous,
                plan
              )
            end

          {:error, :invalid_snapshot} ->
            {:error, {:replace_failed, :invalid_snapshot}}
        end

      {:error, reason} ->
        {:error, {:replace_failed, {:snapshot_failed, reason}}}
    end
  end

  defp validate_snapshot(entries, view_name, zone) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, valid} ->
      if valid_snapshot_entry?(entry, view_name, zone) do
        {:cont, {:ok, [entry | valid]}}
      else
        {:halt, {:error, :invalid_snapshot}}
      end
    end)
    |> case do
      {:ok, valid} -> {:ok, Enum.sort_by(valid, &elem(&1, 0))}
      {:error, :invalid_snapshot} = error -> error
    end
  end

  defp validate_snapshot(_entries, _view_name, _zone), do: {:error, :invalid_snapshot}

  defp valid_snapshot_entry?(
         {key, %{owner: owner, type: type, rrset: rrset, zone: zone, class: :in}},
         view_name,
         zone
       )
       when is_binary(key) do
    with {:ok, canonical_owner} <- Key.canonical_owner(owner),
         true <- canonical_owner == owner,
         true <- Key.valid_rr_type?(type),
         true <- valid_rrset?(rrset) do
      key == Key.zone_rr(view_name, zone, canonical_owner, type)
    else
      _error -> false
    end
  end

  defp valid_snapshot_entry?(_entry, _view_name, _zone), do: false

  defp replacement_plan(view_name, zone, desired_records, previous_entries) do
    current = Map.new(previous_entries)
    now = System.system_time(:second)

    desired =
      Map.new(desired_records, fn record ->
        key = Key.zone_rr(view_name, zone, record.owner, record.type)
        {key, record}
      end)

    puts =
      desired
      |> Enum.reject(fn {key, record} ->
        case Map.fetch(current, key) do
          {:ok, existing} -> same_rrset?(existing, zone, record)
          :error -> false
        end
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, record} -> {key, persisted_record(zone, record, now)} end)

    deletes =
      current
      |> Enum.reject(fn {key, _value} -> Map.has_key?(desired, key) end)
      |> Enum.sort_by(&elem(&1, 0))

    new_keys =
      desired
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(current, &1))
      |> Enum.sort()

    %{
      puts: puts,
      deletes: deletes,
      new_keys: new_keys,
      changed_count: length(puts) + length(deletes)
    }
  end

  defp same_rrset?(existing, zone, record) do
    existing[:owner] == record.owner and existing[:type] == record.type and
      existing[:zone] == zone and existing[:class] == :in and
      canonical_rrset(existing[:rrset]) == canonical_rrset(record.rrset)
  end

  defp canonical_rrset(rrset), do: Enum.sort(rrset)

  defp persisted_record(zone, record, now) do
    %{
      rrset: record.rrset,
      owner: record.owner,
      type: record.type,
      zone: zone,
      class: :in,
      source: :api,
      updated_at: now
    }
  end

  defp apply_replacement(
         backend,
         view_name,
         zone,
         base_zone,
         previous_entries,
         previous,
         plan
       ) do
    if function_exported?(backend, :txn, 2) do
      case Replacement.execute(backend, view_name, zone, base_zone, previous, plan) do
        {:ok, _result} = result -> result
        {:error, reason} -> {:error, {:replace_failed, reason}}
      end
    else
      apply_compensating_replacement(
        backend,
        view_name,
        zone,
        previous_entries,
        previous,
        plan
      )
    end
  end

  defp apply_compensating_replacement(
         backend,
         view_name,
         zone,
         previous_entries,
         previous,
         plan
       ) do
    start_time = System.monotonic_time()

    with :ok <- put_replacement_records(backend, plan.puts),
         :ok <- delete_stale_records(backend, plan.deletes),
         :ok <- increment_replacement_serial(backend, view_name, zone) do
      emit_replacement_changes(start_time, zone, plan.puts, plan.deletes)
      {:ok, %{previous: previous, changed_count: plan.changed_count}}
    else
      {:error, apply_reason} ->
        case compensate_replacement(backend, view_name, zone, previous_entries, plan.new_keys) do
          :ok -> {:error, {:replace_failed, apply_reason}}
          {:error, rollback_reason} -> {:error, {:rollback_failed, apply_reason, rollback_reason}}
        end
    end
  end

  defp put_replacement_records(_backend, []), do: :ok

  defp put_replacement_records(backend, operations) do
    operations
    |> Enum.chunk_every(@max_batch_size)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case put_many_exact(backend, batch) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:put_many_failed, reason}}}
      end
    end)
  end

  defp put_many_exact(backend, operations) do
    requested_keys = operations |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    case backend.put_many(operations) do
      {:ok, results} when is_map(results) ->
        result_keys = results |> Map.keys() |> MapSet.new()

        if result_keys == requested_keys and map_size(results) == length(operations) and
             Enum.all?(requested_keys, &(Map.get(results, &1) == :ok)) do
          :ok
        else
          {:error, :invalid_result}
        end

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_result}
    end
  end

  defp delete_stale_records(backend, records) do
    Enum.reduce_while(records, :ok, fn {key, _value}, :ok ->
      case backend.delete(key) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:delete_failed, key, reason}}}
        _other -> {:halt, {:error, {:delete_failed, key, :invalid_result}}}
      end
    end)
  end

  defp increment_replacement_serial(backend, view_name, zone) do
    case do_increment_serial_locked(backend, view_name, zone, @max_cas_retries) do
      :ok -> :ok
      {:error, reason} -> {:error, {:serial_failed, reason}}
    end
  end

  defp compensate_replacement(backend, view_name, zone, previous_entries, new_keys) do
    restore_error = restore_previous_records(backend, previous_entries)
    delete_error = remove_new_records(backend, new_keys)

    case backend.prefix_scan(Key.zone_rr_prefix(view_name, zone), consistency: :strong) do
      {:ok, entries} ->
        if Enum.sort_by(entries, &elem(&1, 0)) == previous_entries do
          :ok
        else
          {:error, restore_error || delete_error || :content_mismatch}
        end

      {:error, reason} ->
        {:error, restore_error || delete_error || {:verification_failed, reason}}
    end
  end

  defp restore_previous_records(_backend, []), do: nil

  defp restore_previous_records(backend, previous_entries) do
    previous_entries
    |> Enum.chunk_every(@max_batch_size)
    |> Enum.reduce(nil, fn batch, first_error ->
      case put_many_exact(backend, batch) do
        :ok -> first_error
        {:error, reason} -> first_error || {:restore_failed, reason}
      end
    end)
  end

  defp remove_new_records(backend, new_keys) do
    Enum.reduce(new_keys, nil, fn key, first_error ->
      case backend.delete(key) do
        :ok -> first_error
        {:error, reason} -> first_error || {:remove_new_failed, reason}
        _other -> first_error || {:remove_new_failed, :invalid_result}
      end
    end)
  end

  defp emit_replacement_changes(start_time, zone, puts, deletes) do
    Enum.each(puts, fn {key, value} ->
      emit_operation_telemetry(start_time, :zone, :put, key, :strong)
      emit_rr_changed(zone, value.owner, value.type, :put)
      EventBridge.notify(:put, key, value)
    end)

    Enum.each(deletes, fn {key, value} ->
      emit_operation_telemetry(start_time, :zone, :delete, key, :strong)
      emit_rr_changed(zone, value.owner, value.type, :delete)
      EventBridge.notify(:delete, key, nil)
    end)
  end

  defp next_serial(current, :date_serial) do
    {{year, month, day}, _} = :calendar.local_time()
    date_base = year * 1_000_000 + month * 10_000 + day * 100

    if current >= date_base do
      current + 1
    else
      date_base + 1
    end
  end

  defp next_serial(current, :increment), do: current + 1

  # A zone metadata key has the form dns:view:{v}:zone:{name}
  # An RR key has dns:view:{v}:zone:{name}:rr:{owner}:{type}
  # We distinguish them by checking that the key does NOT contain ":rr:"
  defp zone_metadata_key?(key) do
    String.contains?(key, ":zone:") and not String.contains?(key, ":rr:")
  end

  # Extract view_name from key: "dns:view:{view_name}:zone:{zone_name}"
  defp extract_view_name_from_key(key) do
    case String.split(key, ":") do
      ["dns", "view", view_name, "zone", _zone_name] -> view_name
      ["dns", "view", view_name | _rest] -> view_name
      _ -> "default"
    end
  end

  defp ensure_zone_id(_key, %{id: id} = zone) when is_binary(id) and id != "", do: zone

  defp ensure_zone_id(key, %{view_name: view_name, origin: origin} = zone) do
    with {:ok, {view_name, origin}} <- Key.canonical_zone_scope(view_name, origin) do
      case with_zone_lock(view_name, origin, fn -> ensure_zone_id_locked(key, zone, 3) end) do
        %{} = zone -> zone
        _error -> Map.put(zone, :id, generate_uuid())
      end
    else
      _error -> Map.put(zone, :id, generate_uuid())
    end
  end

  defp ensure_zone_id(_key, zone), do: Map.put(zone, :id, generate_uuid())

  defp ensure_zone_id_locked(_key, zone, 0), do: Map.put(zone, :id, generate_uuid())

  defp ensure_zone_id_locked(key, zone, retries) do
    id = generate_uuid()
    now = System.system_time(:second)
    original = Map.delete(zone, :view_name)

    persisted =
      original
      |> Map.put(:id, id)
      |> Map.put(:updated_at, now)

    case Backend.active().put_if(key, persisted, condition: fn old -> old == original end) do
      :ok ->
        Map.put(zone, :id, id)

      {:error, :condition_failed} ->
        reload_zone_with_view_name_locked(key, zone.view_name, retries - 1)

      {:error, _} ->
        Map.put(zone, :id, id)
    end
  end

  defp reload_zone_with_view_name_locked(key, view_name, retries) do
    case Backend.active().get(key, consistency: :strong) do
      {:ok, refreshed} ->
        refreshed = Map.put(refreshed, :view_name, view_name)

        case refreshed do
          %{id: id} when is_binary(id) and id != "" -> refreshed
          _zone -> ensure_zone_id_locked(key, refreshed, retries)
        end

      {:error, _} ->
        %{id: generate_uuid(), view_name: view_name}
    end
  end

  defp generate_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    c_versioned = (c &&& 0x0FFF) ||| 0x4000
    d_variant = (d &&& 0x3FFF) ||| 0x8000

    :io_lib.format(
      "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b",
      [a, b, c_versioned, d_variant, e]
    )
    |> to_string()
  end

  @doc "Default SOA record values for a zone."
  @spec default_soa(zone_name()) :: soa()
  def default_soa(name) do
    %{
      mname: "ns1.#{name}",
      rname: "hostmaster.#{name}",
      serial: 1,
      refresh: 3600,
      retry: 1800,
      expire: 604_800,
      minimum: 86_400
    }
  end

  defp emit_operation_telemetry(start_time, namespace, operation, key, consistency) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:yellow_dog, :store, :operation, :stop],
      %{duration: duration},
      %{
        namespace: namespace,
        operation: operation,
        key: key,
        consistency: consistency
      }
    )
  end

  defp emit_rr_changed(zone, owner, type, action) do
    :telemetry.execute(
      [:yellow_dog, :store, :zone, :rr_changed],
      %{},
      %{zone: zone, owner: owner, type: type, action: action}
    )
  end
end
