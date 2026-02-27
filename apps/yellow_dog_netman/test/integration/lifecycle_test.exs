defmodule YellowDog.Netman.Integration.LifecycleTest do
  @moduledoc """
  Integration tests for the full connection lifecycle:
  interface detected → profile matched → FSM activated → carrier lost → deactivated
  """
  use ExUnit.Case

  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  setup do
    # Create a unique interface name per test to avoid collisions
    iface = "integ_eth#{:rand.uniform(65535)}"

    profile = %Profile{
      id: "integ-profile-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile.id, profile)

    on_exit(fn ->
      # Clean up the connection if still running
      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile.id)
    end)

    %{iface: iface, profile: profile}
  end

  test "start connection and get state", %{iface: iface, profile: profile} do
    # Simulate interface appearing
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    # Start a connection via the supervisor
    assert {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    # Verify the FSM reaches :activated (ipv4 is :disabled, so no DHCP/IP needed)
    {:ok, pid} = Connection.Supervisor.find_connection(iface)
    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.interface == iface
    assert state.profile_id == profile.id
    assert state.state == :activated
  end

  test "connection deactivates on explicit deactivate", %{iface: iface, profile: profile} do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    {:ok, pid} = Connection.Supervisor.find_connection(iface)
    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :activated

    # Deactivate
    Connection.FSM.deactivate(pid)
    Process.sleep(100)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :disconnected
  end

  test "list_connections shows active connections", %{iface: iface, profile: profile} do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    connections = Connection.Supervisor.list_connections()
    conn = Enum.find(connections, &(&1.interface == iface))
    assert conn != nil
    assert conn.profile_id == profile.id
  end

  test "find_connection_by_profile locates the FSM", %{iface: iface, profile: profile} do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    assert {:ok, pid} = Connection.Supervisor.find_connection_by_profile(profile.id)
    assert is_pid(pid)
  end

  test "stop_connection terminates the FSM", %{iface: iface, profile: profile} do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(50)

    assert :ok = Connection.Supervisor.stop_connection(iface)
    Process.sleep(50)

    assert :error = Connection.Supervisor.find_connection(iface)
  end

  test "connection starts in :unavailable when no link exists", %{profile: profile} do
    no_link_iface = "nolink_#{:rand.uniform(65535)}"

    profile = %{profile | id: "nolink-#{no_link_iface}", interface: no_link_iface}
    ProfileStore.put(profile.id, profile)

    {:ok, _pid} = Connection.Supervisor.start_connection(no_link_iface, profile)
    Process.sleep(50)

    {:ok, pid} = Connection.Supervisor.find_connection(no_link_iface)
    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :unavailable

    # Clean up
    Connection.Supervisor.stop_connection(no_link_iface)
    ProfileStore.delete(profile.id)
  end

  test "static IP connection transitions through configuring", %{iface: iface} do
    static_profile = %Profile{
      id: "static-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 50,
      ethernet: %{mtu: nil},
      ipv4: %{method: :manual, address: "192.168.99.10/24", gateway: "192.168.99.1", dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(static_profile.id, static_profile)

    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, static_profile)

    # Simulate address being assigned (the mock netlink backend accepts the command)
    MockNetlink.address_added(iface, "192.168.99.10/24")

    # Wait for ip_check retry (2s state_timeout) to detect the global address
    {:ok, pid} = Connection.Supervisor.find_connection(iface)

    # Poll until activated or timeout
    result =
      Enum.reduce_while(1..30, :ip_check, fn _, _acc ->
        Process.sleep(100)

        case Connection.FSM.get_state(pid) do
          {:ok, %{state: :activated}} -> {:halt, :activated}
          {:ok, %{state: s}} -> {:cont, s}
          _ -> {:cont, :unknown}
        end
      end)

    assert result == :activated

    Connection.Supervisor.stop_connection(iface)
    ProfileStore.delete(static_profile.id)
  end
end
