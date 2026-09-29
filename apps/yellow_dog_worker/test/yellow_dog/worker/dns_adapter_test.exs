defmodule YellowDog.Worker.DnsAdapterTest do
  use ExUnit.Case, async: false

  alias DNS.Message
  alias DNS.Message.Question
  alias YellowDog.Worker.DnsAdapter

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
