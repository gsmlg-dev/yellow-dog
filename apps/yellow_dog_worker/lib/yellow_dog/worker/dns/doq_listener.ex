defmodule YellowDog.Worker.Dns.DoqListener do
  @moduledoc false
  use GenServer

  alias YellowDog.Worker.Dns.{DoqDatagram, Resolver}
  alias YellowDog.Worker.OwnedShutdown

  @protocol_error 2
  @internal_error 1
  @chunk 16_384
  @max_frame 65_537
  @max_connections 32

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  def prepare_reload(pid, material),
    do: GenServer.call(pid, {:prepare_reload, fn -> material end})

  def activate_reload(pid), do: GenServer.call(pid, :activate_reload)
  def finish_reload(pid, activate?), do: GenServer.call(pid, {:finish_reload, activate?})

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    ip = Keyword.fetch!(options, :ip)
    port = Keyword.fetch!(options, :port)
    adapter = Keyword.fetch!(options, :adapter)
    certificate = Keyword.fetch!(options, :certificate)
    table = :ets.new(__MODULE__, [:protected, read_concurrency: true])

    with {:ok, udp} <- open_udp(ip, port, table),
         {:ok, capability} <- udp_capability(udp, {ip, port}, 30),
         {:ok, endpoint} <- open_quic({ip, port}, capability, tls_options(certificate)),
         {:ok, sessions} <- Task.Supervisor.start_link(max_children: @max_connections) do
      :ets.insert(table, {:quic, endpoint})

      {:ok,
       %{
         adapter: adapter,
         udp: udp,
         endpoint: endpoint,
         pending: nil,
         previous: nil,
         address: {ip, port},
         capability: capability,
         sessions: sessions,
         table: table,
         owner: hd(Process.get(:"$ancestors"))
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp tls_options(%{certs: chain, key: key}), do: [cert: chain, key: key, alpn: ["doq"]]

  defp open_udp(ip, port, table) do
    options = [ip: ip, reuseaddr: false, reuseport: false]
    options = if tuple_size(ip) == 8, do: [:inet6, {:ipv6_v6only, true} | options], else: options

    Abyss.Endpoint.start_link(
      transport_module: Abyss.Transport.UDP.Unicast,
      datagram_handler: DoqDatagram,
      handler_options: [endpoint_table: table],
      execution: :per_datagram,
      transport_options: options,
      port: port,
      num_listeners: 1,
      max_packet_size: 4096
    )
  end

  defp udp_capability(udp, address, attempts) do
    with {:ok, ^address} <- Abyss.Endpoint.local_endpoint(udp),
         {:ok, capability} <- Abyss.Endpoint.capability(udp) do
      {:ok, capability}
    else
      _ when attempts > 0 ->
        Process.sleep(20)
        udp_capability(udp, address, attempts - 1)

      _ ->
        OwnedShutdown.stop(udp)
        {:error, :udp_not_ready}
    end
  end

  defp open_quic(address, capability, tls) do
    send_packet = fn {ip, port}, bytes ->
      with {:ok, ref} <-
             Abyss.Endpoint.send(capability, Abyss.Datagram.sockaddr(ip, port), bytes),
           {:ok, _} <- Abyss.Endpoint.await(capability, ref) do
        :ok
      else
        _ -> {:error, :datagram_send_failed}
      end
    end

    Quic.listen(
      io: {:external, address, send_packet},
      tls: tls,
      max_connections: @max_connections
    )
  end

  @impl true
  def handle_call({:prepare_reload, material}, _from, %{pending: nil} = state) do
    case open_quic(state.address, state.capability, tls_options(material.())) do
      {:ok, endpoint} -> {:reply, :ok, %{state | pending: endpoint}}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:activate_reload, _from, %{pending: endpoint} = state)
      when is_pid(endpoint) do
    if Process.alive?(endpoint) do
      :ets.insert(state.table, {:quic, endpoint})
      {:reply, :ok, %{state | endpoint: endpoint, pending: nil, previous: state.endpoint}}
    else
      {:reply, {:error, :endpoint_unavailable}, %{state | pending: nil}}
    end
  end

  def handle_call({:finish_reload, true}, _from, state) do
    OwnedShutdown.stop(state.previous)
    {:reply, :ok, %{state | previous: nil}}
  end

  def handle_call({:finish_reload, false}, _from, %{previous: endpoint} = state)
      when is_pid(endpoint) do
    :ets.insert(state.table, {:quic, endpoint})
    OwnedShutdown.stop(state.endpoint)
    {:reply, :ok, %{state | endpoint: endpoint, previous: nil}}
  end

  def handle_call({:finish_reload, false}, _from, state) do
    OwnedShutdown.stop(state.pending)
    {:reply, :ok, %{state | pending: nil}}
  end

  @impl true
  def handle_info({:quic_accept, endpoint}, %{endpoint: endpoint} = state) do
    accept(state)
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state)
      when pid in [state.owner, state.endpoint, state.udp, state.sessions],
      do: {:stop, {:quic_listener_exit, reason}, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    OwnedShutdown.stop(state.sessions)
    OwnedShutdown.stop(state.pending)
    OwnedShutdown.stop(state.previous)
    OwnedShutdown.stop(state.endpoint)
    OwnedShutdown.stop(state.udp)
    :ok
  end

  defp accept(state) do
    case Quic.accept(state.endpoint, 25) do
      {:ok, connection} ->
        adapter = state.adapter

        case Task.Supervisor.start_child(state.sessions, fn -> serve(connection, adapter) end) do
          {:ok, _} -> :ok
          {:error, _} -> Quic.close(connection, @internal_error)
        end

        accept(state)

      _ ->
        :ok
    end
  end

  defp serve(connection, adapter) do
    with :ok <- Quic.attach(connection, self()),
         {:ok, %{remote: {ip, _}}} <- Quic.info(connection) do
      poll(connection, adapter, ip, %{})
    end
  catch
    :exit, _ -> :ok
  end

  defp poll(connection, adapter, ip, streams) do
    receive do
      {:quic_closed, ^connection, _reason} -> :ok
    after
      10 ->
        case Quic.events(connection, 32, timeout: 200) do
          {:ok, events} ->
            streams = Enum.reduce(events, streams, &handle_event(&1, &2, adapter, ip))
            poll(connection, adapter, ip, streams)

          _ ->
            :ok
        end
    end
  end

  defp handle_event({:stream_open, stream, :uni}, streams, _adapter, _ip) do
    Quic.close(stream.connection, @protocol_error)
    streams
  end

  defp handle_event({:readable, stream}, streams, adapter, ip) do
    case read(stream, Map.get(streams, stream.id, <<>>)) do
      {:pending, data} ->
        Map.put(streams, stream.id, data)

      result ->
        answer(stream, result, adapter, ip)
        Map.delete(streams, stream.id)
    end
  end

  defp handle_event(_event, streams, _adapter, _ip), do: streams

  defp read(stream, buffered) do
    case Quic.read(stream, @chunk, timeout: 200) do
      {:ok, []} ->
        {:pending, buffered}

      {:ok, items} ->
        case consume(items, buffered) do
          {:pending, data} -> read(stream, data)
          result -> result
        end

      _ ->
        :reset
    end
  end

  defp consume([], buffered), do: {:pending, buffered}

  defp consume([{:data, _id, bytes} | rest], buffered)
       when byte_size(buffered) + byte_size(bytes) <= @max_frame,
       do: consume(rest, buffered <> bytes)

  defp consume([{:fin, _id}], <<length::16, packet::binary-size(length)>>)
       when length >= 12,
       do: {:query, packet}

  defp consume([{:reset, _id, _error, _size} | _], _buffered), do: :reset
  defp consume(_events, _buffered), do: :invalid

  defp answer(stream, {:query, <<0::16, _::binary>> = packet}, adapter, ip) do
    with {:ok, context} <- GenServer.call(adapter, :snapshot, 2_000),
         response when is_binary(response) <- Resolver.reply(packet, context, :tcp, ip),
         :ok <- send_answer(stream, <<byte_size(response)::16, response::binary>>) do
      :ok
    else
      _ -> Quic.reset_stream(stream, @internal_error)
    end
  end

  defp answer(_stream, :reset, _adapter, _ip), do: :ok
  defp answer(stream, _invalid, _adapter, _ip), do: Quic.reset_stream(stream, @protocol_error)

  defp send_answer(stream, <<chunk::binary-size(@chunk), rest::binary>>) when rest != <<>> do
    with {:ok, _} <- Quic.send_stream(stream, chunk, false, timeout: 200),
         do: send_answer(stream, rest)
  end

  defp send_answer(stream, bytes) do
    with {:ok, _} <- Quic.send_stream(stream, bytes, true, timeout: 200), do: :ok
  end
end
