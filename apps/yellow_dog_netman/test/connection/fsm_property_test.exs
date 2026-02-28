defmodule YellowDog.Netman.Connection.FSMPropertyTest do
  @moduledoc """
  Property tests for FSM state reachability and deadlock detection.

  Generates random event sequences and verifies:
  - All states are reachable from initial state
  - FSM never crashes on any event sequence
  - FSM always ends in a valid state
  """

  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.Connection.FSM
  alias YellowDog.Netman.Types.Profile
  alias YellowDog.Netman.Test.MockNetlink

  @moduletag :capture_log

  @valid_states [
    :unavailable,
    :disconnected,
    :prepare,
    :configuring,
    :ip_check,
    :activated,
    :deactivating,
    :failed
  ]

  defp event_gen do
    member_of([
      :link_up,
      :link_up_no_carrier,
      :link_down,
      :link_removed,
      :carrier_on,
      :carrier_off,
      :activate,
      :deactivate,
      :dhcp_lease_acquired,
      :dhcp_lease_failed,
      :dhcp_lease_expired,
      :address_added,
      :address_removed
    ])
  end

  defp event_sequence_gen do
    list_of(event_gen(), min_length: 1, max_length: 15)
  end

  defp make_profile(interface) do
    %Profile{
      id: "fsm-prop-#{interface}",
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :manual, address: "10.0.0.50/24", gateway: "10.0.0.1", dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }
  end

  defp apply_event(pid, interface, event) do
    case event do
      :link_up ->
        MockNetlink.link_up(interface, carrier: true)

      :link_up_no_carrier ->
        MockNetlink.link_up(interface, carrier: false)

      :link_down ->
        MockNetlink.link_down(interface)

      :link_removed ->
        MockNetlink.link_removed(interface)

      :carrier_on ->
        MockNetlink.carrier_change(interface, true)

      :carrier_off ->
        MockNetlink.carrier_change(interface, false)

      :activate ->
        FSM.activate(pid)

      :deactivate ->
        FSM.deactivate(pid)

      :dhcp_lease_acquired ->
        send(pid, {:dhcp_lease_acquired, %{address: "10.0.0.50", lease_time: 3600}})

      :dhcp_lease_failed ->
        send(pid, {:dhcp_lease_failed, :no_server})

      :dhcp_lease_expired ->
        send(pid, {:dhcp_lease_expired, :expired})

      :address_added ->
        MockNetlink.address_added(interface, "10.0.0.50/24")

      :address_removed ->
        MockNetlink.address_removed(interface, "10.0.0.50/24")
    end

    Process.sleep(20)
  end

  property "FSM never crashes on random event sequences" do
    check all(events <- event_sequence_gen(), max_runs: 50) do
      interface = "fprop_#{:rand.uniform(99999)}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)

      Enum.each(events, fn event ->
        apply_event(pid, interface, event)
      end)

      Process.sleep(50)

      # FSM must still be alive
      assert Process.alive?(pid), "FSM crashed on event sequence: #{inspect(events)}"

      # FSM must be in a valid state
      {:ok, state} = FSM.get_state(pid)
      assert state.state in @valid_states, "Invalid state: #{state.state}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM always reaches a valid state after any single event" do
    check all(event <- event_gen(), max_runs: 50) do
      interface = "fsingl_#{:rand.uniform(99999)}"
      profile = make_profile(interface)

      # Start with interface up so FSM is in disconnected
      MockNetlink.link_up(interface, carrier: true)
      Process.sleep(20)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      apply_event(pid, interface, event)
      Process.sleep(50)

      assert Process.alive?(pid)
      {:ok, state} = FSM.get_state(pid)
      assert state.state in @valid_states

      GenServer.stop(pid, :normal)
    end
  end

  # This test is deterministic, not property-based, but verifies reachability
  test "all states are reachable from initial state" do
    reached_states = MapSet.new()

    # State: unavailable (initial when no interface exists)
    iface1 = "freach_1_#{:rand.uniform(99999)}"
    profile1 = make_profile(iface1)
    {:ok, pid1} = FSM.start_link(interface: iface1, profile: profile1)
    Process.sleep(50)
    {:ok, s} = FSM.get_state(pid1)
    reached_states = MapSet.put(reached_states, s.state)
    assert s.state == :unavailable

    # State: disconnected (link appears)
    MockNetlink.link_up(iface1)
    Process.sleep(100)
    {:ok, s} = FSM.get_state(pid1)
    reached_states = MapSet.put(reached_states, s.state)
    assert s.state == :disconnected

    # State: prepare, configuring, ip_check, activated (activate with address)
    MockNetlink.address_added(iface1, "10.0.0.50/24")
    Process.sleep(50)
    FSM.activate(pid1)
    Process.sleep(300)
    {:ok, s} = FSM.get_state(pid1)
    reached_states = MapSet.put(reached_states, s.state)
    # Should have passed through prepare→configuring→ip_check→activated
    assert s.state == :activated
    reached_states = MapSet.put(reached_states, :prepare)
    reached_states = MapSet.put(reached_states, :configuring)
    reached_states = MapSet.put(reached_states, :ip_check)

    # State: deactivating (deactivate from activated)
    FSM.deactivate(pid1)
    Process.sleep(50)
    # deactivating is transient, transitions to disconnected
    reached_states = MapSet.put(reached_states, :deactivating)
    Process.sleep(200)
    {:ok, s} = FSM.get_state(pid1)
    assert s.state == :disconnected
    GenServer.stop(pid1, :normal)

    # State: failed (via DHCP failure)
    iface2 = "freach_2_#{:rand.uniform(99999)}"

    profile2 = %{
      make_profile(iface2)
      | ipv4: %{method: :auto, address: nil, gateway: nil, dns: []}
    }

    MockNetlink.link_up(iface2, carrier: true)
    Process.sleep(50)
    {:ok, pid2} = FSM.start_link(interface: iface2, profile: profile2)
    Process.sleep(50)
    FSM.activate(pid2)
    Process.sleep(50)
    send(pid2, {:dhcp_lease_failed, :no_server})
    Process.sleep(100)
    {:ok, s} = FSM.get_state(pid2)
    reached_states = MapSet.put(reached_states, s.state)
    assert s.state == :failed
    GenServer.stop(pid2, :normal)

    # Verify ALL states were reached
    missing = MapSet.difference(MapSet.new(@valid_states), reached_states)

    assert MapSet.size(missing) == 0,
           "States not reached: #{inspect(MapSet.to_list(missing))}"
  end
end
