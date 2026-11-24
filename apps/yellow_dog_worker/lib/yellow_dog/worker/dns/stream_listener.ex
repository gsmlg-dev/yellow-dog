defmodule YellowDog.Worker.Dns.StreamListener do
  @moduledoc false
  use GenServer

  alias YellowDog.Worker.Dns.{Doh, Resolver, Tls}
  alias YellowDog.Worker.OwnedShutdown

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    ip = Keyword.fetch!(options, :ip)
    port = Keyword.fetch!(options, :port)
    adapter = Keyword.fetch!(options, :adapter)
    kind = Keyword.fetch!(options, :kind)
    certificate = options[:certificate]
    transport = if kind == "tcp", do: :gen_tcp, else: :ssl

    socket_options =
      family_options(ip) ++
        [:binary, ip: ip, active: false, reuseaddr: true, send_timeout: 2_000, packet: :raw]

    options =
      if transport == :ssl,
        do: socket_options ++ Tls.otp_options(certificate),
        else: socket_options

    with {:ok, socket} <- transport.listen(port, options),
         {:ok, sessions} <- Task.Supervisor.start_link(max_children: 32),
         {:ok, acceptor} <-
           Task.start_link(fn -> accept(transport, socket, sessions, adapter, kind) end) do
      {:ok,
       %{
         socket: socket,
         transport: transport,
         acceptor: acceptor,
         sessions: sessions,
         owner: hd(Process.get(:"$ancestors"))
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp family_options(ip) when tuple_size(ip) == 8, do: [:inet6, ipv6_v6only: true]
  defp family_options(_ip), do: [:inet]

  @impl true
  def handle_info({:EXIT, pid, reason}, %{owner: pid} = state),
    do: {:stop, {:owner_exited, reason}, state}

  def handle_info({:EXIT, pid, reason}, state) when pid in [state.acceptor, state.sessions],
    do: {:stop, {:stream_listener_exit, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state.transport.close(state.socket)
    OwnedShutdown.terminate_task(state.acceptor)
    OwnedShutdown.stop(state.sessions)
    :ok
  end

  defp accept(transport, socket, sessions, adapter, kind) do
    result =
      case transport do
        :gen_tcp -> :gen_tcp.accept(socket)
        :ssl -> :ssl.transport_accept(socket)
      end

    case result do
      {:ok, client} ->
        delegate(transport, client, sessions, adapter, kind)
        accept(transport, socket, sessions, adapter, kind)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  defp delegate(transport, client, sessions, adapter, kind) do
    case Task.Supervisor.start_child(
           sessions,
           fn -> await_client(transport, adapter, kind) end,
           shutdown: 500
         ) do
      {:ok, handler} ->
        case transport.controlling_process(client, handler) do
          :ok ->
            send(handler, {:client, client})

          {:error, _reason} ->
            transport.close(client)
            Process.exit(handler, :shutdown)
        end

      {:error, _reason} ->
        transport.close(client)
    end
  end

  defp await_client(transport, adapter, kind) do
    receive do
      {:client, socket} ->
        try do
          with {:ok, client} <- handshake(transport, socket, adapter, kind),
               {:ok, {peer, _port}} <- peername(transport, client) do
            serve(kind, transport, client, peer, adapter)
          end
        after
          transport.close(socket)
        end
    after
      2_000 -> :ok
    end
  end

  defp handshake(:ssl, socket, adapter, kind) do
    with {:ok, options} <- GenServer.call(adapter, {:tls_handshake_options, kind}, 2_000) do
      :ssl.handshake(socket, options, 2_000)
    end
  end

  defp handshake(:gen_tcp, socket, _adapter, _kind), do: {:ok, socket}

  defp peername(:ssl, client), do: :ssl.peername(client)
  defp peername(:gen_tcp, client), do: :inet.peername(client)

  defp serve("doh", :ssl, client, peer, adapter), do: Doh.serve(client, peer, adapter)

  defp serve(kind, transport, client, peer, adapter) when kind in ["tcp", "dot"] do
    with {:ok, <<length::16>>} <- transport.recv(client, 2, 2_000),
         true <- length in 12..65_535,
         {:ok, packet} <- transport.recv(client, length, 2_000),
         {:ok, context} <- GenServer.call(adapter, :snapshot, 2_000),
         response when is_binary(response) <- Resolver.reply(packet, context, :tcp, peer),
         :ok <- transport.send(client, <<byte_size(response)::16, response::binary>>) do
      serve(kind, transport, client, peer, adapter)
    end
  catch
    :exit, _ -> :ok
  end
end
