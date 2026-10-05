defmodule YellowDog.Worker.DnsAdapterTest do
  use ExUnit.Case, async: false

  alias DNS.Message
  alias DNS.Message.Question
  alias YellowDog.Worker.DnsAdapter

  test "accepted idle and partial clients cannot block another TCP client or UDP" do
    {adapter, port} = adapter()
    idle = connect(port)
    accepted_owner(idle)
    partial = connect(port)
    :ok = :gen_tcp.send(partial, <<40::16, 1, 2>>)

    assert {:ok, _} = query(:udp, port, "ns1.example.com.", 1)
    valid = connect(port)
    send_query(valid, "ns1.example.com.", 1)
    assert {:ok, response} = receive_response(valid, 500)
    assert [%{data: %{data: {192, 0, 2, 53}}}] = response.anlist
    assert DnsAdapter.status(adapter).ready
  end

  test "a TCP session handles sequential and pipelined framed requests" do
    {_adapter, port} = adapter()
    client = connect(port)

    for type <- [1, 6, 2] do
      send_query(client, "example.com.", type)
      assert {:ok, response} = receive_response(client)
      assert [%{type: %{value: <<^type::16>>}}] = response.qdlist
    end

    send_query(client, "ns1.example.com.", 1)
    send_query(client, "example.com.", 6)
    assert {:ok, %{anlist: [%{type: %{value: <<1::16>>}}]}} = receive_response(client)
    assert {:ok, %{anlist: [%{type: %{value: <<6::16>>}}]}} = receive_response(client)
  end

  test "malformed and oversized frames close only their own session" do
    {adapter, port} = adapter()
    original = :sys.get_state(adapter)

    for frame <- [<<11::16>>, <<4097::16>>, <<12::16, 0::96>>] do
      bad = connect(port)
      :ok = :gen_tcp.send(bad, frame)
      assert {:error, :closed} = :gen_tcp.recv(bad, 0, 3000)
      assert {:ok, _} = query(:tcp, port, "ns1.example.com.", 1)
      assert {:ok, _} = query(:udp, port, "ns1.example.com.", 1)
      assert :sys.get_state(adapter).acceptor == original.acceptor
      assert :sys.get_state(adapter).udp == original.udp
    end
  end

  test "a failed TCP handler does not restart listeners or interrupt another session" do
    {adapter, port} = adapter()
    bad = connect(port)
    handler = accepted_owner(bad)
    good = connect(port)
    original = :sys.get_state(adapter)
    monitor = Process.monitor(handler)
    Process.exit(handler, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^handler, :killed}
    assert {:error, :closed} = :gen_tcp.recv(bad, 0, 1000)
    send_query(good, "ns1.example.com.", 1)
    assert {:ok, _} = receive_response(good)
    assert {:ok, _} = query(:udp, port, "ns1.example.com.", 1)
    assert :sys.get_state(adapter).acceptor == original.acceptor
    assert :sys.get_state(adapter).udp == original.udp
  end

  test "TCP idle and incomplete body deadlines close their sessions" do
    {_adapter, port} = adapter()
    idle = connect(port)
    accepted_owner(idle)
    assert {:error, :closed} = :gen_tcp.recv(idle, 0, 3000)
    partial = connect(port)
    :ok = :gen_tcp.send(partial, <<40::16, 1, 2>>)
    assert {:error, :closed} = :gen_tcp.recv(partial, 0, 3000)
    assert {:ok, _} = query(:tcp, port, "ns1.example.com.", 1)
  end

  test "a fragmented valid frame is completed independently of another client" do
    {_adapter, port} = adapter()
    client = connect(port)
    wire = packet("ns1.example.com.", 1)
    <<first, rest::binary>> = <<byte_size(wire)::16, wire::binary>>
    :ok = :gen_tcp.send(client, <<first>>)
    accepted_owner(client)
    assert {:ok, _} = query(:tcp, port, "example.com.", 6)
    :ok = :gen_tcp.send(client, rest)
    assert {:ok, %{anlist: [%{data: %{data: {192, 0, 2, 53}}}]}} = receive_response(client)
  end

  test "a client that stops reading cannot retain a handler past the send deadline" do
    zone =
      update_in(resource("192.0.2.53"), ["content", "records"], fn records ->
        [soa, ns, address] = records
        [soa, ns | for(_index <- 1..1800, do: address)]
      end)

    {adapter, port} = adapter([zone])

    {:ok, client} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        port,
        [:binary, active: false, recbuf: 1024, buffer: 2048],
        1000
      )

    on_exit(fn -> :gen_tcp.close(client) end)
    handler = accepted_owner(client)
    monitor = Process.monitor(handler)
    wire = packet("ns1.example.com.", 1)
    frame = <<byte_size(wire)::16, wire::binary>>
    :ok = :gen_tcp.send(client, :binary.copy(frame, 256))
    assert queued_send?(handler, System.monotonic_time(:millisecond) + 2000)
    assert {:ok, _} = query(:tcp, port, "example.com.", 6)
    assert {:ok, _} = query(:udp, port, "example.com.", 6)
    assert_receive {:DOWN, ^monitor, :process, ^handler, _}, 3000
    assert DnsAdapter.status(adapter).ready
  end

  test "TCP connection capacity is bounded and becomes reusable after a client exits" do
    {adapter, port} = adapter()
    state = :sys.get_state(adapter)
    assert is_pid(Map.get(state, :sessions))

    clients =
      for _index <- 1..32 do
        client = connect(port)
        accepted_owner(client)
        client
      end

    assert length(Task.Supervisor.children(state.sessions)) == 32
    excess = connect(port)
    assert {:error, :closed} = :gen_tcp.recv(excess, 0, 500)
    [first | _rest] = clients
    handler = accepted_owner(first)
    monitor = Process.monitor(handler)
    :gen_tcp.close(first)
    assert_receive {:DOWN, ^monitor, :process, ^handler, _}, 1000
    assert {:ok, _} = query(:tcp, port, "ns1.example.com.", 1)
  end

  test "stop observes active TCP handlers and listeners terminating" do
    {adapter, port} = adapter()
    clients = for _index <- 1..3, do: connect(port)
    handlers = Enum.map(clients, &accepted_owner/1)
    monitors = Enum.map(handlers, &{&1, Process.monitor(&1)})
    assert :ok = GenServer.stop(adapter)

    for {handler, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^handler, _}, 1000
    end

    for client <- clients, do: assert({:error, :closed} == :gen_tcp.recv(client, 0, 500))
    assert_listeners_closed(port)
  end

  test "negative SOA TTL is capped without changing positive TTL or any SOA RDATA" do
    for {ttl, minimum} <- [{3600, 60}, {60, 3600}, {3600, 0}], transport <- [:udp, :tcp] do
      zone =
        resource("192.0.2.53")
        |> put_in(["content", "records", Access.at(0), "ttl"], ttl)
        |> put_in(["content", "records", Access.at(0), "data", "minimum"], minimum)
        |> update_in(["content", "records"], fn records ->
          records ++
            [
              %{
                "name" => "leaf.branch.example.com.",
                "type" => "A",
                "ttl" => 300,
                "data" => %{"address" => "192.0.2.1"}
              }
            ]
        end)

      {adapter, port} = adapter([zone])
      assert {:ok, %{anlist: [positive]}} = query(transport, port, "example.com.", 6)
      assert positive.ttl == ttl

      for {name, type, rcode} <- [
            {"absent.example.com.", 1, 3},
            {"ns1.example.com.", 2, 0},
            {"branch.example.com.", 1, 0}
          ] do
        assert {:ok, negative} = query(transport, port, name, type)
        assert negative.header.rcode.value == <<rcode::4>>
        assert negative.header.aa == 1
        assert negative.anlist == []
        assert [authority] = negative.nslist
        assert authority == %{positive | ttl: min(ttl, minimum)}
      end

      assert {:ok, %{anlist: [^positive]}} = query(transport, port, "example.com.", 6)
      assert :ok = GenServer.stop(adapter)
      assert_listeners_closed(port)
    end
  end

  test "serves authoritative SOA, NS, A and negative replies over UDP and TCP; swaps content" do
    port = free_port()
    service = service(port)
    resource = resource("192.0.2.53")

    adapter =
      start_supervised!({DnsAdapter, service: service, resources: [resource]},
        restart: :temporary
      )

    assert DnsAdapter.status(adapter).ready

    assert DnsAdapter.status(adapter).loaded_resources == [
             %{"id" => "zone-example", "version" => 1, "digest" => "one"}
           ]

    for transport <- [:udp, :tcp] do
      assert {:ok, a} = query(transport, port, "ns1.example.com.", 1)
      assert a.header.aa == 1
      assert a.header.rcode.value == <<0::4>>
      assert Enum.map(a.anlist, & &1.data.data) == [{192, 0, 2, 53}]

      assert {:ok, ns} = query(transport, port, "example.com.", 2)
      assert length(ns.anlist) == 1
      assert to_string(hd(ns.anlist).data.data) == "ns1.example.com."

      assert {:ok, soa} = query(transport, port, "example.com.", 6)
      assert length(soa.anlist) == 1

      assert {:ok, nxdomain} = query(transport, port, "absent.example.com.", 1)
      assert nxdomain.header.aa == 1
      assert nxdomain.header.rcode.value == <<3::4>>
      assert length(nxdomain.nslist) == 1

      assert {:ok, nodata} = query(transport, port, "ns1.example.com.", 2)
      assert nodata.header.rcode.value == <<0::4>>
      assert nodata.anlist == []
      assert length(nodata.nslist) == 1
    end

    assert :ok = DnsAdapter.update(adapter, service, [resource("192.0.2.54", 2)])
    assert {:ok, changed} = query(:udp, port, "ns1.example.com.", 1)
    assert Enum.map(changed.anlist, & &1.data.data) == [{192, 0, 2, 54}]

    assert {:error, :listener_change_requires_restart} =
             DnsAdapter.update(adapter, service(port + 1), [resource])

    assert {:ok, unchanged} = query(:tcp, port, "ns1.example.com.", 1)
    assert Enum.map(unchanged.anlist, & &1.data.data) == [{192, 0, 2, 54}]

    assert :ok = stop_supervised(DnsAdapter)
    assert_listeners_closed(port)
  end

  test "abrupt adapter death closes both listeners and permits recovery on the same port" do
    port = free_port()
    service = service(port)
    resources = [resource("192.0.2.53")]

    adapter =
      start_supervised!({DnsAdapter, service: service, resources: resources}, restart: :temporary)

    monitor = Process.monitor(adapter)
    state = :sys.get_state(adapter)
    pool = Abyss.Server.listener_pool_pid(state.udp)

    listener_monitors =
      for pid <- [state.udp, state.acceptor | Abyss.ListenerPool.listener_pids(pool)] do
        {pid, Process.monitor(pid)}
      end

    assert {:ok, _} = query(:udp, port, "ns1.example.com.", 1)
    assert {:ok, _} = query(:tcp, port, "ns1.example.com.", 1)
    assert {:error, :eaddrinuse} = exclusive_udp_listener(port)

    Process.exit(adapter, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^adapter, :killed}, 2_000

    for {pid, ref} <- listener_monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end

    assert_listeners_closed(port)

    assert {:error, _} =
             Abyss.Client.send_recv({127, 0, 0, 1}, port, packet("ns1.example.com.", 1), 200)

    recovered =
      start_supervised!({DnsAdapter, service: service, resources: resources},
        id: :recovered,
        restart: :temporary
      )

    assert DnsAdapter.status(recovered).ready
    assert {:ok, _} = query(:udp, port, "ns1.example.com.", 1)
    assert {:ok, _} = query(:tcp, port, "ns1.example.com.", 1)
    assert :ok = stop_supervised(:recovered)
    assert_listeners_closed(port)
  end

  defp assert_listeners_closed(port) do
    assert {:error, :econnrefused} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)

    assert {:ok, socket} = exclusive_udp_listener(port)
    assert :ok = Abyss.Transport.UDP.Unicast.close(socket)
  end

  defp adapter(resources \\ [resource("192.0.2.53")]) do
    port = free_port()

    adapter =
      start_supervised!({DnsAdapter, service: service(port), resources: resources},
        id: make_ref(),
        restart: :temporary
      )

    {adapter, port}
  end

  defp connect(port) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    socket
  end

  defp accepted_owner(client) do
    {:ok, {_, client_port}} = :inet.sockname(client)
    deadline = System.monotonic_time(:millisecond) + 1000
    accepted_owner(client_port, deadline)
  end

  defp accepted_owner(client_port, deadline) do
    owner =
      Enum.find_value(:erlang.ports(), fn socket ->
        with {:ok, {{127, 0, 0, 1}, ^client_port}} <- :inet.peername(socket),
             {:connected, owner} <- :erlang.port_info(socket, :connected),
             {:current_stacktrace, stack} <- Process.info(owner, :current_stacktrace),
             true <-
               Enum.any?(stack, fn {module, function, _, _} ->
                 module == :prim_inet and function in [:recv0, :recv]
               end) do
          owner
        else
          _ -> nil
        end
      end)

    cond do
      is_pid(owner) -> owner
      System.monotonic_time(:millisecond) < deadline -> accepted_owner(client_port, deadline)
      true -> flunk("accepted TCP client did not reach its blocking receive")
    end
  end

  defp queued_send?(handler, deadline) do
    queued =
      Enum.any?(:erlang.ports(), fn socket ->
        :erlang.port_info(socket, :connected) == {:connected, handler} and
          case :erlang.port_info(socket, :queue_size) do
            {:queue_size, size} -> size > 0
            _ -> false
          end
      end)

    cond do
      queued -> true
      System.monotonic_time(:millisecond) < deadline -> queued_send?(handler, deadline)
      true -> false
    end
  end

  defp send_query(client, name, type) do
    wire = packet(name, type)
    :ok = :gen_tcp.send(client, <<byte_size(wire)::16, wire::binary>>)
  end

  defp receive_response(client, timeout \\ 1000) do
    with {:ok, <<size::16>>} <- :gen_tcp.recv(client, 2, timeout),
         {:ok, wire} <- :gen_tcp.recv(client, size, timeout) do
      {:ok, Message.from_iodata(wire)}
    end
  end

  defp exclusive_udp_listener(port) do
    Abyss.Transport.UDP.Unicast.listen(port,
      ip: {127, 0, 0, 1},
      reuseaddr: false,
      reuseport: false
    )
  end

  defp query(:udp, port, name, type) do
    with {:ok, wire} <- Abyss.Client.send_recv({127, 0, 0, 1}, port, packet(name, type), 2_000) do
      {:ok, Message.from_iodata(wire)}
    end
  end

  defp query(:tcp, port, name, type) do
    with {:ok, socket} <- :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000) do
      packet = packet(name, type)
      :ok = :gen_tcp.send(socket, <<byte_size(packet)::16, packet::binary>>)

      result =
        with {:ok, <<length::16>>} <- :gen_tcp.recv(socket, 2, 2_000),
             {:ok, wire} <- :gen_tcp.recv(socket, length, 2_000) do
          {:ok, Message.from_iodata(wire)}
        end

      :gen_tcp.close(socket)
      result
    end
  end

  defp packet(name, type) do
    Message.new()
    |> Message.add_question(Question.new(name, type, 1))
    |> DNS.to_iodata()
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp service(port) do
    %{
      "id" => "dns-primary",
      "type" => "dns",
      "desired_state" => "running",
      "config" => %{"listen_address" => "127.0.0.1", "port" => port},
      "resources" => ["zone-example"]
    }
  end

  defp resource(address, version \\ 1) do
    %{
      "id" => "zone-example",
      "type" => "dns_zone",
      "schema_version" => 1,
      "version" => version,
      "digest" => if(version == 1, do: "one", else: "two"),
      "content" => %{
        "name" => "example.com.",
        "records" => [
          %{
            "name" => "example.com.",
            "type" => "SOA",
            "ttl" => 3600,
            "data" => %{
              "mname" => "ns1.example.com.",
              "rname" => "hostmaster.example.com.",
              "serial" => 2_026_093_001,
              "refresh" => 3600,
              "retry" => 600,
              "expire" => 86400,
              "minimum" => 300
            }
          },
          %{
            "name" => "example.com.",
            "type" => "NS",
            "ttl" => 3600,
            "data" => %{"host" => "ns1.example.com."}
          },
          %{
            "name" => "ns1.example.com.",
            "type" => "A",
            "ttl" => 300,
            "data" => %{"address" => address}
          }
        ]
      }
    }
  end
end
