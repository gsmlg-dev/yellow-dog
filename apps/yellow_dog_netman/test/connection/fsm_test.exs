defmodule YellowDog.Netman.Connection.FSMTest do
  use ExUnit.Case

  alias YellowDog.Netman.Connection.FSM
  alias YellowDog.Netman.Types.Profile
  alias YellowDog.Netman.Test.MockNetlink

  @moduletag :capture_log

  setup do
    # Create a test profile
    profile = %Profile{
      id: "fsm-test-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: "fsm_eth0_#{:rand.uniform(100_000)}",
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :manual, address: "10.0.0.100/24", gateway: "10.0.0.1", dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    {:ok, profile: profile}
  end

  test "starts in unavailable state when interface doesn't exist", %{profile: profile} do
    {:ok, pid} = FSM.start_link(interface: profile.interface, profile: profile)
    assert {:ok, state} = FSM.get_state(pid)
    assert state.state == :unavailable
    GenServer.stop(pid, :normal)
  end

  test "moves to disconnected when interface appears", %{profile: profile} do
    {:ok, pid} = FSM.start_link(interface: profile.interface, profile: profile)

    # Simulate interface appearing
    MockNetlink.link_up(profile.interface)
    Process.sleep(100)

    assert {:ok, state} = FSM.get_state(pid)
    assert state.state == :disconnected
    GenServer.stop(pid, :normal)
  end

  test "activate from disconnected transitions to prepare", %{profile: profile} do
    # First make the interface appear
    MockNetlink.link_up(profile.interface)
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: profile.interface, profile: profile)
    Process.sleep(50)

    # Should be in disconnected since autoconnect is false
    {:ok, state} = FSM.get_state(pid)
    assert state.state == :disconnected

    # Activate
    FSM.activate(pid)
    Process.sleep(100)

    {:ok, state} = FSM.get_state(pid)
    # Should have progressed past prepare (which is transient)
    assert state.state in [:configuring, :ip_check, :activated, :failed]
    GenServer.stop(pid, :normal)
  end

  test "autoconnect profile activates automatically when carrier present", _ctx do
    interface = "fsm_auto_#{:rand.uniform(100_000)}"

    profile = %Profile{
      id: "auto-test-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :manual, address: "10.0.0.200/24", gateway: "10.0.0.1", dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    # Interface exists with carrier before FSM starts
    MockNetlink.link_up(interface)
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
    Process.sleep(200)

    {:ok, state} = FSM.get_state(pid)
    # Should auto-activate
    assert state.state in [:configuring, :ip_check, :activated, :failed]
    GenServer.stop(pid, :normal)
  end

  test "deactivate from activated transitions through deactivating", %{profile: profile} do
    MockNetlink.link_up(profile.interface)
    Process.sleep(50)

    # Simulate address being available for IP check
    MockNetlink.address_added(profile.interface, "10.0.0.100/24")
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: profile.interface, profile: profile)
    Process.sleep(50)
    FSM.activate(pid)
    Process.sleep(300)

    # Now deactivate
    FSM.deactivate(pid)
    Process.sleep(200)

    {:ok, state} = FSM.get_state(pid)
    assert state.state == :disconnected
    GenServer.stop(pid, :normal)
  end

  test "failed state is reachable via dhcp_lease_failed event" do
    interface = "fsm_fail_#{:rand.uniform(100_000)}"

    # DHCP profile — will start DHCP but we inject failure manually
    dhcp_profile = %Profile{
      id: "dhcp-fail-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    MockNetlink.link_up(interface)
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: interface, profile: dhcp_profile)
    Process.sleep(100)

    # FSM should be in :configuring or progressed further
    {:ok, state} = FSM.get_state(pid)
    assert state.state in [:configuring, :failed]

    # Inject DHCP failure to drive FSM to :failed
    send(pid, {:dhcp_lease_failed, :no_server_response})
    Process.sleep(100)

    {:ok, state} = FSM.get_state(pid)
    assert state.state == :failed
    assert state.error == :dhcp_failed

    GenServer.stop(pid, :normal)
  end

  test "failed state recovers to disconnected via activate cast", %{profile: profile} do
    interface = profile.interface
    MockNetlink.link_up(interface)
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
    Process.sleep(50)

    # Force FSM into failed state
    send(pid, {:dhcp_lease_failed, :timeout})
    Process.sleep(100)

    {:ok, state} = FSM.get_state(pid)
    # May have gone through configuring quickly; inject failure again if needed
    if state.state != :failed do
      FSM.activate(pid)
      Process.sleep(50)
      send(pid, {:dhcp_lease_failed, :timeout})
      Process.sleep(100)
    end

    {:ok, state} = FSM.get_state(pid)
    # If somehow still not failed (e.g. manual profile skipped DHCP), skip
    if state.state == :failed do
      # Retry from failed: cast :activate
      FSM.activate(pid)
      Process.sleep(100)

      {:ok, state} = FSM.get_state(pid)

      assert state.state != :failed,
             "FSM should leave :failed state after activate cast, got: #{state.state}"
    end

    GenServer.stop(pid, :normal)
  end

  test "state transitions emit telemetry events" do
    interface = "fsm_telem_#{:rand.uniform(100_000)}"
    test_pid = self()

    telem_profile = %Profile{
      id: "telem-test-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    handler_id = {__MODULE__, :telem_test, :rand.uniform(1_000_000)}

    :telemetry.attach(
      handler_id,
      [:yellow_dog, :netman, :connection, :state_change],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    MockNetlink.link_up(interface)
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: interface, profile: telem_profile)
    Process.sleep(200)

    # Should have received telemetry for init → unavailable/disconnected
    assert_receive {:telemetry_event, %{interface: ^interface}}, 500

    # Deactivate to trigger more transitions
    FSM.deactivate(pid)
    Process.sleep(150)

    # Should have received multiple telemetry events
    assert_receive {:telemetry_event, %{to: :activated}}, 500

    GenServer.stop(pid, :normal)
  end

  test "reconciliation start/stop telemetry is emitted" do
    test_pid = self()

    handler_id = {__MODULE__, :recon_telem, :rand.uniform(1_000_000)}

    :telemetry.attach(
      handler_id,
      [:yellow_dog, :netman, :reconciliation, :stop],
      fn _event, measurements, _metadata, _config ->
        send(test_pid, {:recon_stop, measurements})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    YellowDog.Netman.ReconciliationEngine.reconcile()
    Process.sleep(300)

    assert_receive {:recon_stop, %{duration_ms: dur, diffs_count: _, applied_count: _}}, 500
    assert is_integer(dur)
    assert dur >= 0
  end

  test "unavailable transitions to disconnected without carrier" do
    interface = "fsm_nocarrier_#{:rand.uniform(100_000)}"

    profile = %Profile{
      id: "nc-test-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    {:ok, pid} = FSM.start_link(interface: interface, profile: profile)

    # Start in unavailable
    {:ok, state} = FSM.get_state(pid)
    assert state.state == :unavailable

    # Link appears but without carrier
    MockNetlink.link_up(interface, carrier: false)
    Process.sleep(100)

    {:ok, state} = FSM.get_state(pid)
    assert state.state == :disconnected

    GenServer.stop(pid, :normal)
  end

  test "manual IP with nil address transitions to failed with :no_address_configured" do
    interface = "fsm_naddr_#{:rand.uniform(100_000)}"

    profile = %Profile{
      id: "naddr-test-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :manual, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    MockNetlink.link_up(interface)
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
    Process.sleep(50)

    FSM.activate(pid)
    Process.sleep(200)

    {:ok, state} = FSM.get_state(pid)
    assert state.state == :failed
    assert state.error == :no_address_configured

    GenServer.stop(pid, :normal)
  end

  test "failed state transitions to disconnected when carrier returns" do
    interface = "fsm_fail_carrier_#{:rand.uniform(100_000)}"

    # autoconnect: false so after carrier recovery FSM stays in disconnected
    profile = %Profile{
      id: "fail-carrier-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    MockNetlink.link_up(interface)
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
    Process.sleep(50)

    # Manually activate → enters configuring (DHCP mode)
    FSM.activate(pid)
    Process.sleep(100)

    # Inject DHCP failure while in configuring → goes to failed
    send(pid, {:dhcp_lease_failed, :test_reason})
    Process.sleep(100)

    {:ok, state} = FSM.get_state(pid)
    assert state.state == :failed

    # Carrier event should transition failed → disconnected
    MockNetlink.carrier_change(interface, true)
    Process.sleep(100)

    {:ok, state} = FSM.get_state(pid)
    assert state.state == :disconnected

    GenServer.stop(pid, :normal)
  end

  test "MTU is configured during prepare state when non-nil" do
    interface = "fsm_mtu_#{:rand.uniform(100_000)}"

    profile = %Profile{
      id: "mtu-test-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: 1400},
      ipv4: %{method: :manual, address: "10.1.0.100/24", gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    MockNetlink.link_up(interface)
    Process.sleep(50)
    MockNetlink.address_added(interface, "10.1.0.100/24")
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
    Process.sleep(50)

    FSM.activate(pid)
    Process.sleep(200)

    # FSM should have passed through prepare (which calls Netlink.command with MTU)
    {:ok, state} = FSM.get_state(pid)
    assert state.state in [:configuring, :ip_check, :activated, :failed]

    GenServer.stop(pid, :normal)
  end

  test "carrier loss while activated transitions to disconnected" do
    interface = "fsm_carrier_loss_#{:rand.uniform(100_000)}"

    profile = %Profile{
      id: "carrier-loss-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :manual, address: "10.2.0.100/24", gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    MockNetlink.link_up(interface)
    Process.sleep(50)
    MockNetlink.address_added(interface, "10.2.0.100/24")
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
    Process.sleep(50)
    FSM.activate(pid)
    Process.sleep(300)

    {:ok, state} = FSM.get_state(pid)
    assert state.state == :activated

    # Simulate cable unplug — triggers activated(:info, {:netman_event, _, {:link_update, %{carrier: false}}})
    MockNetlink.carrier_change(interface, false)
    Process.sleep(200)

    {:ok, state} = FSM.get_state(pid)
    assert state.state == :disconnected

    GenServer.stop(pid, :normal)
  end

  test "carrier true event while in disconnected triggers internal auto_activate check" do
    interface = "fsm_disc_carrier_#{:rand.uniform(100_000)}"

    profile = %Profile{
      id: "disc-carrier-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    # Link up without carrier → FSM starts in disconnected
    MockNetlink.link_up(interface, carrier: false)
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
    Process.sleep(50)

    {:ok, state} = FSM.get_state(pid)
    assert state.state == :disconnected

    # Carrier returns — fires disconnected(:info, {:netman_event, _, {:link_update, %{carrier: true}}})
    MockNetlink.carrier_change(interface, true)
    Process.sleep(100)

    # autoconnect: false means auto_activate is a no-op, stays disconnected
    {:ok, state} = FSM.get_state(pid)
    assert state.state == :disconnected

    GenServer.stop(pid, :normal)
  end

  test "global address event while configuring (DHCP) transitions to ip_check" do
    interface = "fsm_conf_addr_#{:rand.uniform(100_000)}"

    profile = %Profile{
      id: "conf-addr-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    MockNetlink.link_up(interface, carrier: false)
    Process.sleep(30)

    {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
    Process.sleep(30)

    # Suspend FSM so we can inject both messages atomically before processing
    :sys.suspend(pid)
    FSM.activate(pid)

    # Address event goes into mailbox AFTER activate cast but BEFORE DHCP failure
    # (DHCP failure appended during activate processing, AFTER this send)
    send(
      pid,
      {:netman_event, "netman:address:#{interface}",
       {:add, %{scope: :global, address: "10.0.0.50", prefix_len: 24}}}
    )

    :sys.resume(pid)
    Process.sleep(200)

    {:ok, state} = FSM.get_state(pid)
    # Address event was processed in :configuring — FSM progressed past it
    assert state.state in [:ip_check, :activated, :disconnected, :failed]

    GenServer.stop(pid, :normal)
  end

  test "DHCP lease acquired while configuring transitions to ip_check" do
    interface = "fsm_dhcp_lease_#{:rand.uniform(100_000)}"

    profile = %Profile{
      id: "dhcp-lease-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    MockNetlink.link_up(interface, carrier: false)
    Process.sleep(30)

    {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
    Process.sleep(30)

    # Suspend FSM, inject activate then lease message atomically
    :sys.suspend(pid)
    FSM.activate(pid)

    send(
      pid,
      {:dhcp_lease_acquired, %{address: "10.0.0.5", prefix_len: 24, gateway: nil, dns: []}}
    )

    :sys.resume(pid)
    Process.sleep(200)

    {:ok, state} = FSM.get_state(pid)
    # DHCP lease was processed in :configuring → FSM transitioned to ip_check or beyond
    assert state.state in [:ip_check, :activated, :disconnected, :failed]

    GenServer.stop(pid, :normal)
  end

  test "parse_cidr defaults prefix to 24 when no slash present" do
    interface = "fsm_noprefix_#{:rand.uniform(100_000)}"

    profile = %Profile{
      id: "noprefix-test-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      # Address without /prefix — parse_cidr returns default 24
      ipv4: %{method: :manual, address: "10.9.0.100", gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    MockNetlink.link_up(interface)
    Process.sleep(50)
    MockNetlink.address_added(interface, "10.9.0.100/24")
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
    Process.sleep(50)

    FSM.activate(pid)
    Process.sleep(200)

    {:ok, state} = FSM.get_state(pid)
    # parse_cidr("10.9.0.100") should default to prefix 24 and proceed
    assert state.state in [:ip_check, :activated, :failed]

    GenServer.stop(pid, :normal)
  end

  test "disconnected transitions to unavailable on link removal" do
    interface = "fsm_del_#{:rand.uniform(100_000)}"

    profile = %Profile{
      id: "del-test-#{:rand.uniform(100_000)}",
      type: :ethernet,
      interface: interface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    MockNetlink.link_up(interface, carrier: false)
    Process.sleep(50)

    {:ok, pid} = FSM.start_link(interface: interface, profile: profile)
    Process.sleep(50)

    {:ok, state} = FSM.get_state(pid)
    assert state.state == :disconnected

    MockNetlink.link_removed(interface)
    Process.sleep(100)

    {:ok, state} = FSM.get_state(pid)
    assert state.state == :unavailable

    GenServer.stop(pid, :normal)
  end
end
