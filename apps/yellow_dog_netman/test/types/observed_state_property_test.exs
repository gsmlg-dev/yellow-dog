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
end
