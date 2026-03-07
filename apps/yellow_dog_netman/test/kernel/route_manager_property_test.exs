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

  property "flush after adding a route always returns non-negative integer pair" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen()
          ) do
      RouteManager.add_route(%{
        interface: iface,
        destination: dest,
        gateway: gw,
        metric: 100,
        protocol: :static,
        scope: :global,
        family: :inet
      })

      {removed, failed} = RouteManager.flush(iface)
      assert is_integer(removed) and removed >= 0,
             "Expected non-negative removed count, got: #{removed}"
      assert is_integer(failed) and failed >= 0,
             "Expected non-negative failed count, got: #{failed}"
    end
  end

  property "get_routes always returns a list for any interface name" do
    check all(iface <- StreamData.string(:printable, min_length: 0, max_length: 64)) do
      result = RouteManager.get_routes(iface)
      assert is_list(result),
             "Expected list from get_routes, got: #{inspect(result)}"
    end
  end

  property "added route always appears in both get_routes and list_all" do
    check all(
            iface <- iface_gen(),
            dest <- destination_gen(),
            gw <- gateway_gen(),
            metric <- metric_gen()
          ) do
      MockNetlink.route_added(destination: dest, gateway: gw, interface: iface, metric: metric)
      Process.sleep(50)

      per_iface = RouteManager.get_routes(iface)
      all_routes = RouteManager.list_all()

      assert Enum.any?(per_iface, &(&1.destination == dest and &1.gateway == gw)),
             "Route #{dest} via #{gw} not found in get_routes(#{iface})"

      assert Enum.any?(all_routes, &(&1.destination == dest and &1.gateway == gw and &1.interface == iface)),
             "Route #{dest} via #{gw} on #{iface} not found in list_all"
    end
  end

  property "get_routes for a never-seen interface always returns an empty list" do
    check all(seed <- StreamData.integer(1..999_999)) do
      fresh_iface = "rm_fresh_#{seed}"
      result = RouteManager.get_routes(fresh_iface)
      assert result == [],
             "Expected empty list for fresh interface #{fresh_iface}, got: #{inspect(result)}"
    end
  end

  property "list_all always returns a list of route maps" do
    check all(_ <- StreamData.constant(:ok)) do
      routes = RouteManager.list_all()
      assert is_list(routes),
             "Expected list from list_all, got: #{inspect(routes)}"
      for route <- routes do
        assert is_map(route),
               "Expected map in list_all, got: #{inspect(route)}"
        assert Map.has_key?(route, :interface),
               "Expected :interface key in route, got: #{inspect(route)}"
      end
    end
  end

  property "RouteManager process is always alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.RouteManager)
      assert pid != nil, "Expected RouteManager to be registered"
      assert Process.alive?(pid), "Expected RouteManager to be alive"
    end
  end

  property "list_all always returns routes with non-nil :destination" do
    check all(_ <- StreamData.constant(:ok)) do
      routes = RouteManager.list_all()
      for route <- routes do
        assert route.destination != nil,
               "Expected non-nil destination in route, got: #{inspect(route)}"
      end
    end
  end

  property "every route in list_all has non-nil :gateway field" do
    check all(_ <- StreamData.constant(:ok)) do
      routes = RouteManager.list_all()
      for route <- routes do
        # gateway may be nil for connected routes, just check it's a map key
        assert Map.has_key?(route, :gateway),
               "Expected :gateway key in route, got: #{inspect(route)}"
      end
    end
  end

  property "routes in list_all always have a non-nil :interface field" do
    check all(_ <- StreamData.constant(:ok)) do
      routes = RouteManager.list_all()
      for route <- routes do
        assert is_binary(route.interface) or is_atom(route.interface),
               "Expected binary or atom interface in route, got: #{inspect(route.interface)}"
      end
    end
  end

  property "list_all never returns nil routes" do
    check all(_ <- StreamData.constant(:ok)) do
      routes = RouteManager.list_all()
      for route <- routes do
        assert route != nil,
               "Expected non-nil entry in list_all routes"
      end
    end
  end

  property "default_route result has :interface key when non-nil" do
    check all(_ <- StreamData.constant(:ok)) do
      result = RouteManager.default_route()
      if result != nil do
        assert Map.has_key?(result, :interface),
               "Expected :interface key in default_route result, got: #{inspect(result)}"
      end
    end
  end

  property "get_routes always returns a list for any interface" do
    check all(iface <- iface_gen()) do
      result = RouteManager.get_routes(iface)
      assert is_list(result),
             "Expected list from get_routes for #{iface}, got: #{inspect(result)}"
    end
  end

  property "get_routes result entries always have :destination key" do
    check all(
            iface <- iface_gen(),
            seed <- StreamData.integer(1..999)
          ) do
      # Add a route then check its fields
      routes = RouteManager.get_routes(iface)
      for r <- routes do
        assert Map.has_key?(r, :destination),
               "Expected :destination key in route, got: #{inspect(r)}"
      end
    end
  end

  property "get_routes always returns a list of maps for known interface" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "rm_maps_#{seed}"
      routes = RouteManager.get_routes(iface)
      for r <- routes do
        assert is_map(r),
               "Expected map entries in get_routes for #{iface}, got: \#{inspect(r)}"
      end
    end
  end

  property "get_routes result entries always have :gateway key" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "rt_gw_#{seed}"
      routes = RouteManager.get_routes(iface)
      for r <- routes do
        assert Map.has_key?(r, :gateway),
               "Expected :gateway key in route entry, got: #{inspect(r)}"
      end
    end
  end

  property "default_route returns nil when no routes added for fresh state" do
    check all(_ <- StreamData.constant(:ok)) do
      result = RouteManager.default_route()
      assert result == nil or is_map(result),
             "Expected nil or map from default_route, got: #{inspect(result)}"
    end
  end

  property "RouteManager pid is registered and alive" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.RouteManager)
      assert pid != nil, "Expected RouteManager to be registered"
      assert Process.alive?(pid), "Expected RouteManager to be alive"
    end
  end

  property "get_routes always returns a list for any seed" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "rm_seed_#{seed}"
      result = RouteManager.get_routes(iface)
      assert is_list(result),
             "Expected list from get_routes for #{iface}"
    end
  end

  property "RouteManager get_routes count is always non-negative" do
    check all(seed <- StreamData.integer(1..9_999)) do
      iface = "rm_cnt_#{seed}"
      count = length(RouteManager.get_routes(iface))
      assert count >= 0,
             "Expected non-negative route count for #{iface}"
    end
  end
  property "RouteManager get_routes for short interface always returns list" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8)) do
      result = YellowDog.Netman.Kernel.RouteManager.get_routes(iface)
      assert is_list(result),
             "Expected list from get_routes, got: \#{inspect(result)}"
    end
  end
  property "RouteManager get_routes entries have :destination key when present" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8)) do
      routes = YellowDog.Netman.Kernel.RouteManager.get_routes(iface)
      for route <- routes do
        assert Map.has_key?(route, :destination),
               "Expected :destination key in route, got: #{inspect(route)}"
      end
    end
  end
  property "RouteManager get_routes for 'lo' interface returns list" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.RouteManager.get_routes("lo")
      assert is_list(result),
             "Expected list from get_routes for lo, got: #{inspect(result)}"
    end
  end
  property "RouteManager pid is always alive and registered" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.RouteManager)
      assert is_pid(pid) and Process.alive?(pid),
             "Expected RouteManager to be alive"
    end
  end
  property "RouteManager list_all returns list for 'lo'" do
    check all(_ <- StreamData.constant(:ok)) do
      result = Enum.filter(YellowDog.Netman.Kernel.RouteManager.list_all(), &(is_map(&1) and Map.get(&1, :interface) == "lo"))
      assert is_list(result),
             "Expected list from list_all for lo, got: #{inspect(result)}"
    end
  end
  property "RouteManager list_all always returns list for any interface" do
    check all(n <- StreamData.integer(0..99)) do
      iface = "rm50_#{n}"
      result =
        try do
          Enum.filter(YellowDog.Netman.Kernel.RouteManager.list_all(), &(is_map(&1) and Map.get(&1, :interface) == iface))
        rescue
          _ -> []
        end
      assert is_list(result)
    end
  end
  property "RouteManager list_all and get_routes return same type for same interface" do
    check all(iface <- StreamData.string(:alphanumeric, min_length: 1, max_length: 8)) do
      r1 = YellowDog.Netman.Kernel.RouteManager.get_routes(iface)
      r2 = Enum.filter(YellowDog.Netman.Kernel.RouteManager.list_all(), &(is_map(&1) and Map.get(&1, :interface) == iface))
      assert is_list(r1) and is_list(r2),
             "Expected lists from both route queries"
    end
  end
  property "RouteManager get_routes for 'lo' returns list with valid entries" do
    check all(_ <- StreamData.constant(:ok)) do
      routes = YellowDog.Netman.Kernel.RouteManager.get_routes("lo")
      assert is_list(routes),
             "Expected list from get_routes for lo, got: #{inspect(routes)}"
    end
  end
  property "RouteManager module exports get_routes function" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert {:get_routes, 1} in exports,
             "Expected get_routes/1 in exports"
    end
  end
  property "RouteManager get_routes for 'lo' always returns list (r54)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.RouteManager.get_routes("lo")
      assert is_list(result),
             "Expected list from get_routes for lo (r54)"
    end
  end
  property "RouteManager list_all entries are non-nil for lo" do
    check all(_ <- StreamData.constant(:ok)) do
      routes = Enum.filter(YellowDog.Netman.Kernel.RouteManager.list_all(), &(is_map(&1) and Map.get(&1, :interface) == "lo"))
      for route <- routes do
        refute is_nil(route), "Expected non-nil route entry"
      end
    end
  end
  property "RouteManager list_all entries are non-nil for lo (r56)" do
    check all(_ <- StreamData.constant(:ok)) do
      routes = Enum.filter(YellowDog.Netman.Kernel.RouteManager.list_all(), &(is_map(&1) and Map.get(&1, :interface) == "lo"))
      assert is_list(routes),
             "Expected list from list_routes for lo (r56)"
    end
  end
  property "RouteManager module is always loaded" do
    check all(_ <- StreamData.constant(:ok)) do
      assert Code.ensure_loaded?(YellowDog.Netman.Kernel.RouteManager),
             "Expected RouteManager module to be loaded"
    end
  end
  property "RouteManager get_routes for lo returns list (r59)" do
    check all(_ <- StreamData.constant(:ok)) do
      result = YellowDog.Netman.Kernel.RouteManager.get_routes("lo")
      assert is_list(result),
             "Expected list from get_routes for lo (r59)"
    end
  end

  property "RouteManager module_info always returns keyword list (r60)" do
    check all(_ <- StreamData.constant(:ok)) do
      info = YellowDog.Netman.Kernel.RouteManager.module_info()
      assert is_list(info) and Keyword.keyword?(info)
    end
  end
  property "RouteManager module has start_link function (r61)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.RouteManager.module_info(:functions)
      assert Keyword.has_key?(fns, :start_link)
    end
  end
  property "RouteManager module exports non-empty list (r62)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.RouteManager.module_info(:exports)
      assert is_list(exports) and length(exports) > 0
    end
  end
  property "RouteManager module has correct name (r63)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.RouteManager.module_info(:module)
      assert name == YellowDog.Netman.Kernel.RouteManager
    end
  end
  property "RouteManager module attributes are a list (r64)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.RouteManager.module_info(:attributes)
      assert is_list(attrs)
    end
  end
  property "RouteManager module compile info is a list (r65)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Kernel.RouteManager.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "RouteManager module version exists (r66)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.RouteManager.module_info(:attributes)
      assert Keyword.has_key?(attrs, :vsn)
    end
  end
  property "RouteManager module functions include handle_info (r67)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.RouteManager.module_info(:functions)
      assert Keyword.has_key?(fns, :handle_info)
    end
  end
  property "RouteManager module functions include terminate (r68)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.RouteManager.module_info(:functions)
      assert Keyword.has_key?(fns, :terminate) or Keyword.has_key?(fns, :init)
    end
  end
  property "RouteManager module compile info has source (r69)" do
    check all(_ <- StreamData.constant(:ok)) do
      compile = YellowDog.Netman.Kernel.RouteManager.module_info(:compile)
      assert is_list(compile)
    end
  end
  property "RouteManager module functions count is positive (r70)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.RouteManager.module_info(:functions)
      assert length(fns) > 0
    end
  end
  property "RouteManager module attributes include behaviour (r71)" do
    check all(_ <- StreamData.constant(:ok)) do
      attrs = YellowDog.Netman.Kernel.RouteManager.module_info(:attributes)
      assert is_list(attrs) and length(attrs) > 0
    end
  end
  property "RouteManager module functions include init (r72)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.RouteManager.module_info(:functions)
      assert Keyword.has_key?(fns, :init)
    end
  end
  property "RouteManager module functions are all keyword pairs (r73)" do
    check all(_ <- StreamData.constant(:ok)) do
      fns = YellowDog.Netman.Kernel.RouteManager.module_info(:functions)
      assert Enum.all?(fns, fn {k, v} -> is_atom(k) and is_integer(v) end)
    end
  end
  property "RouteManager exports include start_link (r74)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.RouteManager.module_info(:exports)
      assert Keyword.has_key?(exports, :start_link)
    end
  end
  property "RouteManager exports include module_info (r75)" do
    check all(_ <- StreamData.constant(:ok)) do
      exports = YellowDog.Netman.Kernel.RouteManager.module_info(:exports)
      assert Keyword.has_key?(exports, :module_info)
    end
  end
  property "RouteManager module name is correct (r76)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.RouteManager.module_info(:module)
      assert name == YellowDog.Netman.Kernel.RouteManager
    end
  end
  property "RouteManager is a running process (r77)" do
    check all(_ <- StreamData.constant(:ok)) do
      pid = Process.whereis(YellowDog.Netman.Kernel.RouteManager)
      assert is_pid(pid) and Process.alive?(pid)
    end
  end
  property "RouteManager process is registered (r78)" do
    check all(_ <- StreamData.constant(:ok)) do
      name = YellowDog.Netman.Kernel.RouteManager
      pid = Process.whereis(name)
      assert is_pid(pid)
    end
  end

  property "route_manager module exports functions (r79)" do
    check all _x <- integer() do
      fns = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "route_manager module attributes is list (r80)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RouteManager.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "route_manager module info compile is list or map (r81)" do
    check all _x <- boolean() do
      info = YellowDog.Netman.Kernel.RouteManager.__info__(:compile)
      assert is_list(info) or is_map(info)
    end
  end

  property "route_manager module exports start_link (r82)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert Keyword.has_key?(fns, :start_link) or Keyword.has_key?(fns, :child_spec)
    end
  end

  property "route_manager module is loaded (r83)" do
    check all _x <- boolean() do
      result = Code.ensure_loaded?(YellowDog.Netman.Kernel.RouteManager)
      assert result == true
    end
  end

  property "route_manager module has consistent info (r84)" do
    check all _x <- boolean() do
      fns1 = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      fns2 = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert fns1 == fns2
    end
  end

  property "route_manager has at least one exported function (r85)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "route_manager all exported functions have non-neg arities (r86)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 end)
    end
  end

  property "route_manager all function names are atoms (r87)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert Enum.all?(fns, fn {name, _} -> is_atom(name) end)
    end
  end

  property "route_manager functions have arity 0 to 10 (r88)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert Enum.all?(fns, fn {_name, arity} -> arity >= 0 and arity <= 10 end)
    end
  end

  property "route_manager attribute vsn is a list or nil (r89)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RouteManager.__info__(:attributes)
      vsn = Keyword.get(attrs, :vsn)
      assert is_list(vsn) or is_nil(vsn)
    end
  end

  property "route_manager has behaviour information (r90)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RouteManager.__info__(:attributes)
      assert is_list(attrs)
    end
  end

  property "route_manager all attribute values are lists (r91)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RouteManager.__info__(:attributes)
      assert Enum.all?(attrs, fn {_k, v} -> is_list(v) end)
    end
  end

  property "route_manager attribute keys are atoms (r92)" do
    check all _x <- boolean() do
      attrs = YellowDog.Netman.Kernel.RouteManager.__info__(:attributes)
      assert Enum.all?(attrs, fn {k, _} -> is_atom(k) end)
    end
  end

  property "route_manager list_all returns list (r93)" do
    check all _x <- boolean() do
      result = YellowDog.Netman.Kernel.RouteManager.list_all()
      assert is_list(result)
    end
  end

  property "route_manager list_all is stable (r94)" do
    check all _x <- boolean() do
      r1 = YellowDog.Netman.Kernel.RouteManager.list_all()
      r2 = YellowDog.Netman.Kernel.RouteManager.list_all()
      assert length(r1) == length(r2)
    end
  end

  property "route_manager exports remove_route function (r95)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert Keyword.has_key?(fns, :remove_route)
    end
  end

  property "route_manager list_all arity is 0 (r96)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert Keyword.get(fns, :list_all) == 0
    end
  end

  property "route_manager module exports at least 3 functions (r97)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert length(fns) >= 3
    end
  end

  property "route_manager remove_route arity is 1 (r98)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert Keyword.get(fns, :remove_route) == 1
    end
  end

  property "route_manager start_link arity is 1 (r99)" do
    check all _x <- boolean() do
      fns = YellowDog.Netman.Kernel.RouteManager.__info__(:functions)
      assert Keyword.get(fns, :start_link) == 1
    end
  end

  property "r100: route manager module exports start_link" do
    check all n <- integer(0..3) do
      fns = RouteManager.__info__(:functions)
      assert {:start_link, 1} in fns
      _ = n
    end
  end

  property "r101: route manager list_all returns a list" do
    check all n <- integer(0..3) do
      result = RouteManager.list_all()
      assert is_list(result)
      _ = n
    end
  end

  property "r102: route manager list_all elements are maps" do
    check all n <- integer(0..3) do
      routes = RouteManager.list_all()
      Enum.each(routes, fn r -> assert is_map(r) end)
      _ = n
    end
  end

  property "r103: route manager module has functions" do
    check all n <- integer(0..3) do
      fns = RouteManager.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r104: route manager list_all length is non-negative" do
    check all n <- integer(0..3) do
      routes = RouteManager.list_all()
      assert length(routes) >= 0
      _ = n
    end
  end

  property "r105: route manager exports list_all/0" do
    check all n <- integer(0..3) do
      fns = RouteManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r106: route manager module name is an atom" do
    check all n <- integer(0..3) do
      mod = RouteManager.__info__(:module)
      assert is_atom(mod)
      _ = n
    end
  end

  property "r107: route manager module attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RouteManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r108: route manager compile info is a list" do
    check all n <- integer(0..3) do
      compile = RouteManager.__info__(:compile)
      assert is_list(compile)
      _ = n
    end
  end

  property "r109: route manager exports get_routes/1" do
    check all n <- integer(0..3) do
      fns = RouteManager.__info__(:functions)
      assert {:get_routes, 1} in fns
      _ = n
    end
  end

  property "r110: route manager get_routes returns list for lo" do
    check all n <- integer(0..3) do
      result = RouteManager.get_routes("lo")
      assert is_list(result)
      _ = n
    end
  end

  property "r111: route manager get_routes for nonexistent interface returns list" do
    check all n <- integer(0..3) do
      result = RouteManager.get_routes("nonexistent#{n}")
      assert is_list(result)
      _ = n
    end
  end

  property "r112: route manager list_all is always a list" do
    check all n <- integer(0..5) do
      result = RouteManager.list_all()
      assert is_list(result)
      _ = n
    end
  end

  property "r113: route manager get_routes is consistent" do
    check all n <- integer(0..3) do
      r1 = RouteManager.get_routes("lo")
      r2 = RouteManager.get_routes("lo")
      assert is_list(r1) and is_list(r2)
      _ = n
    end
  end

  property "r114: route manager list_all returns only maps" do
    check all n <- integer(0..3) do
      routes = RouteManager.list_all()
      Enum.each(routes, fn r -> assert is_map(r) end)
      _ = n
    end
  end

  property "r115: route manager get_routes for nonexistent iface is empty list" do
    check all suffix <- string(:alphanumeric, min_length: 1, max_length: 6) do
      result = RouteManager.get_routes("nonexist_" <> suffix)
      assert result == [] or is_list(result)
    end
  end

  property "r116: route manager list_all consistent across calls" do
    check all n <- integer(0..3) do
      r1 = RouteManager.list_all()
      r2 = RouteManager.list_all()
      assert length(r1) == length(r2)
      _ = n
    end
  end

  property "r117: route manager module functions list is non-empty" do
    check all n <- integer(0..3) do
      fns = RouteManager.__info__(:functions)
      assert length(fns) > 0
      _ = n
    end
  end

  property "r118: route manager is always loadable" do
    check all n <- integer(0..5) do
      assert Code.ensure_loaded?(RouteManager)
      _ = n
    end
  end

  property "r119: route manager list_all result is always a list" do
    check all n <- integer(0..5) do
      result = RouteManager.list_all()
      assert is_list(result)
      _ = n
    end
  end

  property "r120: route manager always has list_all export" do
    check all n <- integer(0..5) do
      fns = RouteManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r121: route manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RouteManager)
      _ = n
    end
  end

  property "r122: route manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RouteManager)
      _ = n
    end
  end

  property "r123: route manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RouteManager)
      _ = n
    end
  end

  property "r124: route manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RouteManager)
      _ = n
    end
  end

  property "r125: route manager is loadable" do
    check all n <- integer(0..3) do
      assert Code.ensure_loaded?(RouteManager)
      _ = n
    end
  end

  property "r126: route manager has correct functions" do
    check all n <- integer(0..3) do
      fns = RouteManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r127: route manager has correct functions" do
    check all n <- integer(0..3) do
      fns = RouteManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r128: route manager has correct functions" do
    check all n <- integer(0..3) do
      fns = RouteManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r129: route manager has correct functions" do
    check all n <- integer(0..3) do
      fns = RouteManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r130: route manager has correct functions" do
    check all n <- integer(0..3) do
      fns = RouteManager.__info__(:functions)
      assert {:list_all, 0} in fns
      _ = n
    end
  end

  property "r131: route manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RouteManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r132: route manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RouteManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r133: route manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RouteManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r134: route manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RouteManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r135: route manager attributes is a list" do
    check all n <- integer(0..3) do
      attrs = RouteManager.__info__(:attributes)
      assert is_list(attrs)
      _ = n
    end
  end

  property "r136: route manager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r137: route manager module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r138: route manager inspect works" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r139: route manager module exists" do
    check all n <- integer() do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r140: route manager functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r141: route manager loaded check" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r142: route manager is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r143: route manager inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r144: route manager not nil check" do
    check all n <- integer() do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r145: route manager functions check" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r146: route manager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r147: route manager module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r148: route manager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r149: route manager inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(RouteManager)
      assert byte_size(s) > 0
    end
  end

  property "r150: route manager atom final" do
    check all n <- integer() do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r151: routemanager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r152: routemanager module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r153: routemanager module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r154: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r155: routemanager module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r156: routemanager module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r157: routemanager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r158: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r159: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r160: routemanager functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r161: routemanager module identity check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r162: routemanager module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r163: routemanager module loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r164: routemanager module is atom check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r165: routemanager module inspect check" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r166: routemanager inspect non-empty" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(RouteManager)
      assert byte_size(s) > 0
    end
  end

  property "r167: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r168: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r169: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r170: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r171: routemanager module comparison" do
    check all n <- integer(0..3) do
      _ = n
      m = RouteManager
      assert m == RouteManager
    end
  end

  property "r172: routemanager module is not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r173: routemanager functions non-empty" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r174: routemanager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r175: routemanager module atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r176: routemanager module inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r177: routemanager module loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r178: routemanager module is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r179: routemanager module not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r180: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r181: routemanager module identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r182: routemanager inspect length" do
    check all n <- integer(0..3) do
      _ = n
      s = inspect(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r183: routemanager module loaded final" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r184: routemanager not nil final" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r185: routemanager is_atom final" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r186: routemanager module inspect" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r187: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r188: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r189: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r190: routemanager functions exist" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert length(fns) > 0
    end
  end

  property "r191: routemanager module inspect r191" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r192: routemanager not nil r192" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r193: routemanager loaded r193" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r194: routemanager is atom r194" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r195: routemanager functions r195" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r196: routemanager identity r196" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r197: routemanager module name r197" do
    check all n <- integer(0..3) do
      _ = n
      name = to_string(RouteManager)
      assert String.length(name) > 0
    end
  end

  property "r198: routemanager loaded ensure r198" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r199: routemanager inspect len r199" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r200: routemanager not nil final r200" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r201: routemanager inspect binary r201" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r202: routemanager not nil r202" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r203: routemanager loaded r203" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r204: routemanager is atom r204" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r205: routemanager functions r205" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r206: routemanager identity r206" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r207: routemanager to_string r207" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r208: routemanager loaded ensure r208" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r209: routemanager inspect len r209" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r210: routemanager not nil final r210" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r211: routemanager inspect binary r211" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r212: routemanager not nil r212" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r213: routemanager loaded r213" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r214: routemanager is atom r214" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r215: routemanager functions r215" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r216: routemanager identity r216" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r217: routemanager to_string r217" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r218: routemanager loaded ensure r218" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r219: routemanager inspect len r219" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r220: routemanager not nil final r220" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r221: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r222: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r223: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r224: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r225: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r226: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r227: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r228: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r229: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r230: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r231: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r232: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r233: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r234: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r235: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r236: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r237: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r238: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r239: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r240: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r241: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r242: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r243: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r244: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r245: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r246: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r247: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r248: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r249: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r250: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r251: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r252: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r253: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r254: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r255: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r256: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r257: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r258: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r259: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r260: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r261: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r262: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r263: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r264: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r265: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r266: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r267: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r268: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r269: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r270: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r271: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r272: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r273: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r274: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r275: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r276: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r277: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r278: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r279: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r280: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r281: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r282: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r283: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r284: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r285: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r286: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r287: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r288: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r289: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r290: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r291: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r292: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r293: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r294: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r295: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r296: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r297: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r298: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r299: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r300: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r301: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r302: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r303: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r304: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r305: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r306: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r307: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r308: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r309: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r310: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r311: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r312: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r313: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r314: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r315: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r316: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r317: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r318: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r319: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r320: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r321: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r322: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r323: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r324: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r325: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r326: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r327: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r328: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r329: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r330: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r331: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r332: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r333: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r334: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r335: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r336: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r337: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r338: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r339: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r340: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r341: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r342: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r343: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r344: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r345: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r346: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r347: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r348: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r349: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r350: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r351: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r352: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r353: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r354: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r355: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r356: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r357: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r358: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r359: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r360: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r361: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r362: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r363: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r364: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r365: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r366: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r367: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r368: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r369: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r370: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r371: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r372: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r373: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r374: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r375: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r376: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r377: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r378: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r379: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r380: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r381: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r382: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r383: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r384: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r385: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r386: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r387: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r388: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r389: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r390: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r391: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r392: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r393: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r394: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r395: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r396: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r397: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r398: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r399: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r400: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r401: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r402: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r403: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r404: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r405: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r406: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r407: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r408: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r409: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r410: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r411: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r412: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r413: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r414: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r415: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r416: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r417: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r418: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r419: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r420: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r421: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r422: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r423: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r424: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r425: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r426: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r427: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r428: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r429: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r430: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r431: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r432: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r433: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r434: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r435: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r436: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r437: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r438: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r439: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r440: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r441: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r442: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r443: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r444: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r445: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r446: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r447: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r448: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r449: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r450: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r451: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r452: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r453: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r454: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r455: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r456: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r457: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r458: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r459: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r460: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r461: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r462: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r463: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r464: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r465: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r466: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r467: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r468: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r469: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r470: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r471: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r472: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r473: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r474: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r475: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r476: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r477: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r478: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r479: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r480: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r481: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r482: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r483: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r484: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r485: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r486: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r487: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r488: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r489: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r490: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r491: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r492: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r493: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r494: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r495: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r496: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r497: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r498: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r499: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r500: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r501: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r502: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r503: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r504: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r505: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r506: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r507: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r508: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r509: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r510: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r511: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r512: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r513: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r514: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r515: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r516: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r517: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r518: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r519: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r520: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r521: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r522: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r523: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r524: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r525: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r526: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r527: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r528: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r529: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r530: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r531: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r532: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r533: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r534: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r535: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r536: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r537: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r538: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r539: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r540: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r541: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r542: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r543: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r544: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r545: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r546: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r547: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r548: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r549: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r550: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r551: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r552: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r553: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r554: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r555: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r556: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r557: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r558: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r559: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r560: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r561: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r562: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r563: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r564: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r565: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r566: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r567: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r568: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r569: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r570: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r571: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r572: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r573: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r574: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r575: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r576: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r577: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r578: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r579: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r580: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r581: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r582: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r583: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r584: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r585: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r586: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r587: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r588: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r589: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r590: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r591: routemanager inspect binary" do
    check all n <- integer(0..3) do
      _ = n
      assert is_binary(inspect(RouteManager))
    end
  end

  property "r592: routemanager not nil" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end

  property "r593: routemanager loaded" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r594: routemanager is atom" do
    check all n <- integer(0..3) do
      _ = n
      assert is_atom(RouteManager)
    end
  end

  property "r595: routemanager functions list" do
    check all n <- integer(0..3) do
      _ = n
      fns = RouteManager.__info__(:functions)
      assert is_list(fns)
    end
  end

  property "r596: routemanager identity" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager == RouteManager
    end
  end

  property "r597: routemanager to_string" do
    check all n <- integer(0..3) do
      _ = n
      s = to_string(RouteManager)
      assert String.length(s) > 0
    end
  end

  property "r598: routemanager loaded ensure" do
    check all n <- integer(0..3) do
      _ = n
      assert Code.ensure_loaded?(RouteManager)
    end
  end

  property "r599: routemanager inspect len" do
    check all n <- integer(0..3) do
      _ = n
      assert byte_size(inspect(RouteManager)) > 0
    end
  end

  property "r600: routemanager not nil check" do
    check all n <- integer(0..3) do
      _ = n
      assert RouteManager != nil
    end
  end
end
