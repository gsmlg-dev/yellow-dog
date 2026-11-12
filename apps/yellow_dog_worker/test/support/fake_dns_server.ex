defmodule YellowDog.Worker.Test.FakeDnsServer do
  @moduledoc false
  # Test-only DNS server listening on UDP and TCP at the same ip/port.
  # handler: (DNS.Message.t() -> binary | :drop) or
  #          (DNS.Message.t(), {:udp | :tcp, peer} -> binary | :drop)

  use GenServer

  def start_link(ip, port, handler), do: GenServer.start_link(__MODULE__, {ip, port, handler})

  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init({ip, port, handler}) do
    {:ok, udp} = :gen_udp.open(port, [:binary, ip: ip, active: true])
    {:ok, bound} = :inet.port(udp)

    {:ok, listen} =
      :gen_tcp.listen(bound, [:binary, ip: ip, active: false, packet: 2, reuseaddr: true])

    server = self()
    spawn_link(fn -> accept_loop(listen, handler, server) end)
    {:ok, %{udp: udp, listen: listen, port: bound, handler: handler}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info({:udp, udp, ip, port, packet}, %{udp: udp} = state) do
    case call(state.handler, packet, {:udp, {ip, port}}) do
      :drop -> :ok
      reply -> :gen_udp.send(udp, ip, port, reply)
    end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp accept_loop(listen, handler, server) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        pid = spawn(fn -> serve(sock, handler) end)
        :gen_tcp.controlling_process(sock, pid)
        accept_loop(listen, handler, server)

      _ ->
        :ok
    end
  end

  defp serve(sock, handler) do
    with {:ok, packet} <- :gen_tcp.recv(sock, 0, 5_000),
         {:ok, peer} <- :inet.peername(sock),
         reply when is_binary(reply) <- call(handler, packet, {:tcp, peer}) do
      :gen_tcp.send(sock, reply)
    end

    :gen_tcp.close(sock)
  end

  defp call(handler, packet, from) do
    message = DNS.Message.from_iodata(packet)
    if is_function(handler, 2), do: handler.(message, from), else: handler.(message)
  end
end
