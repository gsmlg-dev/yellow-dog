defmodule YellowDog.DhcpClient.DhcpSocket do
  @moduledoc """
  Behaviour and GenServer wrapping DHCP socket operations.

  Defines a behaviour for platform-specific socket implementations and provides
  a GenServer that owns the socket resource and forwards received packets to the
  state machine as `{:dhcp_rx, packet_binary}` messages.

  The concrete implementation module is configurable via application env
  (key `:socket_impl`) and defaults to `UdpFallback` for development and testing.
  """

  use GenServer

  @type socket_ref :: reference()

  @callback open(interface :: String.t(), owner :: pid()) ::
              {:ok, socket_ref()} | {:error, term()}
  @callback send_broadcast(socket_ref(), packet :: iodata()) :: :ok | {:error, term()}
  @callback send_unicast(socket_ref(), dest :: :inet.ip4_address(), packet :: iodata()) ::
              :ok | {:error, term()}
  @callback send_arp_probe(socket_ref(), target_ip :: :inet.ip4_address()) ::
              :ok | {:error, term()}
  @callback close(socket_ref()) :: :ok

  defstruct [:socket, :interface, :owner, :impl]

  # --- Public API ---

  @doc "Starts the socket process for the given interface, forwarding packets to `owner_pid`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    interface = Keyword.fetch!(opts, :interface)
    owner_pid = Keyword.fetch!(opts, :owner)
    name = Keyword.get(opts, :name)
    start_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, {interface, owner_pid, opts}, start_opts)
  end

  @doc "Sends a DHCP broadcast packet through the socket."
  @spec send_broadcast(GenServer.server(), iodata()) :: :ok | {:error, term()}
  def send_broadcast(server, packet) do
    GenServer.call(server, {:send_broadcast, packet})
  end

  @doc "Sends a DHCP unicast packet to `dest_ip` through the socket."
  @spec send_unicast(GenServer.server(), :inet.ip4_address(), iodata()) :: :ok | {:error, term()}
  def send_unicast(server, dest_ip, packet) do
    GenServer.call(server, {:send_unicast, dest_ip, packet})
  end

  @doc "Sends an ARP probe for duplicate address detection."
  @spec send_arp_probe(GenServer.server(), :inet.ip4_address()) :: :ok | {:error, term()}
  def send_arp_probe(server, target_ip) do
    GenServer.call(server, {:send_arp_probe, target_ip})
  end

  @doc "Closes the socket and stops the process."
  @spec close(GenServer.server()) :: :ok
  def close(server) do
    GenServer.stop(server)
  end

  # --- GenServer callbacks ---

  @impl true
  def init({interface, owner_pid, opts}) do
    impl = Keyword.get(opts, :impl, default_impl())

    case impl.open(interface, self()) do
      {:ok, socket_ref} ->
        state = %__MODULE__{
          socket: socket_ref,
          interface: interface,
          owner: owner_pid,
          impl: impl
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_broadcast, packet}, _from, state) do
    result = state.impl.send_broadcast(state.socket, packet)
    {:reply, result, state}
  end

  def handle_call({:send_unicast, dest_ip, packet}, _from, state) do
    result = state.impl.send_unicast(state.socket, dest_ip, packet)
    {:reply, result, state}
  end

  def handle_call({:send_arp_probe, target_ip}, _from, state) do
    result = state.impl.send_arp_probe(state.socket, target_ip)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:udp, _socket, _ip, _port, data}, state) do
    forward_to_owner(state.owner, {:dhcp_rx, data})
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      state.impl.close(state.socket)
    end

    :ok
  end

  # `send/2` only accepts PIDs and registered atom names — not via-tuples.
  # When the owner is a via-registered process (the normal production case),
  # resolve the PID through the registry before forwarding.
  defp forward_to_owner(pid, msg) when is_pid(pid), do: send(pid, msg)
  defp forward_to_owner(name, msg) when is_atom(name), do: send(name, msg)

  defp forward_to_owner({:via, module, name}, msg) do
    case module.whereis_name(name) do
      :undefined -> :ok
      pid -> send(pid, msg)
    end
  end

  defp default_impl do
    Application.get_env(
      :yellow_dog_dhcp_client,
      :socket_impl,
      YellowDog.DhcpClient.DhcpSocket.UdpFallback
    )
  end
end

defmodule YellowDog.DhcpClient.DhcpSocket.UdpFallback do
  @moduledoc """
  Development/test socket implementation using `:gen_udp`.

  Opens a UDP socket on a random port with broadcast enabled. Suitable for
  local testing but not for production DHCP operation (which requires binding
  to port 68 with interface-specific socket options).
  """

  @behaviour YellowDog.DhcpClient.DhcpSocket

  @impl true
  def open(_interface, owner_pid) do
    case :gen_udp.open(0, [:binary, {:active, true}, {:broadcast, true}]) do
      {:ok, socket} ->
        ref = make_ref()
        :persistent_term.put({__MODULE__, ref}, {socket, owner_pid})
        {:ok, ref}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def send_broadcast(ref, packet) do
    case :persistent_term.get({__MODULE__, ref}, nil) do
      {socket, _owner} -> :gen_udp.send(socket, {255, 255, 255, 255}, 67, packet)
      nil -> {:error, :socket_closed}
    end
  end

  @impl true
  def send_unicast(ref, dest_ip, packet) do
    case :persistent_term.get({__MODULE__, ref}, nil) do
      {socket, _owner} -> :gen_udp.send(socket, dest_ip, 67, packet)
      nil -> {:error, :socket_closed}
    end
  end

  @impl true
  def send_arp_probe(_ref, _target_ip) do
    {:error, :not_supported}
  end

  @impl true
  def close(ref) do
    case :persistent_term.get({__MODULE__, ref}, nil) do
      {socket, _owner} ->
        :gen_udp.close(socket)
        :persistent_term.erase({__MODULE__, ref})
        :ok

      nil ->
        :ok
    end
  end
end
