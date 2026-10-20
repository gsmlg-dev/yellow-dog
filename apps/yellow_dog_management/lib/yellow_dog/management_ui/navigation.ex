defmodule YellowDog.ManagementUI.Navigation do
  @moduledoc """
  Shared navigation outline and ownership of supported Management routes.

  Route ownership is independent of the selection returned by
  `YellowDog.ManagementUI.Hooks.CurrentPath.selection_for_path/1`.
  """

  alias YellowDog.ManagementUI.Hooks.CurrentPath
  alias YellowDog.ManagementUI.ServicePaths

  @sections [
    %{id: :nodes, label: "Node Management", path: "/management/servers", icon: "server-network"},
    %{id: :data, label: "Data Configuration", path: "/management/zones", icon: "database"},
    %{id: :monitoring, label: "Monitoring", path: "/management", icon: "monitor-dashboard"},
    %{id: :system, label: "System Configuration", path: "/system/process-map", icon: "cog"}
  ]

  @zone_suffixes [
    [],
    ["new"],
    ["import"],
    [:zone_id, "edit"],
    [:zone_id, "records"],
    [:zone_id, "records", "new"],
    [:zone_id, "records", "bulk"],
    [:zone_id, "records", :rr_index, "edit"]
  ]

  @routes [
    {:data, :dns_zones,
     for(
       prefix <- [["management", "zones"], ["server", :server_id, "dns", "zones"]],
       suffix <- @zone_suffixes,
       do: prefix ++ suffix
     )},
    {:data, :dns_views,
     [
       ["management", "dns", "views"],
       ["server", :server_id, "dns", "views"],
       ["server", :server_id, "dns", "views", :service_id]
     ]},
    {:data, :dns_acls,
     [
       ["server", :server_id, "dns", "acl"],
       ["server", :server_id, "dns", "acl", :service_id]
     ]},
    {:nodes, :workers, [["management", "servers"], ["server"]]},
    {:nodes, :worker_services,
     [["server", :server_id, "dashboard"], ["server", :server_id, "dns"]]},
    {:nodes, :netmans, [["management", "netman"], ["netman"]]},
    {:nodes, :netman_overview, [["netman", :netman_id]]},
    {:nodes, :netman_config, [["netman", :netman_id, "config"]]},
    {:nodes, :netman_resolved, [["netman", :netman_id, "resolved"]]},
    {:nodes, :config_targets, [["management", "config"]]},
    {:data, :ip_database, [["system", "ip-database"]]},
    {:data, :mac_database, [["system", "mac-database"]]},
    {:monitoring, :overview, [[], ["management"]]},
    {:monitoring, :events, [["management", "events"]]},
    {:monitoring, :tasks, [["system", "tasks"], ["system", "tasks", :task]]},
    {:monitoring, :logs,
     [["system", "logs"], ["system", "logs", "realtime"], ["system", "logs", "tasks"]]},
    {:monitoring, :tool_mac, [["tool", "mac"]]},
    {:monitoring, :tool_whois, [["tool", "whois"]]},
    {:monitoring, :tool_geoip, [["tool", "geoip"]]},
    {:system, :backups, [["system", "backups"], ["system", "backups", "restore"]]},
    {:system, :process_map, [["system", "process-map"]]}
  ]

  def sections, do: @sections

  def section_for_path(path) do
    case owner_for_path(path) do
      {section, _item} -> section
      nil -> nil
    end
  end

  def item_for_path(path) do
    case owner_for_path(path) do
      {_section, item} -> item
      nil -> nil
    end
  end

  def groups(section, selection, current_path \\ nil)

  def groups(:nodes, selection, _current_path) do
    [
      group("Workers", [
        available(:workers, "Workers", "server-network", "/management/servers"),
        scoped(
          :worker_services,
          "Services & configuration",
          "cog",
          selection,
          :server,
          :dashboard,
          "Worker authentication and connections, service instances and desired enabled state, listen addresses, protocols, ports, and basic parameters are configured in Worker details."
        ),
        available(
          :config_targets,
          "Configuration history",
          "history",
          "/management/config",
          "Prepared configuration targets and history; these do not establish applied runtime state."
        )
      ]),
      group("Netman", [
        available(:netmans, "Netman nodes", "lan", "/management/netman"),
        scoped(:netman_overview, "Overview", "view-dashboard", selection, :netman, :overview),
        scoped(:netman_config, "Configuration", "cog", selection, :netman, :config),
        scoped(:netman_resolved, "Resolved", "dns", selection, :netman, :resolved)
      ])
    ]
  end

  def groups(:data, selection, current_path) do
    views_destination = service_destination(:dns_views, selection, current_path)
    acls_destination = service_destination(:dns_acl, selection, current_path)

    [
      group("DNS", [
        contextual(
          :dns_zones,
          "Zones and records",
          "folder-outline",
          selection,
          :dns_zones,
          "/management/zones"
        ),
        contextual(
          :dns_views,
          "Views",
          "eye",
          selection,
          views_destination,
          "/management/dns/views"
        ),
        scoped(
          :dns_acls,
          "ACLs / matching rules",
          "shield-lock",
          selection,
          :server,
          acls_destination,
          "Select a Worker, then select its DNS service to configure ACLs and matching rules."
        )
      ]),
      group("Service data", [
        planned(:dhcpv4_data, "DHCPv4 data", "server-network"),
        planned(:dhcpv6_data, "DHCPv6 data", "server-network"),
        planned(:mdns_data, "mDNS data", "wifi")
      ]),
      group("Databases", [
        available(:ip_database, "IP Database", "earth", "/system/ip-database"),
        available(:mac_database, "MAC Database", "ethernet", "/system/mac-database")
      ])
    ]
  end

  def groups(:monitoring, _selection, _current_path) do
    [
      group("Observed state", [
        available(:overview, "Overview", "view-dashboard", "/management"),
        planned(:node_status, "Node status", "server-network"),
        planned(:service_status, "Service status", "monitor-eye"),
        planned(:delivery_status, "Configuration delivery", "cloud-sync")
      ]),
      group("History", [
        available(
          :tasks,
          "Tasks & history",
          "clipboard-list",
          "/system/tasks",
          "Existing task pages include task settings and execution history."
        ),
        available(:logs, "Logs", "text-box", "/system/logs"),
        available(:events, "Events and audit", "timeline-text", "/management/events")
      ]),
      group("Network tools", [
        available(:tool_mac, "MAC lookup", "ethernet", "/tool/mac"),
        available(:tool_whois, "Whois", "magnify", "/tool/whois"),
        available(:tool_geoip, "GeoIP", "earth", "/tool/geoip")
      ])
    ]
  end

  def groups(:system, _selection, _current_path) do
    [
      group("Management platform", [
        planned(:platform_settings, "Platform settings", "cog"),
        planned(:api_mcp, "API & MCP integration", "api"),
        planned(
          :platform_access,
          "Access & authentication",
          "shield-lock"
        ),
        planned(:storage_retention, "Storage & retention", "database")
      ]),
      group("Maintenance", [
        available(:backups, "Backups and restore", "backup-restore", "/system/backups"),
        available(
          :process_map,
          "System diagnostics",
          "graph",
          "/system/process-map"
        )
      ])
    ]
  end

  def groups(_section, _selection, _current_path), do: []

  defp owner_for_path(path) when is_binary(path) do
    segments = String.split(URI.parse(path).path || "/", "/", trim: true)

    Enum.find_value(@routes, fn {section, item, patterns} ->
      if Enum.any?(patterns, &matches?(&1, segments)), do: {section, item}
    end)
  end

  defp owner_for_path(_path), do: nil

  defp matches?([], []), do: true

  defp matches?([parameter | pattern], [_segment | segments]) when is_atom(parameter),
    do: matches?(pattern, segments)

  defp matches?([segment | pattern], [segment | segments]), do: matches?(pattern, segments)
  defp matches?(_pattern, _segments), do: false

  defp group(label, items), do: %{label: label, items: items}

  defp available(id, label, icon, path, description \\ nil),
    do: %{
      id: id,
      label: label,
      icon: icon,
      path: path,
      status: :available,
      description: description
    }

  defp planned(id, label, icon),
    do: %{
      id: id,
      label: label,
      icon: icon,
      path: nil,
      status: :planned,
      description: "#{label} is planned; no supported destination is available yet."
    }

  defp contextual(id, label, icon, {:server, server_id}, destination, fallback) do
    path =
      if ServicePaths.valid_server_id?(server_id),
        do: ServicePaths.server_path(server_id, destination),
        else: fallback

    available(id, label, icon, path)
  end

  defp contextual(id, label, icon, _selection, _destination, fallback),
    do: available(id, label, icon, fallback)

  defp scoped(id, label, icon, selection, type, destination, description \\ nil) do
    path = scoped_path(selection, type, destination)

    %{
      id: id,
      label: label,
      icon: icon,
      path: path,
      status: if(path, do: :available, else: :requires_scope),
      description:
        description ||
          "Select a #{if type == :server, do: "Worker", else: "Netman node"} to open #{label}."
    }
  end

  defp scoped_path({:server, id}, :server, destination) do
    if ServicePaths.valid_server_id?(id), do: ServicePaths.server_path(id, destination)
  end

  defp scoped_path({:netman, id}, :netman, destination) do
    if ServicePaths.valid_netman_id?(id), do: ServicePaths.netman_path(id, destination)
  end

  defp scoped_path(_selection, _type, _destination), do: nil

  defp service_destination(destination, {:server, _id} = selection, path) when is_binary(path) do
    segments = String.split(URI.parse(path).path || "/", "/", trim: true)

    with ^selection <- CurrentPath.selection_for_path(path),
         ["server", _worker, "dns", kind, service] when kind in ["views", "acl"] <- segments do
      service_id = URI.decode(service)
      scoped_destination = {service_destination_name(destination), service_id}
      {:server, server_id} = selection
      ServicePaths.server_path(server_id, scoped_destination)
      scoped_destination
    else
      _ -> destination
    end
  rescue
    ArgumentError -> destination
  end

  defp service_destination(destination, _selection, _path), do: destination
  defp service_destination_name(:dns_views), do: :dns_views_service
  defp service_destination_name(:dns_acl), do: :dns_acl_service
end
