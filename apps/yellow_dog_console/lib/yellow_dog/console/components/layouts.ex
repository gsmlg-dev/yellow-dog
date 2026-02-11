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
    # Support both layout usage (@inner_content) and component usage (inner_block slot)
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
    <div class="drawer lg:drawer-open h-full">
      <input id="main-drawer" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex flex-col h-full">
        <.navbar current_user={@current_user} />
        <div class="flex-1 overflow-auto">
          <div class="container mx-auto px-4 sm:px-6 lg:px-8 py-6">
            <.flash_group flash={@flash} />
            <%= if @content do %>
              {@content}
            <% else %>
              {render_slot(@inner_block)}
            <% end %>
          </div>
        </div>
      </div>
      <.sidebar current_path={@current_path} />
    </div>
    """
  end

  # Top navbar component with branding, search, and utilities.
  defp navbar(assigns) do
    ~H"""
    <div class="navbar bg-base-100 shadow-lg">
      <div class="flex-none lg:hidden">
        <label for="main-drawer" class="btn btn-square btn-ghost" aria-label="Open menu">
          <svg
            xmlns="http://www.w3.org/2000/svg"
            fill="none"
            viewBox="0 0 24 24"
            class="inline-block h-6 w-6 stroke-current"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M4 6h16M4 12h16M4 18h16"
            >
            </path>
          </svg>
        </label>
      </div>

      <div class="flex-1">
        <.link navigate="/" class="btn btn-ghost text-xl font-bold">
          <span class="text-primary">Yellow</span>
          <span class="text-warning">Dog</span>
        </.link>
      </div>

      <div class="flex items-center flex-none gap-2">
        <!-- Theme Toggle -->
        <label class="swap swap-rotate btn btn-ghost btn-circle" aria-label="Toggle theme">
          <input
            type="checkbox"
            id="theme-toggle"
            class="theme-controller"
            phx-hook="ThemeToggle"
          />
          <!-- Sun icon -->
          <svg
            class="swap-on h-6 w-6 fill-current"
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
          >
            <path d="M5.64,17l-.71.71a1,1,0,0,0,0,1.41,1,1,0,0,0,1.41,0l.71-.71A1,1,0,0,0,5.64,17ZM5,12a1,1,0,0,0-1-1H3a1,1,0,0,0,0,2H4A1,1,0,0,0,5,12Zm7-7a1,1,0,0,0,1-1V3a1,1,0,0,0-2,0V4A1,1,0,0,0,12,5ZM5.64,7.05a1,1,0,0,0,.7.29,1,1,0,0,0,.71-.29,1,1,0,0,0,0-1.41l-.71-.71A1,1,0,0,0,4.93,6.34Zm12,.29a1,1,0,0,0,.7-.29l.71-.71a1,1,0,1,0-1.41-1.41L17,5.64a1,1,0,0,0,0,1.41A1,1,0,0,0,17.66,7.34ZM21,11H20a1,1,0,0,0,0,2h1a1,1,0,0,0,0-2Zm-9,8a1,1,0,0,0-1,1v1a1,1,0,0,0,2,0V20A1,1,0,0,0,12,19ZM18.36,17A1,1,0,0,0,17,18.36l.71.71a1,1,0,0,0,1.41,0,1,1,0,0,0,0-1.41ZM12,6.5A5.5,5.5,0,1,0,17.5,12,5.51,5.51,0,0,0,12,6.5Zm0,9A3.5,3.5,0,1,1,15.5,12,3.5,3.5,0,0,1,12,15.5Z" />
          </svg>
          <!-- Moon icon -->
          <svg
            class="swap-off h-6 w-6 fill-current"
            xmlns="http://www.w3.org/2000/svg"
            viewBox="0 0 24 24"
          >
            <path d="M21.64,13a1,1,0,0,0-1.05-.14,8.05,8.05,0,0,1-3.37.73A8.15,8.15,0,0,1,9.08,5.49a8.59,8.59,0,0,1,.25-2A1,1,0,0,0,8,2.36,10.14,10.14,0,1,0,22,14.05,1,1,0,0,0,21.64,13Zm-9.5,6.69A8.14,8.14,0,0,1,7.08,5.22v.27A10.15,10.15,0,0,0,17.22,15.63a9.79,9.79,0,0,0,2.1-.22A8.11,8.11,0,0,1,12.14,19.73Z" />
          </svg>
        </label>
        
    <!-- Notifications -->
        <div class="dropdown dropdown-end">
          <div tabindex="0" role="button" class="btn btn-ghost btn-circle" aria-label="Notifications">
            <div class="indicator">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-6 w-6"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"
                />
              </svg>
              <span class="badge badge-xs badge-primary indicator-item"></span>
            </div>
          </div>
          <div
            tabindex="0"
            class="card card-compact dropdown-content bg-base-100 z-[1] mt-3 w-80 shadow-xl"
          >
            <div class="card-body">
              <h3 class="card-title">Notifications</h3>
              <p class="text-sm text-base-content/70">No new notifications</p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Sidebar navigation with service sections and CSS sticky positioning.
  defp sidebar(assigns) do
    ~H"""
    <div class="drawer-side">
      <label for="main-drawer" aria-label="close sidebar" class="drawer-overlay"></label>

      <div class="bg-base-100 min-h-full w-80 sticky top-0 max-h-screen overflow-y-auto">
        <ul class="menu text-base-content p-4">
          <!-- Dashboard -->
          <li class="menu-title">
            <span>Dashboard</span>
          </li>
          <li>
            <.link navigate="/" class={["gap-3", active?(@current_path, "/", :exact)]}>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M3 12l2-2m0 0l7-7 7 7M5 10v10a1 1 0 001 1h3m10-11l2 2m-2-2v10a1 1 0 01-1 1h-3m-6 0a1 1 0 001-1v-4a1 1 0 011-1h2a1 1 0 011 1v4a1 1 0 001 1m-6 0h6"
                />
              </svg>
              <span>Overview</span>
            </.link>
          </li>
          <li>
            <.link navigate="/dashboard" class={["gap-3", active?(@current_path, "/dashboard")]}>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
                />
              </svg>
              <span>Services</span>
            </.link>
          </li>
          
    <!-- Services Section -->
          <li class="menu-title mt-4">
            <span>Services</span>
          </li>
          
    <!-- DNS -->
          <li>
            <details open>
              <summary class="gap-3">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M21 12a9 9 0 01-9 9m9-9a9 9 0 00-9-9m9 9H3m9 9a9 9 0 01-9-9m9 9c1.657 0 3-4.03 3-9s-1.343-9-3-9m0 18c-1.657 0-3-4.03-3-9s1.343-9 3-9m-9 9a9 9 0 019-9"
                  />
                </svg>
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
              <summary class="gap-3">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01"
                  />
                </svg>
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
              <summary class="gap-3">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01"
                  />
                </svg>
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
          
    <!-- mDNS -->
          <li>
            <details open>
              <summary class="gap-3">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M8.111 16.404a5.5 5.5 0 017.778 0M12 20h.01m-7.08-7.071c3.904-3.905 10.236-3.905 14.141 0M1.394 9.393c5.857-5.857 15.355-5.857 21.213 0"
                  />
                </svg>
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
              <summary class="gap-3">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M13 10V3L4 14h7v7l9-11h-7z"
                  />
                </svg>
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
          <li class="menu-title mt-4">
            <span>Tools</span>
          </li>
          <li>
            <details open>
              <summary class="gap-3">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M14.7 6.3a1 1 0 000 1.4l1.6 1.6a1 1 0 001.4 0l3.77-3.77a6 6 0 01-7.94 7.94l-6.91 6.91a2.12 2.12 0 01-3-3l6.91-6.91a6 6 0 017.94-7.94l-3.76 3.76z"
                  />
                </svg>
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
          
    <!-- Fingerprint -->
          <li class="menu-title mt-4">
            <span>Fingerprint</span>
          </li>
          <li>
            <details open>
              <summary class="gap-3">
                <svg
                  xmlns="http://www.w3.org/2000/svg"
                  class="h-5 w-5"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M12 11c0 3.517-1.009 6.799-2.753 9.571m-3.44-2.04l.054-.09A13.916 13.916 0 008 11a4 4 0 118 0c0 1.017-.07 2.019-.203 3m-2.118 6.844A21.88 21.88 0 0015.171 17m3.839 1.132c.645-2.266.99-4.659.99-7.132A8 8 0 008 4.07M3 15.364c.64-1.319 1-2.8 1-4.364 0-1.457.39-2.823 1.07-4"
                  />
                </svg>
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
          
    <!-- Settings -->
          <li class="menu-title mt-4">
            <span>System</span>
          </li>
          <li>
            <.link navigate="/settings" class={["gap-3", active?(@current_path, "/settings")]}>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
                />
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                />
              </svg>
              <span>Settings</span>
            </.link>
          </li>
          <li>
            <.link navigate="/logs" class={["gap-3", active?(@current_path, "/logs")]}>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                />
              </svg>
              <span>Logs</span>
            </.link>
          </li>
          <li>
            <.link navigate="/diagnostics" class={["gap-3", active?(@current_path, "/diagnostics")]}>
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 3v2m6-2v2M9 19v2m6-2v2M5 9H3m2 6H3m18-6h-2m2 6h-2M7 19h10a2 2 0 002-2V7a2 2 0 00-2-2H7a2 2 0 00-2 2v10a2 2 0 002 2zM9 9h6v6H9V9z"
                />
              </svg>
              <span>Service Diagnostics</span>
            </.link>
          </li>
          <li>
            <.link
              navigate="/process-map"
              class={["gap-3", active?(@current_path, "/process-map")]}
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-5 w-5"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M4 5a1 1 0 011-1h14a1 1 0 011 1v2a1 1 0 01-1 1H5a1 1 0 01-1-1V5zM4 13a1 1 0 011-1h6a1 1 0 011 1v6a1 1 0 01-1 1H5a1 1 0 01-1-1v-6zM16 13a1 1 0 011-1h2a1 1 0 011 1v6a1 1 0 01-1 1h-2a1 1 0 01-1-1v-6z"
                />
              </svg>
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
  Renders flash notices using DaisyUI alerts.
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
        Attempting to reconnect <Heroicons.arrow_path class="ml-1 h-3 w-3 animate-spin" />
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
        <Heroicons.arrow_path class="ml-1 h-3 w-3 animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders a single flash notice using DaisyUI alert.
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
      <svg
        xmlns="http://www.w3.org/2000/svg"
        class="h-6 w-6 shrink-0 stroke-current"
        fill="none"
        viewBox="0 0 24 24"
      >
        <path
          :if={@kind == :info}
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
        />
        <path
          :if={@kind == :error}
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="2"
          d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"
        />
      </svg>
      <div>
        <h3 :if={@title} class="font-bold">{@title}</h3>
        <div class="text-sm">{msg}</div>
      </div>
    </div>
    """
  end
end
