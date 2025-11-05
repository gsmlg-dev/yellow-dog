defmodule YellowDog.Console.DnsLive.ZonesLive do
  @moduledoc """
  DNS zones management page showing all loaded zones and their statistics.
  """
  use YellowDog.Console, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:zones")
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS Zones")
     |> assign(:zones, list_zones())
     |> assign(:filter, "")}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :zones, list_zones())}
  end

  @impl true
  def handle_info({:zone_loaded, _zone_name}, socket) do
    {:noreply,
     socket
     |> assign(:zones, list_zones())
     |> put_flash(:info, "Zone reloaded")}
  end

  @impl true
  def handle_info({:zone_updated, _zone_name}, socket) do
    {:noreply, assign(socket, :zones, list_zones())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
        <div>
          <h1 class="text-4xl font-bold">DNS Zones</h1>
          <p class="mt-2 text-base-content/70">Manage loaded DNS zones and records</p>
        </div>
        <button phx-click="refresh" class="btn btn-primary gap-2">
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
          Refresh
        </button>
      </div>
      <!-- Summary Stats -->
      <div class="stats stats-vertical lg:stats-horizontal shadow-xl w-full">
        <div class="stat">
          <div class="stat-figure text-primary">
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
                d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
              />
            </svg>
          </div>
          <div class="stat-title">Total Zones</div>
          <div class="stat-value text-primary"><%= length(@zones) %></div>
        </div>
        <div class="stat">
          <div class="stat-figure text-success">
            <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
              />
            </svg>
          </div>
          <div class="stat-title">Total Records</div>
          <div class="stat-value text-success"><%= total_records(@zones) %></div>
        </div>
        <div class="stat">
          <div class="stat-figure text-info">
            <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M4 7v10c0 2.21 3.582 4 8 4s8-1.79 8-4V7M4 7c0 2.21 3.582 4 8 4s8-1.79 8-4M4 7c0-2.21 3.582-4 8-4s8 1.79 8 4"
              />
            </svg>
          </div>
          <div class="stat-title">Memory Usage</div>
          <div class="stat-value text-info"><%= total_memory(@zones) %></div>
        </div>
      </div>
      <!-- Filter Input -->
      <div class="form-control">
        <label class="input-group">
          <span class="bg-base-300">
            <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
              />
            </svg>
          </span>
          <input
            type="text"
            placeholder="Filter zones by name..."
            class="input input-bordered w-full"
            phx-change="filter"
            name="filter"
            value={@filter}
          />
        </label>
      </div>
      <!-- Zones Table -->
      <.card title="Zones" class="overflow-x-auto">
        <.table id="zones" rows={filtered_zones(@zones, @filter)} zebra hover>
          <:col :let={zone} label="Zone Name">
            <div class="font-mono font-semibold"><%= zone.name %></div>
          </:col>
          <:col :let={zone} label="Record Count">
            <.badge size="lg" color="primary"><%= zone.record_count %></.badge>
          </:col>
          <:col :let={zone} label="Memory">
            <.badge size="lg" color="info"><%= format_memory(zone.memory_mb) %></.badge>
          </:col>
          <:col :let={zone} label="Status">
            <.status_indicator status="running" label="Loaded" />
          </:col>
          <:action :let={zone}>
            <button class="btn btn-ghost btn-sm gap-2" title="View Details">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                />
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
                />
              </svg>
              View
            </button>
          </:action>
        </.table>

        <%= if filtered_zones(@zones, @filter) == [] do %>
          <div class="text-center py-12">
            <svg
              class="mx-auto h-12 w-12 text-base-content/30"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
              />
            </svg>
            <h3 class="mt-2 text-sm font-medium">No zones found</h3>
            <p class="mt-1 text-sm text-base-content/60">
              <%= if @filter != "" do %>
                No zones match your filter criteria.
              <% else %>
                No zones are currently loaded.
              <% end %>
            </p>
          </div>
        <% end %>
      </.card>
    </div>
    """
  end

  defp list_zones do
    try do
      case YellowDog.Dns.Zone.Manager.list_zones() do
        {:ok, zone_names} ->
          Enum.map(zone_names, fn zone_name ->
            stats =
              case YellowDog.Dns.Zone.Storage.get_zone_stats(zone_name) do
                {:ok, zone_stats} -> zone_stats
                {:error, _} -> %{record_count: 0, memory_bytes: 0}
              end

            %{
              name: zone_name,
              record_count: Map.get(stats, :record_count, 0),
              memory_mb:
                Map.get(stats, :memory_bytes, 0) |> then(&(&1 / 1_024 / 1_024)) |> Float.round(2)
            }
          end)

        {:error, _} ->
          []
      end
    rescue
      _ -> []
    end
  end

  defp filtered_zones(zones, filter) when filter == "" or is_nil(filter), do: zones

  defp filtered_zones(zones, filter) do
    filter_lower = String.downcase(filter)

    Enum.filter(zones, fn zone ->
      zone.name |> String.downcase() |> String.contains?(filter_lower)
    end)
  end

  defp total_records(zones), do: Enum.sum(Enum.map(zones, & &1.record_count))

  defp total_memory(zones) do
    total_mb = Enum.sum(Enum.map(zones, & &1.memory_mb)) |> Float.round(2)
    "#{total_mb} MB"
  end

  defp format_memory(mb) when is_float(mb), do: "#{:erlang.float_to_binary(mb, decimals: 2)} MB"
  defp format_memory(mb) when is_integer(mb), do: "#{mb} MB"
  defp format_memory(_), do: "0 MB"
end
