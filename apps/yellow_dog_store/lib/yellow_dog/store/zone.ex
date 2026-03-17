defmodule YellowDog.Store.Zone do
  @moduledoc """
  Authoritative DNS zone data facade over the Store backend.

  Manages zone metadata and resource record sets (RRsets). Zone creation
  uses CAS (`expected: nil`) to prevent duplicates. RRset writes use
  upsert semantics (last-writer-wins). SOA serial auto-increment uses
  CAS with bounded retries to prevent lost updates.

  Key patterns (via `YellowDog.Store.Key`):
  - Zone metadata: `dns:zone:{zone_name}`
  - Resource records: `dns:zone:{zone_name}:rr:{owner}:{type}`
  """

  alias YellowDog.Store.{Backend, EventBridge, Key}

  @type zone_name :: String.t()
  @type owner :: String.t()
  @type rr_type :: atom()
  @type soa :: %{
          mname: String.t(),
          rname: String.t(),
          serial: non_neg_integer(),
          refresh: pos_integer(),
          retry: pos_integer(),
          expire: pos_integer(),
          minimum: pos_integer()
        }

  @zone_prefix "dns:zone:"

  # -------------------------------------------------------------------
  # Zone metadata
  # -------------------------------------------------------------------

  @doc """
  Create zone metadata. Fails if the zone already exists (CAS with `expected: nil`).

  ## Options

    * `:default_ttl` - default TTL for records (default `3600`)
    * `:authoritative` - whether this node is authoritative (default `true`)
    * `:allow_dynamic_update` - accept RFC 2136 dynamic updates (default `false`)
    * `:serial_strategy` - `:date_serial` or `:increment` (default `:date_serial`)
  """
  @spec create_zone(zone_name(), soa(), keyword()) :: :ok | {:error, :already_exists | term()}
  def create_zone(name, soa, opts \\ []) do
    key = Key.zone(name)
    now = System.system_time(:second)

    value = %{
      origin: name,
      soa: soa,
      default_ttl: Keyword.get(opts, :default_ttl, 3600),
      authoritative: Keyword.get(opts, :authoritative, true),
      allow_dynamic_update: Keyword.get(opts, :allow_dynamic_update, false),
      serial_strategy: Keyword.get(opts, :serial_strategy, :date_serial),
      created_at: now,
      updated_at: now
    }

    start_time = System.monotonic_time()

    case Backend.active().put_if(key, value, expected: nil) do
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
  Delete a zone and all its resource records.
  """
  @spec delete_zone(zone_name()) :: :ok | {:error, term()}
  def delete_zone(name) do
    rr_prefix = Key.zone_rr_prefix(name)

    with {:ok, rr_entries} <- Backend.active().prefix_scan(rr_prefix, consistency: :strong) do
      Enum.each(rr_entries, fn {rr_key, _value} ->
        Backend.active().delete(rr_key)
      end)

      zone_key = Key.zone(name)
      start_time = System.monotonic_time()

      case Backend.active().delete(zone_key) do
        :ok ->
          emit_operation_telemetry(start_time, :zone, :delete, zone_key, :strong)
          EventBridge.notify(:delete, zone_key, nil)
          :ok

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  Get zone metadata. Uses `:eventual` consistency.
  """
  @spec get_zone(zone_name()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_zone(name) do
    key = Key.zone(name)
    start_time = System.monotonic_time()
    result = Backend.active().get(key, consistency: :eventual)
    emit_operation_telemetry(start_time, :zone, :get, key, :eventual)
    result
  end

  @doc """
  List all zone names. Scans the `dns:zone:` prefix and filters to
  metadata-only keys (excludes RR sub-keys).
  """
  @spec list_zones() :: {:ok, [zone_name()]} | {:error, term()}
  def list_zones do
    start_time = System.monotonic_time()

    case Backend.active().prefix_scan(@zone_prefix, consistency: :eventual) do
      {:ok, entries} ->
        names =
          entries
          |> Enum.map(fn {key, _value} -> key end)
          |> Enum.filter(&zone_metadata_key?/1)
          |> Enum.map(&extract_zone_name/1)

        emit_operation_telemetry(start_time, :zone, :list, @zone_prefix, :eventual)
        {:ok, names}

      {:error, _} = error ->
        error
    end
  end

  # -------------------------------------------------------------------
  # Resource records
  # -------------------------------------------------------------------

  @doc """
  Create or update an RRset. Uses CAS to prevent concurrent edit races.
  Auto-increments the SOA serial on success.

  `rrset` is a list of record maps, each containing at least `:rdata` and
  optionally `:ttl`.
  """
  @spec put_rrset(zone_name(), owner(), rr_type(), list(map())) ::
          :ok | {:error, term()}
  def put_rrset(zone, owner, type, rrset) do
    key = Key.zone_rr(zone, owner, type)
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

    # Upsert: create or overwrite. SOA serial increment provides
    # zone-level change detection for downstream consumers.
    result = Backend.active().put(key, value)

    case result do
      :ok ->
        emit_operation_telemetry(start_time, :zone, :put, key, :strong)
        emit_rr_changed(zone, owner, type, :put)
        EventBridge.notify(:put, key, value)
        increment_serial(zone)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Lookup a specific RRset. Uses `:eventual` consistency.
  """
  @spec get_rrset(zone_name(), owner(), rr_type()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def get_rrset(zone, owner, type) do
    key = Key.zone_rr(zone, owner, type)
    start_time = System.monotonic_time()
    result = Backend.active().get(key, consistency: :eventual)
    emit_operation_telemetry(start_time, :zone, :get, key, :eventual)
    result
  end

  @doc """
  Remove an RRset. Auto-increments the SOA serial on success.
  """
  @spec delete_rrset(zone_name(), owner(), rr_type()) :: :ok | {:error, term()}
  def delete_rrset(zone, owner, type) do
    key = Key.zone_rr(zone, owner, type)
    start_time = System.monotonic_time()

    case Backend.active().delete(key) do
      :ok ->
        emit_operation_telemetry(start_time, :zone, :delete, key, :strong)
        emit_rr_changed(zone, owner, type, :delete)
        EventBridge.notify(:delete, key, nil)
        increment_serial(zone)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  List all RRsets in a zone via prefix scan.
  """
  @spec list_records(zone_name()) :: {:ok, [map()]} | {:error, term()}
  def list_records(zone) do
    prefix = Key.zone_rr_prefix(zone)
    start_time = System.monotonic_time()

    case Backend.active().prefix_scan(prefix, consistency: :eventual) do
      {:ok, entries} ->
        records = Enum.map(entries, fn {_key, value} -> value end)
        emit_operation_telemetry(start_time, :zone, :list, prefix, :eventual)
        {:ok, records}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  List all RRsets for a specific owner name in a zone.
  """
  @spec list_records(zone_name(), owner()) :: {:ok, [map()]} | {:error, term()}
  def list_records(zone, owner) do
    case list_records(zone) do
      {:ok, records} ->
        filtered = Enum.filter(records, fn r -> r.owner == owner end)
        {:ok, filtered}

      {:error, _} = error ->
        error
    end
  end

  # -------------------------------------------------------------------
  # Import / Export
  # -------------------------------------------------------------------

  @doc """
  Import pre-parsed records into a zone. Creates the zone metadata and
  writes each record as an RRset key.

  `records` is a list of maps, each with `:owner`, `:type`, and `:rrset` keys.
  Full zone file parsing is out of scope for this facade.
  """
  @spec import(zone_name(), list(map())) :: :ok | {:error, term()}
  def import(name, records) when is_list(records) do
    soa =
      records
      |> Enum.find(fn r -> r[:type] == :soa end)
      |> case do
        %{rrset: [soa_data | _]} -> soa_data
        _ -> default_soa(name)
      end

    case create_zone(name, soa) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
      {:error, _} = error -> throw(error)
    end

    now = System.system_time(:second)

    Enum.each(records, fn record ->
      key = Key.zone_rr(name, record.owner, record.type)

      value = %{
        rrset: record.rrset,
        owner: record.owner,
        type: record.type,
        zone: name,
        class: :in,
        source: :import,
        updated_at: now
      }

      Backend.active().put(key, value, consistency: :strong)
    end)

    :telemetry.execute(
      [:yellow_dog, :store, :zone, :imported],
      %{},
      %{zone: name, record_count: length(records)}
    )

    :ok
  catch
    {:error, _} = error -> error
  end

  @doc """
  Export all records in a zone as a list of maps. Formatting into zone
  file text is the caller's responsibility.
  """
  @spec export(zone_name()) :: {:ok, [map()]} | {:error, term()}
  def export(name) do
    list_records(name)
  end

  # -------------------------------------------------------------------
  # SOA serial management
  # -------------------------------------------------------------------

  @doc """
  Increment the SOA serial in the zone metadata. Uses date-based serial
  (YYYYMMDDNN) when the strategy is `:date_serial`, otherwise simple
  increment.

  Uses CAS to prevent lost updates.
  """
  @max_cas_retries 10

  @spec increment_serial(zone_name()) :: :ok | {:error, term()}
  def increment_serial(name), do: increment_serial(name, @max_cas_retries)

  defp increment_serial(_name, 0), do: {:error, :max_retries}

  defp increment_serial(name, retries) do
    key = Key.zone(name)

    case Backend.active().get(key, consistency: :strong) do
      {:ok, zone_meta} ->
        old_serial = zone_meta.soa.serial
        strategy = Map.get(zone_meta, :serial_strategy, :date_serial)
        new_serial = next_serial(old_serial, strategy)

        updated_soa = Map.put(zone_meta.soa, :serial, new_serial)
        now = System.system_time(:second)

        updated_meta =
          zone_meta
          |> Map.put(:soa, updated_soa)
          |> Map.put(:updated_at, now)

        case Backend.active().put_if(key, updated_meta, condition: fn old -> old == zone_meta end) do
          :ok ->
            :telemetry.execute(
              [:yellow_dog, :store, :zone, :serial_incremented],
              %{},
              %{zone: name, old_serial: old_serial, new_serial: new_serial}
            )

            :ok

          {:error, :condition_failed} ->
            increment_serial(name, retries - 1)

          {:error, _} = error ->
            error
        end

      {:error, :not_found} ->
        {:error, :zone_not_found}

      {:error, _} = error ->
        error
    end
  end

  # -------------------------------------------------------------------
  # Private helpers
  # -------------------------------------------------------------------

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

  defp zone_metadata_key?(key) do
    suffix = String.replace_prefix(key, @zone_prefix, "")
    not String.contains?(suffix, ":")
  end

  defp extract_zone_name(key) do
    String.replace_prefix(key, @zone_prefix, "")
  end

  defp default_soa(name) do
    %{
      mname: "ns1.#{name}",
      rname: "admin.#{name}",
      serial: 1,
      refresh: 3600,
      retry: 900,
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
