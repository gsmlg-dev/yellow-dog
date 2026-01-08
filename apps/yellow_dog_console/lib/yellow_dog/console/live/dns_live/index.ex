defmodule YellowDog.Console.DnsLive.Index do
  @moduledoc """
  DNS overview page showing views as the primary navigation.

  DNS data hierarchy:
  - View (ACL, recursion enable/disable)
    - Zone (auth, forward, stub, cache)
      - Resource Records
  """
  use YellowDog.Console, :live_view

  alias YellowDog.Dns.View

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:views")
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "dns:zones")
    end

    {:ok,
     socket
     |> assign(:page_title, "DNS Service")
     |> assign(:status, get_dns_status())
     |> assign(:views, list_views_with_zones())
     |> assign(:expanded_view, nil)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> assign(:status, get_dns_status())
     |> assign(:views, list_views_with_zones())}
  end

  @impl true
  def handle_event("toggle_view", %{"view" => view_name}, socket) do
    expanded =
      if socket.assigns.expanded_view == view_name do
        nil
      else
        view_name
      end

    {:noreply, assign(socket, :expanded_view, expanded)}
  end

  @impl true
  def handle_info({:view_updated, _view_name}, socket) do
    {:noreply, assign(socket, :views, list_views_with_zones())}
  end

  @impl true
  def handle_info({:zone_updated, _zone_name}, socket) do
    {:noreply, assign(socket, :views, list_views_with_zones())}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp get_dns_status do
    try do
      YellowDog.Dns.status()
    rescue
      _ -> %{running: false, info: "DNS service not running"}
    end
  end

  defp list_views_with_zones do
    try do
      views = YellowDog.Dns.ViewManager.list_views()

      Enum.map(views, fn {view_name, pid, priority} ->
        stats = View.stats(pid)

        %{
          name: view_name,
          pid: pid,
          priority: priority,
          recursion_enabled: Map.get(stats, :recursion_enabled, false),
          ecs_enabled: Map.get(stats, :ecs_enabled, false),
          zones: get_view_zones(stats),
          query_count: Map.get(stats, :query_count, 0),
          hit_count: Map.get(stats, :hit_count, 0),
          miss_count: Map.get(stats, :miss_count, 0),
          cache_size: Map.get(stats, :cache_size, 0)
        }
      end)
      |> Enum.sort_by(& &1.priority)
    rescue
      _ -> []
    end
  end

  defp get_view_zones(stats) do
    zones_config = Map.get(stats, :zones, [])

    # zones can be [{type, name}] or [name]
    Enum.map(zones_config, fn
      {type, name} -> %{type: type, name: name}
      name when is_binary(name) -> %{type: :unknown, name: name}
    end)
  end

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

  defp total_zones(views) do
    Enum.sum(Enum.map(views, fn v -> length(v.zones) end))
  end

  defp total_queries(views) do
    Enum.sum(Enum.map(views, fn v -> v.query_count end))
  end
end
