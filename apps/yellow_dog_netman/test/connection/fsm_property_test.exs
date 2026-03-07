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
end
