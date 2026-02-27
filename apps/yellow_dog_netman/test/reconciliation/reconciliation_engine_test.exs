defmodule YellowDog.Netman.ReconciliationEngineTest do
  use ExUnit.Case

  alias YellowDog.Netman.ReconciliationEngine
  alias YellowDog.Netman.Types.{DesiredState, ObservedState, Diff}

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
end
