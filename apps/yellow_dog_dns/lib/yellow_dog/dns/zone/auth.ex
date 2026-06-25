defmodule YellowDog.Dns.Zone.Auth do
  @moduledoc """
  Authoritative zone process.

  Handles DNS queries for zones where this server is authoritative.
  Zone data is stored in an ETS table for fast lookup.

  ## Features

  - AXFR/IXFR support (zone transfers)
  - Dynamic updates (RFC 2136)
  - SOA serial tracking
  - Negative caching (NXDOMAIN/NODATA)
  """

  use GenServer

  alias YellowDog.Dns.IpFormat
  alias YellowDog.Dns.Zone.Behaviour

  @behaviour Behaviour

  # RFC 1034 §3.6.2: limit CNAME chain depth to prevent infinite loops.
  @max_cname_depth 10

  alias YellowDog.Telemetry
  alias DNS.Message
  alias DNS.Message.RCode
  alias DNS.ResourceRecord
  alias DNS.Zone

  defstruct [
    :name,
    :view_name,
    :table,
    :soa,
    :ns_records,
    :created_at,
    :zone_file,
    :zone_data_path,
    :ttl,
    query_count: 0,
    hit_count: 0,
    miss_count: 0,
    dirty: false,
    # Version for optimistic locking - increments on each modification
    version: 1,
    # Timestamp of last modification
    updated_at: nil
  ]

  # Client API

  @doc """
  Starts an authoritative zone process.

  ## Options

  - `:name` - Zone name (required)
  - `:zone_data` - Initial zone data (list of resource records)
  - `:zone_file` - Path to zone file to load
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    zone_name = Keyword.fetch!(opts, :name)
    view_name = Keyword.get(opts, :view_name, "default")

    GenServer.start_link(__MODULE__, opts,
      name: Behaviour.zone_via_tuple(view_name, :auth, zone_name)
    )
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def get_name(pid) do
    GenServer.call(pid, :get_name)
  end

  @doc """
  Gets the view name this zone belongs to.
  """
  @spec get_view(pid()) :: String.t()
  def get_view(pid) do
    GenServer.call(pid, :get_view)
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def resolve(pid, query) do
    GenServer.call(pid, {:resolve, query})
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def reload(pid, config) do
    GenServer.call(pid, {:reload, config})
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def update_config(pid, config) do
    GenServer.call(pid, {:update_config, config})
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  @doc """
  Adds a resource record to the zone.
  """
  @spec add_record(pid(), ResourceRecord.t()) :: :ok
  def add_record(pid, record) do
    GenServer.call(pid, {:add_record, record})
  end

  @doc """
  Removes a resource record from the zone.
  """
  @spec remove_record(pid(), String.t(), atom()) :: :ok
  def remove_record(pid, name, type) do
    GenServer.call(pid, {:remove_record, name, type})
  end

  @doc """
  Gets all records for a name and type.
  """
  @spec get_records(pid(), String.t(), atom()) :: [ResourceRecord.t()]
  def get_records(pid, name, type) do
    GenServer.call(pid, {:get_records, name, type})
  end

  @doc """
  Imports records from a BIND-format zone file string into the zone.

  Parses the given BIND-format string and adds all records to the zone.
  Existing records are preserved; duplicate records may be added.

  Returns `{:ok, stats}` with import statistics on success,
  or `{:error, reason}` on parse failure.

  ## Examples

      Zone.Auth.import_zone_file(pid, \"\"\"
      $TTL 3600
      @   IN  SOA  ns1.example.com. admin.example.com. (
                   2024011501 ; serial
                   3600       ; refresh
                   600        ; retry
                   604800     ; expire
                   86400      ; minimum
               )
          IN  NS   ns1.example.com.
      www IN  A    192.168.1.100
      \"\"\")
  """
  @spec import_zone_file(pid(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def import_zone_file(pid, bind_format_string) do
    GenServer.call(pid, {:import_zone_file, bind_format_string})
  end

  @doc """
  Exports the zone to BIND format string.

  Returns `{:ok, bind_string}` with RFC 1035 compliant zone file content.

  ## Examples

      {:ok, content} = Zone.Auth.export_zone_file(pid)
      File.write!("example.com.zone", content)
  """
  @spec export_zone_file(pid()) :: {:ok, String.t()}
  def export_zone_file(pid) do
    GenServer.call(pid, :export_zone_file)
  end

  @doc """
  Saves the zone data to its zone file.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec save(pid()) :: :ok | {:error, String.t()}
  def save(pid) do
    GenServer.call(pid, :save)
  end

  @doc """
  Gets all records in the zone.
  """
  @spec get_all_records(pid()) :: [ResourceRecord.t()]
  def get_all_records(pid) do
    GenServer.call(pid, :get_all_records)
  end

  @doc """
  Checks if the zone has unsaved changes.
  """
  @spec dirty?(pid()) :: boolean()
  def dirty?(pid) do
    GenServer.call(pid, :dirty?)
  end

  @doc """
  Gets the current version of the zone.

  The version is an integer that increments on each modification.
  Use this for optimistic locking to detect concurrent changes.
  """
  @spec get_version(pid()) :: pos_integer()
  def get_version(pid) do
    GenServer.call(pid, :get_version)
  end

  @doc """
  Gets metadata about the zone including version info.

  Returns a map with:
  - `:version` - Current version number
  - `:updated_at` - DateTime of last modification (nil if never modified)
  - `:created_at` - DateTime when zone was created
  - `:dirty` - Whether zone has unsaved changes
  """
  @spec get_metadata(pid()) :: map()
  def get_metadata(pid) do
    GenServer.call(pid, :get_metadata)
  end

  @doc """
  Adds a record with version check for optimistic locking.

  Returns `{:ok, new_version}` on success, or `{:error, :version_conflict}`
  if the zone was modified since `expected_version`.
  """
  @spec add_record_versioned(pid(), ResourceRecord.t(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, :version_conflict}
  def add_record_versioned(pid, record, expected_version) do
    GenServer.call(pid, {:add_record_versioned, record, expected_version})
  end

  @doc """
  Removes a record with version check for optimistic locking.

  Returns `{:ok, new_version}` on success, or `{:error, :version_conflict}`
  if the zone was modified since `expected_version`.
  """
  @spec remove_record_versioned(pid(), String.t(), atom(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, :version_conflict}
  def remove_record_versioned(pid, name, type, expected_version) do
    GenServer.call(pid, {:remove_record_versioned, name, type, expected_version})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    zone_name = Keyword.fetch!(opts, :name)
    view_name = Keyword.get(opts, :view_name, "default")
    zone_data_path = Keyword.get(opts, :zone_data_path)
    zone_file = Keyword.get(opts, :zone_file)

    # Create ETS table for zone data
    table =
      :ets.new(:"zone_#{view_name}_#{zone_name}", [
        :bag,
        :protected,
        read_concurrency: true
      ])

    state = %__MODULE__{
      name: zone_name,
      view_name: view_name,
      table: table,
      zone_file: zone_file,
      zone_data_path: zone_data_path,
      ttl: Keyword.get(opts, :ttl, 3600),
      created_at: DateTime.utc_now(),
      dirty: false
    }

    # Load initial zone data.
    # Priority: explicit zone_data opts > zone_file > Store persistence > empty
    state =
      cond do
        zone_data = Keyword.get(opts, :zone_data) ->
          load_zone_data(state, zone_data)

        zone_file != nil ->
          load_zone_file(state, zone_file)

        true ->
          load_from_store(state)
      end

    Telemetry.info("Auth zone started", %{name: zone_name, zone_file: zone_file})

    {:ok, state}
  end

  @impl true
  def handle_call(:get_name, _from, state) do
    {:reply, state.name, state}
  end

  @impl true
  def handle_call(:get_view, _from, state) do
    {:reply, state.view_name, state}
  end

  @impl true
  def handle_call({:resolve, query}, _from, state) do
    state = %{state | query_count: state.query_count + 1}

    case do_resolve(state, query) do
      {:ok, response} ->
        state = %{state | hit_count: state.hit_count + 1}
        {:reply, {:ok, response}, state}

      {:error, _} = error ->
        state = %{state | miss_count: state.miss_count + 1}
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:reload, config}, _from, state) do
    # Clear existing data
    :ets.delete_all_objects(state.table)

    # Reload zone data: explicit opts > zone_file > Store > empty
    new_state =
      cond do
        zone_data = Keyword.get(config, :zone_data) ->
          load_zone_data(state, zone_data)

        zone_file = Keyword.get(config, :zone_file) ->
          load_zone_file(state, zone_file)

        true ->
          load_from_store(state)
      end

    Telemetry.info("Auth zone reloaded", %{name: state.name})

    {:reply, :ok, %{new_state | dirty: false}}
  end

  @impl true
  def handle_call({:update_config, config}, _from, state) do
    ttl = Map.get(config, :ttl, state.ttl)
    new_state = %{state | ttl: ttl}

    # Async-sync metadata to Store
    Task.start(fn ->
      try do
        attrs = %{default_ttl: new_state.ttl}
        YellowDog.Store.Zone.update_zone(new_state.view_name, new_state.name, attrs)
      rescue
        _ -> :ok
      end
    end)

    Telemetry.info("Auth zone config updated", %{name: state.name})

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      name: state.name,
      record_count: :ets.info(state.table, :size),
      query_count: state.query_count,
      hit_count: state.hit_count,
      miss_count: state.miss_count,
      created_at: state.created_at,
      version: state.version,
      updated_at: state.updated_at
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:add_record, record}, _from, state) do
    key = {normalize_name(record.name), normalize_type(record.type)}
    :ets.insert(state.table, {key, record})

    new_state = %{
      state
      | dirty: true,
        version: state.version + 1,
        updated_at: DateTime.utc_now()
    }

    # Async-sync the changed RRset to Store for persistence
    async_sync_rrset_to_store(new_state, record.name, record.type)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:remove_record, name, type}, _from, state) do
    :ets.delete(state.table, {normalize_name(name), normalize_type(type)})

    # Async-sync deletion to Store
    async_delete_rrset_from_store(state, name, type)

    new_state = %{
      state
      | dirty: true,
        version: state.version + 1,
        updated_at: DateTime.utc_now()
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:get_records, name, type}, _from, state) do
    records = lookup_records(state.table, name, type)
    {:reply, records, state}
  end

  @impl true
  def handle_call(:get_all_records, _from, state) do
    records = for {_key, record} <- :ets.tab2list(state.table), do: record

    {:reply, records, state}
  end

  @impl true
  def handle_call(:dirty?, _from, state) do
    {:reply, state.dirty, state}
  end

  @impl true
  def handle_call(:get_version, _from, state) do
    {:reply, state.version, state}
  end

  @impl true
  def handle_call(:get_metadata, _from, state) do
    metadata = %{
      version: state.version,
      updated_at: state.updated_at,
      created_at: state.created_at,
      dirty: state.dirty
    }

    {:reply, metadata, state}
  end

  @impl true
  def handle_call({:add_record_versioned, record, expected_version}, _from, state) do
    if state.version == expected_version do
      key = {normalize_name(record.name), normalize_type(record.type)}
      :ets.insert(state.table, {key, record})
      new_version = state.version + 1

      new_state = %{
        state
        | dirty: true,
          version: new_version,
          updated_at: DateTime.utc_now()
      }

      async_sync_rrset_to_store(new_state, record.name, record.type)

      {:reply, {:ok, new_version}, new_state}
    else
      {:reply, {:error, :version_conflict}, state}
    end
  end

  @impl true
  def handle_call({:remove_record_versioned, name, type, expected_version}, _from, state) do
    if state.version == expected_version do
      :ets.delete(state.table, {normalize_name(name), normalize_type(type)})
      new_version = state.version + 1

      new_state = %{
        state
        | dirty: true,
          version: new_version,
          updated_at: DateTime.utc_now()
      }

      async_delete_rrset_from_store(new_state, name, type)

      {:reply, {:ok, new_version}, new_state}
    else
      {:reply, {:error, :version_conflict}, state}
    end
  end

  @impl true
  def handle_call(:save, _from, state) do
    case do_save(state) do
      :ok ->
        {:reply, :ok, %{state | dirty: false}}

      {:error, "No zone file path configured"} = error ->
        # Expected when no file path is set - use debug level (common in tests)
        Telemetry.debug("Zone save skipped (no file path configured)", %{
          zone: state.name
        })

        {:reply, error, state}

      {:error, reason} = error ->
        Telemetry.error("Failed to save zone", %{
          zone: state.name,
          reason: reason
        })

        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:import_zone_file, bind_string}, _from, state) do
    case DNS.Zone.parse_zone_string(bind_string) do
      {:ok, zone} ->
        records = rrsets_to_records(zone)
        count = length(records)

        insert_records(state.table, records)

        new_state = %{
          state
          | dirty: true,
            version: state.version + 1,
            updated_at: DateTime.utc_now()
        }

        # Sync imported RRsets to Store in a single background task
        # (batched to avoid spawning thousands of tasks for large zone files)
        rrset_pairs =
          records
          |> Enum.map(fn r -> {normalize_name(r.name), normalize_type(r.type)} end)
          |> Enum.uniq()

        view_name = new_state.view_name
        zone_name = new_state.name
        table = new_state.table

        Task.start(fn ->
          try do
            Enum.each(rrset_pairs, fn {name, type} ->
              recs = lookup_records(table, name, type)
              rrset_data = Enum.map(recs, &record_to_store_rdata/1)
              YellowDog.Store.Zone.put_rrset(view_name, zone_name, name, type, rrset_data)
            end)
          rescue
            _ -> :ok
          end
        end)

        stats = %{records_imported: count, zone_origin: zone.origin}

        Telemetry.info("Zone file imported", %{
          zone: state.name,
          records_imported: count
        })

        {:reply, {:ok, stats}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:export_zone_file, _from, state) do
    records = get_all_records_from_table(state.table)
    zone = build_zone_struct(state, records)
    content = DNS.Zone.to_bind_format(zone)
    {:reply, {:ok, content}, state}
  end

  @impl true
  def terminate(reason, state) do
    # Flush dirty records to Store for persistence across restarts
    if state.dirty do
      flush_to_store(state)

      # Also save to zone file if configured
      if state.zone_file != nil || state.zone_data_path != nil do
        case do_save(state) do
          :ok ->
            Telemetry.info("Auth zone saved on shutdown", %{name: state.name})

          {:error, save_reason} ->
            Telemetry.error("Failed to save zone on shutdown", %{
              zone: state.name,
              reason: save_reason
            })
        end
      end
    end

    # Clean up ETS table
    :ets.delete(state.table)

    Telemetry.info("Auth zone stopped", %{name: state.name, reason: inspect(reason)})
    :ok
  end

  # Private Functions

  # Load records from Store into ETS on startup.
  # Returns updated state with records loaded, or unchanged state if Store has nothing.
  defp load_from_store(state) do
    try do
      case YellowDog.Store.Zone.get_zone(state.view_name, state.name) do
        {:ok, metadata} when is_map(metadata) ->
          # Load zone metadata (SOA)
          soa_record = build_soa_record_from_metadata(metadata, state.name, state.ttl)

          # Load all RRsets from Store
          case YellowDog.Store.Zone.list_records(state.view_name, state.name) do
            {:ok, rrsets} when is_list(rrsets) ->
              records = store_rrsets_to_records(rrsets, state.name)
              all_records = if soa_record, do: [soa_record | records], else: records
              load_zone_data(state, all_records)

            _ ->
              if soa_record, do: load_zone_data(state, [soa_record]), else: state
          end

        _ ->
          state
      end
    rescue
      _ -> state
    end
  end

  # Convert Store metadata SOA fields to a DNS.Message.Record
  defp build_soa_record_from_metadata(%{soa: soa} = _metadata, zone_name, default_ttl)
       when is_map(soa) do
    mname = Map.get(soa, :mname, "ns1.#{zone_name}")
    rname = Map.get(soa, :rname, "hostmaster.#{zone_name}")
    serial = Map.get(soa, :serial, 1)
    refresh = Map.get(soa, :refresh, 3600)
    retry = Map.get(soa, :retry, 1800)
    expire = Map.get(soa, :expire, 604_800)
    minimum = Map.get(soa, :minimum, 86_400)
    ttl = minimum || default_ttl

    Message.Record.new(
      zone_name,
      :soa,
      :in,
      ttl,
      {mname, rname, serial, refresh, retry, expire, minimum}
    )
  end

  defp build_soa_record_from_metadata(_metadata, _zone_name, _default_ttl), do: nil

  # Convert Store RRset maps back to DNS.Message.Record structs
  defp store_rrsets_to_records(rrsets, zone_name) do
    Enum.flat_map(rrsets, fn rrset ->
      owner = Map.get(rrset, :owner, zone_name)
      type = Map.get(rrset, :type, :unknown)
      records_data = Map.get(rrset, :rrset, [])

      Enum.flat_map(records_data, fn rdata ->
        case build_record_from_store(type, owner, rdata) do
          nil -> []
          record -> [record]
        end
      end)
    end)
  end

  defp build_record_from_store(:a, owner, rdata) do
    case IpFormat.parse_v4(rdata[:address] || Map.get(rdata, "address")) do
      nil -> nil
      ip -> Message.Record.new(owner, :a, :in, Map.get(rdata, :ttl, 3600), ip)
    end
  end

  defp build_record_from_store(:aaaa, owner, rdata) do
    case IpFormat.parse_v6(rdata[:address] || Map.get(rdata, "address")) do
      nil -> nil
      ip -> Message.Record.new(owner, :aaaa, :in, Map.get(rdata, :ttl, 3600), ip)
    end
  end

  defp build_record_from_store(:ns, owner, rdata) do
    nsdname = rdata[:nsdname] || Map.get(rdata, "nsdname")

    if nsdname,
      do: Message.Record.new(owner, :ns, :in, Map.get(rdata, :ttl, 3600), to_string(nsdname))
  end

  defp build_record_from_store(:cname, owner, rdata) do
    cname = rdata[:cname] || Map.get(rdata, "cname")

    if cname,
      do: Message.Record.new(owner, :cname, :in, Map.get(rdata, :ttl, 3600), to_string(cname))
  end

  defp build_record_from_store(:mx, owner, rdata) do
    preference = rdata[:preference] || Map.get(rdata, "preference", 10)
    exchange = rdata[:exchange] || Map.get(rdata, "exchange")

    if exchange,
      do:
        Message.Record.new(
          owner,
          :mx,
          :in,
          Map.get(rdata, :ttl, 3600),
          {preference, to_string(exchange)}
        )
  end

  defp build_record_from_store(:txt, owner, rdata) do
    txtdata = rdata[:txtdata] || Map.get(rdata, "txtdata")

    txt_list =
      cond do
        is_list(txtdata) -> txtdata
        is_binary(txtdata) -> [txtdata]
        true -> nil
      end

    if txt_list, do: Message.Record.new(owner, :txt, :in, Map.get(rdata, :ttl, 3600), txt_list)
  end

  defp build_record_from_store(:srv, owner, rdata) do
    priority = rdata[:priority] || Map.get(rdata, "priority", 0)
    weight = rdata[:weight] || Map.get(rdata, "weight", 0)
    port = rdata[:port] || Map.get(rdata, "port", 0)
    target = rdata[:target] || Map.get(rdata, "target")

    if target,
      do:
        Message.Record.new(
          owner,
          :srv,
          :in,
          Map.get(rdata, :ttl, 3600),
          {priority, weight, port, to_string(target)}
        )
  end

  defp build_record_from_store(:ptr, owner, rdata) do
    ptrdname = rdata[:ptrdname] || Map.get(rdata, "ptrdname")

    if ptrdname,
      do: Message.Record.new(owner, :ptr, :in, Map.get(rdata, :ttl, 3600), to_string(ptrdname))
  end

  defp build_record_from_store(:caa, owner, rdata) do
    flags = rdata[:flags] || Map.get(rdata, "flags", 0)
    tag = rdata[:tag] || Map.get(rdata, "tag")
    value = rdata[:value] || Map.get(rdata, "value")

    if tag && value,
      do: Message.Record.new(owner, :caa, :in, Map.get(rdata, :ttl, 3600), {flags, tag, value})
  end

  defp build_record_from_store(_type, _owner, _rdata), do: nil

  # Async-sync a single RRset to Store after mutation.
  # Store.Zone.put_rrset wraps the 5th arg in its own metadata map,
  # so we only pass the list of rdata maps.
  defp async_sync_rrset_to_store(state, name, type) do
    records = lookup_records(state.table, name, type)
    view_name = state.view_name
    zone_name = state.name

    Task.start(fn ->
      try do
        rrset_data = Enum.map(records, &record_to_store_rdata/1)

        YellowDog.Store.Zone.put_rrset(
          view_name,
          zone_name,
          normalize_name(name),
          normalize_type(type),
          rrset_data
        )
      rescue
        _ -> :ok
      end
    end)
  end

  # Async-sync deletion of an RRset to Store
  defp async_delete_rrset_from_store(state, name, type) do
    view_name = state.view_name
    zone_name = state.name

    Task.start(fn ->
      try do
        YellowDog.Store.Zone.delete_rrset(
          view_name,
          zone_name,
          normalize_name(name),
          normalize_type(type)
        )
      rescue
        _ -> :ok
      end
    end)
  end

  # Convert a DNS.Message.Record to Store rdata map
  defp record_to_store_rdata(record) do
    type = normalize_type(record.type)
    data = record_data(record)
    rdata = rdata_to_bind_map(type, data)
    Map.put(rdata, :ttl, record.ttl || 3600)
  end

  # Flush all dirty records to Store on shutdown
  defp flush_to_store(state) do
    try do
      records = get_all_records_from_table(state.table)

      # Group by {name, type} and sync each RRset
      records
      |> Enum.group_by(fn r -> {normalize_name(r.name), normalize_type(r.type)} end)
      |> Enum.each(fn {{name, type}, recs} ->
        rrset_data = Enum.map(recs, &record_to_store_rdata/1)
        YellowDog.Store.Zone.put_rrset(state.view_name, state.name, name, type, rrset_data)
      end)
    rescue
      _ -> :ok
    end
  end

  defp do_save(%{zone_file: nil, zone_data_path: nil} = _state) do
    {:error, "No zone file path configured"}
  end

  defp do_save(state) do
    file_path = state.zone_file || Path.join(state.zone_data_path, "#{state.name}.zone")

    # Build zone struct from current state
    records = get_all_records_from_table(state.table)
    zone = build_zone_struct(state, records)

    # Ensure directory exists
    dir = Path.dirname(file_path)

    case File.mkdir_p(dir) do
      :ok ->
        Zone.Loader.save_zone_to_file(zone, file_path)

      {:error, reason} ->
        {:error, "Failed to create directory: #{reason}"}
    end
  end

  defp get_all_records_from_table(table) do
    for {_key, record} <- :ets.tab2list(table), do: record
  end

  defp build_zone_struct(state, records) do
    %Zone{
      name: %DNS.Zone.Name{value: state.name},
      type: :authoritative,
      origin: state.name,
      ttl: state.ttl || 3600,
      soa: extract_soa_map(state.soa),
      records: records_to_rrsets(records),
      options: [source_file: state.zone_file],
      comments: []
    }
  end

  # Convert parsed DNS.Zone RRSets back to DNS.Message.Record structs for ETS storage
  defp rrsets_to_records(%DNS.Zone{} = zone) do
    for rrset <- zone.records,
        data <- rrset.data,
        record = rrset_data_to_record(rrset.name, rrset.type, rrset.ttl, data, zone.origin),
        record != nil,
        do: record
  end

  defp rrset_data_to_record(name, type, ttl, data, origin) do
    resolved_name = resolve_name(name, origin)
    build_record(type, resolved_name, ttl, data)
  end

  defp build_record(:a, name, ttl, data) do
    ip = IpFormat.parse_v4(data[:address] || data.address)
    if ip, do: Message.Record.new(name, :a, :in, ttl, ip)
  end

  defp build_record(:aaaa, name, ttl, data) do
    ip = IpFormat.parse_v6(data[:address] || data.address)
    if ip, do: Message.Record.new(name, :aaaa, :in, ttl, ip)
  end

  defp build_record(:ns, name, ttl, data) do
    nsdname = data[:nsdname] || data.nsdname
    Message.Record.new(name, :ns, :in, ttl, to_string(nsdname))
  end

  defp build_record(:cname, name, ttl, data) do
    cname = data[:cname] || data.cname
    Message.Record.new(name, :cname, :in, ttl, to_string(cname))
  end

  defp build_record(:mx, name, ttl, data) do
    preference = data[:preference] || data.preference
    exchange = data[:exchange] || data.exchange
    Message.Record.new(name, :mx, :in, ttl, {preference, to_string(exchange)})
  end

  defp build_record(:txt, name, ttl, data) do
    txtdata = data[:txtdata] || data.txtdata
    txt_list = if is_list(txtdata), do: txtdata, else: [to_string(txtdata)]
    Message.Record.new(name, :txt, :in, ttl, txt_list)
  end

  defp build_record(:srv, name, ttl, data) do
    priority = data[:priority] || data.priority
    weight = data[:weight] || data.weight
    port = data[:port] || data.port
    target = data[:target] || data.target
    Message.Record.new(name, :srv, :in, ttl, {priority, weight, port, to_string(target)})
  end

  defp build_record(:ptr, name, ttl, data) do
    ptrdname = data[:ptrdname] || data.ptrdname
    Message.Record.new(name, :ptr, :in, ttl, to_string(ptrdname))
  end

  defp build_record(:caa, name, ttl, data) do
    flags = data[:flags] || data.flags
    tag = data[:tag] || data.tag
    value = data[:value] || data.value
    Message.Record.new(name, :caa, :in, ttl, {flags, tag, value})
  end

  # SOA records are handled separately via state.soa
  defp build_record(:soa, _name, _ttl, _data), do: nil
  defp build_record(_type, _name, _ttl, _data), do: nil

  # Build a DNS.Message.Record for SOA from zone.soa, which may be:
  #   - %DNS.Zone.Parser.SOARecord{primary_ns:, admin_email:, ...}  (AST-based parser)
  #   - %{mname:, rname:, serial:, ...}                             (FileParser, legacy)
  # Returns nil when no SOA data is present so callers can filter it out safely.
  defp build_soa_from_zone(%DNS.Zone{soa: nil}, _zone_name, _default_ttl), do: nil

  defp build_soa_from_zone(
         %DNS.Zone{soa: %DNS.Zone.Parser.SOARecord{} = soa, origin: origin},
         zone_name,
         default_ttl
       ) do
    name = normalize_origin(origin) || normalize_origin(zone_name)
    ttl = soa.minimum || default_ttl
    mname = trim_trailing_dot(to_string(soa.primary_ns))
    rname = trim_trailing_dot(to_string(soa.admin_email))

    Message.Record.new(
      name,
      :soa,
      :in,
      ttl,
      {mname, rname, soa.serial, soa.refresh, soa.retry, soa.expire, soa.minimum}
    )
  end

  defp build_soa_from_zone(%DNS.Zone{soa: soa, origin: origin}, zone_name, default_ttl)
       when is_map(soa) do
    name = normalize_origin(origin) || normalize_origin(zone_name)
    mname = trim_trailing_dot(to_string(Map.get(soa, :mname, "ns1.#{name}")))
    rname = trim_trailing_dot(to_string(Map.get(soa, :rname, "hostmaster.#{name}")))
    serial = Map.get(soa, :serial, 1)
    refresh = Map.get(soa, :refresh, 3600)
    retry = Map.get(soa, :retry, 1800)
    expire = Map.get(soa, :expire, 604_800)
    minimum = Map.get(soa, :minimum, 86_400)
    ttl = minimum || default_ttl

    Message.Record.new(
      name,
      :soa,
      :in,
      ttl,
      {mname, rname, serial, refresh, retry, expire, minimum}
    )
  end

  defp build_soa_from_zone(_zone, _zone_name, _default_ttl), do: nil

  defp trim_trailing_dot(s), do: String.trim_trailing(s, ".")

  defp resolve_name(nil, origin), do: normalize_origin(origin)
  defp resolve_name("@", origin), do: normalize_origin(origin)

  defp resolve_name(name, origin) do
    name_str = to_string(name)

    cond do
      # Already FQDN (ends with dot or contains origin)
      String.ends_with?(name_str, ".") ->
        String.trim_trailing(name_str, ".")

      # Relative name - append origin
      origin != nil ->
        "#{name_str}.#{normalize_origin(origin)}"

      true ->
        name_str
    end
  end

  defp normalize_origin(nil), do: "."
  defp normalize_origin(origin), do: String.trim_trailing(to_string(origin), ".")

  defp extract_soa_map(nil), do: nil

  defp extract_soa_map(soa_record) do
    soa_record
    |> record_data()
    |> soa_data_to_map()
  end

  defp soa_data_to_map(%DNS.Message.Record.Data.SOA{data: data}), do: soa_data_to_map(data)

  defp soa_data_to_map({mname, rname, serial, refresh, retry, expire, minimum}) do
    %DNS.Zone.Parser.SOARecord{
      primary_ns: to_string(mname),
      admin_email: to_string(rname),
      serial: serial,
      refresh: refresh,
      retry: retry,
      expire: expire,
      minimum: minimum
    }
  end

  defp soa_data_to_map(%{mname: mname, rname: rname} = soa_data) do
    %DNS.Zone.Parser.SOARecord{
      primary_ns: to_string(mname),
      admin_email: to_string(rname),
      serial: soa_data.serial,
      refresh: soa_data.refresh,
      retry: soa_data.retry,
      expire: soa_data.expire,
      minimum: soa_data.minimum
    }
  end

  defp soa_data_to_map(%{primary_ns: primary_ns, admin_email: admin_email} = soa_data) do
    %DNS.Zone.Parser.SOARecord{
      primary_ns: to_string(primary_ns),
      admin_email: to_string(admin_email),
      serial: soa_data.serial,
      refresh: soa_data.refresh,
      retry: soa_data.retry,
      expire: soa_data.expire,
      minimum: soa_data.minimum
    }
  end

  defp records_to_rrsets(records) do
    records
    |> Enum.group_by(fn r -> {normalize_name(r.name), normalize_type(r.type)} end)
    |> Enum.map(fn {{name, type}, recs} ->
      %DNS.Zone.RRSet{
        name: name,
        type: type,
        ttl: List.first(recs).ttl || 3600,
        data: Enum.map(recs, &rdata_to_bind_map(normalize_type(&1.type), record_data(&1))),
        options: []
      }
    end)
  end

  # Extract record data from either DNS.Message.Record (.data) or map-based records (.rdata)
  defp record_data(%{data: data}) when not is_nil(data), do: data
  defp record_data(%{rdata: rdata}), do: rdata

  # Convert rdata structs to the map format expected by DNS.Zone.to_bind_format
  defp rdata_to_bind_map(:a, rdata) do
    address = extract_address(rdata)
    %{type: :a, address: address}
  end

  defp rdata_to_bind_map(:aaaa, rdata) do
    address = extract_address(rdata)
    %{type: :aaaa, address: address}
  end

  defp rdata_to_bind_map(:cname, rdata) do
    target = extract_target(rdata)
    %{type: :cname, cname: target}
  end

  defp rdata_to_bind_map(:ns, rdata) do
    target = extract_target(rdata)
    %{type: :ns, nsdname: target}
  end

  defp rdata_to_bind_map(:ptr, rdata) do
    target = extract_target(rdata)
    %{type: :ptr, ptrdname: target}
  end

  defp rdata_to_bind_map(:mx, rdata) do
    {preference, exchange} = extract_mx(rdata)
    %{type: :mx, preference: preference, exchange: exchange}
  end

  defp rdata_to_bind_map(:txt, rdata) do
    txt = extract_txt(rdata)
    %{type: :txt, txtdata: txt}
  end

  defp rdata_to_bind_map(:srv, rdata) do
    {priority, weight, port, target} = extract_srv(rdata)
    %{type: :srv, priority: priority, weight: weight, port: port, target: target}
  end

  defp rdata_to_bind_map(:caa, rdata) do
    {flags, tag, value} = extract_caa(rdata)
    %{type: :caa, flags: flags, tag: tag, value: value}
  end

  defp rdata_to_bind_map(type, rdata) do
    # Fallback: use to_string for unknown types
    %{type: type, data: rdata_to_string(rdata)}
  end

  # Extract address from A/AAAA records
  defp extract_address(%{data: {_, _, _, _} = ip}), do: IpFormat.format(ip)
  defp extract_address(%{data: {_, _, _, _, _, _, _, _} = ip}), do: IpFormat.format(ip)
  defp extract_address({_, _, _, _} = ip), do: IpFormat.format(ip)
  defp extract_address({_, _, _, _, _, _, _, _} = ip), do: IpFormat.format(ip)
  defp extract_address(rdata), do: to_string(rdata)

  # Extract target domain from CNAME/NS/PTR records
  defp extract_target(%{data: target}), do: to_string(target)
  defp extract_target(target), do: to_string(target)

  # Extract MX data
  defp extract_mx(%{data: %{preference: p, exchange: e}}), do: {p, to_string(e)}
  defp extract_mx(%{preference: p, exchange: e}), do: {p, to_string(e)}
  defp extract_mx({p, e}), do: {p, to_string(e)}
  defp extract_mx(rdata), do: {10, to_string(rdata)}

  # Extract TXT data
  defp extract_txt(%{data: txt}) when is_list(txt), do: Enum.join(txt, " ")
  defp extract_txt(%{data: txt}), do: to_string(txt)
  defp extract_txt(txt) when is_list(txt), do: Enum.join(txt, " ")
  defp extract_txt(txt), do: to_string(txt)

  # Extract SRV data
  defp extract_srv(%{data: %{priority: p, weight: w, port: port, target: t}}),
    do: {p, w, port, to_string(t)}

  defp extract_srv(%{priority: p, weight: w, port: port, target: t}),
    do: {p, w, port, to_string(t)}

  defp extract_srv({p, w, port, t}), do: {p, w, port, to_string(t)}
  defp extract_srv(rdata), do: {0, 0, 0, to_string(rdata)}

  # Extract CAA data
  defp extract_caa(%{data: %{flags: f, tag: t, value: v}}), do: {f, t, v}
  defp extract_caa(%{flags: f, tag: t, value: v}), do: {f, t, v}
  defp extract_caa({f, t, v}), do: {f, t, v}
  defp extract_caa(rdata), do: {0, "issue", to_string(rdata)}

  # Convert rdata to string for fallback
  defp rdata_to_string(rdata) when is_struct(rdata), do: to_string(rdata)
  defp rdata_to_string(rdata) when is_binary(rdata), do: rdata
  defp rdata_to_string(rdata), do: inspect(rdata)

  defp do_resolve(state, query) do
    case query.qdlist do
      [question | _] ->
        resolve_question(state, query, question)

      [] ->
        {:error, :format_error}
    end
  end

  defp resolve_question(state, query, question) do
    qname = normalize_name(question.name)
    qtype = normalize_type(question.type)

    if in_zone?(state.name, qname) do
      records = lookup_records(state.table, qname, qtype)
      cname_records = lookup_records(state.table, qname, :cname)

      cond do
        Enum.any?(records) ->
          {:ok, build_response(query, records, state)}

        Enum.any?(cname_records) ->
          # RFC 1034 §3.6.2: follow the CNAME chain within the zone and include
          # target records in the same answer section. Stops at the zone boundary
          # (out-of-zone targets are left for the client/resolver to pursue) and
          # at @max_cname_depth to prevent loops.
          all_answers = chase_cname_chain(state, cname_records, qtype, 0)
          {:ok, build_response(query, all_answers, state)}

        name_exists?(state.table, qname) ->
          {:ok, build_nodata_response(query, state)}

        true ->
          # RFC 1034 §4.3.3 / RFC 4592: try wildcard expansion before NXDOMAIN.
          # The wildcard candidate is the query name with the leftmost label
          # replaced by "*" (e.g., "a.example.com" → "*.example.com").
          wildcard = wildcard_candidate(qname)

          wildcard_records =
            if wildcard, do: lookup_records(state.table, wildcard, qtype), else: []

          wildcard_cnames =
            if wildcard, do: lookup_records(state.table, wildcard, :cname), else: []

          cond do
            Enum.any?(wildcard_records) ->
              # Substitute the query name as the owner (RFC 4592 §2.2.2)
              expanded = Enum.map(wildcard_records, &%{&1 | name: qname})
              {:ok, build_response(query, expanded, state)}

            Enum.any?(wildcard_cnames) ->
              expanded_cnames = Enum.map(wildcard_cnames, &%{&1 | name: qname})
              all_answers = chase_cname_chain(state, expanded_cnames, qtype, 0)
              {:ok, build_response(query, all_answers, state)}

            wildcard != nil and name_exists?(state.table, wildcard) ->
              # RFC 4592 §2.2.2: the wildcard "exists" but has no records of
              # the requested type → NODATA (not NXDOMAIN).
              {:ok, build_nodata_response(query, state)}

            true ->
              {:ok, build_nxdomain_response(query, state)}
          end
      end
    else
      {:error, :refused}
    end
  end

  defp lookup_records(table, name, type) do
    normalized = normalize_name(name)

    case type do
      :any ->
        # Match any type for this name
        for {_key, record} <- :ets.match_object(table, {{normalized, :_}, :_}), do: record

      specific_type ->
        for {_key, record} <- :ets.lookup(table, {normalized, specific_type}), do: record
    end
  end

  # Follow the CNAME chain within the zone, accumulating all records.
  # Returns the accumulated list of records (CNAMEs + final target records).
  # Stops when the depth limit is reached, the target is out-of-zone, or
  # the target has records of the requested type (end of chain).
  defp chase_cname_chain(_state, _cname_records, _qtype, depth)
       when depth >= @max_cname_depth,
       do: []

  defp chase_cname_chain(state, cname_records, qtype, depth) do
    cname_records ++
      Enum.flat_map(cname_records, fn cname_record ->
        target_name = cname_target_name(cname_record)

        if target_name != nil and in_zone?(state.name, target_name) do
          target_records = lookup_records(state.table, target_name, qtype)
          target_cnames = lookup_records(state.table, target_name, :cname)

          cond do
            Enum.any?(target_records) ->
              target_records

            Enum.any?(target_cnames) ->
              chase_cname_chain(state, target_cnames, qtype, depth + 1)

            true ->
              []
          end
        else
          # Target is out-of-zone — stop here; client resolves the rest.
          []
        end
      end)
  end

  # Extract the target domain name from a CNAME record.
  # Handles both plain maps (from add_record) and DNS.Message.Record structs.
  defp cname_target_name(record) do
    target =
      cond do
        is_binary(Map.get(record, :rdata)) -> Map.get(record, :rdata)
        is_binary(Map.get(record, "rdata")) -> Map.get(record, "rdata")
        is_map(record) and Map.get(record, :data) != nil -> to_string(record.data)
        true -> nil
      end

    if is_binary(target) and target != "", do: normalize_name(target), else: nil
  end

  defp name_exists?(table, name) do
    normalized = normalize_name(name)

    :ets.match_object(table, {{normalized, :_}, :_})
    |> Enum.any?()
  end

  # RFC 1034 §4.3.3 / RFC 4592: build the wildcard candidate for qname by
  # replacing the leftmost label with "*".
  # "a.example.com"   → "*.example.com"
  # "a.b.example.com" → "*.b.example.com"
  # Returns nil for apex queries (no label to strip).
  defp wildcard_candidate(qname) do
    case String.split(qname, ".", parts: 2) do
      [_first, rest] when rest != "" -> "*.#{rest}"
      _ -> nil
    end
  end

  defp in_zone?(zone_name, qname) do
    zone_suffix = normalize_name(zone_name)
    qname == zone_suffix or String.ends_with?(qname, "." <> zone_suffix)
  end

  defp insert_records(table, records) do
    for record <- records do
      key = {normalize_name(record.name), normalize_type(record.type)}
      :ets.insert(table, {key, record})
    end
  end

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp normalize_type(type) when is_atom(type), do: type

  defp normalize_type(%DNS.ResourceRecordType{value: value}) do
    # Convert RRType struct to atom
    case value do
      <<1::16>> -> :a
      <<2::16>> -> :ns
      <<5::16>> -> :cname
      <<6::16>> -> :soa
      <<12::16>> -> :ptr
      <<15::16>> -> :mx
      <<16::16>> -> :txt
      <<28::16>> -> :aaaa
      <<33::16>> -> :srv
      <<43::16>> -> :ds
      <<46::16>> -> :rrsig
      <<47::16>> -> :nsec
      <<48::16>> -> :dnskey
      <<50::16>> -> :nsec3
      <<51::16>> -> :nsec3param
      <<52::16>> -> :tlsa
      <<65::16>> -> :https
      <<99::16>> -> :spf
      <<255::16>> -> :any
      <<256::16>> -> :uri
      <<257::16>> -> :caa
      _ -> :unknown
    end
  end

  defp normalize_type(%{type: type}), do: normalize_type(type)

  @valid_rr_types ~w(a ns cname soa ptr mx txt aaaa srv ds rrsig nsec dnskey nsec3 nsec3param tlsa https spf any uri caa)
  defp normalize_type(type) when is_binary(type) do
    downcased = String.downcase(type)
    if downcased in @valid_rr_types, do: String.to_existing_atom(downcased), else: :unknown
  end

  defp normalize_type(_), do: :unknown

  defp build_response(query, answers, _state) do
    %Message{
      header: %{
        query.header
        | qr: 1,
          aa: 1,
          rcode: RCode.no_error(),
          ancount: length(answers),
          nscount: 0,
          arcount: 0
      },
      qdlist: query.qdlist,
      anlist: answers,
      nslist: [],
      arlist: []
    }
  end

  # RFC 2308 §2: negative responses SHOULD include the zone SOA in the
  # authority section so that resolvers can cache negative results.
  defp build_nodata_response(query, state) do
    authority = if state.soa, do: [state.soa], else: []

    %Message{
      header: %{
        query.header
        | qr: 1,
          aa: 1,
          rcode: RCode.no_error(),
          ancount: 0,
          nscount: length(authority),
          arcount: 0
      },
      qdlist: query.qdlist,
      anlist: [],
      nslist: authority,
      arlist: []
    }
  end

  defp build_nxdomain_response(query, state) do
    authority = if state.soa, do: [state.soa], else: []

    %Message{
      header: %{
        query.header
        | qr: 1,
          aa: 1,
          rcode: RCode.nx_domain(),
          ancount: 0,
          nscount: length(authority),
          arcount: 0
      },
      qdlist: query.qdlist,
      anlist: [],
      nslist: authority,
      arlist: []
    }
  end

  defp load_zone_data(state, zone_data) when is_list(zone_data) do
    {soa, ns_records, _other_records} =
      Enum.reduce(zone_data, {nil, [], []}, fn record, {soa, ns, others} ->
        # Normalize the type for pattern matching
        case normalize_type(record.type) do
          :soa -> {record, ns, others}
          :ns -> {soa, [record | ns], others}
          _ -> {soa, ns, [record | others]}
        end
      end)

    # Insert all records into ETS with normalized keys
    insert_records(state.table, zone_data)

    %{state | soa: soa, ns_records: Enum.reverse(ns_records)}
  end

  defp load_zone_file(state, zone_file) do
    # Ensure parent directory exists
    zone_file
    |> Path.dirname()
    |> File.mkdir_p()

    # Create empty zone file if it doesn't exist
    unless File.exists?(zone_file) do
      Telemetry.info("Creating empty zone file", %{zone: state.name, file: zone_file})
      create_empty_zone_file(state.name, zone_file)
    end

    case DNS.Zone.Loader.load_zone_from_file(state.name, zone_file) do
      {:ok, zone} ->
        zone = ensure_zone_origin(zone, state.name)

        # DNS.Zone.Loader returns DNS.Zone.RRSet structs in zone.records, but the
        # auth zone ETS table and response builder expect DNS.Message.Record structs
        # (which implement DNS.Parameter for wire-format serialization). Use
        # rrsets_to_records/1 to convert non-SOA records. SOA is stored separately
        # in zone.soa by the file parser and must be built explicitly because
        # build_record(:soa, ...) returns nil to avoid double-storing it.
        records = rrsets_to_records(zone)
        soa = build_soa_from_zone(zone, state.name, state.ttl)
        all_records = if soa, do: [soa | records], else: records
        load_zone_data(state, all_records)

      {:error, reason} ->
        Telemetry.error("Failed to load zone file", %{
          zone: state.name,
          file: zone_file,
          reason: inspect(reason)
        })

        state
    end
  end

  defp ensure_zone_origin(%DNS.Zone{origin: nil} = zone, zone_name),
    do: %{zone | origin: zone_name}

  defp ensure_zone_origin(%DNS.Zone{} = zone, _zone_name), do: zone

  defp create_empty_zone_file(zone_name, file_path) do
    # Create a minimal valid zone file with SOA and NS records
    content = """
    ; Zone file for #{zone_name}
    ; Auto-generated - add your DNS records below
    $TTL 86400
    @   IN  SOA ns1.#{zone_name}. hostmaster.#{zone_name}. (
                #{:os.system_time(:second)}  ; serial
                3600        ; refresh (1 hour)
                1800        ; retry (30 minutes)
                604800      ; expire (1 week)
                86400       ; minimum (1 day)
            )
    @   IN  NS  ns1.#{zone_name}.
    """

    File.write(file_path, content)
  end
end
