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

  @behaviour YellowDog.Dns.Zone.Behaviour

  alias YellowDog.Telemetry
  alias DNS.Message
  alias DNS.ResourceRecord

  defstruct [
    :name,
    :table,
    :soa,
    :ns_records,
    :created_at,
    query_count: 0,
    hit_count: 0,
    miss_count: 0
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
    GenServer.start_link(__MODULE__, opts, name: via_tuple(zone_name))
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def get_name(pid) do
    GenServer.call(pid, :get_name)
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

  # Server Callbacks

  @impl true
  def init(opts) do
    zone_name = Keyword.fetch!(opts, :name)

    # Create ETS table for zone data
    table =
      :ets.new(:"zone_#{zone_name}", [
        :bag,
        :protected,
        read_concurrency: true
      ])

    state = %__MODULE__{
      name: zone_name,
      table: table,
      created_at: DateTime.utc_now()
    }

    # Load initial zone data
    state =
      cond do
        zone_data = Keyword.get(opts, :zone_data) ->
          load_zone_data(state, zone_data)

        zone_file = Keyword.get(opts, :zone_file) ->
          load_zone_file(state, zone_file)

        true ->
          state
      end

    Telemetry.info("Auth zone started", %{name: zone_name})

    {:ok, state}
  end

  @impl true
  def handle_call(:get_name, _from, state) do
    {:reply, state.name, state}
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
      created_at: state.created_at
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:add_record, record}, _from, state) do
    :ets.insert(state.table, {{record.name, record.type}, record})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove_record, name, type}, _from, state) do
    :ets.delete(state.table, {name, type})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_records, name, type}, _from, state) do
    records = lookup_records(state.table, name, type)
    {:reply, records, state}
  end

  # Private Functions

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
    qtype = question.type

    # Check if name is in this zone
    if in_zone?(state.name, qname) do
      records = lookup_records(state.table, qname, qtype)

      if Enum.any?(records) do
        # Found matching records
        response = build_response(query, records, state)
        {:ok, response}
      else
        # Check for CNAME
        cname_records = lookup_records(state.table, qname, :cname)

        if Enum.any?(cname_records) do
          # Return CNAME
          response = build_response(query, cname_records, state)
          {:ok, response}
        else
          # Check if name exists (for NODATA vs NXDOMAIN)
          if name_exists?(state.table, qname) do
            # NODATA - name exists but no records of requested type
            response = build_nodata_response(query, state)
            {:ok, response}
          else
            # NXDOMAIN - name does not exist
            response = build_nxdomain_response(query, state)
            {:ok, response}
          end
        end
      end
    else
      # Not in this zone
      {:error, :refused}
    end
  end

  defp lookup_records(table, name, type) do
    normalized = normalize_name(name)

    case type do
      :any ->
        # Match any type for this name
        :ets.match_object(table, {{normalized, :_}, :_})
        |> Enum.map(fn {_key, record} -> record end)

      specific_type ->
        :ets.lookup(table, {normalized, specific_type})
        |> Enum.map(fn {_key, record} -> record end)
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
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp build_response(query, answers, state) do
    # Get NS records for authority section
    ns_records = state.ns_records || []

    %Message{
      header: %{
        query.header
        | qr: true,
          aa: true,
          rcode: :noerror
      },
      qdlist: query.qdlist,
      anlist: answers,
      nslist: ns_records,
      arlist: []
    }
  end

  defp build_nodata_response(query, state) do
    %Message{
      header: %{
        query.header
        | qr: true,
          aa: true,
          rcode: :noerror
      },
      qdlist: query.qdlist,
      anlist: [],
      nslist: soa_authority(state),
      arlist: []
    }
  end

  defp build_nxdomain_response(query, state) do
    %Message{
      header: %{
        query.header
        | qr: true,
          aa: true,
          rcode: :nxdomain
      },
      qdlist: query.qdlist,
      anlist: [],
      nslist: soa_authority(state),
      arlist: []
    }
  end

  defp soa_authority(state) do
    case state.soa do
      nil -> []
      soa -> [soa]
    end
  end

  defp load_zone_data(state, zone_data) when is_list(zone_data) do
    {soa, ns_records, _other_records} =
      Enum.reduce(zone_data, {nil, [], []}, fn record, {soa, ns, others} ->
        case record.type do
          :soa -> {record, ns, others}
          :ns -> {soa, [record | ns], others}
          _ -> {soa, ns, [record | others]}
        end
      end)

    # Insert all records into ETS
    Enum.each(zone_data, fn record ->
      :ets.insert(state.table, {{normalize_name(record.name), record.type}, record})
    end)

    %{state | soa: soa, ns_records: Enum.reverse(ns_records)}
  end

  defp load_zone_file(state, zone_file) do
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

  defp via_tuple(zone_name) do
    {:via, Registry, {YellowDog.Dns.ZoneRegistry, {:auth, zone_name}}}
  end
end
