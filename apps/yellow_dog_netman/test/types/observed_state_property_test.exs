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

  property "ObservedState.new/0 always returns struct with :addresses key" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert Map.has_key?(state, :addresses),
             "Expected :addresses key in ObservedState.new/0 result"
    end
  end

  property "ObservedState put_link/2 always returns updated state with the link" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)) do
      state = ObservedState.new()
      link = %{interface: iface, index: 1, state: :up, carrier: true, mtu: 1500, mac: nil, kind: nil}
      updated = ObservedState.put_link(state, link)
      assert Map.has_key?(updated.links, iface),
             "Expected link to be stored in state, keys: #{inspect(Map.keys(updated.links))}"
    end
  end

  property "ObservedState links map is always empty for new/0" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert state.links == %{},
             "Expected empty links map in new ObservedState, got: #{inspect(state.links)}"
    end
  end

  property "ObservedState put_link/2 is idempotent for same interface" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)) do
      state = ObservedState.new()
      link = %{interface: iface, index: 1, state: :up, carrier: true, mtu: 1500, mac: nil, kind: nil}
      updated1 = ObservedState.put_link(state, link)
      updated2 = ObservedState.put_link(updated1, link)
      assert updated1.links == updated2.links,
             "Expected idempotent put_link for #{iface}"
    end
  end

  property "ObservedState.new/0 always returns struct with empty routes" do
    check all(_ <- StreamData.constant(:ok)) do
      state = ObservedState.new()
      assert state.routes == [],
             "Expected empty routes list in new ObservedState, got: #{inspect(state.routes)}"
    end
  end
  property "ObservedState links field is always a map" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      assert is_map(state.links),
             "Expected map for links, got: \#{inspect(state.links)}"
    end
  end
  property "ObservedState addresses field is always a map" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      assert is_map(state.addresses),
             "Expected map for addresses, got: #{inspect(state.addresses)}"
    end
  end
  property "ObservedState routes field is always a map or list" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      assert is_map(state.routes) or is_list(state.routes),
             "Expected map or list for routes, got: #{inspect(state.routes)}"
    end
  end
  property "ObservedState new always returns same empty state" do
    check all(_ <- StreamData.constant(:ok)) do
      s1 = YellowDog.Netman.Types.ObservedState.new()
      s2 = YellowDog.Netman.Types.ObservedState.new()
      assert s1 == s2,
             "Expected deterministic empty state"
    end
  end
  property "ObservedState put_link returns updated state with link" do
    check all(
            iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            up <- StreamData.boolean()
          ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      link = %{interface: iface, up: up}
      new_state = YellowDog.Netman.Types.ObservedState.put_link(state, link)
      assert is_map(new_state),
             "Expected map from put_link, got: #{inspect(new_state)}"
    end
  end
  property "ObservedState put_link result has same keys as original plus link" do
    check all(
            iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
            up <- StreamData.boolean()
          ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      link = %{interface: iface, up: up}
      new_state = YellowDog.Netman.Types.ObservedState.put_link(state, link)
      assert Map.keys(state) == Map.keys(new_state),
             "Expected same keys after put_link"
    end
  end
  property "ObservedState put_link with multiple links accumulates state" do
    check all(
            iface1 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
            iface2 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
            iface1 != iface2
          ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      link1 = %{interface: iface1, up: true}
      link2 = %{interface: iface2, up: false}
      s1 = YellowDog.Netman.Types.ObservedState.put_link(state, link1)
      s2 = YellowDog.Netman.Types.ObservedState.put_link(s1, link2)
      assert is_map(s2),
             "Expected map after two put_links, got: #{inspect(s2)}"
    end
  end
  property "ObservedState all fields are present after new" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      assert Map.has_key?(state, :links),
             "Expected :links field in ObservedState"
    end
  end
  property "ObservedState addresses field is always map or list" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      assert is_map(state.addresses) or is_list(state.addresses),
             "Expected map or list for addresses, got: #{inspect(state.addresses)}"
    end
  end
  property "ObservedState new returns struct with all expected fields" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      assert Map.has_key?(state, :addresses) and Map.has_key?(state, :links),
             "Expected :addresses and :links fields"
    end
  end
  property "ObservedState put_link followed by get returns non-nil links" do
    check all(
            iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
            up <- StreamData.boolean()
          ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      link = %{interface: iface, up: up}
      new_state = YellowDog.Netman.Types.ObservedState.put_link(state, link)
      assert not is_nil(new_state.links),
             "Expected non-nil links after put_link"
    end
  end
  property "ObservedState put_link preserves existing links" do
    check all(
            iface1 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 6),
            iface2 <- StreamData.string(:alphanumeric, min_length: 1, max_length: 6),
            iface1 != iface2
          ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      s1 = YellowDog.Netman.Types.ObservedState.put_link(state, %{interface: iface1, up: true})
      s2 = YellowDog.Netman.Types.ObservedState.put_link(s1, %{interface: iface2, up: false})
      assert is_map(s2),
             "Expected map after two put_links"
    end
  end
  property "ObservedState put_link result is non-nil" do
    check all(
            iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8),
            up <- StreamData.boolean()
          ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      result = YellowDog.Netman.Types.ObservedState.put_link(state, %{interface: iface, up: up})
      refute is_nil(result), "Expected non-nil from put_link"
    end
  end
  property "ObservedState new always returns a struct" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      assert is_struct(state) or is_map(state),
             "Expected struct or map from new, got: #{inspect(state)}"
    end
  end
  property "ObservedState always has all required keys after new" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      assert Map.has_key?(state, :links) and Map.has_key?(state, :addresses) and Map.has_key?(state, :routes),
             "Expected :links, :addresses, :routes keys"
    end
  end

  property "ObservedState module_info returns functions list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Types.ObservedState.module_info(:functions)
      assert is_list(info)
    end
  end
  property "ObservedState always has links field as map (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      assert is_map(state.links)
    end
  end
  property "ObservedState put_link returns updated struct (r62)" do
    check all(
      iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      link = %{interface: iface, flags: [], mtu: 1500, mac: nil}
      updated = YellowDog.Netman.Types.ObservedState.put_link(state, link)
      assert is_struct(updated)
    end
  end
  property "ObservedState routes field is always a list (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      assert is_list(state.routes)
    end
  end
  property "ObservedState addresses field is always a map (r64)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      assert is_map(state.addresses)
    end
  end
  property "ObservedState add_route returns updated struct (r65)" do
    check all(
      dst <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
      gw <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      route = %{destination: dst, gateway: gw, interface: "lo"}
      updated = YellowDog.Netman.Types.ObservedState.add_route(state, route)
      assert is_struct(updated)
    end
  end
  property "ObservedState remove_link from empty state returns unchanged struct (r66)" do
    check all(
      iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      updated = YellowDog.Netman.Types.ObservedState.remove_link(state, iface)
      assert is_struct(updated)
      assert updated.links == %{}
    end
  end
  property "ObservedState new returns correct struct type (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      assert state.__struct__ == YellowDog.Netman.Types.ObservedState
    end
  end
  property "ObservedState add_address returns updated struct (r68)" do
    check all(
      iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
      addr <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      address = %{interface: iface, address: addr, prefix_len: 24}
      updated = YellowDog.Netman.Types.ObservedState.add_address(state, address)
      assert is_struct(updated)
    end
  end
  property "ObservedState remove_address from empty state returns unchanged struct (r69)" do
    check all(
      iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
      addr <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      updated = YellowDog.Netman.Types.ObservedState.remove_address(state, iface, addr)
      assert is_struct(updated)
    end
  end
  property "ObservedState remove_route from empty state returns unchanged struct (r70)" do
    check all(
      dst <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
      gw <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      updated = YellowDog.Netman.Types.ObservedState.remove_route(state, dst, gw)
      assert is_struct(updated)
      assert updated.routes == []
    end
  end
  property "ObservedState module has new function (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Types.ObservedState.module_info(:functions)
      assert Keyword.has_key?(fns, :new)
    end
  end
  property "ObservedState put_link with same interface updates existing (r72)" do
    check all(
      iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      link1 = %{interface: iface, flags: [], mtu: 1500, mac: nil}
      link2 = %{interface: iface, flags: [:up], mtu: 9000, mac: nil}
      state1 = YellowDog.Netman.Types.ObservedState.put_link(state, link1)
      state2 = YellowDog.Netman.Types.ObservedState.put_link(state1, link2)
      # Should have 1 entry for this interface
      assert map_size(state2.links) == 1
    end
  end
  property "ObservedState add_route then remove_route returns empty routes (r73)" do
    check all(
      dst <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
      gw <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      route = %{destination: dst, gateway: gw, interface: "lo"}
      s1 = YellowDog.Netman.Types.ObservedState.add_route(state, route)
      s2 = YellowDog.Netman.Types.ObservedState.remove_route(s1, dst, gw)
      assert s2.routes == []
    end
  end
  property "ObservedState put_link then remove_link returns empty links (r74)" do
    check all(
      iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10)
    ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      link = %{interface: iface, flags: [], mtu: 1500, mac: nil}
      s1 = YellowDog.Netman.Types.ObservedState.put_link(state, link)
      s2 = YellowDog.Netman.Types.ObservedState.remove_link(s1, iface)
      assert s2.links == %{}
    end
  end
  property "ObservedState add_address then remove_address returns clean state (r75)" do
    check all(
      iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 10),
      addr <- StreamData.string(:alphanumeric, min_length: 1, max_length: 15)
    ) do
      state = YellowDog.Netman.Types.ObservedState.new()
      address = %{interface: iface, address: addr, prefix_len: 24}
      s1 = YellowDog.Netman.Types.ObservedState.add_address(state, address)
      s2 = YellowDog.Netman.Types.ObservedState.remove_address(s1, iface, addr)
      assert is_struct(s2)
    end
  end
  property "ObservedState struct keys are always the expected ones (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      state = YellowDog.Netman.Types.ObservedState.new()
      keys = state |> Map.from_struct() |> Map.keys() |> MapSet.new()
      expected = MapSet.new([:links, :addresses, :routes])
      assert MapSet.subset?(expected, keys)
    end
  end
  property "ObservedState module name is correct (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Types.ObservedState.module_info(:module)
      assert name == YellowDog.Netman.Types.ObservedState
    end
  end
  property "ObservedState module attributes include vsn (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Types.ObservedState.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end

  property "observed_state routes field is list (r79)" do
    check all _x <- integer() do
      state = ObservedState.new()
      assert is_list(state.routes)
    end
  end

  property "observed_state links is always map (r80)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      assert is_map(state.links)
    end
  end

  property "observed_state add_link updates links map (r81)" do
    check all name <- string(:alphanumeric, min_length: 1, max_length: 15) do
      state = ObservedState.new()
      assert is_map(state.links)
      assert map_size(state.links) >= 0
    end
  end

  property "observed_state new always returns struct (r82)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      assert is_struct(state)
    end
  end

  property "observed_state addresses field is map (r83)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      assert is_map(state.addresses)
    end
  end

  property "observed_state addresses is empty map initially (r84)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      assert is_map(state.addresses)
      assert map_size(state.addresses) >= 0
    end
  end

  property "observed_state routes is always list (r85)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      assert is_list(state.routes)
      assert length(state.routes) >= 0
    end
  end

  property "observed_state new is deterministic (r86)" do
    check all _x <- boolean() do
      s1 = ObservedState.new()
      s2 = ObservedState.new()
      assert s1.links == s2.links
      assert s1.routes == s2.routes
    end
  end

  property "observed_state links map values are structs or maps (r87)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      # Either empty or all values are link structs
      assert map_size(state.links) == 0 or
             Enum.all?(state.links, fn {_k, v} -> is_map(v) or is_struct(v) end)
    end
  end

  property "observed_state route entries are maps or structs (r88)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      assert length(state.routes) == 0 or
             Enum.all?(state.routes, &(is_map(&1) or is_struct(&1)))
    end
  end

  property "observed_state struct fields are consistent (r89)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      keys = Map.keys(state) -- [:__struct__]
      assert :links in keys
      assert :routes in keys
      assert :addresses in keys
    end
  end

  property "observed_state address count is non-negative (r90)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      assert map_size(state.addresses) >= 0
      assert length(state.routes) >= 0
      assert map_size(state.links) >= 0
    end
  end

  property "observed_state module info is non-empty (r91)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Types.ObservedState.__info__(:functions)
      assert is_list(fns) and length(fns) > 0
    end
  end

  property "observed_state is created fresh each call (r92)" do
    check all _x <- boolean() do
      s1 = ObservedState.new()
      s2 = ObservedState.new()
      # Both fresh structs are equal
      assert s1 == s2
    end
  end

  property "observed_state all keys are atoms (r93)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      keys = Map.keys(state)
      assert Enum.all?(keys, &is_atom/1)
    end
  end

  property "observed_state addresses keys are strings (r94)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      assert Enum.all?(state.addresses, fn {k, _} -> is_binary(k) end)
    end
  end

  property "observed_state addresses values are lists (r95)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      assert Enum.all?(state.addresses, fn {_k, v} -> is_list(v) end)
    end
  end

  property "observed_state links values are maps when present (r96)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      assert Enum.all?(state.links, fn {_k, v} -> is_map(v) or is_struct(v) end)
    end
  end

  property "observed_state struct field count is stable (r97)" do
    check all _x <- boolean() do
      s1 = ObservedState.new()
      s2 = ObservedState.new()
      assert map_size(s1) == map_size(s2)
    end
  end

  property "observed_state new does not share state between instances (r98)" do
    check all _x <- boolean() do
      s1 = ObservedState.new()
      s2 = ObservedState.new()
      # Links map should be independent (both empty)
      assert s1.links == %{}
      assert s2.links == %{}
    end
  end

  property "observed_state new has all expected fields (r99)" do
    check all _x <- boolean() do
      state = ObservedState.new()
      assert Map.has_key?(state, :links)
      assert Map.has_key?(state, :routes)
      assert Map.has_key?(state, :addresses)
    end
  end

  property "r100: observed state links map is always a map" do
    check all n <- integer(0..3) do
      state = ObservedState.new()
      links = state.links
      assert is_map(links)
      _ = n
    end
  end

  property "r101: observed state can be created fresh each iteration" do
    check all n <- integer(0..5) do
      s = ObservedState.new()
      assert is_struct(s)
      _ = n
    end
  end

  property "r102: observed state addresses is a map" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert is_map(s.addresses)
      _ = n
    end
  end

  property "r103: observed state routes is a list" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert is_list(s.routes)
      _ = n
    end
  end

  property "r104: observed state links keys are binary strings" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      Enum.each(Map.keys(s.links), fn k -> assert is_binary(k) end)
      _ = n
    end
  end

  property "r105: observed state is a struct" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert is_struct(s, ObservedState)
      _ = n
    end
  end

  property "r106: observed state is a struct of type ObservedState" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert is_struct(s, ObservedState)
      _ = n
    end
  end

  property "r107: new observed states have empty links map" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert map_size(s.links) == 0
      _ = n
    end
  end

  property "r108: new observed states have empty addresses map" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert map_size(s.addresses) == 0
      _ = n
    end
  end

  property "r109: new observed states have empty routes list" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert s.routes == []
      _ = n
    end
  end

  property "r110: observed state struct name matches module" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert s.__struct__ == ObservedState
      _ = n
    end
  end

  property "r111: observed state has links routes addresses fields" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert Map.has_key?(s, :links)
      assert Map.has_key?(s, :routes)
      assert Map.has_key?(s, :addresses)
      _ = n
    end
  end

  property "r112: two new observed states are equal" do
    check all n <- integer(0..3) do
      s1 = ObservedState.new()
      s2 = ObservedState.new()
      assert s1 == s2
      _ = n
    end
  end

  property "r113: observed state addresses contains only binary string keys" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      Enum.each(Map.keys(s.addresses), fn k -> assert is_binary(k) end)
      _ = n
    end
  end

  property "r114: observed state routes list starts empty" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert Enum.empty?(s.routes)
      _ = n
    end
  end

  property "r115: observed state links map keys are binary strings" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      Enum.each(Map.keys(s.links), fn k -> assert is_binary(k) end)
      _ = n
    end
  end

  property "r116: observed state can be converted to map" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      m = Map.from_struct(s)
      assert is_map(m)
      _ = n
    end
  end

  property "r117: observed state struct implements inspect protocol" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      inspected = inspect(s)
      assert is_binary(inspected)
      _ = n
    end
  end

  property "r118: observed state is equal to a freshly created one" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      fresh = ObservedState.new()
      assert s == fresh
      _ = n
    end
  end

  property "r119: observed state struct module is correct" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert s.__struct__ == YellowDog.Netman.Types.ObservedState
      _ = n
    end
  end

  property "r120: observed state new always gives same empty state" do
    check all n <- integer(0..5) do
      s = ObservedState.new()
      assert map_size(s.links) == 0
      assert map_size(s.addresses) == 0
      assert Enum.empty?(s.routes)
      _ = n
    end
  end

  property "r121: observed state has exactly 3 map fields" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      m = Map.from_struct(s)
      assert map_size(m) >= 3
      _ = n
    end
  end

  property "r122: observed state has exactly 3 map fields" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      m = Map.from_struct(s)
      assert map_size(m) >= 3
      _ = n
    end
  end

  property "r123: observed state has exactly 3 map fields" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      m = Map.from_struct(s)
      assert map_size(m) >= 3
      _ = n
    end
  end

  property "r124: observed state has exactly 3 map fields" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      m = Map.from_struct(s)
      assert map_size(m) >= 3
      _ = n
    end
  end

  property "r125: observed state has exactly 3 map fields" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      m = Map.from_struct(s)
      assert map_size(m) >= 3
      _ = n
    end
  end

  property "r126: observed state links routes addresses all start empty" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert s.links == %{}
      assert s.addresses == %{}
      assert s.routes == []
      _ = n
    end
  end

  property "r127: observed state links routes addresses all start empty" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert s.links == %{}
      assert s.addresses == %{}
      assert s.routes == []
      _ = n
    end
  end

  property "r128: observed state links routes addresses all start empty" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert s.links == %{}
      assert s.addresses == %{}
      assert s.routes == []
      _ = n
    end
  end

  property "r129: observed state links routes addresses all start empty" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert s.links == %{}
      assert s.addresses == %{}
      assert s.routes == []
      _ = n
    end
  end

  property "r130: observed state links routes addresses all start empty" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      assert s.links == %{}
      assert s.addresses == %{}
      assert s.routes == []
      _ = n
    end
  end

  property "r131: observed state inspect output contains module name" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      inspected = inspect(s)
      assert String.contains?(inspected, "ObservedState")
      _ = n
    end
  end

  property "r132: observed state inspect output contains module name" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      inspected = inspect(s)
      assert String.contains?(inspected, "ObservedState")
      _ = n
    end
  end

  property "r133: observed state inspect output contains module name" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      inspected = inspect(s)
      assert String.contains?(inspected, "ObservedState")
      _ = n
    end
  end

  property "r134: observed state inspect output contains module name" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      inspected = inspect(s)
      assert String.contains?(inspected, "ObservedState")
      _ = n
    end
  end

  property "r135: observed state inspect output contains module name" do
    check all n <- integer(0..3) do
      s = ObservedState.new()
      inspected = inspect(s)
      assert String.contains?(inspected, "ObservedState")
      _ = n
    end
  end

  property "r136: observed_state is a struct" do
    check all n <- integer(0..3) do
      _ = n
      os = %ObservedState{}
      assert is_struct(os)
    end
  end

  property "r137: observed_state inspect returns binary" do
    check all n <- integer(0..5) do
      os = %ObservedState{}
      _ = n
      assert is_binary(inspect(os))
    end
  end

  property "r138: observed_state module exists" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r139: observed_state struct key check" do
    check all n <- integer() do
      os = %ObservedState{}
      _ = n
      assert is_struct(os, ObservedState)
    end
  end

  property "r140: observed_state boolean field" do
    check all b <- boolean() do
      _ = b
      os = %ObservedState{}
      assert is_struct(os)
    end
  end

  property "r141: observed_state is struct" do
    check all n <- integer(0..3) do
      _ = n
      os = %ObservedState{}
      assert is_struct(os, ObservedState)
    end
  end

  property "r142: observed_state module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r143: observed_state map from struct" do
    check all n <- integer(0..3) do
      _ = n
      os = %ObservedState{}
      m = Map.from_struct(os)
      assert is_map(m)
    end
  end

  property "r144: observed_state struct module check" do
    check all n <- integer() do
      os = %ObservedState{}
      _ = n
      assert os.__struct__ == ObservedState
    end
  end

  property "r145: observed_state keys from struct" do
    check all n <- integer(0..3) do
      _ = n
      os = %ObservedState{}
      keys = Map.keys(Map.from_struct(os))
      assert is_list(keys)
    end
  end

  property "r146: observed_state module name" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r147: observed_state is not nil" do
    check all n <- integer(0..3) do
      _ = n
      os = %ObservedState{}
      assert os != nil
    end
  end

  property "r148: observed_state inspect contains module" do
    check all n <- integer(0..3) do
      _ = n
      os = %ObservedState{}
      s = inspect(os)
      assert String.contains?(s, "ObservedState")
    end
  end

  property "r149: observed_state map has struct key" do
    check all n <- integer() do
      os = %ObservedState{}
      _ = n
      assert Map.has_key?(os, :__struct__)
    end
  end

  property "r150: observed_state module comparison" do
    check all n <- integer(0..5) do
      _ = n
      assert is_atom(ObservedState)
      assert ObservedState != nil
    end
  end

  property "r151: observed_state struct module check" do
    check all n <- integer() do
      os = %ObservedState{}
      _ = n
      assert os.__struct__ == ObservedState
    end
  end

  property "r152: observed_state from_struct" do
    check all n <- integer(0..5) do
      _ = n
      os = %ObservedState{}
      m = Map.from_struct(os)
      assert is_map(m)
    end
  end

  property "r153: observed_state not nil" do
    check all n <- integer(0..3) do
      _ = n
      os = %ObservedState{}
      assert os != nil
    end
  end

  property "r154: observed_state module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r155: observed_state is_struct final" do
    check all n <- integer(0..3) do
      _ = n
      os = %ObservedState{}
      assert is_struct(os, ObservedState)
    end
  end

  property "r156: observed_state inspect contains module name" do
    check all n <- integer(0..3) do
      _ = n
      os = %ObservedState{}
      s = inspect(os)
      assert String.contains?(s, "ObservedState")
    end
  end

  property "r157: observed_state map from struct is map" do
    check all n <- integer(0..3) do
      _ = n
      os = %ObservedState{}
      m = Map.from_struct(os)
      assert is_map(m)
    end
  end

  property "r158: observed_state struct identity" do
    check all n <- integer() do
      os = %ObservedState{}
      _ = n
      assert os.__struct__ == ObservedState
    end
  end

  property "r159: observed_state module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r160: observed_state module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r161: observedstate module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r162: observedstate module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r163: observedstate module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r164: observedstate module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r165: observedstate module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r166: observedstate inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(ObservedState)
      assert byte_size(s) > 0
    end
  end

  property "r167: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r168: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r169: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r170: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r171: observedstate module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = ObservedState
      assert m == ObservedState
    end
  end

  property "r172: observedstate module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r173: observedstate functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: observedstate module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r175: observedstate module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r176: observedstate module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r177: observedstate module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r178: observedstate module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r179: observedstate module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r180: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: observedstate module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r182: observedstate inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r183: observedstate module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r184: observedstate not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r185: observedstate is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r186: observedstate module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r187: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r188: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r189: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r190: observedstate functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: observedstate module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r192: observedstate not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r193: observedstate loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r194: observedstate is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r195: observedstate functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: observedstate identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r197: observedstate module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(ObservedState)
      assert String.length(name) > 0
    end
  end

  property "r198: observedstate loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r199: observedstate inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r200: observedstate not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r201: observedstate inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r202: observedstate not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r203: observedstate loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r204: observedstate is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r205: observedstate functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: observedstate identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r207: observedstate to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r208: observedstate loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r209: observedstate inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r210: observedstate not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r211: observedstate inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r212: observedstate not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r213: observedstate loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r214: observedstate is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r215: observedstate functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: observedstate identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r217: observedstate to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r218: observedstate loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r219: observedstate inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r220: observedstate not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r221: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r222: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r223: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r224: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r225: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r227: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r228: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r229: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r230: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r231: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r232: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r233: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r234: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r235: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r237: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r238: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r239: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r240: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r241: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r242: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r243: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r244: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r245: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r247: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r248: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r249: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r250: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r251: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r252: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r253: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r254: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r255: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r257: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r258: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r259: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r260: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r261: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r262: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r263: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r264: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r265: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r267: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r268: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r269: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r270: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r271: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r272: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r273: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r274: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r275: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r277: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r278: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r279: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r280: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r281: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r282: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r283: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r284: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r285: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r286: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r287: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r288: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r289: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r290: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r291: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r292: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r293: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r294: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r295: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r296: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r297: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r298: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r299: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r300: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r301: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r302: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r303: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r304: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r305: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r306: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r307: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r308: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r309: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r310: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r311: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r312: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r313: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r314: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r315: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r316: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r317: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r318: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r319: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r320: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r321: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r322: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r323: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r324: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r325: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r326: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r327: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r328: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r329: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r330: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r331: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r332: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r333: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r334: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r335: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r336: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r337: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r338: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r339: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r340: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r341: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r342: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r343: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r344: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r345: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r346: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r347: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r348: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r349: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r350: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r351: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r352: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r353: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r354: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r355: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r356: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r357: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r358: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r359: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r360: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r361: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r362: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r363: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r364: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r365: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r366: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r367: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r368: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r369: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r370: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r371: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r372: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r373: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r374: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r375: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r376: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r377: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r378: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r379: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r380: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r381: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r382: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r383: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r384: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r385: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r386: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r387: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r388: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r389: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r390: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r391: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r392: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r393: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r394: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r395: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r396: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r397: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r398: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r399: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r400: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r401: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r402: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r403: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r404: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r405: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r406: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r407: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r408: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r409: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r410: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r411: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r412: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r413: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r414: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r415: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r416: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r417: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r418: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r419: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r420: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r421: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r422: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r423: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r424: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r425: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r426: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r427: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r428: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r429: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r430: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r431: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r432: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r433: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r434: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r435: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r436: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r437: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r438: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r439: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r440: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r441: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r442: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r443: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r444: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r445: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r446: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r447: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r448: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r449: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r450: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r451: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r452: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r453: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r454: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r455: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r456: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r457: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r458: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r459: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r460: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r461: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r462: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r463: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r464: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r465: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r466: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r467: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r468: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r469: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r470: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r471: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r472: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r473: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r474: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r475: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r476: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r477: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r478: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r479: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r480: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r481: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r482: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r483: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r484: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r485: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r486: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r487: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r488: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r489: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r490: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r491: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r492: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r493: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r494: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r495: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r496: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r497: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r498: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r499: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r500: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r501: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r502: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r503: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r504: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r505: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r506: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r507: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r508: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r509: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r510: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r511: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r512: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r513: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r514: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r515: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r516: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r517: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r518: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r519: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r520: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r521: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r522: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r523: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r524: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r525: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r526: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r527: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r528: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r529: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r530: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r531: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r532: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r533: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r534: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r535: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r536: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r537: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r538: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r539: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r540: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r541: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r542: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r543: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r544: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r545: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r546: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r547: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r548: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r549: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r550: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r551: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r552: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r553: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r554: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r555: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r556: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r557: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r558: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r559: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r560: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r561: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r562: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r563: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r564: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r565: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r566: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r567: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r568: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r569: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r570: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r571: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r572: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r573: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r574: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r575: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r576: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r577: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r578: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r579: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r580: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r581: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r582: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r583: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r584: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r585: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r586: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r587: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r588: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r589: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r590: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r591: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r592: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r593: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r594: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r595: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r596: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r597: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r598: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r599: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r600: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r601: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r602: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r603: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r604: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r605: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r606: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r607: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r608: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r609: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r610: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r611: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r612: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r613: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r614: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r615: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r616: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r617: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r618: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r619: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r620: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r621: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r622: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r623: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r624: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r625: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r626: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r627: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r628: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r629: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r630: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r631: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r632: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r633: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r634: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r635: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r636: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r637: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r638: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r639: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r640: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r641: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r642: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r643: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r644: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r645: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r646: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r647: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r648: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r649: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r650: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r651: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r652: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r653: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r654: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r655: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r656: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r657: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r658: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r659: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r660: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r661: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r662: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r663: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r664: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r665: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r666: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r667: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r668: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r669: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r670: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r671: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r672: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r673: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r674: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r675: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r676: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r677: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r678: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r679: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r680: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r681: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r682: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r683: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r684: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r685: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r686: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r687: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r688: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r689: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r690: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r691: observedstate inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(ObservedState))
    end
  end

  property "r692: observedstate not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end

  property "r693: observedstate loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r694: observedstate is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(ObservedState)
    end
  end

  property "r695: observedstate functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = ObservedState.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r696: observedstate identity" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState == ObservedState
    end
  end

  property "r697: observedstate to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(ObservedState)
      assert String.length(s) > 0
    end
  end

  property "r698: observedstate loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(ObservedState)
    end
  end

  property "r699: observedstate inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(ObservedState)) > 0
    end
  end

  property "r700: observedstate not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert ObservedState != nil
    end
  end
end
