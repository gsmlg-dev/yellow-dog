defmodule YellowDog.Netman.Integration.DhcpIntegrationTest do
  @moduledoc """
  Integration tests verifying DHCP lifecycle through the Connection FSM.

  In the test environment, `YellowDog.DhcpClient` is available but
  `start_interface/2` fails on non-existent interfaces (no MAC address).
  These tests verify the failure/recovery paths that occur in real
  production when DHCP cannot acquire a lease.
  """
  use ExUnit.Case

  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.ProfileStore
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.Profile

  @moduletag :integration
  @moduletag :capture_log

  setup do
    iface = "dhcp_eth#{:rand.uniform(65535)}"

    profile = %Profile{
      id: "dhcp-test-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: false,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: ["8.8.8.8"]},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(profile.id, profile)

    on_exit(fn ->
      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile.id)
    end)

    %{iface: iface, profile: profile}
  end

  test "DHCP activation on non-existent interface transitions to failed", %{
    iface: iface,
    profile: profile
  } do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(50)

    Connection.FSM.activate(pid)
    Process.sleep(200)

    {:ok, state} = Connection.FSM.get_state(pid)

    # DHCP client fails because the fake interface has no MAC → :failed
    assert state.state == :failed
    assert state.error == :dhcp_failed
  end

  test "failed DHCP connection resets to disconnected on carrier event", %{
    iface: iface,
    profile: profile
  } do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(50)

    Connection.FSM.activate(pid)
    Process.sleep(200)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :failed

    # Carrier event from :failed clears error and moves to :disconnected
    # With autoconnect=false, stays in :disconnected (awaiting explicit activate)
    MockNetlink.carrier_change(iface, true)
    Process.sleep(200)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :disconnected
    assert state.error == nil
  end

  test "failed DHCP connection resets to disconnected on explicit activate", %{
    iface: iface,
    profile: profile
  } do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(50)

    Connection.FSM.activate(pid)
    Process.sleep(200)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :failed

    # Re-activate from :failed clears error → :disconnected → :auto_activate
    # With autoconnect=false, stays in :disconnected
    Connection.FSM.activate(pid)
    Process.sleep(200)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :disconnected
    assert state.error == nil
  end

  test "DHCP failure emits telemetry state_change events", %{iface: iface, profile: profile} do
    ref = make_ref()
    test_pid = self()

    handler_id = "dhcp-test-telemetry-#{iface}"

    :telemetry.attach(
      handler_id,
      [:yellow_dog, :netman, :connection, :state_change],
      fn _event, _measurements, metadata, _config ->
        if metadata.interface == iface do
          send(test_pid, {:telemetry_event, ref, metadata})
        end
      end,
      nil
    )

    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(50)

    Connection.FSM.activate(pid)
    Process.sleep(200)

    :telemetry.detach(handler_id)

    # Collect all telemetry events for this interface
    events = collect_telemetry(ref, [])

    # Should have transitions: disconnected → prepare → configuring → failed
    states = Enum.map(events, fn meta -> {meta.from, meta.to} end)
    assert {:configuring, :failed} in states
  end

  test "DHCP profile with autoconnect fails gracefully on startup", %{iface: iface} do
    auto_profile = %Profile{
      id: "dhcp-auto-#{iface}",
      type: :ethernet,
      interface: iface,
      autoconnect: true,
      autoconnect_priority: 100,
      ethernet: %{mtu: nil},
      ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
      ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
    }

    ProfileStore.put(auto_profile.id, auto_profile)

    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    # With autoconnect=true and carrier present, FSM will auto-activate
    {:ok, pid} = Connection.Supervisor.start_connection(iface, auto_profile)
    Process.sleep(300)

    {:ok, state} = Connection.FSM.get_state(pid)
    # Auto-activation triggers DHCP which fails → :failed (graceful, no crash)
    assert state.state == :failed
    assert is_pid(pid)

    Connection.Supervisor.stop_connection(iface)
    ProfileStore.delete(auto_profile.id)
  end

  test "connection stops cleanly from failed DHCP state", %{iface: iface, profile: profile} do
    MockNetlink.link_up(iface, carrier: true)
    Process.sleep(50)

    {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
    Process.sleep(50)

    Connection.FSM.activate(pid)
    Process.sleep(200)

    {:ok, state} = Connection.FSM.get_state(pid)
    assert state.state == :failed

    # Stop should succeed without crash
    assert :ok = Connection.Supervisor.stop_connection(iface)
    Process.sleep(50)

    assert :error = Connection.Supervisor.find_connection(iface)
  end

  ## Helpers

  defp collect_telemetry(ref, acc) do
    receive do
      {:telemetry_event, ^ref, metadata} ->
        collect_telemetry(ref, [metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
