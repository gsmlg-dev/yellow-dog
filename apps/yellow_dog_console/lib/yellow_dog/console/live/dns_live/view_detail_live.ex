defmodule YellowDog.Console.DnsLive.ViewDetailLive do
  @moduledoc """
  DNS View detail page showing view configuration and zones.
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Dns.View
  alias YellowDog.Dns.ViewManager

  @impl true
  def mount(%{"view_name" => view_name}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:views")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:zones")
    end

    case get_view_details(view_name) do
      {:ok, view} ->
        {:ok,
         socket
         |> assign(:page_title, "View: #{view_name}")
         |> assign(:view_name, view_name)
         |> assign(:view, view)}

      :error ->
        {:ok,
         socket
         |> assign(:page_title, "View Not Found")
         |> assign(:view_name, view_name)
         |> assign(:view, nil)
         |> put_flash(:error, "View '#{view_name}' not found")}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    case get_view_details(socket.assigns.view_name) do
      {:ok, view} ->
        {:noreply, assign(socket, :view, view)}

      :error ->
        {:noreply, put_flash(socket, :error, "View no longer exists")}
    end
  end

  @impl true
  def handle_info({:view_updated, view_name}, socket) do
    if view_name == socket.assigns.view_name do
      case get_view_details(view_name) do
        {:ok, view} -> {:noreply, assign(socket, :view, view)}
        :error -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:zone_updated, _zone_name}, socket) do
    case get_view_details(socket.assigns.view_name) do
      {:ok, view} -> {:noreply, assign(socket, :view, view)}
      :error -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp get_view_details(view_name) do
    try do
      case ViewManager.get_view(view_name) do
        {:ok, pid} ->
          stats = View.stats(pid)

          view = %{
            name: view_name,
            pid: pid,
            priority: Map.get(stats, :priority, 100),
            recursion_enabled: Map.get(stats, :recursion_enabled, false),
            ecs_enabled: Map.get(stats, :ecs_enabled, false),
            zones: get_zones_with_details(stats),
            rpz_zones: Map.get(stats, :rpz_zones, []),
            query_count: Map.get(stats, :query_count, 0),
            hit_count: Map.get(stats, :hit_count, 0),
            miss_count: Map.get(stats, :miss_count, 0),
            cache_size: Map.get(stats, :cache_size, 0)
          }

          {:ok, view}

        :error ->
          :error
      end
    rescue
      _ -> :error
    end
  end

  defp get_zones_with_details(stats) do
    zones_config = Map.get(stats, :zones, [])

    Enum.map(zones_config, fn
      {type, name} ->
        zone_stats = get_zone_stats(type, name)
        Map.merge(%{type: type, name: name}, zone_stats)

      name when is_binary(name) ->
        %{type: :unknown, name: name, record_count: 0, query_count: 0}
    end)
  end

  defp get_zone_stats(type, name) do
    try do
      case YellowDog.Dns.ZoneController.find_zone(type, name) do
        {:ok, pid} ->
          module = zone_module(type)
          stats = module.stats(pid)

          %{
            record_count: Map.get(stats, :record_count, 0),
            query_count: Map.get(stats, :query_count, 0),
            hit_count: Map.get(stats, :hit_count, 0),
            miss_count: Map.get(stats, :miss_count, 0)
          }

        :error ->
          %{record_count: 0, query_count: 0, hit_count: 0, miss_count: 0}
      end
    rescue
      _ -> %{record_count: 0, query_count: 0, hit_count: 0, miss_count: 0}
    end
  end

  defp zone_module(:auth), do: YellowDog.Dns.Zone.Auth
  defp zone_module(:forward), do: YellowDog.Dns.Zone.Forward
  defp zone_module(:stub), do: YellowDog.Dns.Zone.Stub
  defp zone_module(:cache), do: YellowDog.Dns.Zone.Cache
  defp zone_module(_), do: YellowDog.Dns.Zone.Auth

  defp zone_type_badge(:auth), do: "primary"
  defp zone_type_badge(:forward), do: "secondary"
  defp zone_type_badge(:stub), do: "accent"
  defp zone_type_badge(:cache), do: "info"
  defp zone_type_badge(_), do: "ghost"

  defp zone_type_label(:auth), do: "Authoritative"
  defp zone_type_label(:forward), do: "Forward"
  defp zone_type_label(:stub), do: "Stub"
  defp zone_type_label(:cache), do: "Cache"
  defp zone_type_label(_), do: "Unknown"

  defp calculate_hit_rate(hits, misses) do
    total = hits + misses

    if total > 0 do
      round(hits / total * 100)
    else
      0
    end
  end
end
