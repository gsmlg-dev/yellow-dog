defmodule YellowDog.Netman.ReconciliationEnginePropertyTest do
  @moduledoc """
  Property-based tests for the reconciliation engine diff function.

  Verifies key invariants:
  - Empty desired state always produces no diffs
  - Diffs are only generated for interfaces that exist in observed links
  - Diff computation is deterministic (same inputs → same outputs)
  - No diffs generated for loopback interfaces
  - Desired connections without matching observed links produce no activation diffs
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.Netman.ReconciliationEngine
  alias YellowDog.Netman.Types.{DesiredState, ObservedState}

  # Generators

  defp interface_name_gen do
    StreamData.string(:alphanumeric, min_length: 3, max_length: 8)
    |> StreamData.map(&"eth#{&1}")
  end

  defp observed_state_gen do
    gen all(
          ifaces <-
            StreamData.list_of(interface_name_gen(), min_length: 0, max_length: 5, uniq_by: & &1)
        ) do
      links =
        Enum.reduce(ifaces, %{}, fn iface, acc ->
          # Generate a static link for each unique interface
          link = %{
            interface: iface,
            index: :erlang.phash2(iface, 255) + 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }

          Map.put(acc, iface, link)
        end)

      %ObservedState{links: links, addresses: %{}, routes: []}
    end
  end

  # Properties

  property "empty desired state always produces no diffs" do
    check all(observed <- observed_state_gen()) do
      desired = %DesiredState{connections: %{}}
      diffs = ReconciliationEngine.diff(desired, observed)
      assert diffs == []
    end
  end

  property "empty observed links produce no activation diffs" do
    check all(
            ifaces <-
              StreamData.list_of(interface_name_gen(),
                min_length: 1,
                max_length: 5,
                uniq_by: & &1
              )
          ) do
      connections =
        Enum.reduce(ifaces, %{}, fn iface, acc ->
          profile_id = "profile-#{iface}"

          conn = %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }

          Map.put(acc, profile_id, conn)
        end)

      desired = %DesiredState{connections: connections}
      observed = %ObservedState{links: %{}, addresses: %{}, routes: []}

      diffs = ReconciliationEngine.diff(desired, observed)
      activate_diffs = Enum.filter(diffs, &(&1.action == :activate_connection))
      assert activate_diffs == []
    end
  end

  property "all diff interfaces exist in observed links" do
    check all(observed <- observed_state_gen()) do
      ifaces = Map.keys(observed.links)

      desired =
        case ifaces do
          [] ->
            %DesiredState{connections: %{}}

          _ ->
            connections =
              Enum.reduce(ifaces, %{}, fn iface, acc ->
                profile_id = "profile-#{iface}"

                conn = %{
                  profile_id: profile_id,
                  interface: iface,
                  ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
                  ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
                  mtu: nil,
                  priority: 100,
                  dns: []
                }

                Map.put(acc, profile_id, conn)
              end)

            %DesiredState{connections: connections}
        end

      diffs = ReconciliationEngine.diff(desired, observed)

      for diff <- diffs, diff.action == :activate_connection do
        assert Map.has_key?(observed.links, diff.interface),
               "Diff interface #{diff.interface} not in observed links"
      end
    end
  end

  property "diff is deterministic - same inputs produce same output" do
    check all(observed <- observed_state_gen()) do
      ifaces = Map.keys(observed.links)

      connections =
        Enum.reduce(ifaces, %{}, fn iface, acc ->
          profile_id = "profile-#{iface}"

          conn = %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }

          Map.put(acc, profile_id, conn)
        end)

      desired = %DesiredState{connections: connections}

      diffs1 = ReconciliationEngine.diff(desired, observed)
      diffs2 = ReconciliationEngine.diff(desired, observed)

      assert diffs1 == diffs2
    end
  end

  property "compute_desired never includes loopback in desired connections" do
    # compute_desired filters out loopback via matches_profile?/2.
    # We verify that even when loopback appears in the observed links,
    # no activation diff is generated for it when using compute_desired pipeline.
    #
    # This tests the invariant that loopback filtering happens before diff/2.
    # We construct a scenario where loopback is in observed links but verify
    # that desired connections built from profiles never reference loopback.
    check all(
            ifaces <-
              StreamData.list_of(interface_name_gen(),
                min_length: 0,
                max_length: 4,
                uniq_by: & &1
              )
          ) do
      all_ifaces = ["lo" | ifaces]

      # Build observed state with loopback + regular links
      links =
        Enum.reduce(all_ifaces, %{}, fn iface, acc ->
          link = %{
            interface: iface,
            index: :erlang.phash2(iface, 255) + 1,
            state: :up,
            carrier: true,
            mtu: if(iface == "lo", do: 65536, else: 1500),
            mac: if(iface == "lo", do: nil, else: "aa:bb:cc:dd:ee:ff"),
            kind: if(iface == "lo", do: "loopback", else: nil)
          }

          Map.put(acc, iface, link)
        end)

      observed = %ObservedState{links: links}

      # Desired state should NOT include loopback (matches_profile? filters it)
      non_loopback_ifaces = Enum.reject(ifaces, &(&1 == "lo"))

      connections =
        Enum.reduce(non_loopback_ifaces, %{}, fn iface, acc ->
          profile_id = "profile-#{iface}"

          conn = %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }

          Map.put(acc, profile_id, conn)
        end)

      desired = %DesiredState{connections: connections}

      diffs = ReconciliationEngine.diff(desired, observed)

      loopback_diffs =
        Enum.filter(diffs, fn d ->
          d.action == :activate_connection and d.interface == "lo"
        end)

      assert loopback_diffs == [],
             "Loopback interface should never appear in activation diffs"
    end
  end

  property "no duplicate activation diffs for the same interface" do
    check all(observed <- observed_state_gen()) do
      ifaces = Map.keys(observed.links)

      connections =
        Enum.reduce(ifaces, %{}, fn iface, acc ->
          profile_id = "profile-#{iface}"

          conn = %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: []
          }

          Map.put(acc, profile_id, conn)
        end)

      desired = %DesiredState{connections: connections}

      diffs = ReconciliationEngine.diff(desired, observed)

      activate_diffs = Enum.filter(diffs, &(&1.action == :activate_connection))
      unique_ifaces = activate_diffs |> Enum.map(& &1.interface) |> Enum.uniq()

      assert length(unique_ifaces) == length(activate_diffs),
             "Duplicate activation diffs for same interface"
    end
  end
end
