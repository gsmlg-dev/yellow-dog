defmodule YellowDog.Netman.Kernel.RouteManagerPropertyTest do
  use ExUnit.Case
  use ExUnitProperties

  alias YellowDog.Netman.Kernel.RouteManager
  alias YellowDog.Netman.Test.MockNetlink

  # Generators

  defp iface_gen do
    StreamData.string(:alphanumeric, min_length: 3, max_length: 12)
    |> StreamData.map(&("prop_rm_" <> &1))
    |> StreamData.map(&String.slice(&1, 0, 15))
  end

  defp gateway_gen do
    gen all(
          a <- StreamData.integer(10..10),
          b <- StreamData.integer(0..255),
          c <- StreamData.integer(0..255),
          d <- StreamData.integer(1..254)
        ) do
      "#{a}.#{b}.#{c}.#{d}"
    end
  end

  defp destination_gen do
    StreamData.one_of([
      StreamData.constant("default"),
      gen all(
            a <- StreamData.integer(10..10),
            b <- StreamData.integer(0..255),
            c <- StreamData.integer(0..255),
            prefix <- StreamData.integer(8..30)
          ) do
        "#{a}.#{b}.#{c}.0/#{prefix}"
      end
    ])
  end

  defp metric_gen do
    StreamData.integer(0..9999)
  end

  defp protocol_gen do
    StreamData.member_of(["boot", "static", "dhcp", "kernel", "ospf", "bgp", "unknown"])
  end

  defp scope_gen do
    StreamData.member_of(["universe", "link", "host", "site", "random_scope"])
  end

  defp family_gen do
    StreamData.member_of(["inet", "inet6", "unknown"])
  end

  # Properties

  property "add then get_routes returns the route" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen(),
            metric <- metric_gen()
          ) do
      MockNetlink.route_added(
        destination: dest,
        gateway: gw,
        interface: iface,
        metric: metric
      )

      Process.sleep(50)

      routes = RouteManager.get_routes(iface)
      assert Enum.any?(routes, &(&1.destination == dest and &1.gateway == gw))
    end
  end

  property "add then remove then get_routes does not contain the route" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen()
          ) do
      MockNetlink.route_added(destination: dest, gateway: gw, interface: iface)
      Process.sleep(30)
      MockNetlink.route_removed(destination: dest, gateway: gw, interface: iface)
      Process.sleep(50)

      routes = RouteManager.get_routes(iface)
      refute Enum.any?(routes, &(&1.destination == dest and &1.gateway == gw))
    end
  end

  property "list_all is always sorted by metric" do
    check all(
            iface <- iface_gen(),
            metrics <- StreamData.list_of(metric_gen(), min_length: 2, max_length: 5)
          ) do
      for {metric, i} <- Enum.with_index(metrics) do
        MockNetlink.route_added(
          destination: "10.#{rem(i, 256)}.#{div(i, 256)}.0/24",
          gateway: "10.0.0.#{rem(i + 1, 255)}",
          interface: iface,
          metric: metric
        )
      end

      Process.sleep(50)

      routes = RouteManager.list_all()
      iface_routes = Enum.filter(routes, &(&1.interface == iface))
      metrics_list = Enum.map(iface_routes, & &1.metric)
      assert metrics_list == Enum.sort(metrics_list)
    end
  end

  property "protocol is always one of known atoms" do
    check all(
            iface <- iface_gen(),
            protocol <- protocol_gen()
          ) do
      MockNetlink.route_added(
        destination: "10.100.0.0/24",
        gateway: "10.100.0.1",
        interface: iface,
        protocol: protocol
      )

      Process.sleep(50)

      routes = RouteManager.get_routes(iface)
      route = Enum.find(routes, &(&1.destination == "10.100.0.0/24"))
      assert route != nil
      assert route.protocol in [:boot, :static, :dhcp, :kernel, :unspec]
    end
  end

  property "scope is always one of known atoms" do
    check all(
            iface <- iface_gen(),
            scope <- scope_gen()
          ) do
      MockNetlink.route_added(
        destination: "10.101.0.0/24",
        gateway: nil,
        interface: iface,
        scope: scope
      )

      Process.sleep(50)

      routes = RouteManager.get_routes(iface)
      route = Enum.find(routes, &(&1.destination == "10.101.0.0/24"))
      assert route != nil
      assert route.scope in [:universe, :link, :host]
    end
  end

  property "get_routes never crashes for any interface name" do
    check all(iface <- StreamData.string(:printable, min_length: 0, max_length: 64)) do
      result = RouteManager.get_routes(iface)
      assert is_list(result)
    end
  end

  property "family is always one of known atoms" do
    check all(
            iface <- iface_gen(),
            family <- family_gen()
          ) do
      MockNetlink.route_added(
        destination: "10.102.0.0/24",
        gateway: "10.102.0.1",
        interface: iface,
        family: family
      )

      Process.sleep(50)

      routes = RouteManager.get_routes(iface)
      route = Enum.find(routes, &(&1.destination == "10.102.0.0/24"))
      assert route != nil
      assert route.family in [:inet, :inet6]
    end
  end

  property "same route key (dest+gw+iface) is deduplicated to last write" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen(),
            metric1 <- metric_gen(),
            metric2 <- metric_gen()
          ) do
      MockNetlink.route_added(destination: dest, gateway: gw, interface: iface, metric: metric1)
      Process.sleep(20)
      MockNetlink.route_added(destination: dest, gateway: gw, interface: iface, metric: metric2)
      Process.sleep(50)

      routes = RouteManager.get_routes(iface)
      matching = Enum.filter(routes, &(&1.destination == dest and &1.gateway == gw))
      assert length(matching) == 1
      assert hd(matching).metric == metric2
    end
  end

  property "list_all includes routes from multiple distinct interfaces" do
    check all(
            iface1 <- iface_gen(),
            iface2 <- iface_gen(),
            iface1 != iface2,
            gw1 <- gateway_gen(),
            gw2 <- gateway_gen()
          ) do
      dest1 = "10.201.1.0/24"
      dest2 = "10.202.2.0/24"

      MockNetlink.route_added(destination: dest1, gateway: gw1, interface: iface1, metric: 100)
      MockNetlink.route_added(destination: dest2, gateway: gw2, interface: iface2, metric: 200)
      Process.sleep(50)

      all_routes = RouteManager.list_all()

      assert Enum.any?(all_routes, &(&1.interface == iface1 and &1.destination == dest1)),
             "list_all missing route for #{iface1}"

      assert Enum.any?(all_routes, &(&1.interface == iface2 and &1.destination == dest2)),
             "list_all missing route for #{iface2}"
    end
  end

  property "add_route always returns :ok or {:error, _} for any route map" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen(),
            metric <- metric_gen()
          ) do
      result =
        RouteManager.add_route(%{
          destination: dest,
          gateway: gw,
          interface: iface,
          metric: metric
        })

      assert result == :ok or match?({:error, _}, result),
             "Unexpected add_route result: #{inspect(result)}"
    end
  end

  property "remove_route always returns :ok or {:error, _} for any route map" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen()
          ) do
      result = RouteManager.remove_route(%{destination: dest, gateway: gw, interface: iface})

      assert result == :ok or match?({:error, _}, result),
             "Unexpected remove_route result: #{inspect(result)}"
    end
  end

  property "flush always returns a tuple of two non-negative integers" do
    check all(iface <- iface_gen()) do
      result = RouteManager.flush(iface)
      assert is_tuple(result) and tuple_size(result) == 2
      {removed, failed} = result
      assert is_integer(removed) and removed >= 0
      assert is_integer(failed) and failed >= 0
    end
  end

  property "default_route always returns nil or a map" do
    check all(_ <- StreamData.constant(:ok)) do
      result = RouteManager.default_route()
      assert is_nil(result) or is_map(result)
    end
  end

  property "all routes in list_all always have required fields" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen()
          ) do
      MockNetlink.route_added(destination: dest, gateway: gw, interface: iface)
      Process.sleep(50)

      all_routes = RouteManager.list_all()

      for r <- all_routes do
        for field <- [:destination, :gateway, :interface, :metric, :protocol, :scope, :family] do
          assert Map.has_key?(r, field),
                 "Route entry missing required field :#{field} in #{inspect(r)}"
        end
      end
    end
  end

  property "get_routes for a fresh interface with no events returns empty list" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "rm_fresh_#{seed}"
      result = RouteManager.get_routes(fresh_iface)

      assert result == [],
             "Expected empty list for fresh interface #{fresh_iface}, got: #{inspect(result)}"
    end
  end

  property "route added to iface1 is not visible in get_routes(iface2)" do
    check all(
            iface1 <- iface_gen(),
            iface2 <- iface_gen(),
            iface1 != iface2,
            dest <- destination_gen(),
            gw <- gateway_gen()
          ) do
      MockNetlink.route_added(destination: dest, gateway: gw, interface: iface1)
      Process.sleep(50)

      routes2 = RouteManager.get_routes(iface2)

      refute Enum.any?(routes2, &(&1.interface == iface1)),
             "Route for #{iface1} should not appear in #{iface2}'s route list"
    end
  end

  property "list_all always returns a list of maps" do
    check all(_ <- StreamData.constant(:ok)) do
      routes = RouteManager.list_all()
      assert is_list(routes)

      for r <- routes do
        assert is_map(r),
               "Expected map in list_all, got: #{inspect(r)}"
      end
    end
  end

  property "get_routes result is always a subset of list_all for that interface" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen()
          ) do
      MockNetlink.route_added(destination: dest, gateway: gw, interface: iface)
      Process.sleep(50)

      per_iface = RouteManager.get_routes(iface)
      all_routes = RouteManager.list_all()

      for r <- per_iface do
        assert Enum.any?(all_routes, &(&1 == r)),
               "Route #{inspect(r)} in get_routes but not in list_all"
      end
    end
  end

  property "flush on a fresh interface always returns {0, 0}" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "rm_flush_#{seed}"
      result = RouteManager.flush(fresh_iface)

      assert result == {0, 0},
             "Expected {0, 0} for fresh interface #{fresh_iface}, got: #{inspect(result)}"
    end
  end

  property "route_removed event removes route from get_routes" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen(),
            metric <- metric_gen()
          ) do
      MockNetlink.route_added(destination: dest, gateway: gw, interface: iface, metric: metric)
      Process.sleep(50)

      assert Enum.any?(RouteManager.get_routes(iface), &(&1.destination == dest and &1.gateway == gw))

      MockNetlink.route_removed(destination: dest, gateway: gw, interface: iface)
      Process.sleep(50)

      refute Enum.any?(RouteManager.get_routes(iface), &(&1.destination == dest and &1.gateway == gw)),
             "Route #{dest} via #{gw} should be absent after route_removed"
    end
  end

  property "all routes in list_all always have non-negative integer metric" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen(),
            metric <- metric_gen()
          ) do
      MockNetlink.route_added(destination: dest, gateway: gw, interface: iface, metric: metric)
      Process.sleep(50)

      all_routes = RouteManager.list_all()

      for r <- all_routes do
        assert is_integer(r.metric) and r.metric >= 0,
               "Route has invalid metric: #{inspect(r.metric)}"
      end
    end
  end

  property "all routes in get_routes always have :interface matching the queried interface" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen(),
            metric <- metric_gen()
          ) do
      MockNetlink.route_added(destination: dest, gateway: gw, interface: iface, metric: metric)
      Process.sleep(50)

      routes = RouteManager.get_routes(iface)

      for r <- routes do
        assert r.interface == iface,
               "Expected route.interface == #{iface}, got: #{inspect(r.interface)}"
      end
    end
  end

  property "get_routes for a fresh unique interface always returns empty list" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "rm_fresh_#{seed}"
      result = RouteManager.get_routes(fresh_iface)
      assert result == [],
             "Expected [] for fresh interface #{fresh_iface}, got: #{inspect(result)}"
    end
  end

  property "all routes in list_all always have a binary interface field" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen(),
            metric <- metric_gen()
          ) do
      MockNetlink.route_added(destination: dest, gateway: gw, interface: iface, metric: metric)
      Process.sleep(50)

      routes = RouteManager.list_all()

      for r <- routes do
        assert is_binary(r.interface),
               "Expected binary interface field, got: #{inspect(r.interface)}"
      end
    end
  end
end
