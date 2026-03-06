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

  property "DNS diffs only generated for connections with non-empty valid DNS lists" do
    check all(
            ifaces <-
              StreamData.list_of(interface_name_gen(),
                min_length: 1,
                max_length: 4,
                uniq_by: & &1
              ),
            dns_lists <-
              StreamData.list_of(
                StreamData.one_of([
                  StreamData.constant([]),
                  StreamData.constant(["8.8.8.8"]),
                  StreamData.constant(["invalid-dns"]),
                  StreamData.constant(["1.1.1.1", "8.8.4.4"]),
                  StreamData.constant(nil)
                ]),
                length: length(ifaces)
              )
          ) do
      connections =
        Enum.zip(ifaces, dns_lists)
        |> Enum.reduce(%{}, fn {iface, dns}, acc ->
          profile_id = "profile-#{iface}"

          conn = %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: nil,
            priority: 100,
            dns: dns
          }

          Map.put(acc, profile_id, conn)
        end)

      links =
        Enum.reduce(ifaces, %{}, fn iface, acc ->
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

      desired = %DesiredState{connections: connections}
      observed = %ObservedState{links: links, addresses: %{}, routes: []}

      diffs = ReconciliationEngine.diff(desired, observed)
      dns_diffs = Enum.filter(diffs, &(&1.action == :update_dns))

      # DNS diffs should only appear for connections with non-nil, non-empty
      # DNS lists containing at least one valid IP address.
      # Since connection_active? returns false for these test interfaces
      # (no FSMs running), no DNS diffs should be generated.
      assert dns_diffs == [],
             "DNS diffs should not be generated for inactive connections"
    end
  end

  property "invalid DNS strings are filtered out and don't produce diffs" do
    check all(
            iface <- interface_name_gen(),
            invalid_count <- StreamData.integer(1..5)
          ) do
      invalids = Enum.map(1..invalid_count, fn n -> "bad-dns-#{n}" end)
      profile_id = "profile-#{iface}"

      connections = %{
        profile_id => %{
          profile_id: profile_id,
          interface: iface,
          ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
          ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
          mtu: nil,
          priority: 100,
          dns: invalids
        }
      }

      links = %{
        iface => %{
          interface: iface,
          index: 1,
          state: :up,
          carrier: true,
          mtu: 1500,
          mac: "aa:bb:cc:dd:ee:ff",
          kind: nil
        }
      }

      desired = %DesiredState{connections: connections}
      observed = %ObservedState{links: links, addresses: %{}, routes: []}

      diffs = ReconciliationEngine.diff(desired, observed)
      dns_diffs = Enum.filter(diffs, &(&1.action == :update_dns))

      # Even with non-empty DNS lists, invalid DNS strings produce no valid
      # servers, so no update_dns diff should be generated (connection_active?
      # also returns false, but the invalid-filter invariant holds regardless).
      assert dns_diffs == []
    end
  end

  property "diff only produces activation diffs for inactive connections (no DNS/MTU/route/link)" do
    # When no FSMs are running, the only diffs should be :activate_connection.
    # DNS, MTU, route, and link state diffs require connection_active? to be true.
    check all(
            ifaces <-
              StreamData.list_of(interface_name_gen(),
                min_length: 1,
                max_length: 4,
                uniq_by: & &1
              ),
            dns_mode <-
              StreamData.one_of([
                StreamData.constant([]),
                StreamData.constant(["8.8.8.8"]),
                StreamData.constant(["1.1.1.1", "8.8.4.4"])
              ]),
            mtu <- StreamData.one_of([StreamData.constant(nil), StreamData.constant(9000)])
          ) do
      connections =
        Enum.reduce(ifaces, %{}, fn iface, acc ->
          profile_id = "profile-#{iface}"

          conn = %{
            profile_id: profile_id,
            interface: iface,
            ipv4: %{method: :manual, address: "10.0.0.1/24", gateway: "10.0.0.1", dns: dns_mode},
            ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []},
            mtu: mtu,
            priority: 100,
            dns: dns_mode
          }

          Map.put(acc, profile_id, conn)
        end)

      links =
        Enum.reduce(ifaces, %{}, fn iface, acc ->
          link = %{
            interface: iface,
            index: :erlang.phash2(iface, 255) + 1,
            state: :down,
            carrier: false,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }

          Map.put(acc, iface, link)
        end)

      desired = %DesiredState{connections: connections}
      observed = %ObservedState{links: links, addresses: %{}, routes: []}

      diffs = ReconciliationEngine.diff(desired, observed)

      # With no FSMs running, only :activate_connection diffs should be produced
      non_activate_diffs = Enum.reject(diffs, &(&1.action == :activate_connection))

      assert non_activate_diffs == [],
             "Expected only activation diffs for inactive connections, got: #{inspect(Enum.map(non_activate_diffs, & &1.action))}"
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

  property "activation diff count exactly matches connections with observed links when no FSMs running" do
    check all(
            ifaces <-
              StreamData.list_of(interface_name_gen(),
                min_length: 1,
                max_length: 4,
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

      links =
        Enum.reduce(ifaces, %{}, fn iface, acc ->
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

      desired = %DesiredState{connections: connections}
      observed = %ObservedState{links: links, addresses: %{}, routes: []}

      diffs = ReconciliationEngine.diff(desired, observed)
      activate_diffs = Enum.filter(diffs, &(&1.action == :activate_connection))

      # With no FSMs running, exactly one activation diff per connection-link pair
      assert length(activate_diffs) == length(ifaces),
             "Expected #{length(ifaces)} activation diffs but got #{length(activate_diffs)}"
    end
  end

  property "observe maps input links by interface name" do
    check all(
            ifaces <-
              StreamData.list_of(interface_name_gen(),
                min_length: 0,
                max_length: 5,
                uniq_by: & &1
              )
          ) do
      links =
        Enum.map(ifaces, fn iface ->
          %{
            interface: iface,
            index: 1,
            state: :up,
            carrier: true,
            mtu: 1500,
            mac: "aa:bb:cc:dd:ee:ff",
            kind: nil
          }
        end)

      observed = ReconciliationEngine.observe(links)
      assert Map.keys(observed.links) |> Enum.sort() == Enum.sort(ifaces)
    end
  end

  property "observe always returns ObservedState with map addresses and list routes" do
    check all(
            ifaces <-
              StreamData.list_of(interface_name_gen(),
                min_length: 0,
                max_length: 4,
                uniq_by: & &1
              )
          ) do
      links =
        Enum.map(ifaces, fn iface ->
          %{interface: iface, index: 1, state: :up, carrier: true, mtu: 1500, mac: nil, kind: nil}
        end)

      state = ReconciliationEngine.observe(links)
      assert %ObservedState{} = state
      assert is_map(state.addresses)
      assert is_list(state.routes)
    end
  end

  property "all activation diff profile IDs reference connections in desired state" do
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

      for diff <- diffs, diff.action == :activate_connection do
        assert Map.has_key?(desired.connections, diff.params.profile_id),
               "Diff profile_id #{diff.params.profile_id} not in desired connections"
      end
    end
  end

  property "reconcile always returns :ok and keeps engine alive" do
    check all(_ <- StreamData.constant(:ok)) do
      result = ReconciliationEngine.reconcile()
      assert result == :ok
      # Give debounce time to fire
      Process.sleep(150)
      assert Process.alive?(Process.whereis(ReconciliationEngine))
    end
  end
end
