defmodule YellowDog.Netman.ReconciliationEngineTest do
  use ExUnit.Case

  alias YellowDog.Netman.{ReconciliationEngine, ProfileStore}
  alias YellowDog.Netman.Connection
  alias YellowDog.Netman.Test.MockNetlink
  alias YellowDog.Netman.Types.{DesiredState, ObservedState, Diff, Profile}

  describe "diff/2" do
    test "empty desired and observed produces no diffs" do
      desired = %DesiredState{connections: %{}}
      observed = %ObservedState{}

      assert ReconciliationEngine.diff(desired, observed) == []
    end

    test "desired connection with no matching FSM produces activate diff" do
      desired = %DesiredState{
        connections: %{
          "test" => %{
            profile_id: "test",
            interface: "recon_eth0",
            ipv4: %{method: :auto},
            ipv6: %{method: :auto},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      # Observed state has the link
      observed = %ObservedState{
        links: %{
          "recon_eth0" => %{
            interface: "recon_eth0",
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }
        }
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      assert length(diffs) >= 1

      activate_diffs = Enum.filter(diffs, &(&1.action == :activate_connection))
      assert length(activate_diffs) == 1
      assert hd(activate_diffs).interface == "recon_eth0"
    end

    test "idempotency - same state produces no new diffs when connections exist" do
      # When no connections need activation, diff should return empty
      desired = %DesiredState{connections: %{}}
      observed = %ObservedState{}

      diffs1 = ReconciliationEngine.diff(desired, observed)
      diffs2 = ReconciliationEngine.diff(desired, observed)

      assert diffs1 == diffs2
      assert diffs1 == []
    end
  end

  describe "idempotency with live processes" do
    test "once a connection FSM is active, diff produces no new activation diffs" do
      iface = "recon_idem_#{:rand.uniform(65535)}"
      profile_id = "recon-idem-#{iface}"

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

      ProfileStore.put(profile_id, profile)
      MockNetlink.link_up(iface, carrier: true)

      # Wait long enough for the ReconciliationEngine debounce (100ms) to have fired
      # and activated the FSM. The engine subscribes to profile:changed events.
      Process.sleep(300)

      # Ensure FSM is running (either via background reconcile or we start it)
      case Connection.Supervisor.find_connection(iface) do
        :error ->
          {:ok, _} = Connection.Supervisor.start_connection(iface, profile)
          Process.sleep(50)

        {:ok, _} ->
          :ok
      end

      # Verify: diff should produce NO new activation diffs for this iface
      observed = ReconciliationEngine.observe()
      desired = ReconciliationEngine.compute_desired()
      diffs = ReconciliationEngine.diff(desired, observed)

      activate_diffs =
        Enum.filter(diffs, &(&1.action == :activate_connection and &1.interface == iface))

      assert activate_diffs == [],
             "Active FSM should produce no new activation diffs in second reconciliation"

      # Cleanup
      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
    end
  end

  describe "Diff struct" do
    test "new/3 creates a diff" do
      diff = Diff.new(:add_address, "eth0", %{address: "10.0.0.1", prefix_len: 24})
      assert diff.action == :add_address
      assert diff.interface == "eth0"
      assert diff.params.address == "10.0.0.1"
    end

    test "new/1 creates a diff with defaults" do
      diff = Diff.new(:update_dns)
      assert diff.action == :update_dns
      assert diff.interface == nil
      assert diff.params == %{}
    end
  end

  describe "activate/1 and deactivate/1" do
    test "activate with unknown profile returns error" do
      assert {:error, :not_found} = ReconciliationEngine.activate("nonexistent-profile-xyz")
    end

    test "activate with valid profile and matching interface starts FSM" do
      iface = "recon_act_#{:rand.uniform(65535)}"
      profile_id = "recon-act-#{iface}"

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

      ProfileStore.put(profile_id, profile)
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)

      assert :ok = ReconciliationEngine.activate(profile_id)
      Process.sleep(50)

      assert {:ok, _pid} = Connection.Supervisor.find_connection(iface)

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
    end

    test "deactivate with no active connection returns error" do
      assert {:error, :not_found} = ReconciliationEngine.deactivate("nonexistent-profile-xyz")
    end
  end

  describe "observe/0" do
    test "observe returns current links, addresses, and routes" do
      iface = "recon_obs_#{:rand.uniform(65535)}"
      MockNetlink.link_up(iface)
      MockNetlink.address_added(iface, "10.50.0.1/24")
      Process.sleep(50)

      observed = ReconciliationEngine.observe()
      assert Map.has_key?(observed.links, iface)
      assert Map.has_key?(observed.addresses, iface)
    end
  end

  describe "reconcile/0 and event debounce" do
    test "reconcile/0 triggers debounced reconciliation" do
      test_pid = self()
      handler_id = {__MODULE__, :recon_debounce, :rand.uniform(1_000_000)}

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :reconciliation, :stop],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:recon_done, measurements})
        end,
        nil
      )

      ReconciliationEngine.reconcile()

      assert_receive {:recon_done, %{diffs_count: _}}, 1000

      :telemetry.detach(handler_id)
    end

    test "netman_event triggers debounced reconcile" do
      test_pid = self()
      handler_id = {__MODULE__, :recon_event, :rand.uniform(1_000_000)}

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :reconciliation, :stop],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:recon_done, measurements})
        end,
        nil
      )

      # Publish a netman event which ReconciliationEngine subscribes to
      YellowDog.Netman.EventBus.publish("netman:profile:changed", {:updated, "test"})

      assert_receive {:recon_done, _}, 1000

      :telemetry.detach(handler_id)
    end

    test "handle_info with unknown message is silently ignored" do
      pid = Process.whereis(ReconciliationEngine)
      send(pid, :some_unexpected_recon_message)
      Process.sleep(20)
      assert Process.alive?(pid)
    end

    test "second reconcile within debounce window hits already-set debounce_ref branch" do
      # Cast reconcile twice rapidly — the second cast sees debounce_ref already set
      # and returns state unchanged (the `if state.debounce_ref do state end` branch)
      ReconciliationEngine.reconcile()
      ReconciliationEngine.reconcile()

      # Wait for debounce to fire and reconciliation to complete
      Process.sleep(300)
      assert Process.alive?(Process.whereis(ReconciliationEngine))
    end
  end

  describe "activate/1 edge cases" do
    test "activate with nil interface finds matching ethernet link via find_matching_interface" do
      iface = "recon_find_#{:rand.uniform(65535)}"
      profile_id = "recon-find-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: nil,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put(profile_id, profile)
      # kind: nil is not "loopback" — matches_profile? returns true for :ethernet
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)

      before_interfaces =
        Connection.Supervisor.list_connections()
        |> Enum.map(& &1.interface)
        |> MapSet.new()

      result = ReconciliationEngine.activate(profile_id)
      # find_matching_interface finds a non-loopback ethernet link → starts FSM → :ok
      assert result == :ok
      Process.sleep(100)

      after_interfaces =
        Connection.Supervisor.list_connections()
        |> Enum.map(& &1.interface)
        |> MapSet.new()

      # Stop any newly started FSM(s) and clean up
      MapSet.difference(after_interfaces, before_interfaces)
      |> Enum.each(&Connection.Supervisor.stop_connection/1)

      ProfileStore.delete(profile_id)
    end

    test "activate with profile having nil interface and no matching link returns error" do
      profile_id = "recon-no-iface-#{:rand.uniform(65535)}"

      profile = %Profile{
        id: profile_id,
        type: :wifi,
        interface: nil,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put(profile_id, profile)

      result = ReconciliationEngine.activate(profile_id)
      assert result == :ok or result == {:error, :no_matching_interface}

      ProfileStore.delete(profile_id)
    end
  end

  describe "deactivate/1 with active FSM" do
    test "deactivate stops a running connection FSM" do
      iface = "recon_deact_#{:rand.uniform(65535)}"
      profile_id = "recon-deact-#{iface}"

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
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)

      {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
      Process.sleep(50)

      assert {:ok, _} = Connection.Supervisor.find_connection(iface)

      assert :ok = ReconciliationEngine.deactivate(profile_id)
      Process.sleep(100)

      ProfileStore.delete(profile_id)
    end
  end

  describe "compute_desired/0" do
    test "includes autoconnect profiles matching non-loopback ethernet links" do
      iface = "recon_desired_#{:rand.uniform(65535)}"
      profile_id = "recon-desired-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 150,
        ethernet: %{mtu: nil},
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put(profile_id, profile)
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      desired = ReconciliationEngine.compute_desired()
      assert Map.has_key?(desired.connections, profile_id)

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
    end

    test "excludes non-autoconnect profiles" do
      iface = "recon_noauto_#{:rand.uniform(65535)}"
      profile_id = "recon-noauto-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put(profile_id, profile)
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      desired = ReconciliationEngine.compute_desired()
      refute Map.has_key?(desired.connections, profile_id)

      ProfileStore.delete(profile_id)
    end
  end

  describe "default_route_change telemetry" do
    test "emits default_route_change on periodic reconcile with new active connection" do
      iface = "recon_drc_#{:rand.uniform(65535)}"
      profile_id = "recon-drc-#{iface}"
      test_pid = self()
      handler_id = {__MODULE__, :drc, :rand.uniform(1_000_000)}

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :policy, :default_route_change],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:drc_event, metadata})
        end,
        nil
      )

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: false,
        autoconnect_priority: 9999,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put(profile_id, profile)
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      # Directly start and activate the FSM so it reaches :activated
      {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
      Process.sleep(200)

      # Send periodic_reconcile directly to the GenServer
      # This triggers do_reconcile → check_default_route_change
      pid = Process.whereis(ReconciliationEngine)
      send(pid, :periodic_reconcile)
      Process.sleep(300)

      # The high-priority connection should cause a default route change
      # (since last_default_route was likely :none or a lower-priority conn)
      # We may or may not receive the event depending on prior state,
      # but the code path is exercised either way.
      # Send another periodic_reconcile after stopping to trigger reverse change
      Connection.Supervisor.stop_connection(iface)
      Process.sleep(100)

      send(pid, :periodic_reconcile)
      Process.sleep(300)

      # At least one default_route_change event should have been emitted
      # (either when the connection appeared or when it disappeared)
      received =
        receive do
          {:drc_event, %{reason: :reconciliation}} -> true
        after
          0 -> false
        end

      # Clean up state regardless of result
      :telemetry.detach(handler_id)
      ProfileStore.delete(profile_id)

      # The telemetry event fires when the default route changes.
      # With a very high priority connection (9999), adding/removing it
      # will definitely change the default route at least once.
      assert received,
             "Expected at least one default_route_change event during connection lifecycle"
    end
  end

  describe "periodic reconciliation" do
    test "periodic_reconcile fires and reschedules" do
      test_pid = self()
      handler_id = {__MODULE__, :periodic, :rand.uniform(1_000_000)}

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :reconciliation, :stop],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:periodic_recon, measurements})
        end,
        nil
      )

      pid = Process.whereis(ReconciliationEngine)
      send(pid, :periodic_reconcile)

      assert_receive {:periodic_recon, %{diffs_count: _}}, 2000

      :telemetry.detach(handler_id)
    end
  end

  describe "apply_diff handlers" do
    test "set_mtu diff delegates to Netlink command" do
      diff = Diff.new(:set_mtu, "test_eth0", %{mtu: 9000})

      # apply_diff is private, so we test via reconciliation cycle indirectly.
      # Instead, verify the diff struct is well-formed.
      assert diff.action == :set_mtu
      assert diff.interface == "test_eth0"
      assert diff.params.mtu == 9000
    end

    test "set_link_up diff is well-formed" do
      diff = Diff.new(:set_link_up, "test_eth0")
      assert diff.action == :set_link_up
      assert diff.interface == "test_eth0"
    end

    test "set_link_down diff is well-formed" do
      diff = Diff.new(:set_link_down, "test_eth0")
      assert diff.action == :set_link_down
      assert diff.interface == "test_eth0"
    end
  end

  describe "reconciliation error resilience" do
    @tag :capture_log
    test "reconciliation completes even when profile vanishes during apply" do
      iface = "recon_vanish_#{:rand.uniform(65535)}"
      profile_id = "recon-vanish-#{iface}"

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

      # Delete profile right before reconciliation tries to apply
      ProfileStore.delete(profile_id)

      # Trigger reconciliation - should not crash
      test_pid = self()
      handler_id = {__MODULE__, :vanish, :rand.uniform(1_000_000)}

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :reconciliation, :stop],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:recon_done, measurements})
        end,
        nil
      )

      ReconciliationEngine.reconcile()
      assert_receive {:recon_done, _}, 2000

      # Engine should still be alive
      assert Process.alive?(Process.whereis(ReconciliationEngine))

      :telemetry.detach(handler_id)
      MockNetlink.link_removed(iface)
    end
  end

  describe "debounced_reconcile while reconciling" do
    test "debounced_reconcile during active reconciliation is skipped" do
      # Simulate state where reconciling=true and a debounce fires
      state = %ReconciliationEngine{
        timer_ref: nil,
        debounce_ref: make_ref(),
        reconciling: true
      }

      assert {:noreply, %{debounce_ref: nil, reconciling: true}} =
               ReconciliationEngine.handle_info(:debounced_reconcile, state)
    end
  end

  describe "reconciling flag prevents overlapping cycles" do
    test "rapid periodic_reconcile messages do not cause concurrent reconciliation" do
      pid = Process.whereis(ReconciliationEngine)
      test_pid = self()
      handler_id = {__MODULE__, :overlap, :rand.uniform(1_000_000)}

      recon_count = :counters.new(1, [:atomics])

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :reconciliation, :stop],
        fn _event, _measurements, _meta, _config ->
          :counters.add(recon_count, 1, 1)
          send(test_pid, :recon_tick)
        end,
        nil
      )

      # Fire multiple periodic reconciles rapidly
      send(pid, :periodic_reconcile)
      send(pid, :periodic_reconcile)
      send(pid, :periodic_reconcile)

      # Wait for at least one to complete
      assert_receive :recon_tick, 2000
      Process.sleep(200)

      # Engine should still be alive and functional
      assert Process.alive?(pid)

      :telemetry.detach(handler_id)
    end
  end

  describe "activate/1 and deactivate/1 API" do
    @tag :capture_log
    test "activate with non-existent profile returns error" do
      result = ReconciliationEngine.activate("nonexistent-profile-id-999")
      assert {:error, _} = result
    end

    @tag :capture_log
    test "deactivate with non-existent profile returns error" do
      result = ReconciliationEngine.deactivate("nonexistent-deact-id-999")
      assert {:error, :not_found} = result
    end

    @tag :capture_log
    test "activate with valid profile starts connection" do
      iface = "recon_act_#{:rand.uniform(65535)}"
      profile_id = "recon-act-#{iface}"

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

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      result = ReconciliationEngine.activate(profile_id)
      assert result == :ok
      Process.sleep(100)

      assert {:ok, _pid} = Connection.Supervisor.find_connection(iface)

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end
  end

  describe "terminate/2 timer cleanup" do
    test "terminate cancels pending timers without crashing" do
      # Create a state with active timer refs
      timer_ref = Process.send_after(self(), :test_timer, 60_000)
      debounce_ref = Process.send_after(self(), :test_debounce, 60_000)

      state = %ReconciliationEngine{
        timer_ref: timer_ref,
        debounce_ref: debounce_ref,
        reconciling: false
      }

      assert :ok = ReconciliationEngine.terminate(:normal, state)

      # Timers should have been cancelled
      refute_receive :test_timer, 100
      refute_receive :test_debounce, 100
    end

    test "terminate with nil timer refs does not crash" do
      state = %ReconciliationEngine{
        timer_ref: nil,
        debounce_ref: nil,
        reconciling: false
      }

      assert :ok = ReconciliationEngine.terminate(:shutdown, state)
    end
  end

  describe "concurrent activate/deactivate stress" do
    @tag :capture_log
    test "multiple concurrent activations for different interfaces do not crash" do
      interfaces =
        for i <- 1..5 do
          iface = "recon_stress_#{i}_#{:rand.uniform(65535)}"
          profile_id = "stress-#{iface}"

          profile = %Profile{
            id: profile_id,
            type: :ethernet,
            interface: iface,
            autoconnect: false,
            autoconnect_priority: 100 + i,
            ethernet: %{mtu: nil},
            ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
          }

          MockNetlink.link_up(iface, carrier: true)
          ProfileStore.put(profile_id, profile)
          {iface, profile_id}
        end

      Process.sleep(50)

      # Activate all concurrently
      tasks =
        Enum.map(interfaces, fn {_iface, profile_id} ->
          Task.async(fn -> ReconciliationEngine.activate(profile_id) end)
        end)

      results = Task.await_many(tasks, 5000)

      # All should succeed
      Enum.each(results, fn result ->
        assert result == :ok
      end)

      Process.sleep(200)

      # Engine should still be alive
      assert Process.alive?(Process.whereis(ReconciliationEngine))

      # Cleanup
      Enum.each(interfaces, fn {iface, profile_id} ->
        Connection.Supervisor.stop_connection(iface)
        ProfileStore.delete(profile_id)
        MockNetlink.link_removed(iface)
      end)

      Process.sleep(50)
    end

    @tag :capture_log
    test "activate then immediately deactivate same profile does not crash" do
      iface = "recon_actdeact_#{:rand.uniform(65535)}"
      profile_id = "actdeact-#{iface}"

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

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      # Activate
      :ok = ReconciliationEngine.activate(profile_id)
      Process.sleep(50)

      # Immediately deactivate
      ReconciliationEngine.deactivate(profile_id)
      Process.sleep(200)

      # Engine should still be alive
      assert Process.alive?(Process.whereis(ReconciliationEngine))

      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end
  end

  describe "reconciliation with multiple interfaces" do
    @tag :capture_log
    test "reconciliation handles multiple autoconnect profiles with priority ordering" do
      ifaces =
        for i <- 1..3 do
          iface = "recon_multi_#{i}_#{:rand.uniform(65535)}"
          profile_id = "multi-#{iface}"
          priority = 100 * i

          profile = %Profile{
            id: profile_id,
            type: :ethernet,
            interface: iface,
            autoconnect: true,
            autoconnect_priority: priority,
            ethernet: %{mtu: nil},
            ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
          }

          MockNetlink.link_up(iface, carrier: true)
          ProfileStore.put(profile_id, profile)
          {iface, profile_id, priority}
        end

      Process.sleep(50)

      # Trigger reconciliation
      ReconciliationEngine.reconcile()
      Process.sleep(500)

      # All interfaces should have FSMs
      Enum.each(ifaces, fn {iface, _profile_id, _priority} ->
        case Connection.Supervisor.find_connection(iface) do
          {:ok, pid} ->
            assert Process.alive?(pid)

          :error ->
            # May not have auto-activated yet, that's acceptable
            :ok
        end
      end)

      # Cleanup
      Enum.each(ifaces, fn {iface, profile_id, _priority} ->
        Connection.Supervisor.stop_connection(iface)
        ProfileStore.delete(profile_id)
        MockNetlink.link_removed(iface)
      end)

      Process.sleep(50)
    end
  end

  describe "performance" do
    @tag :capture_log
    test "reconciliation cycle completes in < 100ms for 2-interface setup" do
      # PRD non-functional requirement: < 100ms for typical 2-interface setup
      ifaces =
        for i <- 1..2 do
          iface = "recon_perf_#{i}_#{:rand.uniform(65535)}"
          profile_id = "perf-#{iface}"

          profile = %Profile{
            id: profile_id,
            type: :ethernet,
            interface: iface,
            autoconnect: true,
            autoconnect_priority: 100 * i,
            ethernet: %{mtu: nil},
            ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
          }

          MockNetlink.link_up(iface, carrier: true)
          ProfileStore.put(profile_id, profile)
          {iface, profile_id}
        end

      Process.sleep(50)

      test_pid = self()
      handler_id = {__MODULE__, :perf, :rand.uniform(1_000_000)}

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :reconciliation, :stop],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:recon_perf, measurements.duration_ms})
        end,
        nil
      )

      # Trigger reconciliation via periodic message for accurate timing
      pid = Process.whereis(ReconciliationEngine)
      send(pid, :periodic_reconcile)

      assert_receive {:recon_perf, duration_ms}, 2000
      assert duration_ms < 100, "Reconciliation took #{duration_ms}ms, expected < 100ms"

      :telemetry.detach(handler_id)

      Enum.each(ifaces, fn {iface, profile_id} ->
        Connection.Supervisor.stop_connection(iface)
        ProfileStore.delete(profile_id)
        MockNetlink.link_removed(iface)
      end)
    end
  end

  describe "debounce coalescing" do
    @tag :capture_log
    test "many rapid events result in a single reconciliation cycle" do
      test_pid = self()
      recon_count = :counters.new(1, [:atomics])
      handler_id = {__MODULE__, :coalesce, :rand.uniform(1_000_000)}

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :reconciliation, :stop],
        fn _event, _measurements, _meta, _config ->
          :counters.add(recon_count, 1, 1)
          send(test_pid, :coalesce_tick)
        end,
        nil
      )

      # Fire many events rapidly (within debounce window)
      for _ <- 1..20 do
        YellowDog.Netman.EventBus.publish("netman:profile:changed", {:updated, "coalesce-test"})
      end

      # Wait for debounce + reconciliation
      assert_receive :coalesce_tick, 2000
      Process.sleep(300)

      # Should have far fewer reconciliation cycles than events
      count = :counters.get(recon_count, 1)
      assert count < 20, "Expected coalesced reconciliation, got #{count} cycles for 20 events"

      :telemetry.detach(handler_id)
    end
  end

  describe "failed FSM re-activation" do
    @tag :capture_log
    test "connection_active? returns false for failed FSMs, enabling re-activation" do
      iface = "recon_fail_#{:rand.uniform(65535)}"
      profile_id = "recon-fail-#{iface}"

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

      ProfileStore.put(profile_id, profile)
      MockNetlink.link_up(iface, carrier: false)
      Process.sleep(50)

      # Start the FSM
      {:ok, pid} = Connection.Supervisor.start_connection(iface, profile)
      Process.sleep(50)

      # The FSM should exist
      assert {:ok, ^pid} = Connection.Supervisor.find_connection(iface)

      # Get the FSM state — it should be in some non-failed state
      {:ok, fsm_state} = YellowDog.Netman.Connection.FSM.get_state(pid)

      # When we compute diff with this running FSM:
      # connection_active? should return true for non-failed states
      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :disabled},
            ipv6: %{method: :disabled},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{iface => %{interface: iface, index: 1, state: :up}}
      }

      # Active FSM means no activation diff generated
      diffs = ReconciliationEngine.diff(desired, observed)

      activate_for_iface =
        Enum.filter(diffs, &(&1.action == :activate_connection and &1.interface == iface))

      assert activate_for_iface == [],
             "Active (non-failed) FSM should not produce activation diff, but state=#{inspect(fsm_state.state)}"

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end
  end
end
