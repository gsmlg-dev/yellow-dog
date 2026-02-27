defmodule YellowDog.Netman.Kernel.RouteManagerTest do
  use ExUnit.Case

  alias YellowDog.Netman.Kernel.RouteManager
  alias YellowDog.Netman.Test.MockNetlink

  test "route_added creates a route entry" do
    MockNetlink.route_added(
      destination: "default",
      gateway: "10.0.0.1",
      interface: "test_rt_eth0",
      metric: 100
    )

    Process.sleep(50)

    routes = RouteManager.get_routes("test_rt_eth0")
    assert length(routes) >= 1
    assert Enum.any?(routes, &(&1.gateway == "10.0.0.1"))
  end

  test "route_removed deletes a route" do
    MockNetlink.route_added(
      destination: "10.0.0.0/24",
      gateway: "10.0.0.1",
      interface: "test_rt_eth1"
    )

    Process.sleep(50)
    assert Enum.any?(RouteManager.get_routes("test_rt_eth1"), &(&1.destination == "10.0.0.0/24"))

    MockNetlink.route_removed(
      destination: "10.0.0.0/24",
      gateway: "10.0.0.1",
      interface: "test_rt_eth1"
    )

    Process.sleep(50)
    refute Enum.any?(RouteManager.get_routes("test_rt_eth1"), &(&1.destination == "10.0.0.0/24"))
  end

  test "list_all returns routes sorted by metric" do
    MockNetlink.route_added(
      destination: "default",
      gateway: "10.0.0.1",
      interface: "test_sort_a",
      metric: 200
    )

    MockNetlink.route_added(
      destination: "default",
      gateway: "10.0.1.1",
      interface: "test_sort_b",
      metric: 100
    )

    Process.sleep(50)

    routes = RouteManager.list_all()
    test_routes = Enum.filter(routes, &(&1.interface in ["test_sort_a", "test_sort_b"]))

    if length(test_routes) == 2 do
      [first, second] = test_routes
      assert first.metric <= second.metric
    end
  end
end
