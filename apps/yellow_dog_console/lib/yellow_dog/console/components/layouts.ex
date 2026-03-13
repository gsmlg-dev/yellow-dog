defmodule YellowDog.Console.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  Layouts are defined as function components following Phoenix 1.8+ pattern.
  The "root" layout is a skeleton rendered as part of the application router.
  The "app" layout is set as the default layout on both
  `use YellowDog.Console, :controller` and `use YellowDog.Console, :live_view`.
  """
  use YellowDog.Console, :html

  alias Phoenix.LiveView.JS

  embed_templates "layouts/*"

  @doc """
  App layout for pages that need additional wrapping.
  Can be used as a layout (receives @inner_content) or as a component (receives inner_block slot).
  """
  attr :flash, :map, default: %{}, doc: "the map of flash messages"
  attr :current_user, :any, default: nil, doc: "the current user"
  attr :current_path, :string, default: nil, doc: "current page path for sidebar highlighting"
  slot :inner_block, doc: "the inner content when used as a component"

  def app(assigns) do
    assigns =
      assign_new(assigns, :content, fn ->
        if Map.has_key?(assigns, :inner_content) do
          assigns.inner_content
        else
          nil
        end
      end)

    assigns = assign_new(assigns, :current_path, fn -> nil end)

    ~H"""
    <div id="yd-layout" class="yd-layout h-full">
      <.navbar current_user={@current_user} current_path={@current_path} />

      <div class="yd-body">
        <.sidebar current_path={@current_path} />

        <div class="yd-main flex flex-col min-w-0">
          <div class="flex-1 overflow-auto">
            <div class="w-full px-4 sm:px-6 lg:px-8 py-6">
              <.flash_group flash={@flash} />
              <%= if @content do %>
                {@content}
              <% else %>
                {render_slot(@inner_block)}
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @nav_sections [
    %{label: "Servers", icon: "server-network", path: "/server/dashboard"},
    %{label: "Tools", icon: "wrench", path: "/tool/geoip"},
    %{label: "System", icon: "cog", path: "/system/settings"},
    %{label: "Netman", icon: "lan", path: "/netman"}
  ]

  @section_prefixes %{
    "Servers" => ["/server/"],
    "Tools" => ["/tool/"],
    "System" => ["/system/"],
    "Netman" => ["/netman"],
    nil => ["/"]
  }

  defp navbar(assigns) do
    assigns = assign(assigns, :nav_sections, @nav_sections)

    ~H"""
    <.dm_navbar class="border-b border-outline-variant">
      <:start_part>
        <button
          class="btn btn-ghost lg:hidden"
          aria-label="Open menu"
          phx-click={JS.toggle_class("yd-sidebar-open", to: "#yd-layout")}
        >
          <.dm_mdi name="menu" class="w-6 h-6" />
        </button>
        <.link navigate="/" class="btn btn-ghost text-xl font-bold">
          <span class="text-primary">Yellow</span>
          <span class="text-warning">Dog</span>
        </.link>
      </:start_part>
      <:center_part>
        <ul class="hidden lg:flex gap-1">
          <li :for={section <- @nav_sections}>
            <.link
              navigate={section.path}
              class={["btn btn-ghost btn-sm", nav_active?(@current_path, section.label)]}
            >
              <.dm_mdi name={section.icon} class="w-5 h-5" />
              <span>{section.label}</span>
            </.link>
          </li>
        </ul>
      </:center_part>
      <:end_part>
        <.dm_theme_switcher id="theme-toggle" />
        <.dm_dropdown id="notifications-dropdown">
          <:trigger>
            <button class="btn btn-ghost btn-circle" aria-label="Notifications">
              <.dm_mdi name="bell-outline" class="w-6 h-6" />
            </button>
          </:trigger>
          <:content>
            <div class="card bg-surface-container shadow-sm p-4 min-w-64">
              <h3 class="font-semibold mb-2">Notifications</h3>
              <p class="text-sm text-on-surface-variant">No new notifications</p>
            </div>
          </:content>
        </.dm_dropdown>
      </:end_part>
    </.dm_navbar>
    """
  end

  defp nav_active?(nil, _section), do: nil

  defp nav_active?(current_path, section) do
    prefixes = Map.get(@section_prefixes, section, [])

    if Enum.any?(prefixes, &String.starts_with?(current_path, &1)) do
      "btn-active"
    end
  end

  defp active_section(nil), do: nil
  defp active_section("/"), do: nil

  defp active_section(path) do
    Enum.find_value(@section_prefixes, nil, fn {section, prefixes} ->
      if section && Enum.any?(prefixes, &String.starts_with?(path, &1)), do: section
    end)
  end

  defp sidebar(assigns) do
    assigns = assign(assigns, :section, active_section(assigns.current_path))

    ~H"""
    <div :if={@section} class="yd-sidebar">
      <div
        class="yd-sidebar-overlay"
        aria-label="close sidebar"
        phx-click={JS.remove_class("yd-sidebar-open", to: "#yd-layout")}
      >
      </div>

      <div class="bg-surface w-80 overflow-y-auto">
        <ul class="nested-menu nested-menu-bordered p-4">
          <.sidebar_servers :if={@section == "Servers"} current_path={@current_path} />
          <.sidebar_tools :if={@section == "Tools"} current_path={@current_path} />
          <.sidebar_system :if={@section == "System"} current_path={@current_path} />
          <.sidebar_netman :if={@section == "Netman"} current_path={@current_path} />
        </ul>
      </div>
    </div>
    """
  end

  defp sidebar_servers(assigns) do
    ~H"""
    <!-- Dashboard -->
    <li class="nested-menu-title">Dashboard</li>
    <li>
      <.link navigate="/server/dashboard" class={active?(@current_path, "/server/dashboard")}>
        <.dm_mdi name="view-dashboard" class="w-5 h-5" />
        <span>Services</span>
      </.link>
    </li>
    <!-- DNS -->
    <li class="nested-menu-title mt-4">DNS</li>
    <li>
      <.link navigate="/server/dns" class={active?(@current_path, "/server/dns", :exact)}>
        <.dm_mdi name="web" class="w-5 h-5" />
        <span>Overview</span>
      </.link>
    </li>
    <li>
      <.link navigate="/server/dns/views" class={active?(@current_path, "/server/dns/views")}>
        Views
      </.link>
    </li>
    <li>
      <.link navigate="/server/dns/acl" class={active?(@current_path, "/server/dns/acl")}>
        ACL
      </.link>
    </li>
    <li>
      <.link navigate="/server/dns/logs" class={active?(@current_path, "/server/dns/logs")}>
        Query Logs
      </.link>
    </li>
    <li>
      <.link navigate="/server/dns/metrics" class={active?(@current_path, "/server/dns/metrics")}>
        Metrics
      </.link>
    </li>
    <!-- DHCPv4 -->
    <li class="nested-menu-title mt-4">DHCPv4</li>
    <li>
      <.link navigate="/server/dhcpv4" class={active?(@current_path, "/server/dhcpv4", :exact)}>
        <.dm_mdi name="server-network" class="w-5 h-5" />
        <span>Overview</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/dhcpv4/leases"
        class={active?(@current_path, "/server/dhcpv4/leases")}
      >
        Leases
      </.link>
    </li>
    <li>
      <.link navigate="/server/dhcpv4/pools" class={active?(@current_path, "/server/dhcpv4/pools")}>
        Pools
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/dhcpv4/activity"
        class={active?(@current_path, "/server/dhcpv4/activity")}
      >
        Activity
      </.link>
    </li>
    <!-- DHCPv6 -->
    <li class="nested-menu-title mt-4">DHCPv6</li>
    <li>
      <.link navigate="/server/dhcpv6" class={active?(@current_path, "/server/dhcpv6", :exact)}>
        <.dm_mdi name="server-network" class="w-5 h-5" />
        <span>Overview</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/dhcpv6/leases"
        class={active?(@current_path, "/server/dhcpv6/leases")}
      >
        Leases
      </.link>
    </li>
    <li>
      <.link navigate="/server/dhcpv6/pools" class={active?(@current_path, "/server/dhcpv6/pools")}>
        Pools
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/dhcpv6/activity"
        class={active?(@current_path, "/server/dhcpv6/activity")}
      >
        Activity
      </.link>
    </li>
    <!-- mDNS -->
    <li class="nested-menu-title mt-4">mDNS</li>
    <li>
      <.link navigate="/server/mdns" class={active?(@current_path, "/server/mdns", :exact)}>
        <.dm_mdi name="wifi" class="w-5 h-5" />
        <span>Overview</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/mdns/services"
        class={active?(@current_path, "/server/mdns/services")}
      >
        Services
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/mdns/discovery"
        class={active?(@current_path, "/server/mdns/discovery")}
      >
        Discovery
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/mdns/monitor"
        class={active?(@current_path, "/server/mdns/monitor")}
      >
        Monitor
      </.link>
    </li>
    <!-- Netboot -->
    <li class="nested-menu-title mt-4">Netboot</li>
    <li>
      <.link navigate="/server/netboot" class={active?(@current_path, "/server/netboot", :exact)}>
        <.dm_mdi name="flash" class="w-5 h-5" />
        <span>Dashboard</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/netboot/devices"
        class={active?(@current_path, "/server/netboot/devices")}
      >
        Devices
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/netboot/profiles"
        class={active?(@current_path, "/server/netboot/profiles")}
      >
        Boot Profiles
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/netboot/tftp"
        class={active?(@current_path, "/server/netboot/tftp")}
      >
        TFTP Server
      </.link>
    </li>
    <li>
      <.link navigate="/server/netboot/log" class={active?(@current_path, "/server/netboot/log")}>
        Boot Log
      </.link>
    </li>
    <!-- Identity -->
    <li class="nested-menu-title mt-4">Identity</li>
    <li>
      <.link
        navigate="/server/identity"
        class={active?(@current_path, "/server/identity", :exact)}
      >
        <.dm_mdi name="key-variant" class="w-5 h-5" />
        <span>Overview</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/identity/hosts"
        class={active?(@current_path, "/server/identity/hosts")}
      >
        All Hosts
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/identity/approvals"
        class={active?(@current_path, "/server/identity/approvals")}
      >
        Pending Approvals
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/identity/tokens"
        class={active?(@current_path, "/server/identity/tokens")}
      >
        Tokens
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/identity/policies"
        class={active?(@current_path, "/server/identity/policies")}
      >
        Policies
      </.link>
    </li>
    <li>
      <.link
        navigate="/server/identity/audit"
        class={active?(@current_path, "/server/identity/audit")}
      >
        Audit Log
      </.link>
    </li>
    """
  end

  defp sidebar_tools(assigns) do
    ~H"""
    <li class="nested-menu-title">Network Tools</li>
    <li>
      <.link navigate="/tool/geoip" class={active?(@current_path, "/tool/geoip")}>
        <.dm_mdi name="earth" class="w-5 h-5" />
        <span>GeoIP Lookup</span>
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
      <.link navigate="/system/settings" class={active?(@current_path, "/system/settings")}>
        <.dm_mdi name="cog" class="w-5 h-5" />
        <span>Settings</span>
      </.link>
    </li>
    <li>
      <.link navigate="/system/logs" class={active?(@current_path, "/system/logs")}>
        <.dm_mdi name="file-document-outline" class="w-5 h-5" />
        <span>Logs</span>
      </.link>
    </li>
    <li>
      <.link navigate="/system/process-map" class={active?(@current_path, "/system/process-map")}>
        <.dm_mdi name="sitemap" class="w-5 h-5" />
        <span>Process Map</span>
      </.link>
    </li>
    <!-- Provider Data -->
    <li class="nested-menu-title mt-4">Provider</li>
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
        Fingerprints
      </.link>
    </li>
    """
  end

  defp sidebar_netman(assigns) do
    ~H"""
    <li class="nested-menu-title">Network Manager</li>
    <li>
      <.link navigate="/netman" class={active?(@current_path, "/netman", :exact)}>
        <.dm_mdi name="view-dashboard" class="w-5 h-5" />
        <span>Dashboard</span>
      </.link>
    </li>
    <!-- DHCP Client -->
    <li class="nested-menu-title mt-4">DHCP Client</li>
    <li>
      <.link
        navigate="/netman/dhcp-client"
        class={active?(@current_path, "/netman/dhcp-client", :exact)}
      >
        <.dm_mdi name="chip" class="w-5 h-5" />
        <span>Overview</span>
      </.link>
    </li>
    <li>
      <.link
        navigate="/netman/dhcp-client/interfaces"
        class={active?(@current_path, "/netman/dhcp-client/interfaces")}
      >
        Interfaces
      </.link>
    </li>
    <li>
      <.link
        navigate="/netman/dhcp-client/activity"
        class={active?(@current_path, "/netman/dhcp-client/activity")}
      >
        Activity
      </.link>
    </li>
    """
  end

  # Returns "active" class when current_path matches the target path.
  # :exact mode requires exact match (for overview pages that share a prefix).
  # Default mode uses prefix matching (e.g. /dns/views/... matches /dns/views).
  defp active?(nil, _target), do: nil
  defp active?(current, target), do: if(String.starts_with?(current, target), do: "active")

  defp active?(nil, _target, _mode), do: nil

  defp active?(current, target, :exact),
    do: if(current == target, do: "active")

  @doc """
  Renders flash notices.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages to display"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"
  attr :kind, :atom, values: [:info, :error], doc: "used to determine flash kind"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} class="space-y-2">
      <.flash kind={:info} title="Success!" flash={@flash} />
      <.flash kind={:error} title="Error!" flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        Attempting to reconnect <.dm_mdi name="loading" class="ml-1 w-3 h-3 animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        Hang in there while we get back on track
        <.dm_mdi name="loading" class="ml-1 w-3 h-3 animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders a single flash notice.
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used to determine alert styling"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "alert cursor-pointer",
        @kind == :info && "alert-success",
        @kind == :error && "alert-error"
      ]}
      {@rest}
    >
      <.dm_mdi :if={@kind == :info} name="check-circle-outline" class="w-6 h-6" />
      <.dm_mdi :if={@kind == :error} name="close-circle-outline" class="w-6 h-6" />
      <div>
        <h3 :if={@title} class="font-bold">{@title}</h3>
        <div class="text-sm">{msg}</div>
      </div>
    </div>
    """
  end
end
