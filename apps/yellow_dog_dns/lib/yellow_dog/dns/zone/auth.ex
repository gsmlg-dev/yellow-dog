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
    GenServer.start_link(__MODULE__, opts, name: Behaviour.zone_via_tuple(view_name, :auth, zone_name))
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

    # Load initial zone data
    state =
      cond do
        zone_data = Keyword.get(opts, :zone_data) ->
          load_zone_data(state, zone_data)

        zone_file != nil ->
          load_zone_file(state, zone_file)

        true ->
          state
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

    # Reload zone data
    new_state =
      cond do
        zone_data = Keyword.get(config, :zone_data) ->
          load_zone_data(state, zone_data)

        zone_file = Keyword.get(config, :zone_file) ->
          load_zone_file(state, zone_file)

        true ->
          state
      end

    Telemetry.info("Auth zone reloaded", %{name: state.name})

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

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:remove_record, name, type}, _from, state) do
    :ets.delete(state.table, {normalize_name(name), type})

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

      {:reply, {:ok, new_version}, new_state}
    else
      {:reply, {:error, :version_conflict}, state}
    end
  end

  @impl true
  def handle_call({:remove_record_versioned, name, type, expected_version}, _from, state) do
    if state.version == expected_version do
      :ets.delete(state.table, {normalize_name(name), type})
      new_version = state.version + 1

      new_state = %{
        state
        | dirty: true,
          version: new_version,
          updated_at: DateTime.utc_now()
      }

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

        Enum.each(records, fn record ->
          key = {normalize_name(record.name), normalize_type(record.type)}
          :ets.insert(state.table, {key, record})
        end)

        new_state = %{
          state
          | dirty: true,
            version: state.version + 1,
            updated_at: DateTime.utc_now()
        }

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
    # Save zone data on graceful shutdown if dirty
    if state.dirty do
      # Only attempt save if a file path is configured
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
      else
        # No file path configured - this is normal for test zones
        Telemetry.debug("Zone not persisted (no file path configured)", %{name: state.name})
      end
    end

    # Clean up ETS table
    :ets.delete(state.table)

    Telemetry.info("Auth zone stopped", %{name: state.name, reason: inspect(reason)})
    :ok
  end

  # Private Functions

  defp do_save(%{zone_file: nil, zone_data_path: nil} = _state) do
    {:error, "No zone file path configured"}
  end

  defp do_save(state) do
    # Determine the file path
    file_path =
      cond do
        state.zone_file != nil ->
          state.zone_file

        state.zone_data_path != nil ->
          Path.join(state.zone_data_path, "#{state.name}.zone")

        true ->
          nil
      end

    if file_path == nil do
      {:error, "No zone file path configured"}
    else
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
    zone.records
    |> Enum.flat_map(fn rrset ->
      Enum.map(rrset.data, fn data ->
        rrset_data_to_record(rrset.name, rrset.type, rrset.ttl, data, zone.origin)
      end)
    end)
    |> Enum.reject(&is_nil/1)
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
    soa_data = record_data(soa_record)

    %{
      primary_ns: soa_data.mname,
      admin_email: soa_data.rname,
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
  defp extract_address(rdata) when is_struct(rdata), do: to_string(rdata)
  defp extract_address(rdata), do: to_string(rdata)

  # Extract target domain from CNAME/NS/PTR records
  defp extract_target(%{data: target}), do: to_string(target)
  defp extract_target(target) when is_struct(target), do: to_string(target)
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
          {:ok, build_response(query, cname_records, state)}

        name_exists?(state.table, qname) ->
          {:ok, build_nodata_response(query, state)}

        true ->
          {:ok, build_nxdomain_response(query, state)}
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

  defp name_exists?(table, name) do
    normalized = normalize_name(name)

    :ets.match_object(table, {{normalized, :_}, :_})
    |> Enum.any?()
  end

  defp in_zone?(zone_name, qname) do
    zone_suffix = normalize_name(zone_name)
    String.ends_with?(qname, zone_suffix) or qname == zone_suffix
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

  defp build_nodata_response(query, _state) do
    %Message{
      header: %{
        query.header
        | qr: 1,
          aa: 1,
          rcode: RCode.no_error(),
          ancount: 0,
          nscount: 0,
          arcount: 0
      },
      qdlist: query.qdlist,
      anlist: [],
      nslist: [],
      arlist: []
    }
  end

  defp build_nxdomain_response(query, _state) do
    %Message{
      header: %{
        query.header
        | qr: 1,
          aa: 1,
          rcode: RCode.nx_domain(),
          ancount: 0,
          nscount: 0,
          arcount: 0
      },
      qdlist: query.qdlist,
      anlist: [],
      nslist: [],
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
    Enum.each(zone_data, fn record ->
      key = {normalize_name(record.name), normalize_type(record.type)}
      :ets.insert(state.table, {key, record})
    end)

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
        load_zone_data(state, zone.records)

      {:error, reason} ->
        Telemetry.error("Failed to load zone file", %{
          zone: state.name,
          file: zone_file,
          reason: inspect(reason)
        })

        state
    end
  end

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
        IN  NS  ns1.#{zone_name}.
    """

    File.write(file_path, content)
  end

end
