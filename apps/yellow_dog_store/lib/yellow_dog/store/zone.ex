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

  alias YellowDog.Store.{Backend, EventBridge, Key}

  @type view_name :: String.t()
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
  """
  @spec create_zone(view_name(), zone_name(), soa(), keyword()) ::
          :ok | {:error, :already_exists | term()}
  def create_zone(view_name, name, soa, opts \\ []) do
    key = Key.zone(view_name, name)
    now = System.system_time(:second)

    value = %{
      zone_type: :auth,
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
    key = Key.zone(view_name, name)
    now = System.system_time(:second)

    value = %{
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
    key = Key.zone(view_name, name)
    now = System.system_time(:second)

    value = %{
      zone_type: :stub,
      origin: name,
      primaries: primaries,
      refresh_interval: Keyword.get(opts, :refresh_interval, 3600),
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
    zone_key = Key.zone(view_name, name)
    start_time = System.monotonic_time()

    case Backend.active().delete(zone_key) do
      :ok ->
        emit_operation_telemetry(start_time, :zone, :delete, zone_key, :strong)
        EventBridge.notify(:delete, zone_key, nil)

        # Best-effort cleanup of RR entries for auth zones
        rr_prefix = Key.zone_rr_prefix(view_name, name)

        case Backend.active().prefix_scan(rr_prefix, consistency: :strong) do
          {:ok, rr_entries} ->
            failed =
              Enum.count(rr_entries, fn {rr_key, _value} ->
                Backend.active().delete(rr_key) != :ok
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
    key = Key.zone(view_name, name)
    start_time = System.monotonic_time()
    result = Backend.active().get(key, consistency: :eventual)
    emit_operation_telemetry(start_time, :zone, :get, key, :eventual)
    result
  end

  @doc """
  Update zone metadata (any zone type). Merges `attrs` into existing metadata.
  Uses CAS to prevent lost updates.
  """
  @max_update_retries 5

  @spec update_zone(view_name(), zone_name(), map()) :: :ok | {:error, term()}
  def update_zone(view_name, name, attrs),
    do: do_update_zone(view_name, name, attrs, @max_update_retries)

  defp do_update_zone(_view_name, _name, _attrs, 0), do: {:error, :conflict}

  defp do_update_zone(view_name, name, attrs, retries) do
    key = Key.zone(view_name, name)

    case Backend.active().get(key, consistency: :strong) do
      {:ok, zone_meta} ->
        now = System.system_time(:second)

        updated_meta =
          zone_meta
          |> Map.merge(attrs)
          |> Map.put(:updated_at, now)

        case Backend.active().put_if(key, updated_meta, condition: fn old -> old == zone_meta end) do
          :ok ->
            EventBridge.notify(:put, key, updated_meta)
            :ok

          {:error, :condition_failed} ->
            do_update_zone(view_name, name, attrs, retries - 1)

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

    case Backend.active().prefix_scan(prefix, consistency: :eventual) do
      {:ok, entries} ->
        zones =
          entries
          |> Enum.filter(fn {key, _value} -> zone_metadata_key?(key) end)
          |> Enum.map(fn {key, value} ->
            # Inject view_name from key: dns:view:{view_name}:zone:{zone_name}
            view_name = extract_view_name_from_key(key)
            Map.put(value, :view_name, view_name)
          end)

        emit_operation_telemetry(start_time, :zone, :list, prefix, :eventual)
        {:ok, zones}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  List all zones in a specific view.
  """
  @spec list_zones_for_view(view_name()) :: {:ok, [map()]} | {:error, term()}
  def list_zones_for_view(view_name) do
    prefix = Key.zone_prefix(view_name)
    start_time = System.monotonic_time()

    case Backend.active().prefix_scan(prefix, consistency: :eventual) do
      {:ok, entries} ->
        zones =
          entries
          |> Enum.filter(fn {key, _value} -> zone_metadata_key?(key) end)
          |> Enum.map(fn {_key, value} -> Map.put(value, :view_name, view_name) end)

        emit_operation_telemetry(start_time, :zone, :list, prefix, :eventual)
        {:ok, zones}

      {:error, _} = error ->
        error
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

    result = Backend.active().put(key, value)

    case result do
      :ok ->
        emit_operation_telemetry(start_time, :zone, :put, key, :strong)
        emit_rr_changed(zone, owner, type, :put)
        EventBridge.notify(:put, key, value)
        increment_serial(view_name, zone)
        :ok

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Lookup a specific RRset. Uses `:eventual` consistency.
  """
  @spec get_rrset(view_name(), zone_name(), owner(), rr_type()) ::
          {:ok, map()} | {:error, :not_found | term()}
  def get_rrset(view_name, zone, owner, type) do
    key = Key.zone_rr(view_name, zone, owner, type)
    start_time = System.monotonic_time()
    result = Backend.active().get(key, consistency: :eventual)
    emit_operation_telemetry(start_time, :zone, :get, key, :eventual)
    result
  end

  @doc """
  Remove an RRset. Auto-increments the SOA serial on success.
  """
  @spec delete_rrset(view_name(), zone_name(), owner(), rr_type()) :: :ok | {:error, term()}
  def delete_rrset(view_name, zone, owner, type) do
    key = Key.zone_rr(view_name, zone, owner, type)
    start_time = System.monotonic_time()

    case Backend.active().delete(key) do
      :ok ->
        emit_operation_telemetry(start_time, :zone, :delete, key, :strong)
        emit_rr_changed(zone, owner, type, :delete)
        EventBridge.notify(:delete, key, nil)
        increment_serial(view_name, zone)
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
    prefix = Key.zone_rr_prefix(view_name, zone)
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
  @spec list_records(view_name(), zone_name(), owner()) :: {:ok, [map()]} | {:error, term()}
  def list_records(view_name, zone, owner) do
    prefix = Key.zone_rr_owner_prefix(view_name, zone, owner)
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

  # -------------------------------------------------------------------
  # Import / Export
  # -------------------------------------------------------------------

  @doc """
  Import pre-parsed records into an auth zone.
  """
  @spec import_zone(view_name(), zone_name(), list(map())) :: :ok | {:error, term()}
  def import_zone(view_name, name, records) when is_list(records) do
    soa =
      records
      |> Enum.find(fn r -> r[:type] == :soa end)
      |> case do
        %{rrset: [soa_data | _]} -> soa_data
        _ -> default_soa(name)
      end

    with result when result in [:ok, {:error, :already_exists}] <-
           create_zone(view_name, name, soa) do
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

        Backend.active().put(key, value, consistency: :strong)
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

  @max_cas_retries 10

  @doc """
  Increment the SOA serial in the zone metadata. Uses CAS to prevent lost updates.
  """
  @spec increment_serial(view_name(), zone_name()) :: :ok | {:error, term()}
  def increment_serial(view_name, name),
    do: do_increment_serial(view_name, name, @max_cas_retries)

  defp do_increment_serial(_view_name, _name, 0), do: {:error, :max_retries}

  defp do_increment_serial(view_name, name, retries) do
    key = Key.zone(view_name, name)

    case Backend.active().get(key, consistency: :strong) do
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

        case Backend.active().put_if(key, updated_meta, condition: fn old -> old == zone_meta end) do
          :ok ->
            :telemetry.execute(
              [:yellow_dog, :store, :zone, :serial_incremented],
              %{},
              %{zone: name, old_serial: old_serial, new_serial: new_serial}
            )

            :ok

          {:error, :condition_failed} ->
            do_increment_serial(view_name, name, retries - 1)

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

  @doc "Default SOA record values for a zone."
  @spec default_soa(zone_name()) :: soa()
  def default_soa(name) do
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
