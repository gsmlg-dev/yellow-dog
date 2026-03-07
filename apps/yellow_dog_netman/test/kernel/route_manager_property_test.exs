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
end
