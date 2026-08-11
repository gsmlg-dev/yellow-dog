defmodule YellowDog.Console.Components.Sidebar do
  @moduledoc """
  Stateful left navigation for the app layout.

  Keeping the left menu in a LiveComponent gives it a stable component boundary,
  while the PreserveScroll hook keeps the menu's scroll position across live
  navigation between pages in the same section.
  """
  use YellowDog.Console, :live_component

  alias YellowDog.Console.ManagementLive.Data
  alias YellowDog.Console.ServicePaths

  @section_prefixes %{
    "Management" => ["/management"],
    "Servers" => ["/server"],
    "Tools" => ["/tool/"],
    "System" => ["/system/"],
    "Netman" => ["/netman"],
    nil => ["/"]
  }

  @server_navigation [
    {"Dashboard",
     [
       %{label: "Services", icon: "view-dashboard", destination: :dashboard, exact: true},
       %{label: "Settings", icon: "cog", destination: :settings}
     ]},
    {"DNS",
     [
       %{label: "Overview", icon: "web", destination: :dns, exact: true},
       %{label: "Zones", icon: "folder-outline", destination: :dns_zones},
       %{label: "Views", icon: "eye", destination: :dns_views},
       %{label: "ACL", icon: "shield-lock", destination: :dns_acl},
       %{label: "Metrics", icon: "chart-line", destination: :dns_metrics},
       %{label: "Providers", icon: "cloud-sync", destination: :dns_providers}
     ]},
    {"DHCPv4",
     [
       %{label: "Overview", icon: "server-network", destination: :dhcpv4, exact: true},
       %{label: "Leases", icon: "file-document", destination: :dhcpv4_leases},
       %{label: "Pools", icon: "lan", destination: :dhcpv4_pools}
     ]},
    {"DHCPv6",
     [
       %{label: "Overview", icon: "server-network", destination: :dhcpv6, exact: true},
       %{label: "Leases", icon: "file-document", destination: :dhcpv6_leases},
       %{label: "Pools", icon: "lan", destination: :dhcpv6_pools}
     ]},
    {"mDNS",
     [
       %{label: "Overview", icon: "wifi", destination: :mdns, exact: true},
       %{label: "Services", icon: "room-service", destination: :mdns_services},
       %{label: "Discovery", icon: "radar", destination: :mdns_discovery},
       %{label: "Monitor", icon: "monitor-eye", destination: :mdns_monitor}
     ]},
    {"Netboot",
     [
       %{label: "Dashboard", icon: "flash", destination: :netboot, exact: true},
       %{label: "Devices", icon: "devices", destination: :netboot_devices},
       %{label: "Boot Profiles", icon: "playlist-check", destination: :netboot_profiles},
       %{label: "TFTP Server", icon: "folder-network", destination: :netboot_tftp}
     ]},
    {"Identity",
     [
       %{label: "Overview", icon: "key-variant", destination: :identity, exact: true},
       %{label: "All Hosts", icon: "desktop-classic", destination: :identity_hosts},
       %{label: "Pending Approvals", icon: "check-decagram", destination: :identity_approvals},
       %{label: "Tokens", icon: "ticket-account", destination: :identity_tokens},
       %{label: "Policies", icon: "shield-check", destination: :identity_policies}
     ]}
  ]

  @netman_navigation [
    %{label: "Overview", icon: "view-dashboard", destination: :overview, exact: true},
    %{label: "Configuration", icon: "cog", destination: :config},
    %{label: "Interfaces", icon: "ethernet", destination: :interfaces},
    %{label: "Resolved", icon: "dns", destination: :resolved},
    %{label: "DHCP Client", icon: "chip", destination: :dhcp_client}
  ]

  @impl true
  def update(assigns, socket) do
    current_path = Map.get(assigns, :current_path)
    section = section_for_path(current_path)

    {records, selected_record} = navigation_records(section, Map.get(assigns, :navigation_scope))

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:section, section)
     |> assign(:scroll_key, scroll_key(section))
     |> assign(:records, records)
     |> assign(:selected_record, selected_record)}
  end

  @impl true
  def handle_event("select_server", %{"selection" => %{"id" => id}}, socket) do
    navigate_to_selection(socket, :server, id)
  end

  def handle_event("select_netman", %{"selection" => %{"id" => id}}, socket) do
    navigate_to_selection(socket, :netman, id)
  end

  def section_for_path(nil), do: nil
  def section_for_path("/"), do: nil

  def section_for_path(path) do
    Enum.find_value(@section_prefixes, nil, fn {section, prefixes} ->
      if section && Enum.any?(prefixes, &String.starts_with?(path, &1)), do: section
    end)
  end

  defp scroll_key(nil), do: "sidebar:none"
  defp scroll_key(section), do: "sidebar:#{section}"

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="yd-sidebar yd-sidebar-sticky"
      data-scroll-key={@scroll_key}
      phx-hook="PreserveScroll"
      role="navigation"
      aria-label="Section navigation"
      hidden={is_nil(@section)}
    >
      <div
        class="yd-sidebar-overlay"
        aria-label="close sidebar"
        phx-click={JS.remove_class("yd-sidebar-open", to: "#yd-layout")}
      >
      </div>

      <div class="yd-sidebar-panel w-80">
        <ul class="nested-menu nested-menu-bordered p-4">
          <.sidebar_management :if={@section == "Management"} current_path={@current_path} />
          <.sidebar_servers
            :if={@section == "Servers"}
            current_path={@current_path}
            myself={@myself}
            records={@records}
            selected_record={@selected_record}
          />
          <.sidebar_tools :if={@section == "Tools"} current_path={@current_path} />
          <.sidebar_system :if={@section == "System"} current_path={@current_path} />
          <.sidebar_netman
            :if={@section == "Netman"}
            current_path={@current_path}
            myself={@myself}
            records={@records}
            selected_record={@selected_record}
          />
        </ul>
      </div>
    </div>
    """
  end

  defp sidebar_management(assigns) do
    ~H"""
    <li class="nested-menu-title">Management</li>
    <li>
      <.link navigate="/management" class={active?(@current_path, "/management", :exact)}>
        <.dm_mdi name="view-dashboard" class="w-5 h-5" />
        <span>Overview</span>
      </.link>
    </li>
    <li>
      <.link navigate="/management/servers" class={active?(@current_path, "/management/servers")}>
        <.dm_mdi name="server-network" class="w-5 h-5" />
        <span>Servers</span>
      </.link>
    </li>
    <li>
      <.link navigate="/management/netman" class={active?(@current_path, "/management/netman")}>
        <.dm_mdi name="lan" class="w-5 h-5" />
        <span>Netman</span>
      </.link>
    </li>
    <li>
      <.link navigate="/management/profiles" class={active?(@current_path, "/management/profiles")}>
        <.dm_mdi name="playlist-check" class="w-5 h-5" />
        <span>Profiles</span>
      </.link>
    </li>
    <li>
      <.link navigate="/management/config" class={active?(@current_path, "/management/config")}>
        <.dm_mdi name="cog" class="w-5 h-5" />
        <span>Config</span>
      </.link>
    </li>
    <li>
      <.link navigate="/management/events" class={active?(@current_path, "/management/events")}>
        <.dm_mdi name="timeline-text" class="w-5 h-5" />
        <span>Events</span>
      </.link>
    </li>
    """
  end

  defp sidebar_servers(assigns) do
    assigns = assign(assigns, :navigation, @server_navigation)

    ~H"""
    <.selection_control
      id="server-selection-form"
      event="select_server"
      label="Server"
      myself={@myself}
      records={@records}
      selected_record={@selected_record}
    />

    <%= for {{title, items}, section_index} <- Enum.with_index(@navigation) do %>
      <li class={["nested-menu-title", section_index > 0 && "mt-4"]}>{title}</li>
      <.service_navigation_item
        :for={item <- items}
        target_type={:server}
        item={item}
        selected_record={@selected_record}
        current_path={@current_path}
      />
    <% end %>
    """
  end

  defp sidebar_tools(assigns) do
    ~H"""
    <li class="nested-menu-title">Network Tools</li>
    <li>
      <.link navigate="/tool/geoip" class={active?(@current_path, "/tool/geoip")}>
        <.dm_mdi name="earth" class="w-5 h-5" />
        <span>IP Geo Lookup</span>
      </.link>
    </li>
    <li>
      <.link navigate="/tool/whois" class={active?(@current_path, "/tool/whois")}>
        <.dm_mdi name="magnify" class="w-5 h-5" />
        <span>Whois Lookup</span>
      </.link>
    </li>
    <li>
      <.link navigate="/tool/mac" class={active?(@current_path, "/tool/mac")}>
        <.dm_mdi name="ethernet" class="w-5 h-5" />
        <span>MAC Lookup</span>
      </.link>
    </li>
    <!-- Service Diagnostics -->
    <li class="nested-menu-title mt-4">Diagnostics</li>
    <li>
      <.link
        navigate="/tool/diagnostics/dns"
        class={active?(@current_path, "/tool/diagnostics/dns")}
      >
        <.dm_mdi name="web" class="w-5 h-5" />
        <span>DNS</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/tool/diagnostics/mdns"
        class={active?(@current_path, "/tool/diagnostics/mdns")}
      >
        <.dm_mdi name="wifi" class="w-5 h-5" />
        <span>mDNS</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/tool/diagnostics/dhcpv4"
        class={active?(@current_path, "/tool/diagnostics/dhcpv4")}
      >
        <.dm_mdi name="server-network" class="w-5 h-5" />
        <span>DHCPv4</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/tool/diagnostics/dhcpv6"
        class={active?(@current_path, "/tool/diagnostics/dhcpv6")}
      >
        <.dm_mdi name="server-network" class="w-5 h-5" />
        <span>DHCPv6</span>
      </.link>
    </li>
    """
  end

  defp sidebar_system(assigns) do
    ~H"""
    <li class="nested-menu-title">System</li>
    <li>
      <.link navigate="/system/process-map" class={active?(@current_path, "/system/process-map")}>
        <.dm_mdi name="sitemap" class="w-5 h-5" />
        <span>Process Map</span>
      </.link>
    </li>
    <li>
      <.link navigate="/system/tasks" class={active?(@current_path, "/system/tasks")}>
        <.dm_mdi name="calendar-sync" class="w-5 h-5" />
        <span>Tasks</span>
      </.link>
    </li>
    <!-- Backups -->
    <li class="nested-menu-title mt-4">Backups</li>
    <li>
      <.link navigate="/system/backups" class={active?(@current_path, "/system/backups", :exact)}>
        <.dm_mdi name="database-export" class="w-5 h-5" />
        <span>Data Export</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/system/backups/restore"
        class={active?(@current_path, "/system/backups/restore")}
      >
        <.dm_mdi name="backup-restore" class="w-5 h-5" />
        <span>Restore</span>
      </.link>
    </li>
    <!-- Logs -->
    <li class="nested-menu-title mt-4">Log</li>
    <li>
      <.link
        navigate="/system/logs/realtime"
        class={active?(@current_path, "/system/logs/realtime")}
      >
        <.dm_mdi name="pulse" class="w-5 h-5" />
        <span>Realtime Logs</span>
      </.link>
    </li>
    <li>
      <.link navigate="/system/logs/tasks" class={active?(@current_path, "/system/logs/tasks")}>
        <.dm_mdi name="calendar-sync" class="w-5 h-5" />
        <span>Task Log</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/system/logs/dns-query"
        class={active?(@current_path, "/system/logs/dns-query")}
      >
        <.dm_mdi name="web" class="w-5 h-5" />
        <span>DNS Query Logs</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/system/logs/dhcpv4-activity"
        class={active?(@current_path, "/system/logs/dhcpv4-activity")}
      >
        <.dm_mdi name="server-network" class="w-5 h-5" />
        <span>DHCPv4 Activity</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/system/logs/dhcpv6-activity"
        class={active?(@current_path, "/system/logs/dhcpv6-activity")}
      >
        <.dm_mdi name="server-network" class="w-5 h-5" />
        <span>DHCPv6 Activity</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/system/logs/netboot"
        class={active?(@current_path, "/system/logs/netboot")}
      >
        <.dm_mdi name="flash" class="w-5 h-5" />
        <span>Netboot Log</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/system/logs/identity-audit"
        class={active?(@current_path, "/system/logs/identity-audit")}
      >
        <.dm_mdi name="key-variant" class="w-5 h-5" />
        <span>Identity Audit</span>
      </.link>
    </li>
    <!-- Provider Data -->
    <li class="nested-menu-title mt-4">Provider</li>
    <li>
      <.link
        navigate="/system/provider/cloud-dns"
        class={active?(@current_path, "/system/provider/cloud-dns")}
      >
        <.dm_mdi name="cloud" class="w-5 h-5" />
        <span>Cloud DNS</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/system/fingerprint/devices"
        class={active?(@current_path, "/system/fingerprint/devices")}
      >
        <.dm_mdi name="fingerprint" class="w-5 h-5" />
        <span>Device Inventory</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/system/fingerprint/fingerprints"
        class={active?(@current_path, "/system/fingerprint/fingerprints")}
      >
        <.dm_mdi name="database" class="w-5 h-5" />
        <span>Fingerprints</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/system/ip-database"
        class={active?(@current_path, "/system/ip-database")}
      >
        <.dm_mdi name="earth" class="w-5 h-5" />
        <span>IP Database</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/system/mac-database"
        class={active?(@current_path, "/system/mac-database")}
      >
        <.dm_mdi name="ethernet" class="w-5 h-5" />
        <span>MAC Database</span>
      </.link>
    </li>
    """
  end

  defp sidebar_netman(assigns) do
    assigns = assign(assigns, :navigation, @netman_navigation)

    ~H"""
    <.selection_control
      id="netman-selection-form"
      event="select_netman"
      label="Netman"
      myself={@myself}
      records={@records}
      selected_record={@selected_record}
    />

    <li class="nested-menu-title mt-4">Network Manager</li>
    <.service_navigation_item
      :for={item <- @navigation}
      target_type={:netman}
      item={item}
      selected_record={@selected_record}
      current_path={@current_path}
    />
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :label, :string, required: true
  attr :myself, :any, required: true
  attr :records, :list, required: true
  attr :selected_record, :any, default: nil

  defp selection_control(assigns) do
    ~H"""
    <li class="nested-menu-title">Selected {@label}</li>
    <li>
      <form id={@id} phx-change={@event} phx-target={@myself}>
        <label for={"#{@id}-select"} class="sr-only">Select {@label}</label>
        <select
          id={"#{@id}-select"}
          name="selection[id]"
          class="select select-sm w-full"
          aria-label={"Select #{@label}"}
        >
          <option value="" selected={is_nil(@selected_record)}>Select {@label}</option>
          <option
            :for={record <- @records}
            value={record.id}
            selected={selected_record?(@selected_record, record)}
          >
            {record_label(record)}
          </option>
        </select>
      </form>
    </li>
    """
  end

  attr :target_type, :atom, required: true
  attr :item, :map, required: true
  attr :selected_record, :any, default: nil
  attr :current_path, :string, default: nil

  defp service_navigation_item(assigns) do
    path =
      case assigns.selected_record do
        %{id: id} -> service_path(assigns.target_type, id, assigns.item.destination)
        nil -> nil
      end

    assigns =
      assigns
      |> assign(:path, path)
      |> assign(:active_class, navigation_active?(assigns.current_path, path, assigns.item))

    ~H"""
    <li>
      <.link
        :if={@path}
        navigate={@path}
        class={@active_class}
        data-service-navigation
        data-service-target={@target_type}
      >
        <.dm_mdi name={@item.icon} class="w-5 h-5" />
        <span>{@item.label}</span>
      </.link>
      <button
        :if={is_nil(@path)}
        type="button"
        disabled
        aria-disabled="true"
        data-service-navigation
        data-service-target={@target_type}
      >
        <.dm_mdi name={@item.icon} class="w-5 h-5" />
        <span>{@item.label}</span>
      </button>
    </li>
    """
  end

  defp navigation_records("Servers", {:server, selected_id}) do
    records = valid_records(Data.list_servers(), :server)
    {records, Enum.find(records, &(&1.id == selected_id))}
  end

  defp navigation_records("Servers", _scope),
    do: {valid_records(Data.list_servers(), :server), nil}

  defp navigation_records("Netman", {:netman, selected_id}) do
    records = valid_records(Data.list_netmans(), :netman)
    {records, Enum.find(records, &(&1.id == selected_id))}
  end

  defp navigation_records("Netman", _scope),
    do: {valid_records(Data.list_netmans(), :netman), nil}

  defp navigation_records(_section, _scope), do: {[], nil}

  defp valid_records(records, :server),
    do: Enum.filter(records, &ServicePaths.valid_server_id?(&1.id))

  defp valid_records(records, :netman),
    do: Enum.filter(records, &ServicePaths.valid_netman_id?(&1.id))

  defp navigate_to_selection(socket, target_type, "") do
    {:noreply, Phoenix.LiveView.push_navigate(socket, to: selector_path(target_type))}
  end

  defp navigate_to_selection(socket, target_type, id) do
    if Enum.any?(socket.assigns.records, &(&1.id == id)) do
      {:noreply,
       Phoenix.LiveView.push_navigate(
         socket,
         to: service_path(target_type, id, selection_destination(target_type))
       )}
    else
      {:noreply, socket}
    end
  end

  defp service_path(:server, id, destination),
    do: ServicePaths.server_path(id, destination)

  defp service_path(:netman, id, destination),
    do: ServicePaths.netman_path(id, destination)

  defp selector_path(:server), do: "/server"
  defp selector_path(:netman), do: "/netman"

  defp selection_destination(:server), do: :dashboard
  defp selection_destination(:netman), do: :overview

  defp selected_record?(%{id: selected_id}, %{id: id}), do: selected_id == id
  defp selected_record?(_selected_record, _record), do: false

  defp record_label(record) do
    name = Map.get(record, :name) || record.id
    status = Map.get(record, :status, :unknown)
    "#{name} (#{status})"
  end

  defp navigation_active?(_current_path, nil, _item), do: nil

  defp navigation_active?(current_path, path, %{exact: true}),
    do: active?(current_path, path, :exact)

  defp navigation_active?(current_path, path, _item),
    do: active?(current_path, path)

  # Returns "active" class when current_path matches the target path.
  # :exact mode requires exact match (for overview pages that share a prefix).
  # Default mode uses prefix matching (e.g. /dns/views/... matches /dns/views).
  defp active?(nil, _target), do: nil
  defp active?(current, target), do: if(String.starts_with?(current, target), do: "active")

  defp active?(nil, _target, _mode), do: nil

  defp active?(current, target, :exact),
    do: if(current == target, do: "active")
end
