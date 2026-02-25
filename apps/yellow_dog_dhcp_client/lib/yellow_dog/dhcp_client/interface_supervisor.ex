defmodule YellowDog.DhcpClient.InterfaceSupervisor do
  @moduledoc """
  Per-interface supervisor using `rest_for_one` strategy.

  Manages the lifecycle of a single DHCP client interface with three children
  started in order:

  1. `DhcpSocket` - raw socket owner, forwards packets to the state machine
  2. `StateMachine` - `:gen_statem` FSM implementing the DORA lifecycle
  3. `LeaseStore` - ETS-backed lease persistence with periodic disk flush

  The `rest_for_one` strategy ensures that if the socket crashes, the state
  machine and lease store are restarted (FSM re-enters INIT). If the state
  machine crashes, the lease store restarts to re-sync.
  """

  use Supervisor

  alias YellowDog.DhcpClient.{DhcpSocket, LeaseStore, StateMachine}

  @doc """
  Starts the per-interface supervisor.

  ## Options

    * `:interface` - Network interface name (required)
    * `:mac` - Client MAC address as 6-byte binary (required)
    * `:config` - Configuration map (optional)
    * `:name` - Supervisor name (optional)
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    interface = Keyword.fetch!(opts, :interface)
    name = Keyword.get(opts, :name, via_name(interface))
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    interface = Keyword.fetch!(opts, :interface)
    mac = Keyword.fetch!(opts, :mac)
    config = Keyword.get(opts, :config, %{})
    socket_impl = Keyword.get(opts, :socket_impl)

    socket_name = socket_name(interface)
    fsm_name = fsm_name(interface)
    store_name = store_name(interface)

    socket_opts =
      [interface: interface, owner: fsm_name, name: socket_name] ++
        if(socket_impl, do: [impl: socket_impl], else: [])

    children = [
      {DhcpSocket, socket_opts},
      {StateMachine,
       [
         interface: interface,
         mac: mac,
         socket_pid: socket_name,
         config: config,
         name: fsm_name
       ]},
      {LeaseStore,
       [
         interface: interface,
         lease_dir: Map.get(config, :lease_dir),
         name: store_name
       ]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # --- Name generation ---

  defp via_name(interface) do
    {:via, Registry, {YellowDog.DhcpClient.Registry, {:interface_sup, interface}}}
  end

  defp socket_name(interface) do
    {:via, Registry, {YellowDog.DhcpClient.Registry, {:socket, interface}}}
  end

  defp fsm_name(interface) do
    {:via, Registry, {YellowDog.DhcpClient.Registry, {:fsm, interface}}}
  end

  defp store_name(interface) do
    {:via, Registry, {YellowDog.DhcpClient.Registry, {:store, interface}}}
  end
end
