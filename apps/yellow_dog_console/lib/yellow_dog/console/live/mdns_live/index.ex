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
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
        <div>
          <h1 class="text-4xl font-bold">mDNS Service</h1>
          <p class="mt-2 text-base-content/70">Multicast DNS service discovery and monitoring</p>
        </div>
        <div class="flex items-center gap-3">
          <.status_indicator
            status={if @status.running, do: "running", else: "stopped"}
            label={if @status.running, do: "Running", else: "Stopped"}
            pulse
          />
          <button class="btn btn-ghost btn-circle btn-sm">
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
                d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
              />
            </svg>
          </button>
        </div>
      </div>
      <!-- Status Cards -->
      <div class="stats stats-vertical lg:stats-horizontal shadow-xl w-full">
        <!-- Mode Stat -->
        <div class="stat">
          <div class="stat-figure text-info">
            <svg
              class="w-8 h-8"
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
          <div class="stat-title">Mode</div>
          <div class="stat-value text-info text-2xl">
            <%= String.capitalize(to_string(@status.mode)) %>
          </div>
        </div>
        <!-- Registered Services Stat -->
        <div class="stat">
          <div class="stat-figure text-success">
            <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
          </div>
          <div class="stat-title">Registered Services</div>
          <div class="stat-value text-success"><%= @status.registered_services %></div>
          <div class="stat-actions">
            <.link navigate={~p"/mdns/services"} class="btn btn-sm btn-success">
              Manage
            </.link>
          </div>
        </div>
        <!-- Discovered Services Stat -->
        <div class="stat">
          <div class="stat-figure text-secondary">
            <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
              />
            </svg>
          </div>
          <div class="stat-title">Discovered Services</div>
          <div class="stat-value text-secondary"><%= @status.discovered_services %></div>
          <div class="stat-actions">
            <.link navigate={~p"/mdns/discovery"} class="btn btn-sm btn-secondary">
              Browse
            </.link>
          </div>
        </div>
        <!-- Network Hosts Stat -->
        <div class="stat">
          <div class="stat-figure text-accent">
            <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M5 12h14M5 12a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v4a2 2 0 01-2 2M5 12a2 2 0 00-2 2v4a2 2 0 002 2h14a2 2 0 002-2v-4a2 2 0 00-2-2m-2-4h.01M17 16h.01"
              />
            </svg>
          </div>
          <div class="stat-title">Network Hosts</div>
          <div class="stat-value text-accent"><%= @network_stats.unique_hosts %></div>
          <div class="stat-actions">
            <.link navigate={~p"/mdns/monitor"} class="btn btn-sm btn-accent">
              Activity
            </.link>
          </div>
        </div>
      </div>
      <!-- Statistics Grid -->
      <div class="grid grid-cols-1 xl:grid-cols-3 gap-6">
        <!-- Registry Statistics -->
        <.card title="Registry Statistics" class="xl:col-span-1">
          <div class="space-y-3">
            <div class="flex items-center justify-between p-3 rounded-lg bg-base-200">
              <span class="text-sm font-medium">Total Services</span>
              <.badge size="lg"><%= @stats.registry_stats.total %></.badge>
            </div>
            <div class="flex items-center justify-between p-3 rounded-lg bg-base-200">
              <span class="text-sm font-medium">Enabled</span>
              <.badge color="success" size="lg"><%= @stats.registry_stats.enabled %></.badge>
            </div>
            <div class="flex items-center justify-between p-3 rounded-lg bg-base-200">
              <span class="text-sm font-medium">Disabled</span>
              <.badge color="ghost" size="lg"><%= @stats.registry_stats.disabled %></.badge>
            </div>
            <div class="flex items-center justify-between p-3 rounded-lg bg-base-200">
              <span class="text-sm font-medium">Registered (API)</span>
              <.badge color="info" size="lg"><%= @stats.registry_stats.registered %></.badge>
            </div>
            <div class="flex items-center justify-between p-3 rounded-lg bg-base-200">
              <span class="text-sm font-medium">From File</span>
              <.badge color="secondary" size="lg"><%= @stats.registry_stats.from_file %></.badge>
            </div>
          </div>
        </.card>
        <!-- Network Activity -->
        <.card title="Network Activity" class="xl:col-span-2">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div class="stat bg-base-200 rounded-lg">
              <div class="stat-title">Total Responses</div>
              <div class="stat-value text-primary text-3xl">
                <%= @network_stats.total_responses %>
              </div>
            </div>
            <div class="stat bg-base-200 rounded-lg">
              <div class="stat-title">Total Queries</div>
              <div class="stat-value text-secondary text-3xl">
                <%= @network_stats.total_queries %>
              </div>
            </div>
            <div class="stat bg-base-200 rounded-lg">
              <div class="stat-title">Active Services</div>
              <div class="stat-value text-success text-3xl">
                <%= @network_stats.active_services %>
              </div>
            </div>
            <div class="stat bg-base-200 rounded-lg">
              <div class="stat-title">Queries/Minute</div>
              <div class="stat-value text-accent text-3xl">
                <%= Float.round(@network_stats.queries_per_minute, 1) %>
              </div>
            </div>
          </div>

          <div class="divider">Activity Trends</div>

          <div class="space-y-3">
            <div>
              <div class="flex items-center justify-between mb-2">
                <span class="text-sm">Response Rate</span>
                <span class="text-sm font-semibold">
                  <%= if @network_stats.total_queries > 0,
                    do: round(@network_stats.total_responses / @network_stats.total_queries * 100),
                    else: 0 %>%
                </span>
              </div>
              <.progress
                value={
                  if @network_stats.total_queries > 0,
                    do: round(@network_stats.total_responses / @network_stats.total_queries * 100),
                    else: 0
                }
                color="success"
              />
            </div>
            <div>
              <div class="flex items-center justify-between mb-2">
                <span class="text-sm">Network Utilization</span>
                <span class="text-sm font-semibold">
                  <%= min(round(@network_stats.queries_per_minute * 2), 100) %>%
                </span>
              </div>
              <.progress value={min(round(@network_stats.queries_per_minute * 2), 100)} color="info" />
            </div>
          </div>
        </.card>
      </div>
      <!-- Quick Actions -->
      <.card title="Quick Actions">
        <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
          <.link navigate={~p"/mdns/services"} class="btn btn-primary btn-lg gap-2">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 4v16m8-8H4"
              />
            </svg>
            Register Service
          </.link>

          <.link navigate={~p"/mdns/discovery"} class="btn btn-secondary btn-lg gap-2">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
              />
            </svg>
            Discover Services
          </.link>

          <.link navigate={~p"/mdns/monitor"} class="btn btn-accent btn-lg gap-2">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
              />
            </svg>
            Monitor Network
          </.link>
        </div>
      </.card>
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
