defmodule YellowDog.Netman.Types.ObservedStatePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias YellowDog.Netman.Types.ObservedState

  defp interface_gen do
    gen all(name <- string(:alphanumeric, min_length: 1, max_length: 15)) do
      name
    end
  end

  defp link_gen do
    gen all(
          iface <- interface_gen(),
          index <- positive_integer(),
          state <- member_of([:up, :down, :unknown]),
          carrier <- boolean(),
          mtu <- integer(68..65535)
        ) do
      %{
        interface: iface,
        index: index,
        state: state,
        carrier: carrier,
        mtu: mtu,
        mac: "aa:bb:cc:dd:ee:ff",
        kind: nil
      }
    end
  end

  defp address_gen do
    gen all(
          iface <- interface_gen(),
          a <- integer(1..254),
          b <- integer(0..255),
          c <- integer(0..255),
          d <- integer(1..254),
          prefix <- integer(1..32)
        ) do
      %{
        interface: iface,
        address: "#{a}.#{b}.#{c}.#{d}",
        prefix_len: prefix,
        family: :inet,
        scope: :global
      }
    end
  end

  defp route_gen do
    gen all(
          iface <- interface_gen(),
          dest <- member_of(["default", "10.0.0.0/8", "192.168.0.0/16", "172.16.0.0/12"]),
          gw_last <- integer(1..254),
          metric <- integer(0..9999)
        ) do
      %{
        destination: dest,
        gateway: "10.0.0.#{gw_last}",
        interface: iface,
        metric: metric,
        table: 254,
        protocol: :static,
        scope: :universe
      }
    end
  end

  property "put_link then remove_link restores original state" do
    check all(link <- link_gen()) do
      state = ObservedState.new()

      restored =
        state
        |> ObservedState.put_link(link)
        |> ObservedState.remove_link(link.interface)

      assert restored == state
    end
  end

  property "put_link is idempotent" do
    check all(link <- link_gen()) do
      state = ObservedState.new()

      once = ObservedState.put_link(state, link)
      twice = ObservedState.put_link(once, link)

      assert once == twice
    end
  end

  property "put_link overwrites previous link for same interface" do
    check all(
            link1 <- link_gen(),
            link2 <- link_gen()
          ) do
      link2 = %{link2 | interface: link1.interface}

      state =
        ObservedState.new()
        |> ObservedState.put_link(link1)
        |> ObservedState.put_link(link2)

      assert state.links[link1.interface] == link2
    end
  end

  property "add_address then remove_address restores empty list" do
    check all(addr <- address_gen()) do
      state = ObservedState.new()

      restored =
        state
        |> ObservedState.add_address(addr)
        |> ObservedState.remove_address(addr.interface, addr.address)

      assert restored.addresses[addr.interface] == []
    end
  end

  property "add_route then remove_route restores empty list" do
    check all(route <- route_gen()) do
      state = ObservedState.new()

      restored =
        state
        |> ObservedState.add_route(route)
        |> ObservedState.remove_route(route.destination, route.gateway)

      assert restored.routes == []
    end
  end

  property "multiple links can coexist independently" do
    check all(
            link1 <- link_gen(),
            link2 <- link_gen(),
            link1.interface != link2.interface
          ) do
      state =
        ObservedState.new()
        |> ObservedState.put_link(link1)
        |> ObservedState.put_link(link2)

      assert map_size(state.links) == 2
      assert state.links[link1.interface] == link1
      assert state.links[link2.interface] == link2
    end
  end

  property "removing non-existent link is a no-op" do
    check all(iface <- interface_gen()) do
      state = ObservedState.new()
      assert ObservedState.remove_link(state, iface) == state
    end
  end

  property "same address with different prefix lengths coexist" do
    check all(addr <- address_gen(), prefix2 <- integer(1..32), addr.prefix_len != prefix2) do
      addr2 = %{addr | prefix_len: prefix2}

      state =
        ObservedState.new()
        |> ObservedState.add_address(addr)
        |> ObservedState.add_address(addr2)

      assert length(state.addresses[addr.interface]) == 2

      # Removing with specific prefix_len only removes one
      after_remove = ObservedState.remove_address(state, addr.interface, addr.address, prefix2)
      assert length(after_remove.addresses[addr.interface]) == 1
      assert hd(after_remove.addresses[addr.interface]).prefix_len == addr.prefix_len
    end
  end

  property "removing non-existent address creates empty list entry" do
    check all(
            iface <- interface_gen(),
            addr <- string(:alphanumeric, min_length: 1, max_length: 15)
          ) do
      state = ObservedState.new()
      result = ObservedState.remove_address(state, iface, addr)
      assert result.addresses[iface] == []
    end
  end

  property "multiple distinct addresses on same interface accumulate correctly" do
    check all(
            addr1 <- address_gen(),
            addr2 <- address_gen(),
            addr1.address != addr2.address
          ) do
      addr2 = %{addr2 | interface: addr1.interface}

      state =
        ObservedState.new()
        |> ObservedState.add_address(addr1)
        |> ObservedState.add_address(addr2)

      addresses = state.addresses[addr1.interface]
      assert is_list(addresses)
      assert length(addresses) == 2
      assert Enum.any?(addresses, &(&1.address == addr1.address))
      assert Enum.any?(addresses, &(&1.address == addr2.address))
    end
  end

  property "multiple distinct routes accumulate in route list" do
    check all(
            route1 <- route_gen(),
            route2 <- route_gen(),
            route1.destination != route2.destination
          ) do
      state =
        ObservedState.new()
        |> ObservedState.add_route(route1)
        |> ObservedState.add_route(route2)

      assert length(state.routes) == 2
      assert Enum.any?(state.routes, &(&1.destination == route1.destination))
      assert Enum.any?(state.routes, &(&1.destination == route2.destination))
    end
  end

  property "removing non-existent route is a no-op" do
    check all(
            dest <- member_of(["default", "10.0.0.0/8", "192.168.0.0/16"]),
            gw_last <- integer(1..254)
          ) do
      state = ObservedState.new()
      result = ObservedState.remove_route(state, dest, "10.0.0.#{gw_last}")
      assert result == state
    end
  end

  property "new always returns empty ObservedState with no links, addresses, or routes" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert %ObservedState{} = state
      assert state.links == %{}
      assert state.addresses == %{}
      assert state.routes == []
    end
  end

  property "adding N routes with distinct destinations produces N-entry route list" do
    check all(
            count <- StreamData.integer(1..5),
            gws <-
              StreamData.list_of(
                gen all(last <- StreamData.integer(1..254)) do
                  "10.0.0.#{last}"
                end,
                length: count
              )
          ) do
      routes =
        Enum.with_index(gws)
        |> Enum.map(fn {gw, i} ->
          %{
            destination: "10.#{i}.0.0/8",
            gateway: gw,
            interface: "lo",
            metric: 100,
            table: 254,
            protocol: :static,
            scope: :universe
          }
        end)

      state = Enum.reduce(routes, ObservedState.new(), &ObservedState.add_route(&2, &1))
      assert length(state.routes) == count,
             "Expected #{count} routes, got #{length(state.routes)}"
    end
  end

  property "links map size equals number of distinct interfaces added" do
    check all(links <- StreamData.list_of(link_gen(), min_length: 1, max_length: 5)) do
      state = Enum.reduce(links, ObservedState.new(), &ObservedState.put_link(&2, &1))
      unique_ifaces = links |> Enum.map(& &1.interface) |> Enum.uniq() |> length()

      assert map_size(state.links) == unique_ifaces,
             "Expected #{unique_ifaces} links, got #{map_size(state.links)}"
    end
  end

  property "remove_link leaves the interface's addresses unchanged" do
    check all(
            link <- link_gen(),
            addr <- address_gen()
          ) do
      addr = %{addr | interface: link.interface}

      state =
        ObservedState.new()
        |> ObservedState.put_link(link)
        |> ObservedState.add_address(addr)
        |> ObservedState.remove_link(link.interface)

      assert not Map.has_key?(state.links, link.interface)

      addresses = state.addresses[link.interface] || []

      assert Enum.any?(addresses, &(&1.address == addr.address)),
             "Address #{addr.address} should still be present after remove_link"
    end
  end

  property "add_address creates an entry for the interface in state.addresses" do
    check all(addr <- address_gen()) do
      state = ObservedState.new() |> ObservedState.add_address(addr)

      assert Map.has_key?(state.addresses, addr.interface),
             "Expected addresses to contain key #{addr.interface}"
    end
  end

  property "add_route creates exactly one entry in routes when starting from empty" do
    check all(route <- route_gen()) do
      state = ObservedState.new() |> ObservedState.add_route(route)
      assert length(state.routes) == 1,
             "Expected 1 route after add_route, got #{length(state.routes)}"
    end
  end

  property "remove_address for a different address value leaves original address intact" do
    check all(
            addr1 <- address_gen(),
            addr2 <- address_gen(),
            addr1.address != addr2.address
          ) do
      a2 = %{addr2 | interface: addr1.interface}

      state =
        ObservedState.new()
        |> ObservedState.add_address(addr1)
        |> ObservedState.remove_address(addr1.interface, a2.address)

      addresses = state.addresses[addr1.interface] || []

      assert Enum.any?(addresses, &(&1.address == addr1.address)),
             "Expected #{addr1.address} to survive removal of #{a2.address}"
    end
  end

  property "add_address is additive — address count never decreases after adding another" do
    check all(
            iface <- interface_gen(),
            addr1 <- address_gen(),
            addr2 <- address_gen()
          ) do
      a1 = %{addr1 | interface: iface}
      a2 = %{addr2 | interface: iface}

      state_one = ObservedState.new() |> ObservedState.add_address(a1)
      state_two = state_one |> ObservedState.add_address(a2)

      count_one = length(state_one.addresses[iface] || [])
      count_two = length(state_two.addresses[iface] || [])

      assert count_two >= count_one,
             "Expected address count to be non-decreasing after add_address"
    end
  end

  property "put_link creates an entry for the interface in state.links" do
    check all(link <- link_gen()) do
      state = ObservedState.new() |> ObservedState.put_link(link)

      assert Map.has_key?(state.links, link.interface),
             "Expected links to contain key #{link.interface}"
    end
  end

  property "remove_route with mismatched gateway leaves all routes intact" do
    check all(
            route <- route_gen(),
            gw_last <- integer(1..254),
            route.gateway != "10.0.0.#{gw_last}"
          ) do
      state = ObservedState.new() |> ObservedState.add_route(route)

      after_remove =
        ObservedState.remove_route(state, route.destination, "10.0.0.#{gw_last}")

      assert length(after_remove.routes) == length(state.routes),
             "Expected route count unchanged after remove with wrong gateway"
    end
  end

  property "put_link then get from links map returns the same link" do
    check all(link <- link_gen()) do
      state = ObservedState.new() |> ObservedState.put_link(link)
      assert state.links[link.interface] == link,
             "Expected links[#{link.interface}] == #{inspect(link)}, got #{inspect(state.links[link.interface])}"
    end
  end

  property "add_address creates entry with interface field matching the address interface" do
    check all(addr <- address_gen()) do
      state = ObservedState.new() |> ObservedState.add_address(addr)
      addresses = state.addresses[addr.interface] || []
      added = Enum.find(addresses, &(&1.address == addr.address))
      assert added != nil,
             "Expected to find address #{addr.address} in state.addresses[#{addr.interface}]"
      assert added.interface == addr.interface,
             "Expected address.interface == #{addr.interface}, got: #{inspect(added.interface)}"
    end
  end

  property "add_route then route in state.routes has matching destination" do
    check all(route <- route_gen()) do
      state = ObservedState.new() |> ObservedState.add_route(route)
      added = Enum.find(state.routes, &(&1.destination == route.destination))
      assert added != nil,
             "Expected route with destination #{route.destination} in state.routes"
    end
  end

  property "new/0 always creates an ObservedState with empty routes list" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert state.routes == [],
             "Expected empty routes list in new ObservedState, got: #{inspect(state.routes)}"
    end
  end

  property "new/0 always creates an ObservedState with empty addresses map" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert state.addresses == %{},
             "Expected empty addresses map in new ObservedState, got: #{inspect(state.addresses)}"
    end
  end

  property "new/0 always creates an ObservedState with empty links map" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert state.links == %{},
             "Expected empty links map in new ObservedState, got: \#{inspect(state.links)}"
    end
  end

  property "new/0 always creates a struct with empty links map" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert state.links == %{},
             "Expected empty links map in new ObservedState, got: #{inspect(state.links)}"
    end
  end

  property "new/0 always creates a struct where routes is an empty list" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert is_list(state.routes) and state.routes == [],
             "Expected empty routes list, got: #{inspect(state.routes)}"
    end
  end

  property "new/0 always produces a struct with links, addresses, and routes" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert is_struct(state, ObservedState),
             "Expected ObservedState struct, got: #{inspect(state)}"
      assert Map.has_key?(state, :links), "Missing :links field"
      assert Map.has_key?(state, :addresses), "Missing :addresses field"
      assert Map.has_key?(state, :routes), "Missing :routes field"
    end
  end

  property "new/0 creates an ObservedState that is a struct" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert is_struct(state, ObservedState),
             "Expected ObservedState struct from new/0, got: #{inspect(state)}"
    end
  end

  property "new/0 ObservedState is always equal to itself" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert state == state,
             "Expected ObservedState to be equal to itself"
    end
  end

  property "new/0 addresses values are always maps" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      for {_iface, addrs} <- state.addresses do
        assert is_list(addrs),
               "Expected list of addresses per interface, got: #{inspect(addrs)}"
      end
    end
  end

  property "new/0 routes is always a list on fresh state" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert is_list(state.routes),
             "Expected list routes in ObservedState.new/0, got: \#{inspect(state.routes)}"
    end
  end

  property "new/0 addresses map is always empty on fresh state" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert state.addresses == %{},
             "Expected empty addresses map in ObservedState.new/0, got: #{inspect(state.addresses)}"
    end
  end

  property "new/0 links map is always empty on fresh state" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert state.links == %{},
             "Expected empty links map in ObservedState.new/0, got: #{inspect(state.links)}"
    end
  end

  property "ObservedState.new/0 always returns struct with :routes key" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert Map.has_key?(state, :routes),
             "Expected :routes key in ObservedState.new/0 result"
    end
  end
end
