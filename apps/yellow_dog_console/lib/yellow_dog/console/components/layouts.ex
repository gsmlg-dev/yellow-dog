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
      <.sidebar current_path={@current_path} />

      <div class="yd-main flex flex-col h-full min-w-0">
        <.navbar current_user={@current_user} />
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
    """
  end

  defp navbar(assigns) do
    ~H"""
    <.dm_navbar>
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

  defp sidebar(assigns) do
    ~H"""
    <div class="yd-sidebar">
      <div
        class="yd-sidebar-overlay"
        aria-label="close sidebar"
        phx-click={JS.remove_class("yd-sidebar-open", to: "#yd-layout")}
      >
      </div>

      <div class="bg-surface min-h-full w-80 max-h-screen overflow-y-auto">
        <ul class="nested-menu nested-menu-bordered p-4">
          <!-- Dashboard -->
          <li class="nested-menu-title">Dashboard</li>
          <li>
            <.link navigate="/" class={active?(@current_path, "/", :exact)}>
              <.dm_mdi name="home" class="w-5 h-5" />
              <span>Overview</span>
            </.link>
          </li>
          <li>
            <.link navigate="/dashboard" class={active?(@current_path, "/dashboard")}>
              <.dm_mdi name="view-dashboard" class="w-5 h-5" />
              <span>Services</span>
            </.link>
          </li>
          
    <!-- Services -->
          <li class="nested-menu-title mt-4">Services</li>
          
    <!-- DNS -->
          <li>
            <details open>
              <summary>
                <.dm_mdi name="web" class="w-5 h-5" />
                <span>DNS</span>
              </summary>
              <ul>
                <li>
                  <.link navigate="/dns" class={active?(@current_path, "/dns", :exact)}>
                    Overview
                  </.link>
                </li>
                <li>
                  <.link navigate="/dns/views" class={active?(@current_path, "/dns/views")}>
                    Views
                  </.link>
                </li>
                <li>
                  <.link navigate="/dns/acl" class={active?(@current_path, "/dns/acl")}>ACL</.link>
                </li>
                <li>
                  <.link navigate="/dns/logs" class={active?(@current_path, "/dns/logs")}>
                    Query Logs
                  </.link>
                </li>
                <li>
                  <.link navigate="/dns/metrics" class={active?(@current_path, "/dns/metrics")}>
                    Metrics
                  </.link>
                </li>
              </ul>
            </details>
          </li>
          
    <!-- DHCPv4 -->
          <li>
            <details open>
              <summary>
                <.dm_mdi name="server-network" class="w-5 h-5" />
                <span>DHCPv4</span>
              </summary>
              <ul>
                <li>
                  <.link navigate="/dhcpv4" class={active?(@current_path, "/dhcpv4", :exact)}>
                    Overview
                  </.link>
                </li>
                <li>
                  <.link navigate="/dhcpv4/leases" class={active?(@current_path, "/dhcpv4/leases")}>
                    Leases
                  </.link>
                </li>
                <li>
                  <.link navigate="/dhcpv4/pools" class={active?(@current_path, "/dhcpv4/pools")}>
                    Pools
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/dhcpv4/activity"
                    class={active?(@current_path, "/dhcpv4/activity")}
                  >
                    Activity
                  </.link>
                </li>
              </ul>
            </details>
          </li>
          
    <!-- DHCPv6 -->
          <li>
            <details open>
              <summary>
                <.dm_mdi name="server-network" class="w-5 h-5" />
                <span>DHCPv6</span>
              </summary>
              <ul>
                <li>
                  <.link navigate="/dhcpv6" class={active?(@current_path, "/dhcpv6", :exact)}>
                    Overview
                  </.link>
                </li>
                <li>
                  <.link navigate="/dhcpv6/leases" class={active?(@current_path, "/dhcpv6/leases")}>
                    Leases
                  </.link>
                </li>
                <li>
                  <.link navigate="/dhcpv6/pools" class={active?(@current_path, "/dhcpv6/pools")}>
                    Pools
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/dhcpv6/activity"
                    class={active?(@current_path, "/dhcpv6/activity")}
                  >
                    Activity
                  </.link>
                </li>
              </ul>
            </details>
          </li>
          
    <!-- DHCP Client -->
          <li>
            <details open>
              <summary>
                <.dm_mdi name="chip" class="w-5 h-5" />
                <span>DHCP Client</span>
              </summary>
              <ul>
                <li>
                  <.link
                    navigate="/dhcp-client"
                    class={active?(@current_path, "/dhcp-client", :exact)}
                  >
                    Overview
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/dhcp-client/interfaces"
                    class={active?(@current_path, "/dhcp-client/interfaces")}
                  >
                    Interfaces
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/dhcp-client/activity"
                    class={active?(@current_path, "/dhcp-client/activity")}
                  >
                    Activity
                  </.link>
                </li>
              </ul>
            </details>
          </li>
          
    <!-- mDNS -->
          <li>
            <details open>
              <summary>
                <.dm_mdi name="wifi" class="w-5 h-5" />
                <span>mDNS</span>
              </summary>
              <ul>
                <li>
                  <.link navigate="/mdns" class={active?(@current_path, "/mdns", :exact)}>
                    Overview
                  </.link>
                </li>
                <li>
                  <.link navigate="/mdns/services" class={active?(@current_path, "/mdns/services")}>
                    Services
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/mdns/discovery"
                    class={active?(@current_path, "/mdns/discovery")}
                  >
                    Discovery
                  </.link>
                </li>
                <li>
                  <.link navigate="/mdns/monitor" class={active?(@current_path, "/mdns/monitor")}>
                    Monitor
                  </.link>
                </li>
              </ul>
            </details>
          </li>
          
    <!-- Netboot -->
          <li>
            <details open>
              <summary>
                <.dm_mdi name="flash" class="w-5 h-5" />
                <span>Netboot</span>
              </summary>
              <ul>
                <li>
                  <.link navigate="/netboot" class={active?(@current_path, "/netboot", :exact)}>
                    Dashboard
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/netboot/devices"
                    class={active?(@current_path, "/netboot/devices")}
                  >
                    Devices
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/netboot/profiles"
                    class={active?(@current_path, "/netboot/profiles")}
                  >
                    Boot Profiles
                  </.link>
                </li>
                <li>
                  <.link navigate="/netboot/tftp" class={active?(@current_path, "/netboot/tftp")}>
                    TFTP Server
                  </.link>
                </li>
                <li>
                  <.link navigate="/netboot/log" class={active?(@current_path, "/netboot/log")}>
                    Boot Log
                  </.link>
                </li>
              </ul>
            </details>
          </li>
          
    <!-- Tools -->
          <li class="nested-menu-title mt-4">Tools</li>
          <li>
            <details open>
              <summary>
                <.dm_mdi name="wrench" class="w-5 h-5" />
                <span>Network</span>
              </summary>
              <ul>
                <li>
                  <.link navigate="/tools/geoip" class={active?(@current_path, "/tools/geoip")}>
                    GeoIP Lookup
                  </.link>
                </li>
                <li>
                  <.link navigate="/tools/whois" class={active?(@current_path, "/tools/whois")}>
                    Whois Lookup
                  </.link>
                </li>
                <li>
                  <.link navigate="/tools/mac" class={active?(@current_path, "/tools/mac")}>
                    MAC Lookup
                  </.link>
                </li>
              </ul>
            </details>
          </li>
          
    <!-- Identity -->
          <li class="nested-menu-title mt-4">Identity</li>
          <li>
            <details open>
              <summary>
                <.dm_mdi name="key-variant" class="w-5 h-5" />
                <span>Host Registry</span>
              </summary>
              <ul>
                <li>
                  <.link navigate="/identity" class={active?(@current_path, "/identity")}>
                    Overview
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/identity/hosts"
                    class={active?(@current_path, "/identity/hosts")}
                  >
                    All Hosts
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/identity/approvals"
                    class={active?(@current_path, "/identity/approvals")}
                  >
                    Pending Approvals
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/identity/tokens"
                    class={active?(@current_path, "/identity/tokens")}
                  >
                    Tokens
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/identity/policies"
                    class={active?(@current_path, "/identity/policies")}
                  >
                    Policies
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/identity/audit"
                    class={active?(@current_path, "/identity/audit")}
                  >
                    Audit Log
                  </.link>
                </li>
              </ul>
            </details>
          </li>
          
    <!-- Fingerprint -->
          <li class="nested-menu-title mt-4">Fingerprint</li>
          <li>
            <details open>
              <summary>
                <.dm_mdi name="fingerprint" class="w-5 h-5" />
                <span>Devices</span>
              </summary>
              <ul>
                <li>
                  <.link
                    navigate="/fingerprint/devices"
                    class={active?(@current_path, "/fingerprint/devices")}
                  >
                    Device Inventory
                  </.link>
                </li>
                <li>
                  <.link
                    navigate="/fingerprint/fingerprints"
                    class={active?(@current_path, "/fingerprint/fingerprints")}
                  >
                    Fingerprints
                  </.link>
                </li>
              </ul>
            </details>
          </li>
          
    <!-- System -->
          <li class="nested-menu-title mt-4">System</li>
          <li>
            <.link navigate="/settings" class={active?(@current_path, "/settings")}>
              <.dm_mdi name="cog" class="w-5 h-5" />
              <span>Settings</span>
            </.link>
          </li>
          <li>
            <.link navigate="/logs" class={active?(@current_path, "/logs")}>
              <.dm_mdi name="file-document-outline" class="w-5 h-5" />
              <span>Logs</span>
            </.link>
          </li>
          <li>
            <.link navigate="/diagnostics" class={active?(@current_path, "/diagnostics")}>
              <.dm_mdi name="stethoscope" class="w-5 h-5" />
              <span>Service Diagnostics</span>
            </.link>
          </li>
          <li>
            <.link navigate="/process-map" class={active?(@current_path, "/process-map")}>
              <.dm_mdi name="sitemap" class="w-5 h-5" />
              <span>Process Map</span>
            </.link>
          </li>
        </ul>
      </div>
    </div>
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
