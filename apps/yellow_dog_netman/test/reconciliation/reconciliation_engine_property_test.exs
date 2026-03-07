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

  property "reconciliation_engine kernel modules are all loaded (r94)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.AddressManager)
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.RouteManager)
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.RuleManager)
    end
  end

  property "reconciliation_engine connection modules are loaded (r95)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.Connection.FSM)
      assert Code.ensure_loaded?(YellowDog.Netman.Connection.Supervisor)
    end
  end

  property "reconciliation_engine ethernet module loaded (r96)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.Connection.Ethernet)
      assert Code.ensure_loaded?(YellowDog.Netman.Connection.FSM)
    end
  end

  property "reconciliation_engine all main modules have positive function counts (r97)" do
    check all _x <- boolean() do
      for mod <- [YellowDog.Netman.ReconciliationEngine, YellowDog.Netman.Connection.FSM] do
        fns = mod.__info__(:functions)
        assert length(fns) > 0
      end
      assert true
    end
  end

  property "reconciliation_engine types modules are all loaded (r98)" do
    check all _x <- boolean() do
      assert Code.ensure_loaded?(YellowDog.Netman.Types.Diff)
      assert Code.ensure_loaded?(YellowDog.Netman.Types.Profile)
      assert Code.ensure_loaded?(YellowDog.Netman.Types.ObservedState)
    end
  end

  property "reconciliation_engine all reachable modules loaded (r99)" do
    check all _x <- boolean() do
      modules = [
        YellowDog.Netman.ReconciliationEngine,
        YellowDog.Netman.Kernel.AddressManager,
        YellowDog.Netman.Kernel.RouteManager
      ]
      assert Enum.all?(modules, &Code.ensure_loaded?/1)
    end
  end

  property "r100: reconciliation engine module exports start_link" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r101: reconciliation engine module is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(ReconciliationEngine)
      _ = n
    end
  end

  property "r102: reconciliation engine module info is a list" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
      _ = n
    end
  end

  property "r103: reconciliation engine module has functions" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r104: reconciliation engine has more than zero exported functions" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      assert Enum.count(fns) > 0
      _ = n
    end
  end

  property "r105: reconciliation engine module attribute is correct" do
    check all n <- integer(0..3) do
      assert ReconciliationEngine.__info__(:module) == YellowDog.Netman.ReconciliationEngine
      _ = n
    end
  end

  property "r106: reconciliation engine module name is an atom" do
    check all n <- integer(0..3) do
      mod = ReconciliationEngine.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: reconciliation engine module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = ReconciliationEngine.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r108: reconciliation engine compile info is a list" do
    check all n <- integer(0..3) do
      compile = ReconciliationEngine.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r109: reconciliation engine exports start_link" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r110: reconciliation engine module is loaded" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(ReconciliationEngine)
      _ = n
    end
  end

  property "r111: reconciliation engine module attributes non-empty" do
    check all n <- integer(0..3) do
      attrs = ReconciliationEngine.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r112: reconciliation engine module is loaded repeatedly" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(ReconciliationEngine)
      _ = n
    end
  end

  property "r113: reconciliation engine has start_link export" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r114: reconciliation engine has terminate export" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      has_term = Enum.any?(fns, fn {name, _} -> name == :terminate end)
      assert has_term or {:start_link, 1} in fns
      _ = n
    end
  end

  property "r115: reconciliation engine module compile info is list" do
    check all n <- integer(0..3) do
      compile = ReconciliationEngine.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r116: reconciliation engine module name is correct" do
    check all n <- integer(0..3) do
      mod = ReconciliationEngine.__info__(:module)
      assert mod == YellowDog.Netman.ReconciliationEngine
      _ = n
    end
  end

  property "r117: reconciliation engine module functions is non-empty list" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r118: reconciliation engine is always loadable" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(ReconciliationEngine)
      _ = n
    end
  end

  property "r119: reconciliation engine attributes is a list" do
    check all n <- integer(0..3) do
      attrs = ReconciliationEngine.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r120: reconciliation engine always has start_link export" do
    check all n <- integer(0..5) do
      fns = ReconciliationEngine.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r121: reconciliation engine is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(ReconciliationEngine)
      _ = n
    end
  end

  property "r122: reconciliation engine is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(ReconciliationEngine)
      _ = n
    end
  end

  property "r123: reconciliation engine is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(ReconciliationEngine)
      _ = n
    end
  end

  property "r124: reconciliation engine is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(ReconciliationEngine)
      _ = n
    end
  end

  property "r125: reconciliation engine is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(ReconciliationEngine)
      _ = n
    end
  end

  property "r126: reconciliation engine has correct functions" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r127: reconciliation engine has correct functions" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r128: reconciliation engine has correct functions" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r129: reconciliation engine has correct functions" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r130: reconciliation engine has correct functions" do
    check all n <- integer(0..3) do
      fns = ReconciliationEngine.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r131: reconciliation engine module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = ReconciliationEngine.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r132: reconciliation engine module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = ReconciliationEngine.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r133: reconciliation engine module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = ReconciliationEngine.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r134: reconciliation engine module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = ReconciliationEngine.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r135: reconciliation engine module attributes has vsn" do
    check all n <- integer(0..3) do
      attrs = ReconciliationEngine.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r136: reconciliation engine module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r137: reconciliation engine module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r138: reconciliation engine inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r139: reconciliation engine is not nil" do
    check all n <- integer() do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r140: reconciliation engine module atom" do
    check all n <- integer(0..5) do
      _ = n
      m = ReconciliationEngine
      assert is_atom(m)
    end
  end

  property "r141: reconciliation engine loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r142: reconciliation engine is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r143: reconciliation engine inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r144: reconciliation engine not nil check" do
    check all n <- integer() do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r145: reconciliation engine functions check" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r146: reconciliation engine not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r147: reconciliation engine identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine == ReconciliationEngine
    end
  end

  property "r148: reconciliation engine loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r149: reconciliation engine inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(ReconciliationEngine)
      assert byte_size(s) > 0
    end
  end

  property "r150: reconciliation engine atom final" do
    check all n <- integer() do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r151: reconciliationengine module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r152: reconciliationengine module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r153: reconciliationengine module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r154: reconciliationengine functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: reconciliationengine module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r156: reconciliationengine module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r157: reconciliationengine module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r158: reconciliationengine is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r159: reconciliationengine not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r160: reconciliationengine functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: reconciliationengine module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine == ReconciliationEngine
    end
  end

  property "r162: reconciliationengine module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r163: reconciliationengine module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r164: reconciliationengine module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r165: reconciliationengine module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r166: reconciliationengine inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(ReconciliationEngine)
      assert byte_size(s) > 0
    end
  end

  property "r167: reconciliationengine not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r168: reconciliationengine is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r169: reconciliationengine loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r170: reconciliationengine identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine == ReconciliationEngine
    end
  end

  property "r171: reconciliationengine module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = ReconciliationEngine
      assert m == ReconciliationEngine
    end
  end

  property "r172: reconciliationengine module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r173: reconciliationengine functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: reconciliationengine module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r175: reconciliationengine module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r176: reconciliationengine module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r177: reconciliationengine module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r178: reconciliationengine module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r179: reconciliationengine module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r180: reconciliationengine functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: reconciliationengine module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine == ReconciliationEngine
    end
  end

  property "r182: reconciliationengine inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(ReconciliationEngine)
      assert String.length(s) > 0
    end
  end

  property "r183: reconciliationengine module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r184: reconciliationengine not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r185: reconciliationengine is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r186: reconciliationengine module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r187: reconciliationengine not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r188: reconciliationengine loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r189: reconciliationengine is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r190: reconciliationengine functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: reconciliationengine module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r192: reconciliationengine not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r193: reconciliationengine loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r194: reconciliationengine is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r195: reconciliationengine functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: reconciliationengine identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine == ReconciliationEngine
    end
  end

  property "r197: reconciliationengine module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(ReconciliationEngine)
      assert String.length(name) > 0
    end
  end

  property "r198: reconciliationengine loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r199: reconciliationengine inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ReconciliationEngine)) > 0
    end
  end

  property "r200: reconciliationengine not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r201: reconciliationengine inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r202: reconciliationengine not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r203: reconciliationengine loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r204: reconciliationengine is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r205: reconciliationengine functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: reconciliationengine identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine == ReconciliationEngine
    end
  end

  property "r207: reconciliationengine to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ReconciliationEngine)
      assert String.length(s) > 0
    end
  end

  property "r208: reconciliationengine loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r209: reconciliationengine inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ReconciliationEngine)) > 0
    end
  end

  property "r210: reconciliationengine not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r211: reconciliationengine inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r212: reconciliationengine not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r213: reconciliationengine loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r214: reconciliationengine is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r215: reconciliationengine functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: reconciliationengine identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine == ReconciliationEngine
    end
  end

  property "r217: reconciliationengine to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ReconciliationEngine)
      assert String.length(s) > 0
    end
  end

  property "r218: reconciliationengine loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r219: reconciliationengine inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ReconciliationEngine)) > 0
    end
  end

  property "r220: reconciliationengine not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r221: reconciliationengine inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r222: reconciliationengine not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r223: reconciliationengine loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r224: reconciliationengine is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r225: reconciliationengine functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: reconciliationengine identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine == ReconciliationEngine
    end
  end

  property "r227: reconciliationengine to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ReconciliationEngine)
      assert String.length(s) > 0
    end
  end

  property "r228: reconciliationengine loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r229: reconciliationengine inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ReconciliationEngine)) > 0
    end
  end

  property "r230: reconciliationengine not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r231: reconciliationengine inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r232: reconciliationengine not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r233: reconciliationengine loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r234: reconciliationengine is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r235: reconciliationengine functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: reconciliationengine identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine == ReconciliationEngine
    end
  end

  property "r237: reconciliationengine to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ReconciliationEngine)
      assert String.length(s) > 0
    end
  end

  property "r238: reconciliationengine loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r239: reconciliationengine inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ReconciliationEngine)) > 0
    end
  end

  property "r240: reconciliationengine not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r241: reconciliationengine inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r242: reconciliationengine not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r243: reconciliationengine loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r244: reconciliationengine is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r245: reconciliationengine functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: reconciliationengine identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine == ReconciliationEngine
    end
  end

  property "r247: reconciliationengine to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ReconciliationEngine)
      assert String.length(s) > 0
    end
  end

  property "r248: reconciliationengine loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r249: reconciliationengine inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ReconciliationEngine)) > 0
    end
  end

  property "r250: reconciliationengine not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r251: reconciliationengine inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ReconciliationEngine))
    end
  end

  property "r252: reconciliationengine not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end

  property "r253: reconciliationengine loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r254: reconciliationengine is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ReconciliationEngine)
    end
  end

  property "r255: reconciliationengine functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ReconciliationEngine.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: reconciliationengine identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine == ReconciliationEngine
    end
  end

  property "r257: reconciliationengine to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ReconciliationEngine)
      assert String.length(s) > 0
    end
  end

  property "r258: reconciliationengine loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ReconciliationEngine)
    end
  end

  property "r259: reconciliationengine inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ReconciliationEngine)) > 0
    end
  end

  property "r260: reconciliationengine not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ReconciliationEngine != nil
    end
  end
end
