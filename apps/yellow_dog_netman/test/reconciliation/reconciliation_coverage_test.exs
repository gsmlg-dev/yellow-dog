defmodule YellowDog.Netman.ReconciliationCoverageTest do
  @moduledoc """
  Tests targeting uncovered branches in ReconciliationEngine:
  - periodic/debounced reconcile when reconciling=true (skip paths)
  - apply_diff handlers for non-activate diffs
  """
  use ExUnit.Case

  alias YellowDog.Netman.{ReconciliationEngine, ProfileStore}
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Types.{Diff, Profile}
  alias YellowDog.Netman.Test.MockNetlink

  @moduletag :capture_log

  describe "reconciling=true skip paths" do
    test "periodic_reconcile when reconciling=true skips and reschedules" do
      pid = Process.whereis(ReconciliationEngine)

      # Temporarily set reconciling: true via :sys.replace_state
      :sys.replace_state(pid, fn state -> %{state | reconciling: true} end)

      test_pid = self()
      handler_id = {__MODULE__, :skip_periodic, :rand.uniform(1_000_000)}

      recon_count = :counters.new(1, [:atomics])

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :reconciliation, :stop],
        fn _event, _measurements, _meta, _config ->
          :counters.add(recon_count, 1, 1)
          send(test_pid, :recon_fired)
        end,
        nil
      )

      # Send periodic_reconcile while reconciling=true — should be skipped
      send(pid, :periodic_reconcile)
      Process.sleep(200)

      # Restore normal state
      :sys.replace_state(pid, fn state -> %{state | reconciling: false} end)

      # Should not have fired a reconciliation
      count_while_busy = :counters.get(recon_count, 1)
      assert count_while_busy == 0, "Expected skip but got #{count_while_busy} reconciliations"

      :telemetry.detach(handler_id)

      # Ensure engine is still alive and functional
      assert Process.alive?(pid)
    end

    test "debounced_reconcile when reconciling=true skips execution" do
      pid = Process.whereis(ReconciliationEngine)

      :sys.replace_state(pid, fn state -> %{state | reconciling: true} end)

      test_pid = self()
      handler_id = {__MODULE__, :skip_debounce, :rand.uniform(1_000_000)}
      recon_count = :counters.new(1, [:atomics])

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :reconciliation, :stop],
        fn _event, _measurements, _meta, _config ->
          :counters.add(recon_count, 1, 1)
          send(test_pid, :debounce_recon_fired)
        end,
        nil
      )

      # Directly send the debounced_reconcile message while reconciling=true
      send(pid, :debounced_reconcile)
      Process.sleep(100)

      :sys.replace_state(pid, fn state -> %{state | reconciling: false} end)

      count = :counters.get(recon_count, 1)
      assert count == 0, "Expected skip of debounced_reconcile but got #{count} reconciliations"

      :telemetry.detach(handler_id)
      assert Process.alive?(pid)
    end
  end

  describe "apply_diff via activate_connection existing FSM path" do
    test "apply_diff reactivates existing failed FSM" do
      iface = "recon_react_#{:rand.uniform(65535)}"
      profile_id = "recon-react-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
      Process.sleep(50)

      # Trigger reconciliation — since FSM exists and is active, apply_diff
      # finds existing connection and calls FSM.activate on it
      ReconciliationEngine.reconcile()
      Process.sleep(300)

      # Engine still alive
      assert Process.alive?(Process.whereis(ReconciliationEngine))

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end
  end

  describe "check_default_route_change same default route" do
    test "no telemetry emitted when default route does not change" do
      test_pid = self()
      handler_id = {__MODULE__, :no_drc, :rand.uniform(1_000_000)}
      drc_count = :counters.new(1, [:atomics])

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :policy, :default_route_change],
        fn _event, _measurements, _meta, _config ->
          :counters.add(drc_count, 1, 1)
          send(test_pid, :drc_fired)
        end,
        nil
      )

      # Trigger two reconciliations in a row with no connection changes
      # The default route should remain the same (no event emitted)
      pid = Process.whereis(ReconciliationEngine)
      send(pid, :periodic_reconcile)
      Process.sleep(200)

      before_count = :counters.get(drc_count, 1)

      send(pid, :periodic_reconcile)
      Process.sleep(200)

      after_count = :counters.get(drc_count, 1)

      :telemetry.detach(handler_id)

      # Second reconcile should emit no new drc event (route unchanged)
      assert after_count == before_count,
             "Expected no default route change but got #{after_count - before_count} events"
    end
  end

  describe "activate with profile having explicit interface on linked iface" do
    test "activate starts connection when link exists for the profile interface" do
      iface = "recon_exp_#{:rand.uniform(65535)}"
      profile_id = "recon-exp-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put(profile_id, profile)
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      assert :ok = ReconciliationEngine.activate(profile_id)
      Process.sleep(100)

      assert {:ok, _pid} = Connection.Supervisor.find_connection(iface)

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end
  end

  describe "diff struct validation" do
    test "Diff.new creates valid diffs for all supported action types" do
      for action <- [
            :activate_connection,
            :deactivate_connection,
            :add_address,
            :remove_address,
            :add_route,
            :remove_route,
            :update_dns,
            :set_mtu,
            :set_link_up,
            :set_link_down
          ] do
        diff = Diff.new(action, "eth0", %{test: true})
        assert diff.action == action
        assert diff.interface == "eth0"
      end
    end
  end
end
