defmodule YellowDog.ManagementUI.NavigationTest do
  use ExUnit.Case, async: true

  alias YellowDog.ManagementUI.{Navigation, Router}
  alias YellowDog.ManagementUI.Hooks.CurrentPath

  @zone_suffixes [
    "",
    "/new",
    "/import",
    "/:zone_id/edit",
    "/:zone_id/records",
    "/:zone_id/records/new",
    "/:zone_id/records/bulk",
    "/:zone_id/records/:rr_index/edit"
  ]

  @owned_routes [
    {:nodes, :workers, ["/management/servers", "/server"]},
    {:nodes, :enrollment, ["/management/servers/enrollment"]},
    {:nodes, :worker_services,
     [
       "/server/:server_id/dashboard",
       "/server/:server_id/dns",
       "/server/:server_id/connection",
       "/server/:server_id/services",
       "/server/:server_id/services/new",
       "/server/:server_id/services/:service_id/edit",
       "/server/:server_id/targets",
       "/server/:server_id/targets/:revision"
     ]},
    {:nodes, :netmans, ["/management/netman", "/netman"]},
    {:nodes, :netman_overview, ["/netman/:netman_id"]},
    {:nodes, :netman_config, ["/netman/:netman_id/config"]},
    {:nodes, :netman_resolved, ["/netman/:netman_id/resolved"]},
    {:nodes, :config_targets, ["/management/config"]},
    {:data, :dns_zones,
     for(
       prefix <- ["/management/zones", "/server/:server_id/dns/zones"],
       suffix <- @zone_suffixes,
       do: prefix <> suffix
     )},
    {:data, :dns_views,
     [
       "/management/dns/views",
       "/server/:server_id/dns/views",
       "/server/:server_id/dns/views/:service_id"
     ]},
    {:data, :dns_acls, ["/server/:server_id/dns/acl", "/server/:server_id/dns/acl/:service_id"]},
    {:data, :ip_database, ["/system/ip-database"]},
    {:data, :mac_database, ["/system/mac-database"]},
    {:monitoring, :overview, ["/", "/management"]},
    {:monitoring, :events, ["/management/events"]},
    {:monitoring, :tasks, ["/system/tasks", "/system/tasks/:task"]},
    {:monitoring, :logs, ["/system/logs", "/system/logs/realtime", "/system/logs/tasks"]},
    {:monitoring, :tool_mac, ["/tool/mac"]},
    {:monitoring, :tool_whois, ["/tool/whois"]},
    {:monitoring, :tool_geoip, ["/tool/geoip"]},
    {:system, :backups, ["/system/backups", "/system/backups/restore"]},
    {:system, :process_map, ["/system/process-map"]}
  ]

  test "four ordered sections have stable IDs and supported entry routes" do
    assert Enum.map(Navigation.sections(), &{&1.id, &1.label, &1.path}) == [
             {:nodes, "Node Management", "/management/servers"},
             {:data, "Data Configuration", "/management/zones"},
             {:monitoring, "Monitoring", "/management"},
             {:system, "System Configuration", "/system/process-map"}
           ]

    for section <- Navigation.sections() do
      assert Navigation.section_for_path(section.path) == section.id
      assert_live_route(section.path)
    end
  end

  test "every routed LiveView has exactly its declared section and secondary owner" do
    routed_paths =
      Router.__routes__()
      |> Enum.filter(&(&1.plug == Phoenix.LiveView.Plug))
      |> Enum.map(& &1.path)
      |> MapSet.new()

    declared_paths =
      @owned_routes
      |> Enum.flat_map(fn {_section, _item, paths} -> paths end)
      |> MapSet.new()

    assert routed_paths == declared_paths

    for {section, item, paths} <- @owned_routes, path <- paths do
      concrete = concrete_path(path)
      assert Navigation.section_for_path(concrete) == section, concrete
      assert Navigation.item_for_path(concrete) == item, concrete
      assert Navigation.section_for_path(concrete <> "?server_id=other#details") == section
      assert Navigation.item_for_path(concrete <> "?netman_id=other#details") == item
    end
  end

  test "unknown paths and accidental prefix matches have no owner" do
    for path <- [
          nil,
          "/unknown",
          "/management-other",
          "/management/servers-extra",
          "/management/zones-old",
          "/management/zones/a/records/0/edit/extra",
          "/server/a",
          "/server/a/dashboard/extra",
          "/server/a/dns/providers",
          "/server/a/dns/views/service/edit",
          "/server/a/dns/acl/service/edit",
          "/netman/a/interfaces",
          "/netman/a/dhcp-client",
          "/system/tasks/a/extra",
          "/system/logs/dns-query",
          "/system/backups/restore/extra",
          "/system/process-map-extra",
          "/tool/mac/extra"
        ] do
      assert Navigation.section_for_path(path) == nil, inspect(path)
      assert Navigation.item_for_path(path) == nil, inspect(path)
    end
  end

  test "all available links resolve to supported routes with and without a selection" do
    for selection <- [nil, {:server, "worker-1"}, {:netman, "netman-1"}],
        section <- Navigation.sections(),
        item <- items(section.id, selection) do
      assert item.status in [:available, :requires_scope, :planned]

      if item.status == :available do
        assert is_binary(item.path)
        assert_live_route(item.path)
        assert Navigation.section_for_path(item.path) == section.id
        assert Navigation.item_for_path(item.path) == item.id
      else
        assert item.path == nil
        assert is_binary(item.description) and item.description != ""
      end
    end
  end

  test "zero Workers leaves global navigation usable and scope-dependent items explanatory" do
    assert item(:nodes, :workers).status == :available
    assert item(:nodes, :worker_services).status == :requires_scope
    assert item(:nodes, :netman_config).status == :requires_scope
    assert item(:data, :dns_zones).path == "/management/zones"
    assert item(:data, :dns_views).path == "/management/dns/views"
    assert item(:data, :dns_acls).status == :requires_scope
    assert item(:data, :ip_database).status == :available
    assert item(:monitoring, :overview).status == :available
    assert item(:system, :process_map).status == :available

    services = item(:nodes, :worker_services)
    assert services.description =~ "authentication and connections"
    assert services.description =~ "listen addresses"

    for section <- Navigation.sections(),
        planned <- items(section.id, nil),
        planned.status == :planned do
      assert planned.path == nil
      refute Map.has_key?(planned, :event)
      refute Map.has_key?(planned, :handler)
    end
  end

  test "scoped Data keeps the validated Worker and DNS service in crosslinks" do
    path = "/server/%77orker-1/dns/views/service%20one?server_id=other#settings"
    assert {:server, "worker-1"} = selection = CurrentPath.selection_for_path(path)
    assert Navigation.section_for_path(path) == :data
    assert Navigation.item_for_path(path) == :dns_views
    assert item(:data, :dns_zones, selection, path).path == "/server/worker-1/dns/zones"

    assert item(:data, :dns_views, selection, path).path ==
             "/server/worker-1/dns/views/service%20one"

    assert item(:data, :dns_acls, selection, path).path ==
             "/server/worker-1/dns/acl/service%20one"

    acl_path = "/server/worker-1/dns/acl/service%20one"

    assert item(:data, :dns_views, selection, acl_path).path ==
             "/server/worker-1/dns/views/service%20one"
  end

  test "query identities and invalid selections cannot construct scoped links" do
    assert CurrentPath.selection_for_path("/management/dns/views?server_id=worker-1") == nil

    for path <- ["/server/bad%2Fid/dns/views", "/server/%2E%2E/dns/acl"] do
      assert CurrentPath.selection_for_path(path) == nil
      assert item(:data, :dns_acls, CurrentPath.selection_for_path(path)).path == nil
    end

    for selection <- [{:server, "bad/id"}, {:server, ".."}, {:netman, "bad/id"}] do
      assert item(:nodes, :worker_services, selection).status == :requires_scope
      assert item(:nodes, :netman_config, selection).status == :requires_scope
      assert item(:data, :dns_zones, selection).path == "/management/zones"
    end

    selection = {:server, "worker-1"}

    for path <- ["/server/other/dns/views/foreign", "/server/worker-1/dns/views/bad%2Fservice"] do
      assert item(:data, :dns_views, selection, path).path == "/server/worker-1/dns/views"
      assert item(:data, :dns_acls, selection, path).path == "/server/worker-1/dns/acl"
    end

    assert Navigation.groups(nil, nil) == []
  end

  defp concrete_path(pattern) do
    Regex.replace(~r/:[a-z_]+/, pattern, fn
      ":server_id" -> "worker-1"
      ":netman_id" -> "netman-1"
      ":rr_index" -> "0"
      _parameter -> "resource-1"
    end)
  end

  defp assert_live_route(path) do
    assert %{plug: Phoenix.LiveView.Plug} =
             Phoenix.Router.route_info(Router, "GET", path, "localhost")
  end

  defp items(section, selection, path \\ nil),
    do: section |> Navigation.groups(selection, path) |> Enum.flat_map(& &1.items)

  defp item(section, id, selection \\ nil, path \\ nil),
    do: Enum.find(items(section, selection, path), &(&1.id == id))
end
