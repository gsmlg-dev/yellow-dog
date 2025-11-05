defmodule YellowDog.Console.DnsLive.ViewsLive do
  @moduledoc """
  DNS Views management page showing configured views and their settings.
  """
  use YellowDog.Console, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:views")
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS Views")
     |> assign(:views, list_views())
     |> assign(:filter, "")}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :views, list_views())}
  end

  @impl true
  def handle_info({:view_updated, _view_name}, socket) do
    {:noreply, assign(socket, :views, list_views())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
        <div>
          <h1 class="text-4xl font-bold">DNS Views</h1>
          <p class="mt-2 text-base-content/70">
            Configure DNS views for different client perspectives
          </p>
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
                d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
              />
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
              />
            </svg>
          </div>
          <div class="stat-title">Total Views</div>
          <div class="stat-value text-primary"><%= length(@views) %></div>
        </div>
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
          <div class="stat-title">Active Views</div>
          <div class="stat-value text-success"><%= count_active(@views) %></div>
        </div>
        <div class="stat">
          <div class="stat-figure text-info">
            <svg class="w-8 h-8" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
              />
            </svg>
          </div>
          <div class="stat-title">Total Zones</div>
          <div class="stat-value text-info"><%= total_zones(@views) %></div>
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
            placeholder="Filter views by name..."
            class="input input-bordered w-full"
            phx-change="filter"
            name="filter"
            value={@filter}
          />
        </label>
      </div>
      <!-- Views Table -->
      <.card title="Configured Views" class="overflow-x-auto">
        <.table id="views" rows={filtered_views(@views, @filter)} zebra hover>
          <:col :let={view} label="View Name">
            <div class="font-mono font-semibold"><%= view.name %></div>
          </:col>
          <:col :let={view} label="Priority">
            <.badge size="lg" color="primary"><%= view.priority %></.badge>
          </:col>
          <:col :let={view} label="Zones">
            <.badge size="lg" color="success"><%= view.zone_count %></.badge>
          </:col>
          <:col :let={view} label="ACL Rules">
            <.badge size="lg" color="info"><%= view.acl_count %></.badge>
          </:col>
          <:col :let={view} label="Status">
            <.status_indicator status={if view.enabled, do: "running", else: "stopped"} label={
              if view.enabled, do: "Enabled", else: "Disabled"
            } />
          </:col>
          <:action :let={_view}>
            <button class="btn btn-ghost btn-sm gap-2" title="View Details">
              <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
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
              Configure
            </button>
          </:action>
        </.table>

        <%= if filtered_views(@views, @filter) == [] do %>
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
                d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
              />
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
              />
            </svg>
            <h3 class="mt-2 text-sm font-medium">No views found</h3>
            <p class="mt-1 text-sm text-base-content/60">
              <%= if @filter != "" do %>
                No views match your filter criteria.
              <% else %>
                No views are currently configured.
              <% end %>
            </p>
          </div>
        <% end %>
      </.card>
      <!-- About Views -->
      <.card title="About DNS Views">
        <div class="prose max-w-none">
          <p>
            DNS Views allow you to serve different DNS responses to different clients based on their network location or other criteria. This is useful for:
          </p>
          <ul class="list-disc list-inside space-y-1 ml-4">
            <li>Split-horizon DNS (internal vs. external views)</li>
            <li>Geographic load balancing</li>
            <li>Network segregation</li>
            <li>Development and staging environments</li>
          </ul>
          <p class="mt-4">
            Each view has a priority, zones, and ACL rules that determine which clients can access it. Views are evaluated in priority order, with lower numbers having higher priority.
          </p>
        </div>
      </.card>
    </div>
    """
  end

  defp list_views do
    try do
      case YellowDog.Dns.View.Manager.get_views() do
        {:ok, views} ->
          Enum.map(views, fn {view_name, view_config} ->
            %{
              name: view_name,
              priority: Map.get(view_config, :priority, 100),
              zone_count: count_zones(view_config),
              acl_count: count_acl_rules(view_config),
              enabled: Map.get(view_config, :enabled, true)
            }
          end)
          |> Enum.sort_by(& &1.priority)

        {:error, _} ->
          []
      end
    rescue
      _ -> []
    end
  end

  defp count_zones(view_config) do
    case Map.get(view_config, :zones) do
      zones when is_list(zones) -> length(zones)
      zones when is_map(zones) -> map_size(zones)
      _ -> 0
    end
  end

  defp count_acl_rules(view_config) do
    case Map.get(view_config, :match_clients) do
      rules when is_list(rules) -> length(rules)
      _ -> 0
    end
  end

  defp filtered_views(views, filter) when filter == "" or is_nil(filter), do: views

  defp filtered_views(views, filter) do
    filter_lower = String.downcase(filter)

    Enum.filter(views, fn view ->
      view.name |> to_string() |> String.downcase() |> String.contains?(filter_lower)
    end)
  end

  defp count_active(views), do: Enum.count(views, & &1.enabled)

  defp total_zones(views), do: Enum.sum(Enum.map(views, & &1.zone_count))
end
