defmodule YellowDog.DhcpClient.DhcpSocket.NativeTest do
  use ExUnit.Case, async: true

  @socket Path.expand("../lib/yellow_dog/dhcp_client/dhcp_socket.ex", __DIR__)
  @adapter Path.expand("../lib/yellow_dog/dhcp_client/dhcp_socket/native.ex", __DIR__)

  test "adapts native resources and preserves the facade's operation contracts" do
    source = """
    ExUnit.start(autorun: false)
    import ExUnit.Assertions

    defmodule Abyss.DhcpSocket.Native do
      def open("failure", _owner), do: {:error, :eacces}
      def open(interface, owner) do
        socket = make_ref()
        send(owner, {:opened, interface, socket})
        socket
      end
      def send_broadcast(socket, packet) do
        send(self(), {:broadcast, socket, packet})
        :ok
      end
      def send_unicast(socket, destination, packet) do
        send(self(), {:unicast, socket, destination, packet})
        {:error, "socket closed"}
      end
      def send_arp_probe(socket, target) do
        send(self(), {:probe, socket, target})
        {:error, "ARP socket not available"}
      end
      def close(socket) do
        send(self(), {:closed, socket})
        :ok
      end
    end

    Code.require_file(#{inspect(@socket)})
    Code.require_file(#{inspect(@adapter)})
    alias YellowDog.DhcpClient.DhcpSocket.Native

    assert {:error, :eacces} = Native.open("failure", self())
    assert {:ok, socket} = Native.open("fixture0", self())
    assert_receive {:opened, "fixture0", ^socket}
    assert :ok = Native.send_broadcast(socket, [<<1>>, <<2>>])
    assert_receive {:broadcast, ^socket, [<<1>>, <<2>>]}
    assert {:error, "socket closed"} = Native.send_unicast(socket, {192, 0, 2, 1}, <<3>>)
    assert_receive {:unicast, ^socket, {192, 0, 2, 1}, <<3>>}
    assert {:error, "ARP socket not available"} = Native.send_arp_probe(socket, {192, 0, 2, 2})
    assert_receive {:probe, ^socket, {192, 0, 2, 2}}
    assert :ok = Native.close(socket)
    assert_receive {:closed, ^socket}
    """

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["--erl", "+S 2:2", "-e", source],
        stderr_to_stdout: true,
        env: [{"ERL_LIBS", nil}, {"ELIXIR_ERL_OPTIONS", nil}]
      )

    assert status == 0, output
  end
end
