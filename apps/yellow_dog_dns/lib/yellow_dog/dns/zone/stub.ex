defmodule YellowDog.Dns.Zone.Stub do
  @moduledoc """
  Stub zone process.

  A stub zone holds NS records for a zone and delegates queries
  to the authoritative servers listed in those NS records.

  ## Features

  - Holds NS records for delegation
  - Queries authoritative servers directly
  - Caches NS glue records
  """

  use GenServer

  @behaviour YellowDog.Dns.Zone.Behaviour

  alias YellowDog.Telemetry

  defstruct [
    :name,
    :ns_records,
    :created_at,
    query_count: 0
  ]

  # Client API

  @doc """
  Starts a stub zone process.
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

  # Server Callbacks

  @impl true
  def init(opts) do
    zone_name = Keyword.fetch!(opts, :name)
    ns_records = Keyword.get(opts, :ns_records, [])

    state = %__MODULE__{
      name: zone_name,
      ns_records: ns_records,
      created_at: DateTime.utc_now()
    }

    Telemetry.info("Stub zone started", %{name: zone_name})

    {:ok, state}
  end

  @impl true
  def handle_call(:get_name, _from, state) do
    {:reply, state.name, state}
  end

  @impl true
  def handle_call({:resolve, _query}, _from, state) do
    state = %{state | query_count: state.query_count + 1}
    # TODO: Implement stub zone resolution
    {:reply, {:error, :not_implemented}, state}
  end

  @impl true
  def handle_call({:reload, config}, _from, state) do
    ns_records = Keyword.get(config, :ns_records, state.ns_records)
    {:reply, :ok, %{state | ns_records: ns_records}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      name: state.name,
      ns_count: length(state.ns_records),
      query_count: state.query_count,
      created_at: state.created_at
    }

    {:reply, stats, state}
  end

  defp via_tuple(zone_name) do
    {:via, Registry, {YellowDog.Dns.ZoneRegistry, {:stub, zone_name}}}
  end
end
