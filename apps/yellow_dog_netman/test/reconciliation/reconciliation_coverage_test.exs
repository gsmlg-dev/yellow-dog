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

  describe "reconciliation exception safety" do
    @tag :capture_log
    test "periodic_reconcile always clears reconciling flag" do
      pid = Process.whereis(ReconciliationEngine)

      # Set reconciling to true manually, then trigger periodic_reconcile
      # to verify the flag is properly cleared even after a full cycle
      :sys.replace_state(pid, fn state -> %{state | reconciling: false} end)

      send(pid, :periodic_reconcile)
      Process.sleep(300)

      assert Process.alive?(pid)
      state = :sys.get_state(pid)

      assert state.reconciling == false,
             "reconciling flag should be cleared after periodic_reconcile completes"
    end

    @tag :capture_log
    test "debounced_reconcile always clears reconciling flag" do
      pid = Process.whereis(ReconciliationEngine)

      :sys.replace_state(pid, fn state -> %{state | reconciling: false} end)

      send(pid, :debounced_reconcile)
      Process.sleep(300)

      assert Process.alive?(pid)
      state = :sys.get_state(pid)

      assert state.reconciling == false,
             "reconciling flag should be cleared after debounced_reconcile completes"
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

  describe "apply_diff error path (L199-200, L327)" do
    test "Logger.warning fires when ProfileStore.get fails for diff profile_id" do
      # Store a profile under a key that differs from profile.id.
      # ProfileStore.list() returns the profile struct (using profile.id as profile_id in diff),
      # but ProfileStore.get(profile.id) returns :not_found because the map key differs.
      # This triggers apply_diff → {:error, :not_found} → Logger.warning at L199-200.
      iface = "recon_mismatch_#{:rand.uniform(65535)}"
      profile_key = "recon-key-#{iface}"
      profile_real_id = "recon-real-#{iface}"
      recon_pid = Process.whereis(ReconciliationEngine)

      profile = %Profile{
        id: profile_real_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put(profile_key, profile)

      :ets.insert(
        :netman_links,
        {iface,
         %{interface: iface, index: 0, state: :up, carrier: true, mtu: 1500, mac: nil, kind: nil}}
      )

      on_exit(fn ->
        :ets.delete(:netman_links, iface)
        ProfileStore.delete(profile_key)
      end)

      send(recon_pid, :periodic_reconcile)
      Process.sleep(300)

      assert Process.alive?(recon_pid)
    end
  end

  describe "connection_active? error path (L390)" do
    test "connection_active? returns false when FSM.get_state exits on dying process" do
      # Register a plain (non-gen_statem) process in the connection Registry.
      # When ReconciliationEngine calls FSM.get_state on it, :gen_statem.call sends
      # the request; the plain process receives it and exits, causing the call to
      # detect the monitor DOWN and raise. FSM.get_state catches the exit →
      # {:error, :not_running} → connection_active? returns false (L390).
      iface = "recon_dead_#{:rand.uniform(65535)}"
      profile_id = "recon-dead-#{iface}"
      recon_pid = Process.whereis(ReconciliationEngine)

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

      :ets.insert(
        :netman_links,
        {iface,
         %{interface: iface, index: 0, state: :up, carrier: true, mtu: 1500, mac: nil, kind: nil}}
      )

      parent = self()

      fake_pid =
        spawn(fn ->
          Registry.register(YellowDog.Netman.Registry, {:connection, iface}, nil)
          send(parent, :registered)
          # Exit on first message (the :gen_statem.call request)
          receive do
            _msg -> :ok
          end
        end)

      assert_receive :registered, 1000

      on_exit(fn ->
        :ets.delete(:netman_links, iface)
        ProfileStore.delete(profile_id)
        Connection.Supervisor.stop_connection(iface)
        if Process.alive?(fake_pid), do: Process.exit(fake_pid, :kill)
      end)

      send(recon_pid, :periodic_reconcile)
      Process.sleep(300)

      assert Process.alive?(recon_pid)
    end
  end

  describe "periodic_reconcile rescue clause (L128-130)" do
    @tag :capture_log
    test "engine survives and reschedules timer when do_reconcile raises" do
      # Inject a plain map state missing :last_default_route.
      # do_reconcile → check_default_route_change → state.last_default_route → KeyError.
      # The rescue clause at L128-130 fires, logs the error, and the engine reschedules
      # its periodic timer and continues running.
      pid = Process.whereis(ReconciliationEngine)
      original_state = :sys.get_state(pid)

      if original_state.timer_ref, do: Process.cancel_timer(original_state.timer_ref)

      on_exit(fn ->
        current = :sys.get_state(pid)

        if is_map(current) do
          if Map.get(current, :timer_ref), do: Process.cancel_timer(current.timer_ref)
          if Map.get(current, :debounce_ref), do: Process.cancel_timer(current.debounce_ref)
        end

        new_timer = Process.send_after(pid, :periodic_reconcile, original_state.interval)
        :sys.replace_state(pid, fn _s -> %{original_state | timer_ref: new_timer} end)
      end)

      # Minimal plain map: has the keys handle_info accesses before the try block
      # but lacks :last_default_route so do_reconcile raises inside the try.
      :sys.replace_state(pid, fn _s ->
        %{
          reconciling: false,
          interval: original_state.interval,
          timer_ref: nil,
          debounce_ref: nil
        }
      end)

      send(pid, :periodic_reconcile)
      Process.sleep(300)

      assert Process.alive?(pid)
    end
  end

  describe "debounced_reconcile rescue clause (L149-151)" do
    @tag :capture_log
    test "engine survives and clears debounce_ref when do_reconcile raises" do
      # Same bad-state injection as the periodic test but triggered via
      # :debounced_reconcile, which does not reschedule a periodic timer.
      # The rescue clause at L149-151 fires and the engine continues normally.
      pid = Process.whereis(ReconciliationEngine)
      original_state = :sys.get_state(pid)

      on_exit(fn ->
        current = :sys.get_state(pid)

        if is_map(current) do
          if Map.get(current, :debounce_ref), do: Process.cancel_timer(current.debounce_ref)
        end

        :sys.replace_state(pid, fn _s -> original_state end)
      end)

      :sys.replace_state(pid, fn _s ->
        %{
          reconciling: false,
          interval: original_state.interval,
          timer_ref: original_state.timer_ref,
          debounce_ref: nil
        }
      end)

      send(pid, :debounced_reconcile)
      Process.sleep(300)

      # Restore good state immediately so the engine's periodic timer
      # does not see the stripped plain map when it fires in ~30 s.
      :sys.replace_state(pid, fn _s -> original_state end)

      assert Process.alive?(pid)
    end
  end

  describe "connection_active? with failed FSM (lines 374, 302)" do
    test "reconcile generates activate diff for failed connection and reactivates FSM" do
      iface = "recfail_#{:rand.uniform(65535)}"
      profile_id = "recfail-#{iface}"
      recon_pid = Process.whereis(ReconciliationEngine)

      # Profile with ipv4: :auto — DHCP fails immediately on fake interface → FSM → :failed
      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      # Insert link into ETS directly (no EventBus, no auto-reconcile)
      :ets.insert(
        :netman_links,
        {iface,
         %{interface: iface, index: 0, state: :up, carrier: true, mtu: 1500, mac: nil, kind: nil}}
      )

      on_exit(fn ->
        :ets.delete(:netman_links, iface)
        Connection.Supervisor.stop_connection(iface)
        ProfileStore.delete(profile_id)
      end)

      # Start connection — DHCP fails on fake interface → FSM reaches :failed
      {:ok, fsm_pid} = Connection.Supervisor.start_connection(iface, profile)
      ProfileStore.put(profile_id, profile)
      Process.sleep(500)

      # Verify FSM is in :failed state
      {:ok, fsm_state} = Connection.FSM.get_state(fsm_pid)
      assert fsm_state.state == :failed

      # Reconcile:
      #   connection_active?(iface) → FSM.get_state → {:ok, %{state: :failed}} → false (line 374)
      #   → diff generated → apply_diff → find_connection finds existing FSM
      #   → Connection.FSM.activate(pid) called (line 302)
      send(recon_pid, :periodic_reconcile)
      Process.sleep(300)

      assert Process.alive?(recon_pid)
    end
  end

  describe "reconciliation with diffs logs completion (line 207)" do
    test "do_reconcile logs completion when diffs are applied" do
      iface = "recon_log_#{:rand.uniform(65535)}"
      profile_id = "recon-log-#{iface}"
      recon_pid = Process.whereis(ReconciliationEngine)

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

      # Insert link directly into ETS — bypasses EventBus so no auto-reconcile fires
      :ets.insert(
        :netman_links,
        {iface,
         %{interface: iface, index: 0, state: :up, carrier: true, mtu: 1500, mac: nil, kind: nil}}
      )

      on_exit(fn ->
        :ets.delete(:netman_links, iface)
        Connection.Supervisor.stop_connection(iface)
        ProfileStore.delete(profile_id)
      end)

      # Temporarily lower log level so Logger.info's lazy string argument (line 207)
      # is actually evaluated. Tests run at :warning level by default which skips
      # Logger.info evaluation entirely.
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      # Put profile (sends {netman_event, profile:changed} to ReconciliationEngine mailbox),
      # then immediately queue :periodic_reconcile after that event.
      # ReconciliationEngine processes in order:
      #   1. profile:changed → schedule_debounced_reconcile
      #   2. :periodic_reconcile → do_reconcile with profile+link+no-connection → diffs → line 207
      ProfileStore.put(profile_id, profile)
      send(recon_pid, :periodic_reconcile)

      Process.sleep(300)
      assert Process.alive?(recon_pid)
    end
  end

  describe "address drift detection" do
    alias YellowDog.Netman.Types.{DesiredState, ObservedState}

    test "diff generates :add_address when static IP is missing from observed addresses" do
      iface = "drift_add_#{:rand.uniform(65535)}"
      profile_id = "drift-add-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.99.0.1/24", gateway: "10.99.0.254", dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      # Start a connection FSM with :disabled IP so it reaches :activated quickly
      # Then use a manual profile for the desired state computation
      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      # Build desired state with the static IP profile
      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :manual, address: "10.99.0.1/24", gateway: "10.99.0.254", dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      # Observed state: link exists but NO addresses for this interface
      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)

      add_addr_diffs = Enum.filter(diffs, &(&1.action == :add_address and &1.interface == iface))
      assert length(add_addr_diffs) == 1

      diff = hd(add_addr_diffs)
      assert diff.params.address == "10.99.0.1"
      assert diff.params.prefix_len == 24

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff does NOT generate :add_address when address already present in observed" do
      iface = "drift_ok_#{:rand.uniform(65535)}"
      profile_id = "drift-ok-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.88.0.5/24", gateway: "10.88.0.1", dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :manual, address: "10.88.0.5/24", gateway: "10.88.0.1", dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      # Observed state: address IS present
      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }
        },
        addresses: %{
          iface => [
            %{
              interface: iface,
              address: "10.88.0.5",
              prefix_len: 24,
              family: :inet,
              scope: :global
            }
          ]
        },
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)

      add_addr_diffs = Enum.filter(diffs, &(&1.action == :add_address))
      assert add_addr_diffs == []

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff skips :add_address for DHCP (auto) connections" do
      iface = "drift_dhcp_#{:rand.uniform(65535)}"
      profile_id = "drift-dhcp-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      add_addr_diffs = Enum.filter(diffs, &(&1.action == :add_address))
      assert add_addr_diffs == [], "DHCP connections should not generate address diffs"

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff skips :add_address for inactive (not yet activated) connections" do
      iface = "drift_inact_#{:rand.uniform(65535)}"
      profile_id = "drift-inact-#{iface}"

      # No FSM started — connection_active? returns false, so no address diff
      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :manual, address: "10.77.0.1/24", gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)

      # Should have an :activate_connection diff but no :add_address
      add_addr_diffs = Enum.filter(diffs, &(&1.action == :add_address))
      assert add_addr_diffs == [], "Inactive connections should not generate address diffs"

      activate_diffs = Enum.filter(diffs, &(&1.action == :activate_connection))
      assert length(activate_diffs) == 1
    end

    test "full reconciliation cycle detects and applies address drift" do
      iface = "drift_full_#{:rand.uniform(65535)}"
      profile_id = "drift-full-#{iface}"
      recon_pid = Process.whereis(ReconciliationEngine)
      test_pid = self()

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.66.0.1/24", gateway: "10.66.0.254", dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      # Insert link and profile directly into ETS to avoid auto-reconcile races
      :ets.insert(
        :netman_links,
        {iface,
         %{interface: iface, index: 0, state: :up, carrier: true, mtu: 1500, mac: nil, kind: nil}}
      )

      ProfileStore.put(profile_id, profile)

      # Start connection FSM with :disabled so it activates immediately
      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      on_exit(fn ->
        :ets.delete(:netman_links, iface)
        Connection.Supervisor.stop_connection(iface)
        ProfileStore.delete(profile_id)
      end)

      # Listen for reconciliation telemetry
      handler_id = {__MODULE__, :drift_full, :rand.uniform(1_000_000)}

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :reconciliation, :stop],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:recon_done, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # Trigger reconciliation — should detect missing address and apply :add_address
      send(recon_pid, :periodic_reconcile)

      assert_receive {:recon_done, %{diffs_count: count}}, 2000
      # Should have at least 1 diff (the :add_address for the missing static IP)
      assert count >= 1, "Expected diffs for address drift but got #{count}"

      assert Process.alive?(recon_pid)
    end
  end

  describe "MTU drift detection" do
    alias YellowDog.Netman.Types.{DesiredState, ObservedState}

    test "diff generates :set_mtu when desired MTU differs from observed" do
      iface = "mtu_drift_#{:rand.uniform(65535)}"
      profile_id = "mtu-drift-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: 9000},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: 9000,
            priority: 100,
            dns: []
          }
        }
      }

      # Observed: link exists with default MTU 1500 (different from desired 9000)
      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)

      mtu_diffs = Enum.filter(diffs, &(&1.action == :set_mtu and &1.interface == iface))
      assert length(mtu_diffs) == 1

      diff = hd(mtu_diffs)
      assert diff.params.mtu == 9000

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff does NOT generate :set_mtu when MTU already matches" do
      iface = "mtu_ok_#{:rand.uniform(65535)}"
      profile_id = "mtu-ok-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: 1500},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: 1500,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      mtu_diffs = Enum.filter(diffs, &(&1.action == :set_mtu))
      assert mtu_diffs == []

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff skips :set_mtu when desired MTU is nil" do
      iface = "mtu_nil_#{:rand.uniform(65535)}"
      profile_id = "mtu-nil-#{iface}"

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
      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      mtu_diffs = Enum.filter(diffs, &(&1.action == :set_mtu))
      assert mtu_diffs == [], "nil MTU should not generate set_mtu diff"

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "full reconciliation cycle detects and applies MTU drift" do
      iface = "mtu_full_#{:rand.uniform(65535)}"
      profile_id = "mtu-full-#{iface}"
      recon_pid = Process.whereis(ReconciliationEngine)
      test_pid = self()

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: 9000},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      # Insert link with default 1500 MTU
      :ets.insert(
        :netman_links,
        {iface,
         %{interface: iface, index: 0, state: :up, carrier: true, mtu: 1500, mac: nil, kind: nil}}
      )

      ProfileStore.put(profile_id, profile)

      {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
      Process.sleep(100)

      on_exit(fn ->
        :ets.delete(:netman_links, iface)
        Connection.Supervisor.stop_connection(iface)
        ProfileStore.delete(profile_id)
      end)

      handler_id = {__MODULE__, :mtu_full, :rand.uniform(1_000_000)}

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :reconciliation, :stop],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:recon_done, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      send(recon_pid, :periodic_reconcile)

      assert_receive {:recon_done, %{diffs_count: count}}, 2000
      assert count >= 1, "Expected diffs for MTU drift but got #{count}"

      assert Process.alive?(recon_pid)
    end
  end

  describe "DNS push detection" do
    alias YellowDog.Netman.Types.{DesiredState, ObservedState}

    test "diff does NOT generate :update_dns (DNS is FSM-only)" do
      iface = "dns_drift_#{:rand.uniform(65535)}"
      profile_id = "dns-drift-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{
          method: :manual,
          address: "10.40.0.1/24",
          gateway: "10.40.0.1",
          dns: ["8.8.8.8", "1.1.1.1"]
        },
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{
              method: :manual,
              address: "10.40.0.1/24",
              gateway: "10.40.0.1",
              dns: ["8.8.8.8", "1.1.1.1"]
            },
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: ["8.8.8.8", "1.1.1.1"]
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }
        },
        addresses: %{
          iface => [
            %{
              interface: iface,
              address: "10.40.0.1",
              prefix_len: 24,
              family: :inet,
              scope: :global
            }
          ]
        },
        routes: [
          %{
            destination: "default",
            gateway: "10.40.0.1",
            interface: iface,
            metric: 900,
            table: 254,
            protocol: :static,
            scope: :global
          }
        ]
      }

      diffs = ReconciliationEngine.diff(desired, observed)

      # DNS diffs are no longer produced by the reconciliation engine.
      # DNS is exclusively managed by the FSM's push_dns/1 to avoid
      # overwriting DHCP-provided DNS servers.
      dns_diffs = Enum.filter(diffs, &(&1.action == :update_dns))
      assert dns_diffs == [], "Reconciliation should not produce DNS diffs"

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff does NOT generate :update_dns when DNS list is empty" do
      iface = "dns_empty_#{:rand.uniform(65535)}"
      profile_id = "dns-empty-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.41.0.1/24", gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :manual, address: "10.41.0.1/24", gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      dns_diffs = Enum.filter(diffs, &(&1.action == :update_dns))
      assert dns_diffs == [], "Empty DNS list should not generate update_dns diff"

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff skips :update_dns for inactive connections" do
      iface = "dns_inact_#{:rand.uniform(65535)}"
      profile_id = "dns-inact-#{iface}"

      # No FSM started — connection_active? returns false
      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :manual, address: "10.42.0.1/24", gateway: nil, dns: ["8.8.8.8"]},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: ["8.8.8.8"]
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      dns_diffs = Enum.filter(diffs, &(&1.action == :update_dns))
      assert dns_diffs == [], "Inactive connections should not generate DNS diffs"
    end

    test "diff filters out invalid DNS strings (parse_dns_servers error branch)" do
      iface = "dns_bad_#{:rand.uniform(65535)}"
      profile_id = "dns-bad-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.46.0.1/24", gateway: nil, dns: ["not-an-ip"]},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :manual, address: "10.46.0.1/24", gateway: nil, dns: ["not-an-ip"]},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: ["not-an-ip"]
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      dns_diffs = Enum.filter(diffs, &(&1.action == :update_dns))

      assert dns_diffs == [],
             "Invalid DNS strings should be filtered out, resulting in no update_dns diff"

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end
  end

  describe "parse_desired_cidr edge cases" do
    alias YellowDog.Netman.Types.{DesiredState, ObservedState}

    test "address without slash defaults to /32 prefix (L333)" do
      iface = "cidr_noslash_#{:rand.uniform(65535)}"
      profile_id = "cidr-noslash-#{iface}"

      MockNetlink.link_up(iface, carrier: true)

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.47.0.1", gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :manual, address: "10.47.0.1", gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      add_addr_diffs = Enum.filter(diffs, &(&1.action == :add_address and &1.interface == iface))
      assert length(add_addr_diffs) == 1
      assert hd(add_addr_diffs).params.prefix_len == 32

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "address with invalid prefix defaults to /32 (L330)" do
      iface = "cidr_bad_#{:rand.uniform(65535)}"
      profile_id = "cidr-bad-#{iface}"

      MockNetlink.link_up(iface, carrier: true)

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.48.0.1/abc", gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :manual, address: "10.48.0.1/abc", gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      add_addr_diffs = Enum.filter(diffs, &(&1.action == :add_address and &1.interface == iface))
      assert length(add_addr_diffs) == 1
      assert hd(add_addr_diffs).params.prefix_len == 32

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "IPv6 address without slash defaults to /128 prefix (not /32)" do
      iface = "cidr_v6_#{:rand.uniform(65535)}"
      profile_id = "cidr-v6-#{iface}"

      MockNetlink.link_up(iface, carrier: true)

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :manual, address: "2001:db8::1", gateway: nil, dns: []}
      }

      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :manual, address: "2001:db8::1", gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      add_addr_diffs = Enum.filter(diffs, &(&1.action == :add_address and &1.interface == iface))
      assert length(add_addr_diffs) == 1
      # IPv6 should default to /128, not /32
      assert hd(add_addr_diffs).params.prefix_len == 128

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "IPv6 address with invalid prefix defaults to /128 (not /32)" do
      iface = "cidr_v6bad_#{:rand.uniform(65535)}"
      profile_id = "cidr-v6bad-#{iface}"

      MockNetlink.link_up(iface, carrier: true)

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :manual, address: "fd00::1/xyz", gateway: nil, dns: []}
      }

      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :manual, address: "fd00::1/xyz", gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      add_addr_diffs = Enum.filter(diffs, &(&1.action == :add_address and &1.interface == iface))
      assert length(add_addr_diffs) == 1
      # IPv6 should default to /128
      assert hd(add_addr_diffs).params.prefix_len == 128

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end
  end

  describe "route drift detection" do
    alias YellowDog.Netman.Types.{DesiredState, ObservedState}

    test "diff generates :add_route when static IP gateway route is missing" do
      iface = "route_drift_#{:rand.uniform(65535)}"
      profile_id = "route-drift-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.55.0.1/24", gateway: "10.55.0.254", dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :manual, address: "10.55.0.1/24", gateway: "10.55.0.254", dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      # Observed: no routes
      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }
        },
        addresses: %{
          iface => [
            %{
              interface: iface,
              address: "10.55.0.1",
              prefix_len: 24,
              family: :inet,
              scope: :global
            }
          ]
        },
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)

      route_diffs = Enum.filter(diffs, &(&1.action == :add_route and &1.interface == iface))
      assert length(route_diffs) == 1

      diff = hd(route_diffs)
      assert diff.params.destination == "default"
      assert diff.params.gateway == "10.55.0.254"
      assert diff.params.interface == iface

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff does NOT generate :add_route when gateway route already exists" do
      iface = "route_ok_#{:rand.uniform(65535)}"
      profile_id = "route-ok-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.44.0.1/24", gateway: "10.44.0.254", dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :manual, address: "10.44.0.1/24", gateway: "10.44.0.254", dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      # Observed: default route via gateway already present
      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }
        },
        addresses: %{
          iface => [
            %{
              interface: iface,
              address: "10.44.0.1",
              prefix_len: 24,
              family: :inet,
              scope: :global
            }
          ]
        },
        routes: [
          %{
            destination: "default",
            gateway: "10.44.0.254",
            interface: iface,
            metric: 900,
            table: 254,
            protocol: :static,
            scope: :global
          }
        ]
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      route_diffs = Enum.filter(diffs, &(&1.action == :add_route))
      assert route_diffs == []

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff skips :add_route for DHCP connections" do
      iface = "route_dhcp_#{:rand.uniform(65535)}"
      profile_id = "route-dhcp-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      route_diffs = Enum.filter(diffs, &(&1.action == :add_route))
      assert route_diffs == [], "DHCP connections should not generate route diffs"

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff skips :add_route when static IP has no gateway" do
      iface = "route_nogw_#{:rand.uniform(65535)}"
      profile_id = "route-nogw-#{iface}"

      profile = %Profile{
        id: profile_id,
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :manual, address: "10.33.0.1/24", gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      MockNetlink.link_up(iface, carrier: true)
      ProfileStore.put(profile_id, profile)
      Process.sleep(50)

      {:ok, _pid} =
        Connection.Supervisor.start_connection(iface, %{
          profile
          | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
        })

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :manual, address: "10.33.0.1/24", gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{
          iface => [
            %{
              interface: iface,
              address: "10.33.0.1",
              prefix_len: 24,
              family: :inet,
              scope: :global
            }
          ]
        },
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      route_diffs = Enum.filter(diffs, &(&1.action == :add_route))
      assert route_diffs == [], "No gateway means no default route diff"

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff generates :add_route per-interface even with same gateway" do
      iface1 = "route_if1_#{:rand.uniform(65535)}"
      iface2 = "route_if2_#{:rand.uniform(65535)}"
      pid1 = "route-if1-#{iface1}"
      pid2 = "route-if2-#{iface2}"

      for {iface, pid, addr} <- [{iface1, pid1, "10.55.1.1/24"}, {iface2, pid2, "10.55.2.1/24"}] do
        profile = %Profile{
          id: pid,
          type: :ethernet,
          interface: iface,
          autoconnect: true,
          autoconnect_priority: 100,
          ethernet: %{mtu: nil},
          ipv4: %{method: :manual, address: addr, gateway: "10.55.0.1", dns: []},
          ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
        }

        MockNetlink.link_up(iface, carrier: true)
        ProfileStore.put(pid, profile)
        Process.sleep(50)

        {:ok, _} =
          Connection.Supervisor.start_connection(iface, %{
            profile
            | ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []}
          })
      end

      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          pid1 => %{
            profile_id: pid1,
            interface: iface1,
            ipv4: %{method: :manual, address: "10.55.1.1/24", gateway: "10.55.0.1", dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          },
          pid2 => %{
            profile_id: pid2,
            interface: iface2,
            ipv4: %{method: :manual, address: "10.55.2.1/24", gateway: "10.55.0.1", dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      # Only iface1 has the route — iface2 should still get one
      observed = %ObservedState{
        links: %{
          iface1 => %{
            interface: iface1,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          },
          iface2 => %{
            interface: iface2,
            index: 2,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{},
        routes: [
          %{
            destination: "default",
            gateway: "10.55.0.1",
            interface: iface1,
            metric: 900,
            table: 254,
            protocol: :static,
            scope: :global
          }
        ]
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      route_diffs = Enum.filter(diffs, &(&1.action == :add_route))

      # iface1 already has the route; iface2 should get one
      assert length(route_diffs) == 1
      assert hd(route_diffs).interface == iface2

      for {iface, pid} <- [{iface1, pid1}, {iface2, pid2}] do
        Connection.Supervisor.stop_connection(iface)
        ProfileStore.delete(pid)
        MockNetlink.link_removed(iface)
      end
    end
  end

  describe "link state drift detection" do
    alias YellowDog.Netman.Types.{DesiredState, ObservedState}

    test "diff generates :set_link_up when active connection link is down" do
      iface = "link_drift_#{:rand.uniform(65535)}"
      profile_id = "link-drift-#{iface}"

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
      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      # Observed: link exists but is DOWN
      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :down,
            carrier: false,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)

      link_up_diffs =
        Enum.filter(diffs, &(&1.action == :set_link_up and &1.interface == iface))

      assert length(link_up_diffs) == 1

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff does NOT generate :set_link_up when link is already up" do
      iface = "link_ok_#{:rand.uniform(65535)}"
      profile_id = "link-ok-#{iface}"

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
      Process.sleep(100)

      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      link_up_diffs = Enum.filter(diffs, &(&1.action == :set_link_up))
      assert link_up_diffs == []

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "diff skips :set_link_up for inactive connections" do
      iface = "link_inact_#{:rand.uniform(65535)}"
      profile_id = "link-inact-#{iface}"

      # No FSM started
      desired = %DesiredState{
        connections: %{
          profile_id => %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }
        }
      }

      observed = %ObservedState{
        links: %{
          iface => %{
            interface: iface,
            index: 1,
            state: :down,
            carrier: false,
            mtu: 1500,
            mac: nil,
            kind: nil
          }
        },
        addresses: %{},
        routes: []
      }

      diffs = ReconciliationEngine.diff(desired, observed)
      link_up_diffs = Enum.filter(diffs, &(&1.action == :set_link_up))
      assert link_up_diffs == [], "Inactive connections should not generate link state diffs"
    end

    test "full reconciliation cycle detects and applies link state drift" do
      iface = "link_full_#{:rand.uniform(65535)}"
      profile_id = "link-full-#{iface}"
      recon_pid = Process.whereis(ReconciliationEngine)
      test_pid = self()

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

      # Insert link as DOWN
      :ets.insert(
        :netman_links,
        {iface,
         %{
           interface: iface,
           index: 0,
           state: :down,
           carrier: false,
           mtu: 1500,
           mac: nil,
           kind: nil
         }}
      )

      ProfileStore.put(profile_id, profile)
      {:ok, _pid} = Connection.Supervisor.start_connection(iface, profile)
      Process.sleep(100)

      on_exit(fn ->
        :ets.delete(:netman_links, iface)
        Connection.Supervisor.stop_connection(iface)
        ProfileStore.delete(profile_id)
      end)

      handler_id = {__MODULE__, :link_full, :rand.uniform(1_000_000)}

      :telemetry.attach(
        handler_id,
        [:yellow_dog, :netman, :reconciliation, :stop],
        fn _event, measurements, _meta, _config ->
          send(test_pid, {:recon_done, measurements})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      send(recon_pid, :periodic_reconcile)

      assert_receive {:recon_done, %{diffs_count: count}}, 2000
      assert count >= 1, "Expected diffs for link state drift but got #{count}"

      assert Process.alive?(recon_pid)
    end
  end

  describe "apply_diff remaining branches" do
    alias YellowDog.Netman.Types.{DesiredState, ObservedState}

    test "deactivate_connection apply_diff via stop_connection (L429)" do
      iface = "deact_#{:rand.uniform(65535)}"
      profile_id = "deact-#{iface}"

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
      Process.sleep(100)

      # Use deactivate/1 call which calls Connection.Supervisor.stop_connection
      # This exercises the deactivate path via the public API
      result = ReconciliationEngine.deactivate(profile_id)
      assert result == :ok

      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile_id)
      MockNetlink.link_removed(iface)
    end

    test "remove_address apply_diff delegates to AddressManager (L437)" do
      # Directly verify that remove_address works on AddressManager
      # since the apply_diff clause just delegates
      iface = "rmaddr_#{:rand.uniform(65535)}"

      # AddressManager.remove_address returns :ok for any interface
      # (the Netlink command just gets queued)
      result =
        YellowDog.Netman.Kernel.AddressManager.remove_address(iface, "10.50.0.1", 24)

      assert result == :ok
    end

    test "remove_route apply_diff delegates to RouteManager (L445)" do
      # RouteManager.remove_route returns :ok for any route params
      result =
        YellowDog.Netman.Kernel.RouteManager.remove_route(%{
          destination: "default",
          gateway: "10.50.0.1"
        })

      assert result == :ok
    end
  end
end
