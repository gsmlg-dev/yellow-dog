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
