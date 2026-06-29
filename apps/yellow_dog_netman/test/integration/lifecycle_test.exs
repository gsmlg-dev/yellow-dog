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

  @moduletag :integration

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

    # Delete profile first so ReconciliationEngine doesn't re-spawn the FSM
    # (autoconnect=true + link up + profile in store = reconciliation re-activates)
    ProfileStore.delete(profile.id)

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

  test "carrier loss deactivates connection, carrier return re-activates", %{
    iface: iface,
    profile: profile
  } do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(100)

    {:ok, pid} = Connection.Supervisor.find_connection(iface)
    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :activated

    # Simulate carrier loss (cable unplug)
    MockNetlink.carrier_change(iface, false)
    Process.sleep(150)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :disconnected

    # Simulate carrier return (cable plug back in)
    MockNetlink.carrier_change(iface, true)
    Process.sleep(150)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :activated
  end

  test "multiple interfaces activate concurrently with independent FSMs", %{profile: profile} do
    iface1 = "multi_eth#{:rand.uniform(65535)}"
    iface2 = "multi_eth#{:rand.uniform(65535)}"

    profile1 = %{profile | id: "multi-profile-#{iface1}", interface: iface1}
    profile2 = %{profile | id: "multi-profile-#{iface2}", interface: iface2}

    ProfileStore.put(profile1.id, profile1)
    ProfileStore.put(profile2.id, profile2)

    MockNetlink.link_up(iface1, carrier: true)
    MockNetlink.link_up(iface2, carrier: true)
    Process.sleep(50)

    {:ok, pid1} = Connection.Supervisor.start_connection(iface1, profile1)
    {:ok, pid2} = Connection.Supervisor.start_connection(iface2, profile2)
    Process.sleep(150)

    {:ok, state1} = Connection.FSM.get_state(pid1)
    {:ok, state2} = Connection.FSM.get_state(pid2)

    assert state1.interface == iface1
    assert state1.state == :activated

    assert state2.interface == iface2
    assert state2.state == :activated

    refute pid1 == pid2

    connections = Connection.Supervisor.list_connections()
    ifaces = Enum.map(connections, & &1.interface)
    assert iface1 in ifaces
    assert iface2 in ifaces

    # Deactivating one leaves the other running
    Connection.Supervisor.stop_connection(iface1)
    Process.sleep(50)

    assert :error = Connection.Supervisor.find_connection(iface1)
    assert {:ok, _} = Connection.Supervisor.find_connection(iface2)

    Connection.Supervisor.stop_connection(iface2)
    ProfileStore.delete(profile1.id)
    ProfileStore.delete(profile2.id)
  end

  test "higher priority connection gets lower route metric" do
    iface_hi = "prio_eth#{:rand.uniform(65535)}"
    iface_lo = "prio_eth#{:rand.uniform(65535)}"

    profile_hi = %Profile{
      id: "hi-priority-#{iface_hi}",
      type: :ethernet,
      interface: iface_hi,
      autoconnect: true,
      autoconnect_priority: 500,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    profile_lo = %Profile{
      id: "lo-priority-#{iface_lo}",
      type: :ethernet,
      interface: iface_lo,
      autoconnect: true,
      autoconnect_priority: 50,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile_hi.id, profile_hi)
    ProfileStore.put(profile_lo.id, profile_lo)

    MockNetlink.link_up(iface_hi, carrier: true)
    MockNetlink.link_up(iface_lo, carrier: true)
    Process.sleep(50)

    {:ok, pid_hi} = Connection.Supervisor.start_connection(iface_hi, profile_hi)
    {:ok, pid_lo} = Connection.Supervisor.start_connection(iface_lo, profile_lo)
    Process.sleep(150)

    {:ok, state_hi} = Connection.FSM.get_state(pid_hi)
    {:ok, state_lo} = Connection.FSM.get_state(pid_lo)

    assert state_hi.state == :activated
    assert state_lo.state == :activated

    connections = [state_hi, state_lo]
    metrics = YellowDog.Netman.PolicyEngine.route_metrics(connections)

    metric_hi = Map.get(metrics, profile_hi.id)
    metric_lo = Map.get(metrics, profile_lo.id)

    assert metric_hi < metric_lo,
           "Higher autoconnect_priority should yield a lower route metric"

    Connection.Supervisor.stop_connection(iface_hi)
    Connection.Supervisor.stop_connection(iface_lo)
    ProfileStore.delete(profile_hi.id)
    ProfileStore.delete(profile_lo.id)
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
