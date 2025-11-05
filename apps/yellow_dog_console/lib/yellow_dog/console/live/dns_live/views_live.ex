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
