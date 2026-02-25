defmodule YellowDog.DhcpClient.DhcpSocketTest do
  use ExUnit.Case, async: true

  alias YellowDog.DhcpClient.DhcpSocket

  defmodule NoOpSocketImpl do
    @moduledoc false
    @behaviour YellowDog.DhcpClient.DhcpSocket
    @impl true
    def open(_interface, _owner), do: {:ok, make_ref()}
    @impl true
    def send_broadcast(_ref, _packet), do: :ok
    @impl true
    def send_unicast(_ref, _dest, _packet), do: :ok
    @impl true
    def send_arp_probe(_ref, _ip), do: :ok
    @impl true
    def close(_ref), do: :ok
  end

  # ── forward_to_owner with different owner types ──

  describe "packet forwarding to owner" do
    test "forwards {:dhcp_rx, data} to a PID owner" do
      {:ok, socket_pid} =
        DhcpSocket.start_link(interface: "eth0", owner: self(), impl: NoOpSocketImpl)

      on_exit(fn -> if Process.alive?(socket_pid), do: GenServer.stop(socket_pid) end)

      # Simulate a UDP packet arriving at the socket process
      send(socket_pid, {:udp, make_ref(), {192, 168, 1, 1}, 67, "dhcp-data"})

      assert_receive {:dhcp_rx, "dhcp-data"}, 500
    end

    test "forwards {:dhcp_rx, data} to a via-name owner (regression for crash bug)" do
      # Create a temporary registry for this test
      registry_name = :"test_reg_#{:erlang.unique_integer([:positive])}"
      {:ok, _registry_pid} = Registry.start_link(keys: :unique, name: registry_name)
      owner_key = :test_owner
      via_name = {:via, Registry, {registry_name, owner_key}}

      # Register the test process under the via-name
      {:ok, _} = Registry.register(registry_name, owner_key, nil)

      {:ok, socket_pid} =
        DhcpSocket.start_link(interface: "eth0", owner: via_name, impl: NoOpSocketImpl)

      on_exit(fn -> if Process.alive?(socket_pid), do: GenServer.stop(socket_pid) end)

      # Simulate a UDP packet arriving
      send(socket_pid, {:udp, make_ref(), {192, 168, 1, 1}, 67, "via-data"})

      # The socket must resolve the via-name and forward to the registered PID (self())
      assert_receive {:dhcp_rx, "via-data"}, 500
    end

    test "silently drops packet when via-name owner is not yet registered" do
      registry_name = :"test_reg_#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)
      # Note: we do NOT register the test process under this key
      unregistered_via = {:via, Registry, {registry_name, :nobody}}

      {:ok, socket_pid} =
        DhcpSocket.start_link(interface: "eth0", owner: unregistered_via, impl: NoOpSocketImpl)

      on_exit(fn -> if Process.alive?(socket_pid), do: GenServer.stop(socket_pid) end)

      # Simulate a UDP packet — should NOT crash the socket, just be dropped
      send(socket_pid, {:udp, make_ref(), {192, 168, 1, 1}, 67, "nobody-home"})

      # Socket should still be alive
      Process.sleep(50)
      assert Process.alive?(socket_pid)
    end
  end

  # ── send_broadcast and send_unicast ──

  describe "send_broadcast/2" do
    test "delegates to impl and returns :ok" do
      {:ok, pid} = DhcpSocket.start_link(interface: "eth0", owner: self(), impl: NoOpSocketImpl)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert :ok = DhcpSocket.send_broadcast(pid, <<1, 2, 3>>)
    end
  end

  describe "send_unicast/3" do
    test "delegates to impl and returns :ok" do
      {:ok, pid} = DhcpSocket.start_link(interface: "eth0", owner: self(), impl: NoOpSocketImpl)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert :ok = DhcpSocket.send_unicast(pid, {192, 168, 1, 1}, <<1, 2, 3>>)
    end
  end

  describe "send_arp_probe/2" do
    test "delegates to impl" do
      {:ok, pid} = DhcpSocket.start_link(interface: "eth0", owner: self(), impl: NoOpSocketImpl)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert :ok = DhcpSocket.send_arp_probe(pid, {192, 168, 1, 50})
    end
  end
end
