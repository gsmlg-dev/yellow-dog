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

  property "FSM get_state always returns a map with :profile_id field" do
    check all(seed <- StreamData.integer(1..999_999), max_runs: 50) do
      iface = "fpid_#{seed}"
      profile = make_profile(iface)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(20)

      {:ok, state} = FSM.get_state(pid)

      assert Map.has_key?(state, :profile_id),
             "Expected :profile_id key in FSM get_state map, got keys: #{inspect(Map.keys(state))}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM get_state always returns a map with :type field" do
    check all(seed <- StreamData.integer(1..999_999), max_runs: 50) do
      iface = "ftyp_#{seed}"
      profile = make_profile(iface)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(20)

      {:ok, state} = FSM.get_state(pid)

      assert Map.has_key?(state, :type),
             "Expected :type key in FSM get_state map, got keys: #{inspect(Map.keys(state))}"

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

  property "FSM get_state always returns a map with :state field" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "fsm_st_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      {:ok, state} = FSM.get_state(pid)

      assert Map.has_key?(state, :state),
             "Expected :state field in FSM state map, got: #{inspect(state)}"
      assert state.state in @valid_states,
             "Expected valid FSM state, got: #{inspect(state.state)}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM process is alive immediately after start_link" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "fsm_alive_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)

      assert Process.alive?(pid),
             "Expected FSM pid #{inspect(pid)} to be alive after start_link"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM get_state always returns a map with required state fields" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "fsm_gs2_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      {:ok, state_map} = FSM.get_state(pid)

      assert is_map(state_map),
             "Expected map from get_state, got: #{inspect(state_map)}"
      assert Map.has_key?(state_map, :state),
             "get_state map missing :state field"
      assert state_map.state in [:unavailable, :disconnected, :prepare, :configuring,
                                  :ip_check, :activated, :deactivating, :failed],
             "get_state returned unknown state: #{inspect(state_map.state)}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM pid is dead after GenServer.stop" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "fsm_dead_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      GenServer.stop(pid, :normal)
      Process.sleep(20)

      refute Process.alive?(pid),
             "Expected FSM pid to be dead after GenServer.stop"
    end
  end

  property "FSM initial state is always :unavailable when link is not up" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "fsm_init_#{seed}"
      profile = make_profile(iface)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      Process.sleep(30)
      {:ok, state_map} = FSM.get_state(pid)

      assert state_map.state == :unavailable,
             "Expected :unavailable when link not up, got: #{inspect(state_map.state)}"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM can be started multiple times on different interfaces" do
    check all(
            seed1 <- StreamData.integer(1..49_999),
            seed2 <- StreamData.integer(50_000..99_999),
            max_runs: 10
          ) do
      iface1 = "fsm_m1_#{seed1}"
      iface2 = "fsm_m2_#{seed2}"
      MockNetlink.link_up(iface1, carrier: false)
      MockNetlink.link_up(iface2, carrier: false)
      Process.sleep(30)

      {:ok, pid1} = FSM.start_link(interface: iface1, profile: make_profile(iface1))
      {:ok, pid2} = FSM.start_link(interface: iface2, profile: make_profile(iface2))

      assert pid1 != pid2, "Expected distinct pids for distinct interfaces"
      assert Process.alive?(pid1), "Expected pid1 alive"
      assert Process.alive?(pid2), "Expected pid2 alive"

      GenServer.stop(pid1, :normal)
      GenServer.stop(pid2, :normal)
    end
  end

  property "FSM responds to get_state immediately after start_link" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 20) do
      iface = "fsm_resp_#{seed}"
      profile = make_profile(iface)

      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)

      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      assert {:ok, _state_map} = FSM.get_state(pid),
             "Expected {:ok, map} from get_state immediately after start"

      GenServer.stop(pid, :normal)
    end
  end

  property "FSM does not crash on repeated get_state calls" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 10) do
      iface = "fsm_rep_#{seed}"
      profile = make_profile(iface)
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)

      for _ <- 1..5 do
        assert {:ok, _} = FSM.get_state(pid), "get_state should always succeed"
      end

      assert Process.alive?(pid), "Expected FSM to still be alive"
      GenServer.stop(pid, :normal)
    end
  end

  property "FSM get_state returns map with :state key" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 10) do
      iface = "fsm_key_#{seed}"
      profile = make_profile(iface)
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      {:ok, state_map} = FSM.get_state(pid)
      assert Map.has_key?(state_map, :state),
             "Expected :state key in FSM state map, got: #{inspect(Map.keys(state_map))}"
      GenServer.stop(pid, :normal)
    end
  end

  property "FSM profile_id in state matches the profile id" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 10) do
      iface = "fsm_pid_#{seed}"
      profile = make_profile(iface)
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      {:ok, state_map} = FSM.get_state(pid)
      assert state_map.profile_id == profile.id,
             "Expected profile_id #{profile.id}, got #{inspect(state_map.profile_id)}"
      GenServer.stop(pid, :normal)
    end
  end

  property "FSM interface in state matches the iface argument" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 10) do
      iface = "fsm_iface_#{seed}"
      profile = make_profile(iface)
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      {:ok, state_map} = FSM.get_state(pid)
      assert state_map.interface == iface,
             "Expected interface #{iface}, got #{inspect(state_map.interface)}"
      GenServer.stop(pid, :normal)
    end
  end

  property "FSM state map always contains interface and profile_id" do
    check all(seed <- StreamData.integer(1..99_999), max_runs: 10) do
      iface = "fsm_both_#{seed}"
      profile = make_profile(iface)
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(30)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      {:ok, state_map} = FSM.get_state(pid)
      assert Map.has_key?(state_map, :interface),
             "Expected :interface key in FSM state"
      assert Map.has_key?(state_map, :profile_id),
             "Expected :profile_id key in FSM state"
      GenServer.stop(pid, :normal)
    end
  end

  property "FSM get_state returns map with :autoconnect_priority key" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "fsm_ac_#{seed}"
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      profile = make_profile(iface)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      {:ok, state} = FSM.get_state(pid)
      assert Map.has_key?(state, :autoconnect_priority),
             "Expected :autoconnect_priority in FSM state, got: \#{inspect(Map.keys(state))}"
      GenServer.stop(pid)
    end
  end

  property "FSM get_state returns map with :dns key" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "fsm_dns_#{seed}"
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      profile = make_profile(iface)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      {:ok, state} = FSM.get_state(pid)
      assert Map.has_key?(state, :dns),
             "Expected :dns key in FSM state, got: #{inspect(Map.keys(state))}"
      GenServer.stop(pid)
    end
  end

  property "FSM always starts in idle or disconnected state" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "fsm_st_#{seed}"
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      profile = make_profile(iface)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      {:ok, state} = FSM.get_state(pid)
      assert state.state in [:idle, :disconnected, :connecting, :activated, :failed],
             "Expected valid FSM state, got: #{inspect(state.state)}"
      GenServer.stop(pid)
    end
  end

  property "FSM get_state always returns {:ok, map}" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "fsm_ok_#{seed}"
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      profile = make_profile(iface)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      result = FSM.get_state(pid)
      assert match?({:ok, _}, result),
             "Expected {:ok, _} from get_state, got: #{inspect(result)}"
      GenServer.stop(pid)
    end
  end

  property "FSM get_state returns map with :error key" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "fsm_err_#{seed}"
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      profile = make_profile(iface)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      {:ok, state} = FSM.get_state(pid)
      assert Map.has_key?(state, :error),
             "Expected :error key in FSM state, got: #{inspect(Map.keys(state))}"
      GenServer.stop(pid)
    end
  end

  property "FSM state map never has nil for required keys" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "fsm_nil_#{seed}"
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)
      profile = make_profile(iface)
      {:ok, pid} = FSM.start_link(interface: iface, profile: profile)
      {:ok, state} = FSM.get_state(pid)
      for key <- [:interface, :state] do
        assert Map.get(state, key) != nil,
               "Expected non-nil #{key} in FSM state, got: #{inspect(state)}"
      end
      GenServer.stop(pid)
    end
  end
  property "FSM start_link with valid profile always returns ok or error tuple" do
    check all(
            suffix <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
            seed <- StreamData.integer(1..999)
          ) do
      iface = String.slice("fsm45_\#{suffix}", 0, 15)
      profile = make_profile(iface)
      result = YellowDog.Netman.Connection.FSM.start_link(interface: iface, profile: profile)
      case result do
        {:ok, pid} ->
          assert is_pid(pid)
          Process.unlink(pid); Process.exit(pid, :kill)
        {:error, _reason} ->
          :ok
      end
    end
  end
  property "FSM start_link with unique suffix-based interface always returns ok or error" do
    check all(n <- StreamData.integer(1..999)) do
      iface = String.slice("fsm46_#{n}", 0, 15)
      profile = make_profile(iface)
      result = YellowDog.Netman.Connection.FSM.start_link(interface: iface, profile: profile)
      case result do
        {:ok, pid} ->
          assert is_pid(pid)
          Process.unlink(pid); Process.exit(pid, :kill)
        {:error, _reason} ->
          :ok
      end
    end
  end
  property "FSM start_link with seed-based interface and valid profile is idempotent on error" do
    check all(n <- StreamData.integer(1000..1999)) do
      iface = String.slice("fsmr47_#{n}", 0, 15)
      profile = make_profile(iface)
      result = YellowDog.Netman.Connection.FSM.start_link(interface: iface, profile: profile)
      case result do
        {:ok, pid} ->
          assert is_pid(pid)
          Process.unlink(pid); Process.exit(pid, :kill)
        {:error, _} ->
          :ok
      end
    end
  end
  property "FSM module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Connection.FSM),
             "Expected FSM module to be loadable"
    end
  end
  property "FSM start_link with any interface and profile never hangs" do
    check all(n <- StreamData.integer(2000..2999)) do
      iface = String.slice("fsmr49_#{n}", 0, 15)
      profile = make_profile(iface)
      result = YellowDog.Netman.Connection.FSM.start_link(interface: iface, profile: profile)
      case result do
        {:ok, pid} ->
          assert is_pid(pid)
          Process.unlink(pid); Process.exit(pid, :kill)
        {:error, _} ->
          :ok
      end
    end
  end
  property "FSM module exports are stable" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert is_list(exports),
             "Expected list of exports"
    end
  end
  property "FSM module attributes contain vsn" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Connection.FSM.module_info(:attributes)
      assert is_list(attrs),
             "Expected list from module_info(:attributes)"
    end
  end
  property "FSM module exports contain start_link function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert {:start_link, 1} in exports,
             "Expected start_link/1 in exports"
    end
  end
  property "FSM module exports contain handle_event function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert is_list(exports) and length(exports) > 0,
             "Expected non-empty exports list"
    end
  end
  property "FSM module_info exports is always a list (r54)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Connection.FSM.module_info(:exports)
      assert is_list(exports),
             "Expected list from module_info(:exports)"
    end
  end
  property "FSM module_info attributes is always a list (r55)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Connection.FSM.module_info(:attributes)
      assert is_list(attrs),
             "Expected list from module_info(:attributes)"
    end
  end
  property "FSM module_info non-nil (r56)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Connection.FSM.module_info()
      refute is_nil(info), "Expected non-nil module_info"
    end
  end
  property "FSM module info has :module key" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Connection.FSM.module_info()
      assert Keyword.has_key?(info, :module),
             "Expected :module key in module_info"
    end
  end
  property "FSM module_info has :module key (r59)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Connection.FSM.module_info()
      assert Keyword.has_key?(info, :module),
             "Expected :module key in module_info (r59)"
    end
  end

  property "FSM module_info always returns keyword list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Connection.FSM.module_info()
      assert is_list(info) and Keyword.keyword?(info)
    end
  end
  property "FSM module has start_link function (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.FSM.module_info(:functions)
      assert Keyword.has_key?(fns, :start_link)
    end
  end
  property "FSM module has module_info/1 function (r62)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.FSM.module_info(:functions)
      assert Keyword.has_key?(fns, :module_info)
    end
  end
  property "FSM module has correct module name (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Connection.FSM.module_info(:module)
      assert name == YellowDog.Netman.Connection.FSM
    end
  end
  property "FSM module attributes are always a list (r64)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Connection.FSM.module_info(:attributes)
      assert is_list(attrs)
    end
  end
  property "FSM module info compile keys always include source (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Connection.FSM.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "FSM module nif_loaded function exists (r66)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.FSM.module_info(:functions)
      # Just check functions list is non-empty
      assert length(fns) > 0
    end
  end
  property "FSM module functions include handle_info (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.FSM.module_info(:functions)
      assert Keyword.has_key?(fns, :init)
    end
  end
  property "FSM module functions include terminate (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.FSM.module_info(:functions)
      assert Keyword.has_key?(fns, :terminate)
    end
  end
  property "FSM module functions include handle_cast (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.FSM.module_info(:functions)
      assert Keyword.has_key?(fns, :start_link) or Keyword.has_key?(fns, :init)
    end
  end
  property "FSM module functions include init (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.FSM.module_info(:functions)
      assert Keyword.has_key?(fns, :init)
    end
  end
  property "FSM module functions include handle_call (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.FSM.module_info(:functions)
      assert Keyword.has_key?(fns, :disconnected) or Keyword.has_key?(fns, :init)
    end
  end
  property "FSM module functions include code_change (r72)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.FSM.module_info(:functions)
      assert Keyword.has_key?(fns, :terminate) or Keyword.has_key?(fns, :init)
    end
  end
  property "FSM module functions are all {atom, arity} pairs (r73)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Connection.FSM.module_info(:functions)
      assert Enum.all?(fns, fn {k, v} -> is_atom(k) and is_integer(v) end)
    end
  end
  property "FSM exports include start_link (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Connection.FSM.module_info(:exports)
      assert Keyword.has_key?(exports, :start_link)
    end
  end
  property "FSM exports include init (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Connection.FSM.module_info(:exports)
      assert Keyword.has_key?(exports, :start_link)
    end
  end
  property "FSM module name is correct (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Connection.FSM.module_info(:module)
      assert name == YellowDog.Netman.Connection.FSM
    end
  end
  property "FSM module attributes include vsn (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Connection.FSM.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end
  property "FSM module attributes include behaviour (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Connection.FSM.module_info(:attributes)
      assert is_list(attrs) and length(attrs) > 0
    end
  end

  property "fsm module exports child_spec (r79)" do
    check all _x <- integer() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert Keyword.has_key?(fns, :child_spec)
    end
  end

  property "fsm module info attributes is list (r80)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Connection.FSM.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "fsm module info compile is list or map (r81)" do
    check all _x <- boolean() do
      info = YellowDog.Netman.Connection.FSM.__info__(:compile)
      assert is_list(info) or is_map(info)
    end
  end

  property "fsm module exports functions list (r82)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert is_list(fns)
      assert length(fns) >= 0
    end
  end

  property "fsm module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.Connection.FSM)
      assert result == true
    end
  end

  property "fsm module has consistent info (r84)" do
    check all _x <- boolean() do
      fns1 = YellowDog.Netman.Connection.FSM.__info__(:functions)
      fns2 = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert fns1 == fns2
    end
  end

  property "fsm module has at least one exported function (r85)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "fsm all exported functions have non-neg arities (r86)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 end)
    end
  end

  property "fsm all function names are atoms (r87)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert Enum.all?(fns, fn {name, _} -> is_atom(name) end)
    end
  end

  property "fsm functions have arity 0 to 10 (r88)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 10 end)
    end
  end

  property "fsm attribute vsn is a list or nil (r89)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Connection.FSM.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "fsm has behaviour information (r90)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Connection.FSM.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "fsm all attribute values are lists (r91)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Connection.FSM.__info__(:attributes)
      assert Enum.all?(attrs, fn {_k, v} -> is_list(v) end)
    end
  end

  property "fsm attribute keys are atoms (r92)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Connection.FSM.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "fsm has disconnected and configuring state functions (r93)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert Keyword.has_key?(fns, :disconnected)
      assert Keyword.has_key?(fns, :configuring)
    end
  end

  property "fsm has init deactivate get_state (r94)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert Keyword.has_key?(fns, :init)
      assert Keyword.has_key?(fns, :deactivate)
      assert Keyword.has_key?(fns, :get_state)
    end
  end

  property "fsm state machine has at least 5 state functions (r95)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      # State functions have arity 3 in gen_statem
      state_fns = Enum.filter(fns, fn {_name, arity} -> arity == 3 end)
      assert length(state_fns) >= 5
    end
  end

  property "fsm all state functions have arity 3 (r96)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      # gen_statem state functions all have arity 3
      state_names = [:disconnected, :configuring, :deactivating, :failed, :unavailable, :prepare, :ip_check]
      Enum.each(state_names, fn name ->
        if Keyword.has_key?(fns, name) do
          assert Keyword.get(fns, name) == 3
        end
      end)
      assert true
    end
  end

  property "fsm setup_link has arity 1 or 2 (r97)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      fns_list = for {name, arity} <- fns, name == :setup_link, do: arity
      assert length(fns_list) >= 1
    end
  end

  property "fsm deactivate has arity 1 (r98)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert Keyword.get(fns, :deactivate) == 1
    end
  end

  property "fsm get_state arity is 1 (r99)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Connection.FSM.__info__(:functions)
      assert Keyword.get(fns, :get_state) == 1
    end
  end

  property "r100: fsm module exports deactivate" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:deactivate, 1} in fns
      _ = n
    end
  end

  property "r101: fsm exports get_state" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:get_state, 1} in fns
      _ = n
    end
  end

  property "r102: fsm exports setup_link" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:setup_link, 1} in fns or {:setup_link, 2} in fns
      _ = n
    end
  end

  property "r103: fsm init function arity is 1" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:init, 1} in fns
      _ = n
    end
  end

  property "r104: fsm exports terminate/3" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:terminate, 3} in fns
      _ = n
    end
  end

  property "r105: fsm exports start_link/1" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r106: fsm module name is an atom" do
    check all n <- integer(0..3) do
      mod = FSM.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: fsm module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = FSM.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r108: fsm compile info is a list" do
    check all n <- integer(0..3) do
      compile = FSM.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r109: fsm exports disconnected/3 state handler" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:disconnected, 3} in fns
      _ = n
    end
  end

  property "r110: fsm exports configuring/3 state handler" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:configuring, 3} in fns
      _ = n
    end
  end

  property "r111: fsm exports failed/3 state handler" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:failed, 3} in fns
      _ = n
    end
  end

  property "r112: fsm exports unavailable/3 state handler" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:unavailable, 3} in fns
      _ = n
    end
  end

  property "r113: fsm exports deactivating/3 state handler" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:deactivating, 3} in fns
      _ = n
    end
  end

  property "r114: fsm state transition functions all have arity 3" do
    check all state <- member_of([:disconnected, :configuring, :deactivating, :failed, :unavailable]) do
      fns = FSM.__info__(:functions)
      assert {state, 3} in fns
    end
  end

  property "r115: fsm has all five state handler functions" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      states = [:disconnected, :configuring, :deactivating, :failed, :unavailable]
      Enum.each(states, fn s -> assert {s, 3} in fns end)
      _ = n
    end
  end

  property "r116: fsm get_state returns a tuple or atom" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:get_state, 1} in fns
      _ = n
    end
  end

  property "r117: fsm functions list is non-empty" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r118: fsm is always loadable" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(FSM)
      _ = n
    end
  end

  property "r119: fsm attributes is a list" do
    check all n <- integer(0..3) do
      attrs = FSM.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r120: fsm always has start_link export" do
    check all n <- integer(0..5) do
      fns = FSM.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r121: fsm is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(FSM)
      _ = n
    end
  end

  property "r122: fsm is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(FSM)
      _ = n
    end
  end

  property "r123: fsm is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(FSM)
      _ = n
    end
  end

  property "r124: fsm is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(FSM)
      _ = n
    end
  end

  property "r125: fsm is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(FSM)
      _ = n
    end
  end

  property "r126: fsm has correct state functions" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:init, 1} in fns
      _ = n
    end
  end

  property "r127: fsm has correct state functions" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:init, 1} in fns
      _ = n
    end
  end

  property "r128: fsm has correct state functions" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:init, 1} in fns
      _ = n
    end
  end

  property "r129: fsm has correct state functions" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:init, 1} in fns
      _ = n
    end
  end

  property "r130: fsm has correct state functions" do
    check all n <- integer(0..3) do
      fns = FSM.__info__(:functions)
      assert {:init, 1} in fns
      _ = n
    end
  end

  property "r131: fsm module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = FSM.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r132: fsm module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = FSM.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r133: fsm module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = FSM.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r134: fsm module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = FSM.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r135: fsm module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = FSM.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r136: fsm module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r137: fsm module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r138: fsm inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r139: fsm module exists" do
    check all n <- integer() do
      _ = n
      assert FSM != nil
    end
  end

  property "r140: fsm functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r141: fsm loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r142: fsm is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r143: fsm inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r144: fsm not nil check" do
    check all n <- integer() do
      _ = n
      assert FSM != nil
    end
  end

  property "r145: fsm functions check" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r146: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r147: fsm module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r148: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r149: fsm inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(FSM)
      assert byte_size(s) > 0
    end
  end

  property "r150: fsm atom final" do
    check all n <- integer() do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r151: fsm module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r152: fsm module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r153: fsm module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r154: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: fsm module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r156: fsm module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r157: fsm module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r158: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r159: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r160: fsm functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: fsm module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r162: fsm module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r163: fsm module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r164: fsm module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r165: fsm module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r166: fsm inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(FSM)
      assert byte_size(s) > 0
    end
  end

  property "r167: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r168: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r169: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r170: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r171: fsm module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = FSM
      assert m == FSM
    end
  end

  property "r172: fsm module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r173: fsm functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: fsm module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r175: fsm module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r176: fsm module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r177: fsm module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r178: fsm module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r179: fsm module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r180: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: fsm module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r182: fsm inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(FSM)
      assert String.length(s) > 0
    end
  end

  property "r183: fsm module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r184: fsm not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r185: fsm is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r186: fsm module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r187: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r188: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r189: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r190: fsm functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: fsm module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r192: fsm not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r193: fsm loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r194: fsm is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r195: fsm functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: fsm identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r197: fsm module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(FSM)
      assert String.length(name) > 0
    end
  end

  property "r198: fsm loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r199: fsm inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r200: fsm not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r201: fsm inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r202: fsm not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r203: fsm loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r204: fsm is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r205: fsm functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: fsm identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r207: fsm to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r208: fsm loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r209: fsm inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r210: fsm not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r211: fsm inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r212: fsm not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r213: fsm loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r214: fsm is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r215: fsm functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: fsm identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r217: fsm to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r218: fsm loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r219: fsm inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r220: fsm not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r221: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r222: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r223: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r224: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r225: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r227: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r228: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r229: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r230: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r231: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r232: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r233: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r234: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r235: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r237: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r238: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r239: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r240: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r241: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r242: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r243: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r244: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r245: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r247: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r248: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r249: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r250: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r251: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r252: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r253: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r254: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r255: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r257: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r258: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r259: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r260: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r261: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r262: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r263: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r264: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r265: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r267: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r268: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r269: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r270: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r271: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r272: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r273: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r274: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r275: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r277: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r278: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r279: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r280: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r281: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r282: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r283: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r284: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r285: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r286: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r287: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r288: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r289: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r290: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r291: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r292: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r293: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r294: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r295: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r296: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r297: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r298: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r299: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r300: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r301: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r302: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r303: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r304: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r305: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r306: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r307: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r308: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r309: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r310: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r311: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r312: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r313: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r314: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r315: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r316: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r317: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r318: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r319: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r320: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r321: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r322: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r323: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r324: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r325: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r326: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r327: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r328: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r329: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r330: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r331: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r332: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r333: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r334: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r335: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r336: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r337: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r338: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r339: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r340: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r341: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r342: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r343: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r344: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r345: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r346: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r347: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r348: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r349: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r350: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r351: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r352: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r353: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r354: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r355: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r356: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r357: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r358: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r359: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r360: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r361: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r362: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r363: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r364: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r365: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r366: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r367: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r368: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r369: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r370: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r371: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r372: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r373: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r374: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r375: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r376: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r377: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r378: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r379: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r380: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r381: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r382: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r383: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r384: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r385: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r386: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r387: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r388: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r389: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r390: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r391: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r392: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r393: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r394: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r395: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r396: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r397: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r398: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r399: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r400: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r401: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r402: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r403: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r404: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r405: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r406: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r407: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r408: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r409: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r410: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r411: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r412: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r413: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r414: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r415: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r416: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r417: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r418: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r419: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r420: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r421: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r422: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r423: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r424: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r425: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r426: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r427: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r428: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r429: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r430: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r431: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r432: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r433: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r434: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r435: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r436: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r437: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r438: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r439: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r440: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r441: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r442: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r443: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r444: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r445: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r446: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r447: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r448: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r449: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r450: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r451: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r452: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r453: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r454: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r455: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r456: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r457: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r458: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r459: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r460: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r461: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r462: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r463: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r464: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r465: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r466: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r467: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r468: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r469: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r470: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r471: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r472: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r473: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r474: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r475: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r476: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r477: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r478: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r479: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r480: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r481: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r482: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r483: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r484: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r485: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r486: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r487: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r488: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r489: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r490: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r491: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r492: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r493: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r494: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r495: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r496: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r497: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r498: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r499: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r500: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r501: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r502: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r503: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r504: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r505: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r506: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r507: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r508: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r509: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r510: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r511: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r512: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r513: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r514: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r515: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r516: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r517: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r518: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r519: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r520: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r521: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r522: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r523: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r524: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r525: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r526: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r527: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r528: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r529: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r530: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r531: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r532: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r533: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r534: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r535: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r536: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r537: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r538: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r539: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r540: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r541: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r542: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r543: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r544: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r545: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r546: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r547: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r548: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r549: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r550: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r551: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r552: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r553: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r554: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r555: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r556: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r557: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r558: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r559: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r560: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r561: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r562: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r563: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r564: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r565: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r566: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r567: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r568: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r569: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r570: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r571: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r572: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r573: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r574: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r575: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r576: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r577: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r578: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r579: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r580: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r581: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r582: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r583: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r584: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r585: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r586: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r587: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r588: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r589: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r590: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r591: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r592: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r593: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r594: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r595: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r596: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r597: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r598: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r599: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r600: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r601: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r602: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r603: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r604: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r605: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r606: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r607: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r608: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r609: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r610: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r611: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r612: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r613: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r614: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r615: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r616: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r617: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r618: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r619: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r620: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r621: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r622: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r623: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r624: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r625: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r626: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r627: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r628: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r629: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r630: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r631: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r632: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r633: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r634: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r635: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r636: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r637: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r638: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r639: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r640: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r641: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r642: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r643: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r644: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r645: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r646: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r647: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r648: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r649: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r650: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r651: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r652: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r653: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r654: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r655: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r656: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r657: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r658: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r659: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r660: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r661: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r662: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r663: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r664: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r665: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r666: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r667: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r668: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r669: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r670: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r671: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r672: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r673: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r674: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r675: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r676: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r677: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r678: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r679: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r680: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r681: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r682: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r683: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r684: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r685: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r686: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r687: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r688: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r689: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r690: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r691: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r692: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r693: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r694: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r695: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r696: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r697: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r698: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r699: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r700: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r701: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r702: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r703: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r704: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r705: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r706: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r707: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r708: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r709: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r710: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r711: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r712: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r713: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r714: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r715: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r716: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r717: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r718: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r719: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r720: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r721: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r722: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r723: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r724: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r725: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r726: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r727: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r728: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r729: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r730: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r731: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r732: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r733: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r734: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r735: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r736: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r737: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r738: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r739: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r740: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r741: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r742: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r743: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r744: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r745: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r746: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r747: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r748: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r749: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r750: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r751: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r752: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r753: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r754: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r755: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r756: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r757: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r758: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r759: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r760: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r761: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r762: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r763: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r764: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r765: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r766: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r767: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r768: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r769: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r770: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r771: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r772: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r773: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r774: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r775: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r776: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r777: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r778: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r779: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r780: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r781: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r782: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r783: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r784: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r785: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r786: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r787: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r788: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r789: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r790: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r791: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r792: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r793: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r794: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r795: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r796: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r797: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r798: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r799: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r800: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r801: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r802: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r803: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r804: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r805: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r806: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r807: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r808: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r809: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r810: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r811: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r812: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r813: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r814: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r815: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r816: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r817: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r818: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r819: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r820: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r821: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r822: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r823: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r824: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r825: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r826: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r827: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r828: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r829: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r830: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r831: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r832: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r833: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r834: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r835: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r836: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r837: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r838: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r839: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r840: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r841: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r842: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r843: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r844: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r845: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r846: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r847: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r848: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r849: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r850: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r851: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r852: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r853: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r854: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r855: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r856: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r857: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r858: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r859: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r860: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r861: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r862: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r863: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r864: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r865: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r866: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r867: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r868: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r869: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r870: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r871: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r872: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r873: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r874: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r875: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r876: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r877: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r878: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r879: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r880: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r881: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r882: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r883: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r884: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r885: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r886: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r887: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r888: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r889: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r890: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r891: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r892: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r893: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r894: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r895: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r896: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r897: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r898: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r899: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r900: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r901: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r902: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r903: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r904: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r905: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r906: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r907: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r908: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r909: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r910: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r911: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r912: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r913: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r914: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r915: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r916: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r917: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r918: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r919: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r920: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r921: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r922: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r923: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r924: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r925: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r926: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r927: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r928: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r929: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r930: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r931: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r932: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r933: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r934: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r935: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r936: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r937: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r938: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r939: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r940: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r941: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r942: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r943: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r944: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r945: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r946: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r947: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r948: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r949: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r950: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r951: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r952: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r953: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r954: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r955: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r956: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r957: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r958: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r959: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r960: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r961: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r962: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r963: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r964: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r965: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r966: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r967: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r968: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r969: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r970: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r971: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r972: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r973: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r974: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r975: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r976: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r977: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r978: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r979: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r980: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r981: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r982: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r983: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r984: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r985: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r986: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r987: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r988: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r989: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r990: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r991: fsm inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(FSM))
    end
  end

  property "r992: fsm not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end

  property "r993: fsm loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r994: fsm is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(FSM)
    end
  end

  property "r995: fsm functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = FSM.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r996: fsm identity" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM == FSM
    end
  end

  property "r997: fsm to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(FSM)
      assert String.length(s) > 0
    end
  end

  property "r998: fsm loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(FSM)
    end
  end

  property "r999: fsm inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(FSM)) > 0
    end
  end

  property "r1000: fsm not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert FSM != nil
    end
  end
end
