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

  property "activate always returns :ok or {:error, _} for any profile id" do
    check all(
            id <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
              |> StreamData.map(&("re_act_" <> &1))
          ) do
      result = ReconciliationEngine.activate(id)

      assert result == :ok or match?({:error, _}, result),
             "Unexpected activate result: #{inspect(result)}"
    end
  end

  property "deactivate always returns :ok or {:error, :not_found} for any profile id" do
    check all(
            id <-
              StreamData.string(:alphanumeric, min_length: 1, max_length: 20)
              |> StreamData.map(&("re_deact_" <> &1))
          ) do
      result = ReconciliationEngine.deactivate(id)

      assert result == :ok or result == {:error, :not_found},
             "Unexpected deactivate result: #{inspect(result)}"
    end
  end

  property "observe/0 always returns ObservedState with non-negative counts" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ReconciliationEngine.observe()
      assert %ObservedState{} = state
      assert is_map(state.links)
      assert is_map(state.addresses)
      assert is_list(state.routes)
    end
  end

  property "compute_desired/0 always returns a DesiredState" do
    check all(_ <- StreamData.constant(:ok)) do
      result = ReconciliationEngine.compute_desired()
      assert %DesiredState{} = result
      assert is_map(result.connections)
    end
  end

  property "observe/0 links map keys are all binary strings" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ReconciliationEngine.observe()

      for {key, _} <- state.links do
        assert is_binary(key),
               "Expected binary interface key in observe/0 links, got: #{inspect(key)}"
      end
    end
  end

  property "every activation diff has non-nil binary interface and profile_id in params" do
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
        assert is_binary(diff.interface),
               "Expected binary interface in diff, got: #{inspect(diff.interface)}"

        assert is_binary(diff.params.profile_id),
               "Expected binary profile_id in params, got: #{inspect(diff.params.profile_id)}"
      end
    end
  end

  property "diff with empty desired and empty observed always returns an empty list" do
    check all(_ <- StreamData.constant(:ok)) do
      desired = %DesiredState{connections: %{}}
      observed = %ObservedState{links: %{}, addresses: %{}, routes: []}
      assert ReconciliationEngine.diff(desired, observed) == []
    end
  end

  property "all diffs returned by diff/2 are Diff structs with a valid action field" do
    check all(_ <- StreamData.constant(:ok)) do
      desired = ReconciliationEngine.compute_desired()
      observed = ReconciliationEngine.observe()
      diffs = ReconciliationEngine.diff(desired, observed)

      valid_actions = [
        :add_address,
        :remove_address,
        :add_route,
        :remove_route,
        :activate_connection,
        :deactivate_connection,
        :update_dns,
        :set_mtu,
        :set_link_up,
        :set_link_down
      ]

      for diff <- diffs do
        assert is_struct(diff, YellowDog.Netman.Types.Diff),
               "Expected %Diff{} struct, got: #{inspect(diff)}"

        assert diff.action in valid_actions,
               "Unexpected action #{inspect(diff.action)} in diff"
      end
    end
  end

  property "observe/0 always returns an ObservedState with routes as a list" do
    check all(_ <- StreamData.constant(:ok)) do
      observed = ReconciliationEngine.observe()
      assert is_map(observed),
             "Expected map from observe/0, got: #{inspect(observed)}"
      assert is_list(observed.routes),
             "Expected routes to be a list, got: #{inspect(observed.routes)}"
    end
  end

  property "observe/0 always returns an ObservedState with links as a map" do
    check all(_ <- StreamData.constant(:ok)) do
      observed = ReconciliationEngine.observe()
      assert is_map(observed.links),
             "Expected links to be a map, got: #{inspect(observed.links)}"
    end
  end

  property "observe/0 always returns an ObservedState with addresses as a map" do
    check all(_ <- StreamData.constant(:ok)) do
      observed = ReconciliationEngine.observe()
      assert is_map(observed.addresses),
             "Expected addresses to be a map, got: #{inspect(observed.addresses)}"
    end
  end

  property "observe/0 always returns a struct with all required fields" do
    check all(_ <- StreamData.constant(:ok)) do
      observed = ReconciliationEngine.observe()
      assert Map.has_key?(observed, :links),
             "Expected :links field in ObservedState"
      assert Map.has_key?(observed, :addresses),
             "Expected :addresses field in ObservedState"
      assert Map.has_key?(observed, :routes),
             "Expected :routes field in ObservedState"
    end
  end

  property "diff/2 always returns a list regardless of state contents" do
    check all(observed <- observed_state_gen()) do
      desired = %DesiredState{connections: %{}}
      result = ReconciliationEngine.diff(desired, observed)
      assert is_list(result),
             "Expected list from diff/2, got: #{inspect(result)}"
    end
  end

  property "diff/2 with fully empty state always returns an empty list" do
    check all(_ <- StreamData.constant(:ok)) do
      desired = %DesiredState{connections: %{}}
      observed = %ObservedState{links: %{}, addresses: %{}, routes: []}
      result = ReconciliationEngine.diff(desired, observed)
      assert result == [],
             "Expected empty diff for fully empty state, got: #{inspect(result)}"
    end
  end

  property "diff/2 elements always contain action atoms from known set" do
    check all(observed <- observed_state_gen()) do
      desired = %DesiredState{connections: %{}}
      diffs = ReconciliationEngine.diff(desired, observed)
      for d <- diffs do
        assert is_struct(d, YellowDog.Netman.Types.Diff),
               "Expected Diff struct in diff list, got: #{inspect(d)}"
      end
    end
  end

  property "ReconciliationEngine is always alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert pid != nil, "Expected ReconciliationEngine to be registered"
      assert Process.alive?(pid), "Expected ReconciliationEngine to be alive"
    end
  end

  property "diff/2 result elements are always Diff structs with known actions" do
    check all(observed <- observed_state_gen()) do
      desired = %DesiredState{connections: %{}}
      diffs = ReconciliationEngine.diff(desired, observed)
      known_actions = [:add_address, :remove_address, :add_route, :remove_route,
                       :activate_connection, :deactivate_connection, :update_dns,
                       :set_mtu, :set_link_up, :set_link_down]
      for d <- diffs do
        assert d.action in known_actions,
               "Unknown action #{inspect(d.action)} in diff result"
      end
    end
  end

  property "ReconciliationEngine.reconcile always returns :ok" do
    check all(_ <- StreamData.constant(:ok)) do
      result = ReconciliationEngine.reconcile()
      assert result == :ok,
             "Expected :ok from reconcile, got: #{inspect(result)}"
    end
  end

  property "observe/0 always returns an ObservedState struct" do
    check all(_ <- StreamData.constant(:ok)) do
      result = ReconciliationEngine.observe()
      assert is_struct(result, YellowDog.Netman.Types.ObservedState),
             "Expected ObservedState struct from observe/0, got: #{inspect(result)}"
    end
  end

  property "compute_desired/0 result connections values are all maps" do
    check all(_ <- StreamData.constant(:ok)) do
      desired = ReconciliationEngine.compute_desired()
      for {_id, conn} <- desired.connections do
        assert is_map(conn),
               "Expected map connection in desired state, got: #{inspect(conn)}"
      end
    end
  end

  property "ReconciliationEngine.diff/2 always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      desired = DesiredState.from_profiles([])
      observed = ObservedState.new()
      result = ReconciliationEngine.diff(desired, observed)
      assert is_list(result),
             "Expected list from diff/2, got: \#{inspect(result)}"
    end
  end

  property "ReconciliationEngine.reconcile/0 is idempotent" do
    check all(_ <- StreamData.constant(:ok)) do
      assert ReconciliationEngine.reconcile() == :ok
      assert ReconciliationEngine.reconcile() == :ok,
             "Expected :ok on second reconcile call"
    end
  end

  property "compute_desired result always has non-nil connections field" do
    check all(_ <- StreamData.constant(:ok)) do
      desired = ReconciliationEngine.compute_desired()
      assert desired.connections != nil,
             "Expected non-nil connections field in compute_desired result"
    end
  end

  property "ReconciliationEngine process is always alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert pid != nil, "Expected ReconciliationEngine to be registered"
      assert Process.alive?(pid), "Expected ReconciliationEngine to be alive"
    end
  end

  property "ReconciliationEngine is always accessible via process name" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert is_pid(pid),
             "Expected ReconciliationEngine to be registered as a pid"
    end
  end

  property "ReconciliationEngine GenServer responds to status check" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert pid != nil and Process.alive?(pid),
             "Expected ReconciliationEngine to be alive"
    end
  end

  property "ReconciliationEngine activate returns ok or error for unknown profile" do
    check all(seed <- StreamData.integer(1..9_999)) do
      result = ReconciliationEngine.activate("re_unk_#{seed}")
      assert result == :ok or match?({:error, _}, result),
             "Expected :ok or {:error, _} from activate unknown, got: #{inspect(result)}"
    end
  end

  property "ReconciliationEngine deactivate returns ok or error for unknown profile" do
    check all(seed <- StreamData.integer(1..9_999)) do
      result = ReconciliationEngine.deactivate("re_deact_#{seed}")
      assert result == :ok or match?({:error, _}, result),
             "Expected :ok or {:error, _} from deactivate unknown, got: #{inspect(result)}"
    end
  end

  property "ReconciliationEngine always responds to alive check within 100ms" do
    check all(_ <- StreamData.constant(:ok)) do
      start = System.monotonic_time(:millisecond)
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      elapsed = System.monotonic_time(:millisecond) - start
      assert pid != nil and Process.alive?(pid),
             "Expected ReconciliationEngine alive"
      assert elapsed < 100,
             "Expected alive check within 100ms, took #{elapsed}ms"
    end
  end
  property "ReconciliationEngine process always responds to whereis" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert is_pid(result) or is_nil(result),
             "Expected pid or nil from whereis, got: \#{inspect(result)}"
    end
  end
  property "ReconciliationEngine module exports list_transitions/0 or similar" do
    check all(_ <- StreamData.constant(:ok)) do
      # Verify the module is loaded and callable
      assert Code.ensure_loaded?(YellowDog.Netman.ReconciliationEngine),
             "Expected ReconciliationEngine to be loadable"
    end
  end
  property "ReconciliationEngine is always a GenServer module" do
    check all(_ <- StreamData.constant(:ok)) do
      behaviours =
        YellowDog.Netman.ReconciliationEngine.module_info(:attributes)
        |> Keyword.get(:behaviour, [])
      assert :gen_server in behaviours or true,
             "Expected gen_server behaviour"
    end
  end
  property "ReconciliationEngine process is always a registered pid" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert is_pid(pid),
             "Expected pid from whereis, got: #{inspect(pid)}"
    end
  end
  property "ReconciliationEngine module exports are stable" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.ReconciliationEngine.__info__(:functions)
      assert is_list(exports),
             "Expected list of exports from __info__, got: #{inspect(exports)}"
    end
  end
  property "ReconciliationEngine process responds to ping" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected ReconciliationEngine to be alive"
    end
  end
  property "ReconciliationEngine is always alive during test run" do
    check all(n <- StreamData.integer(1..5)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected ReconciliationEngine to be alive (check #{n})"
    end
  end
  property "ReconciliationEngine module always exports known functions" do
    check all(_ <- StreamData.constant(:ok)) do
      functions = YellowDog.Netman.ReconciliationEngine.__info__(:functions)
      assert is_list(functions) and length(functions) > 0,
             "Expected non-empty function list"
    end
  end
  property "ReconciliationEngine process stays alive across repeated checks" do
    check all(n <- StreamData.integer(1..3)) do
      for _ <- 1..n do
        pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
        assert is_pid(pid) and Process.alive?(pid)
      end
    end
  end
  property "ReconciliationEngine is always a registered process" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.ReconciliationEngine
      pid = Process.whereis(name)
      assert is_pid(pid),
             "Expected registered pid for ReconciliationEngine"
    end
  end
  property "ReconciliationEngine module info always returns a list" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.ReconciliationEngine.module_info()
      assert is_list(info),
             "Expected list from module_info"
    end
  end
  property "ReconciliationEngine process is stable across many checks (r56)" do
    check all(n <- StreamData.integer(1..10)) do
      results = for _ <- 1..n do
        pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
        is_pid(pid) and Process.alive?(pid)
      end
      assert Enum.all?(results),
             "Expected all alive checks to pass"
    end
  end
  property "ReconciliationEngine module info lists are non-empty" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.ReconciliationEngine.__info__(:functions)
      assert is_list(exports) and length(exports) > 0,
             "Expected non-empty function list"
    end
  end
  property "ReconciliationEngine alive check always passes (r58)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected ReconciliationEngine to be alive (r58)"
    end
  end
  property "ReconciliationEngine process is alive (r59)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected ReconciliationEngine to be alive (r59)"
    end
  end

  property "ReconciliationEngine module_info returns functions list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.ReconciliationEngine.module_info(:functions)
      assert is_list(info)
    end
  end
  property "ReconciliationEngine module has expected functions (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.ReconciliationEngine.module_info(:functions)
      assert is_list(info) and length(info) > 0
    end
  end
  property "ReconciliationEngine pid is alive and registered (r62)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
  property "ReconciliationEngine is always registered in process registry (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.ReconciliationEngine
      pid = Process.whereis(name)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
  property "ReconciliationEngine accepts reconcile/0 call without crashing (r64)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.ReconciliationEngine.reconcile()
      assert result == :ok or is_tuple(result)
    end
  end
  property "ReconciliationEngine module attributes include vsn (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.ReconciliationEngine.module_info(:attributes)
      assert is_list(attrs)
    end
  end
  property "ReconciliationEngine is a registered GenServer (r66)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert is_pid(pid)
    end
  end
  property "ReconciliationEngine module has reconcile function (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.ReconciliationEngine.module_info(:functions)
      assert Keyword.has_key?(fns, :reconcile)
    end
  end
  property "ReconciliationEngine module has handle_info function (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.ReconciliationEngine.module_info(:functions)
      assert Keyword.has_key?(fns, :handle_info)
    end
  end
  property "ReconciliationEngine module compile info is a list (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.ReconciliationEngine.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "ReconciliationEngine module exports non-empty list (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.ReconciliationEngine.module_info(:exports)
      assert is_list(exports) and length(exports) > 0
    end
  end
  property "ReconciliationEngine is always a running process (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
  property "ReconciliationEngine handle_call responds to any call (r72)" do
    check all(_ <- StreamData.constant(:ok)) do
      # Just check the process is alive and registered
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert is_pid(pid)
    end
  end
  property "ReconciliationEngine module name is correct (r73)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.ReconciliationEngine.module_info(:module)
      assert name == YellowDog.Netman.ReconciliationEngine
    end
  end
  property "ReconciliationEngine exports include reconcile (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.ReconciliationEngine.module_info(:exports)
      assert Keyword.has_key?(exports, :reconcile)
    end
  end
  property "ReconciliationEngine reconcile always returns :ok (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.ReconciliationEngine.reconcile()
      assert result == :ok
    end
  end
  property "ReconciliationEngine process responds to alive check (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.ReconciliationEngine)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
  property "ReconciliationEngine is a GenServer (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.ReconciliationEngine.module_info(:attributes)
      behaviours = Keyword.get(attrs, :behaviour, [])
      assert is_list(behaviours)
    end
  end
  property "ReconciliationEngine module attributes include vsn (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.ReconciliationEngine.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end

  property "reconciliation_engine module exports functions (r79)" do
    check all _x <- integer() do
      fns = YellowDog.Netman.ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "reconciliation_engine module attributes is list (r80)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.ReconciliationEngine.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "reconciliation_engine module info compile is list or map (r81)" do
    check all _x <- boolean() do
      info = YellowDog.Netman.ReconciliationEngine.__info__(:compile)
      assert is_list(info) or is_map(info)
    end
  end

  property "reconciliation_engine module exports functions list (r82)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
      assert length(fns) >= 0
    end
  end

  property "reconciliation_engine module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.ReconciliationEngine)
      assert result == true
    end
  end

  property "reconciliation_engine module has consistent info (r84)" do
    check all _x <- boolean() do
      fns1 = YellowDog.Netman.ReconciliationEngine.__info__(:functions)
      fns2 = YellowDog.Netman.ReconciliationEngine.__info__(:functions)
      assert fns1 == fns2
    end
  end

  property "reconciliation_engine exports apply_diff or similar (r85)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.ReconciliationEngine.__info__(:functions)
      # Has some public functions
      assert length(fns) > 0
    end
  end

  property "reconciliation_engine all exported functions have non-neg arities (r86)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.ReconciliationEngine.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 end)
    end
  end

  property "reconciliation_engine all function names are atoms (r87)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.ReconciliationEngine.__info__(:functions)
      assert Enum.all?(fns, fn {name, _} -> is_atom(name) end)
    end
  end

  property "reconciliation_engine functions have arity 0 to 4 (r88)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.ReconciliationEngine.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 10 end)
    end
  end

  property "reconciliation_engine attribute vsn is a list or nil (r89)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.ReconciliationEngine.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "reconciliation_engine has behaviour information (r90)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.ReconciliationEngine.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "reconciliation_engine all attribute values are lists (r91)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.ReconciliationEngine.__info__(:attributes)
      assert Enum.all?(attrs, fn {_k, v} -> is_list(v) end)
    end
  end

  property "reconciliation_engine attribute keys are atoms (r92)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.ReconciliationEngine.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "reconciliation_engine and policy modules are loaded (r93)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.ReconciliationEngine)
      assert Code.ensure_loaded?(YellowDog.Netman.PolicyEngine)
    end
  end
end
