defmodule YellowDog.Netman.Types.ObservedStateTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netman.Types.ObservedState

  test "new/0 creates empty state" do
    state = ObservedState.new()
    assert state.links == %{}
    assert state.addresses == %{}
    assert state.routes == []
  end

  test "put_link/2 adds a link" do
    state = ObservedState.new()

    link = %{
      interface: "eth0",
      index: 1,
      state: :up,
      carrier: true,
      mtu: 1500,
      mac: "aa:bb:cc:dd:ee:ff",
      kind: nil
    }

    state = ObservedState.put_link(state, link)
    assert Map.has_key?(state.links, "eth0")
    assert state.links["eth0"].carrier == true
  end

  test "remove_link/2 removes a link" do
    state =
      ObservedState.new()
      |> ObservedState.put_link(%{
        interface: "eth0",
        index: 1,
        state: :up,
        carrier: true,
        mtu: 1500,
        mac: nil,
        kind: nil
      })
      |> ObservedState.remove_link("eth0")

    refute Map.has_key?(state.links, "eth0")
  end

  test "add_address/2 adds an address" do
    state = ObservedState.new()

    addr = %{
      interface: "eth0",
      address: "10.0.0.1",
      prefix_len: 24,
      family: :inet,
      scope: :global
    }

    state = ObservedState.add_address(state, addr)
    assert length(state.addresses["eth0"]) == 1
  end

  test "remove_address/3 removes an address" do
    addr = %{
      interface: "eth0",
      address: "10.0.0.1",
      prefix_len: 24,
      family: :inet,
      scope: :global
    }

    state =
      ObservedState.new()
      |> ObservedState.add_address(addr)
      |> ObservedState.remove_address("eth0", "10.0.0.1")

    assert state.addresses["eth0"] == []
  end

  test "remove_address/4 with prefix_len only removes matching prefix" do
    addr24 = %{
      interface: "eth0",
      address: "10.0.0.1",
      prefix_len: 24,
      family: :inet,
      scope: :global
    }

    addr32 = %{
      interface: "eth0",
      address: "10.0.0.1",
      prefix_len: 32,
      family: :inet,
      scope: :global
    }

    state =
      ObservedState.new()
      |> ObservedState.add_address(addr24)
      |> ObservedState.add_address(addr32)
      |> ObservedState.remove_address("eth0", "10.0.0.1", 32)

    assert length(state.addresses["eth0"]) == 1
    assert hd(state.addresses["eth0"]).prefix_len == 24
  end

  test "add_route/2 adds a route" do
    route = %{
      destination: "default",
      gateway: "10.0.0.1",
      interface: "eth0",
      metric: 100,
      table: 254,
      protocol: :dhcp,
      scope: :universe
    }

    state = ObservedState.new() |> ObservedState.add_route(route)
    assert length(state.routes) == 1
  end

  test "remove_route/3 removes a route" do
    route = %{
      destination: "default",
      gateway: "10.0.0.1",
      interface: "eth0",
      metric: 100,
      table: 254,
      protocol: :dhcp,
      scope: :universe
    }

    state =
      ObservedState.new()
      |> ObservedState.add_route(route)
      |> ObservedState.remove_route("default", "10.0.0.1")

    assert state.routes == []
  end
end
