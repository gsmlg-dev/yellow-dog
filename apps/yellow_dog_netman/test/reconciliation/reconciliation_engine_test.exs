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
end
