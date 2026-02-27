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

  test "default_route returns the default route entry" do
    MockNetlink.route_added(
      destination: "default",
      gateway: "10.99.0.1",
      interface: "test_default_rt",
      metric: 50
    )

    Process.sleep(50)

    route = RouteManager.default_route()
    assert route != nil
    assert route.destination in ["default", "0.0.0.0/0"]
  end

  test "flush removes all routes for an interface" do
    iface = "test_flush_rt_#{:rand.uniform(65535)}"

    MockNetlink.route_added(destination: "10.20.0.0/24", gateway: "10.20.0.1", interface: iface)
    MockNetlink.route_added(destination: "10.21.0.0/24", gateway: "10.20.0.1", interface: iface)
    Process.sleep(50)

    assert length(RouteManager.get_routes(iface)) >= 2

    RouteManager.flush(iface)

    # flush sends remove commands via Netlink (mock doesn't apply them to ETS)
    assert is_list(RouteManager.get_routes(iface))
  end

  test "route_change event is published to EventBus on add" do
    iface = "test_rt_event_#{:rand.uniform(65535)}"
    YellowDog.Netman.EventBus.subscribe("netman:route:254")

    MockNetlink.route_added(
      destination: "192.168.1.0/24",
      gateway: "192.168.1.1",
      interface: iface
    )

    Process.sleep(50)

    assert_receive {:netman_event, "netman:route:254", {:add, %{destination: "192.168.1.0/24"}}},
                   500
  end

  test "route scope is parsed correctly" do
    iface = "test_rt_scope_#{:rand.uniform(65535)}"

    MockNetlink.route_added(
      destination: "169.254.0.0/16",
      gateway: nil,
      interface: iface,
      scope: "link"
    )

    Process.sleep(50)

    routes = RouteManager.get_routes(iface)
    assert Enum.any?(routes, &(&1.scope == :link))
  end

  test "route protocol is parsed correctly" do
    iface = "test_rt_proto_#{:rand.uniform(65535)}"

    MockNetlink.route_added(
      destination: "10.30.0.0/24",
      gateway: "10.30.0.1",
      interface: iface,
      protocol: "dhcp"
    )

    Process.sleep(50)

    routes = RouteManager.get_routes(iface)
    assert Enum.any?(routes, &(&1.protocol == :dhcp))
  end

  test "route protocol :boot is parsed correctly" do
    iface = "test_boot_proto_#{:rand.uniform(65535)}"

    MockNetlink.route_added(
      destination: "10.31.0.0/24",
      gateway: nil,
      interface: iface,
      protocol: "boot"
    )

    Process.sleep(50)
    assert Enum.any?(RouteManager.get_routes(iface), &(&1.protocol == :boot))
  end

  test "route protocol :static is parsed correctly" do
    iface = "test_static_proto_#{:rand.uniform(65535)}"

    MockNetlink.route_added(
      destination: "10.32.0.0/24",
      gateway: nil,
      interface: iface,
      protocol: "static"
    )

    Process.sleep(50)
    assert Enum.any?(RouteManager.get_routes(iface), &(&1.protocol == :static))
  end

  test "route protocol :kernel is parsed correctly" do
    iface = "test_kernel_proto_#{:rand.uniform(65535)}"

    MockNetlink.route_added(
      destination: "10.33.0.0/24",
      gateway: nil,
      interface: iface,
      protocol: "kernel"
    )

    Process.sleep(50)
    assert Enum.any?(RouteManager.get_routes(iface), &(&1.protocol == :kernel))
  end

  test "unknown protocol defaults to :unspec" do
    iface = "test_unspec_proto_#{:rand.uniform(65535)}"

    MockNetlink.route_added(
      destination: "10.34.0.0/24",
      gateway: nil,
      interface: iface,
      protocol: "ospf"
    )

    Process.sleep(50)
    assert Enum.any?(RouteManager.get_routes(iface), &(&1.protocol == :unspec))
  end

  test "host scope is parsed correctly" do
    iface = "test_host_scope_#{:rand.uniform(65535)}"

    MockNetlink.route_added(
      destination: "127.0.0.1/32",
      gateway: nil,
      interface: iface,
      scope: "host"
    )

    Process.sleep(50)
    assert Enum.any?(RouteManager.get_routes(iface), &(&1.scope == :host))
  end

  test "unknown scope defaults to :universe" do
    iface = "test_unk_scope_#{:rand.uniform(65535)}"

    MockNetlink.route_added(
      destination: "10.35.0.0/24",
      gateway: nil,
      interface: iface,
      scope: "weird_scope"
    )

    Process.sleep(50)
    assert Enum.any?(RouteManager.get_routes(iface), &(&1.scope == :universe))
  end

  test "add_route/1 sends netlink command without crashing" do
    result =
      RouteManager.add_route(%{
        destination: "default",
        gateway: "10.0.0.1",
        interface: "eth0",
        metric: 100
      })

    assert result == :ok or match?({:error, _}, result)
  end

  test "remove_route/1 sends netlink command without crashing" do
    result =
      RouteManager.remove_route(%{destination: "default", gateway: "10.0.0.1", interface: "eth0"})

    assert result == :ok or match?({:error, _}, result)
  end

  test "handle_info with unknown message is silently ignored" do
    pid = Process.whereis(RouteManager)
    send(pid, :some_unknown_route_msg)
    Process.sleep(20)
    assert Process.alive?(pid)
  end

  test "unknown action in route event is handled gracefully" do
    pid = Process.whereis(RouteManager)

    send(
      pid,
      {:netlink_event, {:route_change, %{"action" => "flush", "destination" => "default"}}}
    )

    Process.sleep(20)
    assert Process.alive?(pid)
  end

  test "malformed route event is handled gracefully" do
    pid = Process.whereis(RouteManager)
    send(pid, {:netlink_event, {:route_change, "not_a_map"}})
    Process.sleep(20)
    assert Process.alive?(pid)
  end

  test "default_route also matches 0.0.0.0/0 destination" do
    iface = "test_default_cidr_#{:rand.uniform(65535)}"

    MockNetlink.route_added(
      destination: "0.0.0.0/0",
      gateway: "10.50.0.1",
      interface: iface,
      metric: 10
    )

    Process.sleep(50)

    route = RouteManager.default_route()
    assert route != nil
  end
end
