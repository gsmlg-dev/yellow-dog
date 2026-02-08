defmodule YellowDog.Console.MdnsLive.MonitorLive do
  @moduledoc """
  LiveView for real-time monitoring of mDNS network activity.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.FormatHelper, only: [format_ip: 1, format_time: 1]
  import YellowDog.Console.ServiceHelper

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "mdns:monitor")
      # Refresh queries every 5 seconds
      :timer.send_interval(5_000, self(), :refresh)
    end

    {:ok,
     assign(socket,
       page_title: "Network Monitor",
       service_running: service_running?(YellowDog.Mdns),
       queries: get_recent_queries(50),
       stats: get_network_stats(),
       limit: 50,
       search: "",
       auto_refresh: true
     )}
  end

  @impl true
  def handle_event("set_limit", %{"limit" => limit}, socket) do
    case Integer.parse(limit) do
      {limit_int, ""} when limit_int > 0 ->
        {:noreply,
         socket
         |> assign(:limit, limit_int)
         |> assign(:queries, get_recent_queries(limit_int))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_auto_refresh", _params, socket) do
    {:noreply, assign(socket, :auto_refresh, !socket.assigns.auto_refresh)}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    csv = build_monitor_csv(socket.assigns.stats, socket.assigns.queries)
    timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")
    filename = "mdns_monitor_#{timestamp}.csv"
    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, assign(socket, :search, search)}
  end

  @impl true
  def handle_event("clear_cache", _params, socket) do
    try do
      YellowDog.Mdns.clear_cache()
      {:noreply, put_flash(socket, :info, "Cache cleared successfully")}
    catch
      _, _ ->
        {:noreply, put_flash(socket, :error, "mDNS service is not running")}
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

  @doc "Filters queries by search term against name, type, or source IP. Public for testability."
  def filtered_queries(queries, ""), do: queries

  def filtered_queries(queries, search) do
    term = String.downcase(search)

    Enum.filter(queries, fn query ->
      String.contains?(String.downcase(query.name || ""), term) or
        String.contains?(String.downcase(to_string(query.type)), term) or
        String.contains?(String.downcase(format_ip(query.source_ip)), term)
    end)
  end

  defp get_recent_queries(limit) do
    try do
      YellowDog.Mdns.get_recent_queries(limit: limit)
    catch
      :exit, _ -> []
      :error, _ -> []
    end
  end

  defp get_network_stats do
    default = %{
      total_responses: 0,
      total_queries: 0,
      active_services: 0,
      unique_hosts: 0,
      queries_per_minute: 0.0,
      most_queried_services: []
    }

    try do
      YellowDog.Mdns.network_stats()
    catch
      :exit, _ -> default
      :error, _ -> default
    end
  end

  defp format_timestamp(timestamp) when is_integer(timestamp) do
    timestamp |> DateTime.from_unix!() |> format_time()
  end

  defp format_timestamp(_), do: "Unknown"

  defp build_monitor_csv(stats, queries) do
    # Section 1: Network Statistics
    stats_section =
      "Network Statistics\n" <>
        "Metric,Value\n" <>
        "Total Queries,#{stats.total_queries}\n" <>
        "Total Responses,#{stats.total_responses}\n" <>
        "Queries/Min,#{Float.round(stats.queries_per_minute, 1)}\n" <>
        "Unique Hosts,#{stats.unique_hosts}\n" <>
        "Active Services,#{stats.active_services}\n"

    # Section 2: Most Queried Services
    services_section =
      if stats.most_queried_services && stats.most_queried_services != [] do
        "\nMost Queried Services\n" <>
          "Service,Query Count\n" <>
          Enum.map_join(stats.most_queried_services, "\n", fn {name, count} ->
            "#{csv_escape(name)},#{count}"
          end) <> "\n"
      else
        ""
      end

    # Section 3: Recent Queries
    queries_section =
      if Enum.any?(queries) do
        "\nRecent Queries\n" <>
          "Time,Source IP,Query Name,Type,Class\n" <>
          Enum.map_join(queries, "\n", fn query ->
            [
              csv_escape(format_timestamp(query.timestamp)),
              csv_escape(format_ip(query.source_ip)),
              csv_escape(query.name),
              csv_escape(to_string(query.type)),
              csv_escape(to_string(query.class))
            ]
            |> Enum.join(",")
          end) <> "\n"
      else
        ""
      end

    stats_section <> services_section <> queries_section
  end

  defp calculate_percentage(count, services) do
    max_count = Enum.reduce(services, 1, fn s, acc -> max(elem(s, 1), acc) end)
    if max_count > 0, do: count / max_count * 100, else: 0
  end
end
