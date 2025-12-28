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
      # Use ViewManager.list_views/0 which returns [{name, pid, priority}]
      views = YellowDog.Dns.ViewManager.list_views()

      Enum.map(views, fn {view_name, _pid, priority} ->
        %{
          name: view_name,
          priority: priority,
          zone_count: 0,
          acl_count: 0,
          enabled: true
        }
      end)
      |> Enum.sort_by(& &1.priority)
    rescue
      _ -> []
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
