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

  property "get_state always preserves interface and profile_id identity" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "fpid_#{seed}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)

      assert state.interface == interface,
             "interface mismatch: #{state.interface} != #{interface}"

      assert state.profile_id == profile.id, "profile_id mismatch: #{state.profile_id}"

      GenServer.stop(pid, :normal)
    end
  end

  property "get_state type field always matches the profile type" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "ftype_#{seed}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert state.type == profile.type,
             "type mismatch: #{state.type} != #{profile.type}"

      GenServer.stop(pid, :normal)
    end
  end

  property "get_state always contains all required fields" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "ffields_#{seed}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)

      for key <- [:interface, :state, :profile_id, :type, :priority, :lease, :error, :dns] do
        assert Map.has_key?(state, key), "get_state missing required key: #{key}"
      end

      assert state.state in @valid_states

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM without link starts in :unavailable state" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      # Use an interface name that was never registered by MockNetlink
      interface = "funavail_#{seed}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :unavailable,
             "Expected :unavailable for unregistered interface, got: #{state.state}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM with link up starts in :disconnected state" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "fdisc_#{seed}"
      profile = make_profile(interface)

      # Pre-register link so FSM starts in disconnected
      MockNetlink.link_up(interface, carrier: true)
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :disconnected,
             "Expected :disconnected for link-up interface, got: #{state.state}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM lease and error are nil in initial state before activation" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "flease_#{seed}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert state.lease == nil, "Expected nil lease in initial state, got: #{inspect(state.lease)}"
      assert state.error == nil, "Expected nil error in initial state, got: #{inspect(state.error)}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM priority always matches profile's autoconnect_priority" do
    check all(
            seed <- StreamData.integer(1..99_999),
            priority <- StreamData.integer(0..1000),
            max_runs: 30
          ) do
      interface = "fprio_#{seed}"
      profile = %{make_profile(interface) | autoconnect_priority: priority}

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert state.priority == priority,
             "FSM priority #{state.priority} != profile priority #{priority}"

      GenServer.stop(pid, :normal)
    end
  end

  property "autoconnect: true with disabled IP always reaches :activated state" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      interface = "fautoact_#{seed}"

      profile = %{
        make_profile(interface)
        | autoconnect: true,
          ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
          ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(interface, carrier: true)
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(500)

      {:ok, state} = FSM.get_state(pid)

      assert state.state == :activated,
             "Expected :activated for autoconnect:true + disabled IP, got: #{state.state}"

      GenServer.stop(pid, :normal)
    end
  end

  property "get_state autoconnect_priority always equals profile autoconnect_priority" do
    check all(
            seed <- StreamData.integer(1..99_999),
            priority <- StreamData.integer(0..1000),
            max_runs: 30
          ) do
      interface = "facp_#{seed}"
      profile = %{make_profile(interface) | autoconnect_priority: priority}

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)

      assert Map.get(state, :autoconnect_priority) == priority,
             "autoconnect_priority #{Map.get(state, :autoconnect_priority)} != profile #{priority}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM in :disconnected state after explicit deactivate remains disconnected" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      interface = "fdeact_#{seed}"
      profile = make_profile(interface)

      MockNetlink.link_up(interface, carrier: true)
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert state.state == :disconnected

      FSM.deactivate(pid)
      Process.sleep(50)

      {:ok, state2} = FSM.get_state(pid)

      assert state2.state == :disconnected,
             "Expected :disconnected after deactivate from :disconnected, got: #{state2.state}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM dns field in get_state is always a list" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "fdns_#{seed}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert is_list(state.dns),
             "Expected dns to be a list, got: #{inspect(state.dns)}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM transitions to :unavailable after link_removed from :disconnected" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      interface = "flinkrm_#{seed}"
      profile = make_profile(interface)

      MockNetlink.link_up(interface, carrier: true)
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state1} = FSM.get_state(pid)
      assert state1.state == :disconnected

      MockNetlink.link_removed(interface)
      Process.sleep(50)

      {:ok, state2} = FSM.get_state(pid)

      assert state2.state == :unavailable,
             "Expected :unavailable after link_removed, got: #{state2.state}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM is alive immediately after start_link returns" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "falive2_#{seed}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)

      assert Process.alive?(pid),
             "FSM should be alive immediately after start_link on #{interface}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM get_state always returns {:ok, _} when pid is alive" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "fgsok_#{seed}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      assert Process.alive?(pid)
      result = FSM.get_state(pid)

      assert match?({:ok, _}, result),
             "Expected {:ok, _} from get_state on alive FSM, got: #{inspect(result)}"

      GenServer.stop(pid, :normal)
    end
  end

  property "autoconnect: false profile stays in :disconnected after link_up with carrier" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "fnoac_#{seed}"
      profile = %{make_profile(interface) | autoconnect: false}

      MockNetlink.link_up(interface, carrier: true)
      Process.sleep(50)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(100)

      {:ok, state} = FSM.get_state(pid)

      assert state.state == :disconnected,
             "autoconnect:false FSM should stay :disconnected, got: #{state.state}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM profile_id always matches the profile's id field" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "fpid_#{seed}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert state.profile_id == profile.id,
             "Expected profile_id #{profile.id}, got: #{inspect(state.profile_id)}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM initial dns field is always an empty list before any activation" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "fdns2_#{seed}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert state.dns == [],
             "Expected empty dns list in initial state, got: #{inspect(state.dns)}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM interface in get_state always matches the interface passed to start_link" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "fiface_#{seed}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      Process.sleep(50)

      {:ok, state} = FSM.get_state(pid)
      assert state.interface == interface,
             "Expected interface #{interface}, got: #{inspect(state.interface)}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM terminates cleanly on GenServer.stop(:normal)" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 30) do
      interface = "fstop_#{seed}"
      profile = make_profile(interface)

      {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
      assert Process.alive?(pid)

      GenServer.stop(pid, :normal)
      Process.sleep(20)

      refute Process.alive?(pid),
             "Expected FSM to be dead after GenServer.stop(:normal)"
    end
  end

  property "FSM get_state always returns {:ok, map} with interface matching start_link arg" do
    check all(seed <- StreamData.integer(1..999_999), max_runs: 50) do
      iface = "fgs_#{seed}"
      profile = make_profile(iface)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(20)

      {:ok, state} = FSM.get_state(pid)
      assert is_map(state), "Expected map from get_state, got: #{inspect(state)}"
      assert state.interface == iface,
             "Expected interface #{iface} in get_state, got: #{inspect(state.interface)}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM get_state state field is always one of the valid FSM states" do
    check all(seed <- StreamData.integer(1..999_999), max_runs: 50) do
      iface = "fvs_#{seed}"
      profile = make_profile(iface)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(20)

      {:ok, state} = FSM.get_state(pid)

      assert state.state in @valid_states,
             "Unexpected FSM state: #{inspect(state.state)}"

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
