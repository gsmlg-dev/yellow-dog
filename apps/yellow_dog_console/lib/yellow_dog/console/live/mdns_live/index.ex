defmodule YellowDog.Console.MdnsLive.Index do
  @moduledoc """
  mDNS overview page showing status, statistics, and quick actions.
  """
  use YellowDog.Console, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # Subscribe to service updates
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "mdns:services")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "mdns:monitor")
    end

    {:ok,
     socket
     |> assign(:page_title, "mDNS Service")
     |> assign(:status, get_mdns_status())
     |> assign(:stats, get_mdns_stats())
     |> assign(:network_stats, get_network_stats())}
  end

  @impl true
  def handle_info({:service_registered, _service_id}, socket) do
    {:noreply,
     socket
     |> assign(:stats, get_mdns_stats())
     |> put_flash(:info, "Service registered successfully")}
  end

  @impl true
  def handle_info({:service_unregistered, _service_id}, socket) do
    {:noreply,
     socket
     |> assign(:stats, get_mdns_stats())
     |> put_flash(:info, "Service unregistered")}
  end

  @impl true
  def handle_info({:service_updated, _service_id}, socket) do
    {:noreply, assign(socket, :stats, get_mdns_stats())}
  end

  @impl true
  def handle_info(:network_update, socket) do
    {:noreply, assign(socket, :network_stats, get_network_stats())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <!-- Header -->
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-3xl font-bold text-zinc-900">mDNS Service</h1>
          <p class="mt-2 text-zinc-600">Multicast DNS service discovery and monitoring</p>
        </div>
        <div class="flex items-center space-x-2">
          <div class={"w-3 h-3 rounded-full #{if @status.running, do: "bg-green-500", else: "bg-red-500"}"}>
          </div>
          <span class="text-sm font-medium text-zinc-900">
            <%= if @status.running, do: "Running", else: "Stopped" %>
          </span>
        </div>
      </div>
      <!-- Status Cards -->
      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <!-- Mode Card -->
        <div class="bg-white rounded-lg shadow p-6">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm text-zinc-500">Mode</p>
              <p class="mt-1 text-2xl font-semibold text-zinc-900">
                <%= String.capitalize(to_string(@status.mode)) %>
              </p>
            </div>
            <div class="w-12 h-12 bg-blue-100 rounded-full flex items-center justify-center">
              <svg
                class="w-6 h-6 text-blue-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M8 16H6a2 2 0 01-2-2V6a2 2 0 012-2h8a2 2 0 012 2v2m-6 12h8a2 2 0 002-2v-8a2 2 0 00-2-2h-8a2 2 0 00-2 2v8a2 2 0 002 2z"
                />
              </svg>
            </div>
          </div>
        </div>
        <!-- Registered Services Card -->
        <div class="bg-white rounded-lg shadow p-6">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm text-zinc-500">Registered Services</p>
              <p class="mt-1 text-2xl font-semibold text-zinc-900">
                <%= @status.registered_services %>
              </p>
            </div>
            <div class="w-12 h-12 bg-green-100 rounded-full flex items-center justify-center">
              <svg
                class="w-6 h-6 text-green-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
            </div>
          </div>
          <div class="mt-4">
            <.link
              navigate={~p"/mdns/services"}
              class="text-sm text-blue-600 hover:text-blue-700 font-medium"
            >
              Manage services →
            </.link>
          </div>
        </div>
        <!-- Discovered Services Card -->
        <div class="bg-white rounded-lg shadow p-6">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm text-zinc-500">Discovered Services</p>
              <p class="mt-1 text-2xl font-semibold text-zinc-900">
                <%= @status.discovered_services %>
              </p>
            </div>
            <div class="w-12 h-12 bg-purple-100 rounded-full flex items-center justify-center">
              <svg
                class="w-6 h-6 text-purple-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                />
              </svg>
            </div>
          </div>
          <div class="mt-4">
            <.link
              navigate={~p"/mdns/discovery"}
              class="text-sm text-blue-600 hover:text-blue-700 font-medium"
            >
              Browse network →
            </.link>
          </div>
        </div>
        <!-- Network Hosts Card -->
        <div class="bg-white rounded-lg shadow p-6">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-sm text-zinc-500">Network Hosts</p>
              <p class="mt-1 text-2xl font-semibold text-zinc-900">
                <%= @network_stats.unique_hosts %>
              </p>
            </div>
            <div class="w-12 h-12 bg-orange-100 rounded-full flex items-center justify-center">
              <svg
                class="w-6 h-6 text-orange-600"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01"
                />
              </svg>
            </div>
          </div>
          <div class="mt-4">
            <.link
              navigate={~p"/mdns/monitor"}
              class="text-sm text-blue-600 hover:text-blue-700 font-medium"
            >
              View activity →
            </.link>
          </div>
        </div>
      </div>
      <!-- Registry Statistics -->
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-8">
        <div class="bg-white rounded-lg shadow">
          <div class="px-6 py-4 border-b border-zinc-200">
            <h2 class="text-lg font-medium text-zinc-900">Registry Statistics</h2>
          </div>
          <div class="p-6">
            <dl class="space-y-4">
              <div class="flex items-center justify-between">
                <dt class="text-sm text-zinc-500">Total Services</dt>
                <dd class="text-sm font-medium text-zinc-900">
                  <%= @stats.registry_stats.total %>
                </dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-sm text-zinc-500">Enabled Services</dt>
                <dd class="text-sm font-medium text-green-600">
                  <%= @stats.registry_stats.enabled %>
                </dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-sm text-zinc-500">Disabled Services</dt>
                <dd class="text-sm font-medium text-zinc-600">
                  <%= @stats.registry_stats.disabled %>
                </dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-sm text-zinc-500">Registered (API)</dt>
                <dd class="text-sm font-medium text-blue-600">
                  <%= @stats.registry_stats.registered %>
                </dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-sm text-zinc-500">From File</dt>
                <dd class="text-sm font-medium text-purple-600">
                  <%= @stats.registry_stats.from_file %>
                </dd>
              </div>
            </dl>
          </div>
        </div>
        <!-- Network Statistics -->
        <div class="bg-white rounded-lg shadow">
          <div class="px-6 py-4 border-b border-zinc-200">
            <h2 class="text-lg font-medium text-zinc-900">Network Activity</h2>
          </div>
          <div class="p-6">
            <dl class="space-y-4">
              <div class="flex items-center justify-between">
                <dt class="text-sm text-zinc-500">Total Responses</dt>
                <dd class="text-sm font-medium text-zinc-900">
                  <%= @network_stats.total_responses %>
                </dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-sm text-zinc-500">Total Queries</dt>
                <dd class="text-sm font-medium text-zinc-900">
                  <%= @network_stats.total_queries %>
                </dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-sm text-zinc-500">Active Services</dt>
                <dd class="text-sm font-medium text-green-600">
                  <%= @network_stats.active_services %>
                </dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-sm text-zinc-500">Queries/Minute</dt>
                <dd class="text-sm font-medium text-blue-600">
                  <%= Float.round(@network_stats.queries_per_minute, 1) %>
                </dd>
              </div>
              <div class="flex items-center justify-between">
                <dt class="text-sm text-zinc-500">Unique Hosts</dt>
                <dd class="text-sm font-medium text-purple-600">
                  <%= @network_stats.unique_hosts %>
                </dd>
              </div>
            </dl>
          </div>
        </div>
      </div>
      <!-- Quick Actions -->
      <div class="bg-white rounded-lg shadow">
        <div class="px-6 py-4 border-b border-zinc-200">
          <h2 class="text-lg font-medium text-zinc-900">Quick Actions</h2>
        </div>
        <div class="p-6">
          <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
            <.link
              navigate={~p"/mdns/services"}
              class="flex items-center justify-center px-4 py-3 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
            >
              <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 4v16m8-8H4"
                />
              </svg>
              <span class="font-medium">Register Service</span>
            </.link>

            <.link
              navigate={~p"/mdns/discovery"}
              class="flex items-center justify-center px-4 py-3 bg-purple-600 text-white rounded-lg hover:bg-purple-700 transition-colors"
            >
              <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                />
              </svg>
              <span class="font-medium">Discover Services</span>
            </.link>

            <.link
              navigate={~p"/mdns/monitor"}
              class="flex items-center justify-center px-4 py-3 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors"
            >
              <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
                />
              </svg>
              <span class="font-medium">Monitor Network</span>
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp get_mdns_status do
    try do
      YellowDog.Mdns.status()
    rescue
      _ -> %{running: false, mode: :unknown, registered_services: 0, discovered_services: 0}
    end
  end

  defp get_mdns_stats do
    try do
      registry_stats = YellowDog.Mdns.ServiceRegistry.stats()
      %{registry_stats: registry_stats}
    rescue
      _ ->
        %{
          registry_stats: %{
            total: 0,
            enabled: 0,
            disabled: 0,
            registered: 0,
            from_file: 0
          }
        }
    end
  end

  defp get_network_stats do
    try do
      YellowDog.Mdns.network_stats()
    rescue
      _ ->
        %{
          total_responses: 0,
          total_queries: 0,
          active_services: 0,
          unique_hosts: 0,
          queries_per_minute: 0.0
        }
    end
  end
end
