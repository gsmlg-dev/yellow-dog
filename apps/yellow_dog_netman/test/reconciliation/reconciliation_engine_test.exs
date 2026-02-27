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
    test "second reconciliation cycle produces no new activation diffs" do
      iface = "recon_idem_#{:rand.uniform(65535)}"

      profile = %Profile{
        id: "recon-idem-#{iface}",
        type: :ethernet,
        interface: iface,
        autoconnect: true,
        autoconnect_priority: 100,
        ethernet: %{mtu: nil},
        ipv4: %{method: :disabled, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      ProfileStore.put(profile.id, profile)
      MockNetlink.link_up(iface, carrier: true)
      Process.sleep(50)

      # First cycle: should produce activate_connection diff
      observed1 = ReconciliationEngine.observe()
      desired1 = ReconciliationEngine.compute_desired()
      diffs1 = ReconciliationEngine.diff(desired1, observed1)

      activate_diffs = Enum.filter(diffs1, &(&1.action == :activate_connection))

      assert length(activate_diffs) >= 1,
             "Expected at least one activation diff for new interface"

      # Apply diffs: start the connection FSM
      for diff <- activate_diffs do
        {:ok, p} = ProfileStore.get(diff.params.profile_id)
        Connection.Supervisor.start_connection(diff.interface, p)
      end

      Process.sleep(100)

      # Second cycle: FSMs are now active, should produce no new activation diffs
      observed2 = ReconciliationEngine.observe()
      desired2 = ReconciliationEngine.compute_desired()
      diffs2 = ReconciliationEngine.diff(desired2, observed2)

      activate_diffs2 =
        Enum.filter(diffs2, &(&1.action == :activate_connection and &1.interface == iface))

      assert activate_diffs2 == [],
             "Second reconciliation cycle should produce no activation diffs for already-active interface"

      # Cleanup
      Connection.Supervisor.stop_connection(iface)
      ProfileStore.delete(profile.id)
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
end
