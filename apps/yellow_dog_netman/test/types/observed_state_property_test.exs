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
end
