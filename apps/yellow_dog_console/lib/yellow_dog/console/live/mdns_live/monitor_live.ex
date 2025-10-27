defmodule YellowDog.Console.MdnsLive.MonitorLive do
  @moduledoc """
  LiveView for real-time monitoring of mDNS network activity.
  """
  use YellowDog.Console, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "mdns:monitor")
      # Refresh queries every 5 seconds
      :timer.send_interval(5_000, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "Network Monitor")
     |> assign(:queries, get_recent_queries(50))
     |> assign(:stats, get_network_stats())
     |> assign(:limit, 50)
     |> assign(:auto_refresh, true)}
  end

  @impl true
  def handle_event("set_limit", %{"limit" => limit}, socket) do
    limit_int = String.to_integer(limit)

    {:noreply,
     socket
     |> assign(:limit, limit_int)
     |> assign(:queries, get_recent_queries(limit_int))}
  end

  @impl true
  def handle_event("toggle_auto_refresh", _params, socket) do
    {:noreply, assign(socket, :auto_refresh, !socket.assigns.auto_refresh)}
  end

  @impl true
  def handle_event("clear_cache", _params, socket) do
    try do
      YellowDog.Mdns.clear_cache()
      {:noreply, put_flash(socket, :info, "Cache cleared successfully")}
    rescue
      _ -> {:noreply, put_flash(socket, :error, "Failed to clear cache")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    if socket.assigns.auto_refresh do
      {:noreply,
       socket
       |> assign(:queries, get_recent_queries(socket.assigns.limit))
       |> assign(:stats, get_network_stats())}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:network_update, socket) do
    if socket.assigns.auto_refresh do
      {:noreply, assign(socket, :stats, get_network_stats())}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-3xl font-bold text-zinc-900">Network Monitor</h1>
          <p class="mt-2 text-zinc-600">Real-time mDNS query and response monitoring</p>
        </div>
        <div class="flex items-center space-x-3">
          <button
            type="button"
            phx-click="toggle_auto_refresh"
            class={[
              "inline-flex items-center px-4 py-2 rounded-lg transition-colors",
              if(@auto_refresh,
                do: "bg-green-600 text-white hover:bg-green-700",
                else: "bg-zinc-200 text-zinc-700 hover:bg-zinc-300"
              )
            ]}
          >
            <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <%= if @auto_refresh do %>
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 9v6m4-6v6m7-3a9 9 0 11-18 0 9 9 0 0118 0z" />
              <% else %>
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
              <% end %>
            </svg>
            <%= if @auto_refresh, do: "Auto-Refresh On", else: "Auto-Refresh Off" %>
          </button>
          <button
            type="button"
            phx-click="clear_cache"
            data-confirm="Are you sure you want to clear all cached data?"
            class="inline-flex items-center px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 transition-colors"
          >
            <svg class="w-5 h-5 mr-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
              />
            </svg>
            Clear Cache
          </button>
        </div>
      </div>
      <!-- Network Statistics -->
      <div class="grid grid-cols-1 md:grid-cols-5 gap-4">
        <div class="bg-white rounded-lg shadow p-4">
          <p class="text-sm text-zinc-500">Total Queries</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= @stats.total_queries %></p>
        </div>
        <div class="bg-white rounded-lg shadow p-4">
          <p class="text-sm text-zinc-500">Total Responses</p>
          <p class="mt-1 text-2xl font-semibold text-zinc-900"><%= @stats.total_responses %></p>
        </div>
        <div class="bg-white rounded-lg shadow p-4">
          <p class="text-sm text-zinc-500">Queries/Min</p>
          <p class="mt-1 text-2xl font-semibold text-blue-600">
            <%= Float.round(@stats.queries_per_minute, 1) %>
          </p>
        </div>
        <div class="bg-white rounded-lg shadow p-4">
          <p class="text-sm text-zinc-500">Unique Hosts</p>
          <p class="mt-1 text-2xl font-semibold text-purple-600"><%= @stats.unique_hosts %></p>
        </div>
        <div class="bg-white rounded-lg shadow p-4">
          <p class="text-sm text-zinc-500">Active Services</p>
          <p class="mt-1 text-2xl font-semibold text-green-600"><%= @stats.active_services %></p>
        </div>
      </div>
      <!-- Most Queried Services -->
      <%= if @stats.most_queried_services && length(@stats.most_queried_services) > 0 do %>
        <div class="bg-white rounded-lg shadow">
          <div class="px-6 py-4 border-b border-zinc-200">
            <h2 class="text-lg font-medium text-zinc-900">Most Queried Services</h2>
          </div>
          <div class="p-6">
            <div class="space-y-3">
              <div
                :for={service <- Enum.take(@stats.most_queried_services, 5)}
                class="flex items-center justify-between"
              >
                <div class="flex-1">
                  <p class="text-sm font-medium text-zinc-900"><%= elem(service, 0) %></p>
                  <div class="mt-1 w-full bg-zinc-200 rounded-full h-2">
                    <div
                      class="bg-blue-600 h-2 rounded-full"
                      style={"width: #{calculate_percentage(elem(service, 1), @stats.most_queried_services)}%"}
                    >
                    </div>
                  </div>
                </div>
                <div class="ml-4">
                  <span class="text-sm font-semibold text-zinc-900"><%= elem(service, 1) %></span>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>
      <!-- Query Log -->
      <div class="bg-white rounded-lg shadow">
        <div class="px-6 py-4 border-b border-zinc-200 flex items-center justify-between">
          <h2 class="text-lg font-medium text-zinc-900">Recent Queries</h2>
          <select phx-change="set_limit" name="limit" class="rounded-md border-zinc-300 text-sm">
            <option value="50" selected={@limit == 50}>50 queries</option>
            <option value="100" selected={@limit == 100}>100 queries</option>
            <option value="200" selected={@limit == 200}>200 queries</option>
            <option value="500" selected={@limit == 500}>500 queries</option>
          </select>
        </div>
        <div class="overflow-x-auto">
          <%= if Enum.empty?(@queries) do %>
            <div class="p-12 text-center">
              <svg
                class="mx-auto h-12 w-12 text-zinc-400"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
                />
              </svg>
              <h3 class="mt-2 text-sm font-medium text-zinc-900">No queries logged yet</h3>
              <p class="mt-1 text-sm text-zinc-500">
                mDNS queries will appear here as they are detected on the network
              </p>
            </div>
          <% else %>
            <table class="min-w-full divide-y divide-zinc-200">
              <thead class="bg-zinc-50">
                <tr>
                  <th
                    scope="col"
                    class="px-6 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider"
                  >
                    Time
                  </th>
                  <th
                    scope="col"
                    class="px-6 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider"
                  >
                    Source IP
                  </th>
                  <th
                    scope="col"
                    class="px-6 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider"
                  >
                    Query Name
                  </th>
                  <th
                    scope="col"
                    class="px-6 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider"
                  >
                    Type
                  </th>
                  <th
                    scope="col"
                    class="px-6 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider"
                  >
                    Class
                  </th>
                </tr>
              </thead>
              <tbody class="bg-white divide-y divide-zinc-200">
                <tr :for={query <- @queries} class="hover:bg-zinc-50">
                  <td class="px-6 py-4 whitespace-nowrap text-sm text-zinc-500">
                    <%= format_timestamp(query.timestamp) %>
                  </td>
                  <td class="px-6 py-4 whitespace-nowrap text-sm font-medium text-zinc-900">
                    <%= format_ip(query.source_ip) %>
                  </td>
                  <td class="px-6 py-4 text-sm text-zinc-900">
                    <%= query.name %>
                  </td>
                  <td class="px-6 py-4 whitespace-nowrap">
                    <span class="inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium bg-blue-100 text-blue-800">
                      <%= query.type %>
                    </span>
                  </td>
                  <td class="px-6 py-4 whitespace-nowrap text-sm text-zinc-500">
                    <%= query.class %>
                  </td>
                </tr>
              </tbody>
            </table>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp get_recent_queries(limit) do
    try do
      YellowDog.Mdns.get_recent_queries(limit: limit)
    rescue
      _ -> []
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
          queries_per_minute: 0.0,
          most_queried_services: []
        }
    end
  end

  defp format_timestamp(timestamp) when is_integer(timestamp) do
    datetime = DateTime.from_unix!(timestamp)
    Calendar.strftime(datetime, "%H:%M:%S")
  end

  defp format_timestamp(_), do: "Unknown"

  defp format_ip({a, b, c, d}) do
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp format_ip({a, b, c, d, e, f, g, h}) do
    parts = [a, b, c, d, e, f, g, h]
    hex_parts = Enum.map(parts, &Integer.to_string(&1, 16))
    Enum.join(hex_parts, ":")
  end

  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_), do: "Unknown"

  defp calculate_percentage(count, services) do
    max_count = services |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 1 end)
    if max_count > 0, do: count / max_count * 100, else: 0
  end
end
