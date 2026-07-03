defmodule YellowDog.DhcpClient.DhcpSocket.UdpFallbackTest do
  use ExUnit.Case, async: true

  alias YellowDog.DhcpClient.DhcpSocket.UdpFallback

  describe "open/2" do
    test "returns {:ok, ref} with a reference" do
      {:ok, ref} = UdpFallback.open("eth0", self())
      assert is_reference(ref)
      UdpFallback.close(ref)
    end
  end

  describe "send_arp_probe/2" do
    test "returns {:error, :not_supported}" do
      {:ok, ref} = UdpFallback.open("eth0", self())
      assert {:error, :not_supported} = UdpFallback.send_arp_probe(ref, {192, 168, 1, 50})
      UdpFallback.close(ref)
    end
  end

  describe "close/1" do
    test "returns :ok and cleans up the persistent_term entry" do
      {:ok, ref} = UdpFallback.open("eth0", self())
      assert :ok = UdpFallback.close(ref)
      # Second close is also safe (returns :ok on missing entry)
      assert :ok = UdpFallback.close(ref)
    end
  end
end

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

    test "forwards NIF-delivered {:dhcp_rx, data} to the owner" do
      {:ok, socket_pid} =
        DhcpSocket.start_link(interface: "eth0", owner: self(), impl: NoOpSocketImpl)

      on_exit(fn -> if Process.alive?(socket_pid), do: GenServer.stop(socket_pid) end)

      # The native NIF delivers packets directly as {:dhcp_rx, binary}
      send(socket_pid, {:dhcp_rx, "nif-data"})

      assert_receive {:dhcp_rx, "nif-data"}, 500
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

  describe "close/1" do
    test "stops the GenServer process" do
      {:ok, pid} = DhcpSocket.start_link(interface: "eth0", owner: self(), impl: NoOpSocketImpl)
      assert Process.alive?(pid)

      DhcpSocket.close(pid)

      # Give the process a moment to stop
      Process.sleep(50)
      refute Process.alive?(pid)
    end
  end

  describe "init/1 failure" do
    defmodule FailingSocketImpl do
      @moduledoc false
      @behaviour YellowDog.DhcpClient.DhcpSocket
      @impl true
      def open(_interface, _owner), do: {:error, :eacces}
      @impl true
      def send_broadcast(_ref, _packet), do: :ok
      @impl true
      def send_unicast(_ref, _dest, _packet), do: :ok
      @impl true
      def send_arp_probe(_ref, _ip), do: :ok
      @impl true
      def close(_ref), do: :ok
    end

    test "start_link returns {:error, reason} when impl.open fails" do
      # trap_exit so the EXIT signal from the failed GenServer becomes a message
      Process.flag(:trap_exit, true)
      result = DhcpSocket.start_link(interface: "eth0", owner: self(), impl: FailingSocketImpl)
      assert {:error, :eacces} = result
    end
  end

  describe "NIF socket status messages" do
    test "stops with {:dhcp_socket_down, reason} when the poll thread dies" do
      Process.flag(:trap_exit, true)

      {:ok, socket_pid} =
        DhcpSocket.start_link(interface: "eth0", owner: self(), impl: NoOpSocketImpl)

      send(socket_pid, {:dhcp_socket_down, :recv_error})

      assert_receive {:EXIT, ^socket_pid, {:dhcp_socket_down, :recv_error}}, 500
    end

    test "stays alive and keeps forwarding after {:arp_socket_down, reason}" do
      {:ok, socket_pid} =
        DhcpSocket.start_link(interface: "eth0", owner: self(), impl: NoOpSocketImpl)

      on_exit(fn -> if Process.alive?(socket_pid), do: GenServer.stop(socket_pid) end)

      send(socket_pid, {:arp_socket_down, :socket_error})
      send(socket_pid, {:dhcp_rx, "still-working"})

      assert_receive {:dhcp_rx, "still-working"}, 500
      assert Process.alive?(socket_pid)
    end
  end

  describe "packet forwarding to atom-named owner" do
    test "forwards {:dhcp_rx, data} to a registered atom owner" do
      atom_name = :"test_atom_owner_#{:erlang.unique_integer([:positive])}"
      Process.register(self(), atom_name)

      on_exit(fn ->
        try do
          Process.unregister(atom_name)
        rescue
          ArgumentError -> :ok
        end
      end)

      {:ok, socket_pid} =
        DhcpSocket.start_link(interface: "eth0", owner: atom_name, impl: NoOpSocketImpl)

      on_exit(fn -> if Process.alive?(socket_pid), do: GenServer.stop(socket_pid) end)

      send(socket_pid, {:udp, make_ref(), {192, 168, 1, 1}, 67, "atom-data"})

      assert_receive {:dhcp_rx, "atom-data"}, 500
    end
  end
end
