defmodule YellowDog.Console.DashboardLive do
  use YellowDog.Console, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:services, get_service_status())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <h1 class="text-3xl font-bold text-zinc-900">Dashboard</h1>
        <p class="mt-2 text-zinc-600">Monitor and manage your Yellow Dog services</p>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <div :for={service <- @services} class="bg-white rounded-lg shadow p-6">
          <div class="flex items-center justify-between">
            <div>
              <h3 class="text-lg font-medium text-zinc-900"><%= service.name %></h3>
              <p class="text-sm text-zinc-600"><%= service.description %></p>
            </div>
            <div class={"w-3 h-3 rounded-full #{service.status_class}"}></div>
          </div>
          <div class="mt-4">
            <div class="flex items-center justify-between text-sm">
              <span class="text-zinc-500">Status</span>
              <span class={["font-medium", service.status_class]}>
                <%= service.status %>
              </span>
            </div>
            <div class="flex items-center justify-between text-sm mt-2">
              <span class="text-zinc-500">Port</span>
              <span class="font-medium text-zinc-900"><%= service.port %></span>
            </div>
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <div class="bg-white rounded-lg shadow">
          <div class="px-6 py-4 border-b border-zinc-200">
            <h2 class="text-lg font-medium text-zinc-900">Service Status</h2>
          </div>
          <div class="p-6">
            <div class="space-y-4">
              <div :for={service <- @services} class="flex items-center justify-between">
                <div class="flex items-center space-x-3">
                  <div class={"w-2 h-2 rounded-full #{service.status_class}"}></div>
                  <span class="text-sm font-medium text-zinc-900"><%= service.name %></span>
                </div>
                <span class={["text-sm", service.status_class]}><%= service.status %></span>
              </div>
            </div>
          </div>
        </div>

        <div class="bg-white rounded-lg shadow">
          <div class="px-6 py-4 border-b border-zinc-200">
            <h2 class="text-lg font-medium text-zinc-900">Quick Actions</h2>
          </div>
          <div class="p-6">
            <div class="space-y-3">
              <button class="w-full text-left px-4 py-3 bg-zinc-50 hover:bg-zinc-100 rounded-lg transition-colors">
                <div class="flex items-center justify-between">
                  <span class="text-sm font-medium text-zinc-900">View DNS Zones</span>
                  <svg class="w-4 h-4 text-zinc-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"></path>
                  </svg>
                </div>
              </button>
              <button class="w-full text-left px-4 py-3 bg-zinc-50 hover:bg-zinc-100 rounded-lg transition-colors">
                <div class="flex items-center justify-between">
                  <span class="text-sm font-medium text-zinc-900">DHCP Leases</span>
                  <svg class="w-4 h-4 text-zinc-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"></path>
                  </svg>
                </div>
              </button>
              <button class="w-full text-left px-4 py-3 bg-zinc-50 hover:bg-zinc-100 rounded-lg transition-colors">
                <div class="flex items-center justify-between">
                  <span class="text-sm font-medium text-zinc-900">Configuration</span>
                  <svg class="w-4 h-4 text-zinc-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5l7 7-7 7"></path>
                  </svg>
                </div>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp get_service_status do
    [
      %{
        name: "DNS",
        description: "Domain Name Service",
        status: "Running",
        status_class: "bg-green-500 text-green-600",
        port: "5353"
      },
      %{
        name: "DHCPv4",
        description: "DHCP IPv4 Service",
        status: "Running",
        status_class: "bg-green-500 text-green-600",
        port: "67"
      },
      %{
        name: "DHCPv6",
        description: "DHCP IPv6 Service",
        status: "Stopped",
        status_class: "bg-red-500 text-red-600",
        port: "547"
      },
      %{
        name: "mDNS",
        description: "Multicast DNS",
        status: "Stopped",
        status_class: "bg-red-500 text-red-600",
        port: "5353"
      }
    ]
  end
end
