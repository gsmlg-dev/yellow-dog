defmodule YellowDog.Worker.DnsAdapter do
  @moduledoc "Authoritative DNS listener for one normalized Worker service."
  use GenServer

  alias YellowDog.Worker.Dns.Resolver
  alias YellowDog.Worker.Dns.UdpHandler
  alias YellowDog.Worker.OwnedShutdown

  @ready_attempts 50

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def update(pid, service, resources), do: GenServer.call(pid, {:update, service, resources})
  def status(pid), do: GenServer.call(pid, :status)

  def validate(service, resources) do
    with {:ok, _zones} <- Resolver.build(resources),
         {:ok, _ip, _port} <- parse_binding(service),
         do: :ok
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    service = Keyword.fetch!(opts, :service)
    resources = Keyword.fetch!(opts, :resources)

    with {:ok, zones} <- Resolver.build(resources),
         {:ok, ip, port} <- parse_binding(service) do
      case :gen_tcp.listen(port, [
             :binary,
             {:ip, ip},
             {:active, false},
             {:reuseaddr, true},
             {:send_timeout, 2000},
             {:send_timeout_close, true},
             {:packet, 0}
           ]) do
        {:ok, tcp} -> start_listeners(tcp, service, resources, zones, ip, port)
        {:error, reason} -> {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_listeners(tcp, service, resources, zones, ip, port) do
    case start_udp(ip, port) do
      {:ok, udp} ->
        case wait_udp(udp, ip, port, @ready_attempts) do
          :ok ->
            adapter = self()
            {:ok, sessions} = Task.Supervisor.start_link(max_children: 32)
            {:ok, acceptor} = Task.start_link(fn -> accept_loop(tcp, adapter, sessions) end)
            owned = OwnedShutdown.tree(udp) ++ [sessions, acceptor]

            {:ok,
             %{
               service: service,
               resources: resources,
               zones: zones,
               ip: ip,
               port: port,
               tcp: tcp,
               udp: udp,
               acceptor: acceptor,
               sessions: sessions,
               owner: hd(Process.get(:"$ancestors")),
               owned: owned
             }}

          {:error, reason} ->
            Abyss.stop(udp, 2_000)
            :gen_tcp.close(tcp)
            {:stop, reason}
        end

      {:error, reason} ->
        :gen_tcp.close(tcp)
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, state.zones}, state}

  def handle_call({:update, service, resources}, _from, state) do
    with {:ok, ip, port} <- parse_binding(service),
         true <- ip == state.ip and port == state.port,
         {:ok, zones} <- Resolver.build(resources) do
      {:reply, :ok, %{state | service: service, resources: resources, zones: zones}}
    else
      false -> {:reply, {:error, :listener_change_requires_restart}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:status, _from, state) do
    ready =
      Process.alive?(state.udp) and Process.alive?(state.acceptor) and
        udp_ready?(state.udp, state.ip, state.port)

    {:reply,
     %{
       ready: ready,
       owned_pids: [self() | state.owned],
       listeners: %{udp: ready, tcp: Process.alive?(state.acceptor)},
       listen_address: state.service["config"]["listen_address"],
       port: state.port,
       loaded_resources:
         Enum.map(
           state.resources,
           &%{"id" => &1["id"], "version" => &1["version"], "digest" => &1["digest"]}
         )
     }, state}
  end

  @impl GenServer
  def handle_info({:EXIT, pid, reason}, state)
      when pid == state.udp or pid == state.acceptor or pid == state.sessions do
    {:stop, {:listener_exited, reason}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{owner: pid} = state),
    do: {:stop, {:owner_exited, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    :gen_tcp.close(state.tcp)

    acceptor_result = OwnedShutdown.terminate_task(state.acceptor)
    session_result = OwnedShutdown.stop(state.sessions)
    udp_result = OwnedShutdown.stop(state.udp, state.owned -- [state.sessions, state.acceptor])

    case {acceptor_result, session_result, udp_result} do
      {:ok, :ok, :ok} -> :ok
      errors -> exit({:listener_shutdown_failed, errors})
    end
  end

  defp parse_binding(%{
         "type" => "dns",
         "config" => %{"listen_address" => address, "port" => port}
       })
       when is_binary(address) and is_integer(port) and port in 1..65_535 do
    case :inet.parse_ipv4_address(String.to_charlist(address)) do
      {:ok, ip} -> {:ok, ip, port}
      _ -> {:error, :invalid_listen_address}
    end
  end

  defp parse_binding(_), do: {:error, :invalid_service}

  defp start_udp(ip, port) do
    Abyss.start_link(
      transport_module: Abyss.Transport.UDP.Unicast,
      handler_module: UdpHandler,
      handler_options: [adapter: self()],
      port: port,
      transport_options: [ip: ip],
      num_listeners: 1,
      max_packet_size: 4096
    )
  end

  defp wait_udp(udp, ip, port, attempts) do
    cond do
      udp_ready?(udp, ip, port) ->
        :ok

      attempts == 0 ->
        {:error, :udp_not_ready}

      true ->
        Process.sleep(20)
        wait_udp(udp, ip, port, attempts - 1)
    end
  end

  defp udp_ready?(udp, ip, port) do
    with pool when is_pid(pool) <- Abyss.Server.listener_pool_pid(udp),
         [listener | _] <- Abyss.ListenerPool.listener_pids(pool),
         {:ok, {^ip, ^port}} <- Abyss.Listener.listener_info_cached(listener) do
      true
    else
      _ -> false
    end
  catch
    :exit, _ -> false
  end

  defp accept_loop(tcp, adapter, sessions) do
    case :gen_tcp.accept(tcp) do
      {:ok, client} ->
        start_session(client, adapter, sessions)
        accept_loop(tcp, adapter, sessions)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        exit({:accept_failed, reason})
    end
  end

  defp start_session(client, adapter, sessions) do
    case Task.Supervisor.start_child(sessions, fn -> await_client(adapter) end, shutdown: 500) do
      {:ok, handler} ->
        case :gen_tcp.controlling_process(client, handler) do
          :ok ->
            send(handler, {:client, client})

          {:error, reason} ->
            :gen_tcp.close(client)
            Process.exit(handler, {:ownership_failed, reason})
        end

      {:error, :max_children} ->
        :gen_tcp.close(client)

      {:error, reason} ->
        :gen_tcp.close(client)
        exit({:session_start_failed, reason})
    end
  end

  defp await_client(adapter) do
    receive do
      {:client, client} ->
        try do
          handle_client(client, adapter)
        after
          :gen_tcp.close(client)
        end
    after
      2000 -> exit(:ownership_timeout)
    end
  end

  defp handle_client(client, adapter) do
    with {:ok, <<length::16>>} <- :gen_tcp.recv(client, 2, 2_000),
         true <- length in 12..4096,
         {:ok, packet} <- :gen_tcp.recv(client, length, 2_000),
         {:ok, zones} <- GenServer.call(adapter, :snapshot, 2_000),
         response when is_binary(response) <- Resolver.reply(packet, zones, :tcp) do
      case :gen_tcp.send(client, <<byte_size(response)::16, response::binary>>) do
        :ok -> handle_client(client, adapter)
        {:error, reason} -> {:error, {:send_failed, reason}}
      end
    else
      {:error, :closed} -> :ok
      {:error, reason} -> {:error, reason}
      false -> {:error, :invalid_frame_size}
      nil -> {:error, :malformed_query}
    end
  end
end
