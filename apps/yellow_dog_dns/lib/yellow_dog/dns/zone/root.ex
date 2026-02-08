defmodule YellowDog.Dns.Zone.Root do
  @moduledoc """
  Root zone process.

  Holds root hints (root nameserver addresses) for initiating
  recursive DNS resolution.

  ## Features

  - Root hints loading from file or defaults
  - Root nameserver address caching
  - Priming queries support
  """

  use GenServer

  alias YellowDog.Dns.Zone.Behaviour

  @behaviour Behaviour

  alias YellowDog.Telemetry

  @default_root_servers [
    # Root servers - a.root-servers.net through m.root-servers.net
    {{198, 41, 0, 4}, 53},
    {{199, 9, 14, 201}, 53},
    {{192, 33, 4, 12}, 53},
    {{199, 7, 91, 13}, 53},
    {{192, 203, 230, 10}, 53},
    {{192, 5, 5, 241}, 53},
    {{192, 112, 36, 4}, 53},
    {{198, 97, 190, 53}, 53},
    {{192, 36, 148, 17}, 53},
    {{192, 58, 128, 30}, 53},
    {{193, 0, 14, 129}, 53},
    {{199, 7, 83, 42}, 53},
    {{202, 12, 27, 33}, 53}
  ]

  defstruct [
    :name,
    :view_name,
    :root_servers,
    :created_at,
    query_count: 0
  ]

  # Client API

  @doc """
  Starts a root zone process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    zone_name = Keyword.get(opts, :name, ".")
    view_name = Keyword.get(opts, :view_name, "default")

    GenServer.start_link(__MODULE__, opts,
      name: Behaviour.zone_via_tuple(view_name, :root, zone_name)
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
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  @doc """
  Returns the list of root servers.
  """
  @spec get_root_servers(pid()) :: list()
  def get_root_servers(pid) do
    GenServer.call(pid, :get_root_servers)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    zone_name = Keyword.get(opts, :name, ".")
    view_name = Keyword.get(opts, :view_name, "default")
    root_servers = Keyword.get(opts, :root_servers, @default_root_servers)

    state = %__MODULE__{
      name: zone_name,
      view_name: view_name,
      root_servers: root_servers,
      created_at: DateTime.utc_now()
    }

    Telemetry.info("Root zone started", %{
      name: zone_name,
      view: view_name,
      servers: length(root_servers)
    })

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
  def handle_call({:resolve, _query}, _from, state) do
    state = %{state | query_count: state.query_count + 1}
    # Return referral to root servers
    {:reply, {:referral, state.root_servers}, state}
  end

  @impl true
  def handle_call({:reload, config}, _from, state) do
    root_servers = Keyword.get(config, :root_servers, state.root_servers)
    {:reply, :ok, %{state | root_servers: root_servers}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      name: state.name,
      root_server_count: length(state.root_servers),
      query_count: state.query_count,
      created_at: state.created_at
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:get_root_servers, _from, state) do
    {:reply, state.root_servers, state}
  end
end
