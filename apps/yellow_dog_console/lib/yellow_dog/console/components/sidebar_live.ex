defmodule YellowDog.Console.SidebarLive do
  @moduledoc """
  Sidebar navigation LiveComponent with CSS sticky positioning.
  """
  use YellowDog.Console, :live_component

  @impl true
  def render(assigns) do
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
            <a href="/" class="gap-3">
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
            </a>
          </li>
          <li>
            <a href="/dashboard" class="gap-3">
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
            </a>
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
                <div class="badge badge-success badge-sm">Running</div>
              </summary>
              <ul>
                <li><a href="/dns">Overview</a></li>
                <li><a href="/dns/zones">Zones</a></li>
                <li><a href="/dns/cache">Cache</a></li>
                <li><a href="/dns/views">Views</a></li>
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
                <div class="badge badge-success badge-sm">Running</div>
              </summary>
              <ul>
                <li><a href="/dhcpv4">Overview</a></li>
                <li><a href="/dhcpv4/leases">Leases</a></li>
                <li><a href="/dhcpv4">Pools</a></li>
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
                <div class="badge badge-error badge-sm">Stopped</div>
              </summary>
              <ul>
                <li><a href="/dhcpv6">Overview</a></li>
                <li><a href="/dhcpv6/leases">Leases</a></li>
                <li><a href="/dhcpv6">Pools</a></li>
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
                <div class="badge badge-success badge-sm">Running</div>
              </summary>
              <ul>
                <li><a href="/mdns">Overview</a></li>
                <li><a href="/mdns/services">Services</a></li>
                <li><a href="/mdns/discovery">Discovery</a></li>
                <li><a href="/mdns/monitor">Monitor</a></li>
              </ul>
            </details>
          </li>
          
    <!-- Settings -->
          <li class="menu-title mt-4">
            <span>System</span>
          </li>
          <li>
            <a href="/settings" class="gap-3">
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
            </a>
          </li>
          <li>
            <a href="/logs" class="gap-3">
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
            </a>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
