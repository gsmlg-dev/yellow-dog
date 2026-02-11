defmodule YellowDog.Console.MdnsLive.DiscoveryLive do
  @moduledoc """
  LiveView for browsing discovered services on the local network.
  """
  use YellowDog.Console, :live_view

  import YellowDog.Console.CsvHelper
  import YellowDog.Console.FormatHelper, only: [format_expiration: 1, format_time_ago: 1]
  import YellowDog.Console.ServiceHelper
  import YellowDog.Console.StringHelper, only: [downcase_contains?: 2]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "mdns:monitor")
      # Refresh discovered services every 10 seconds
      :timer.send_interval(10_000, self(), :refresh)
    end

    {:ok,
     assign(socket,
       page_title: "Network Discovery",
       service_running: service_running?(YellowDog.Mdns),
       services: list_discovered_services(),
       search: "",
       type_filter: "all",
       selected_service: nil
     )}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply,
     socket
     |> assign(:search, search)
     |> assign(:services, filter_services(search, socket.assigns.type_filter))}
  end

  @impl true
  def handle_event("filter_by_type", %{"type" => type}, socket) do
    {:noreply,
     socket
     |> assign(:type_filter, type)
     |> assign(:services, filter_services(socket.assigns.search, type))}
  end

  @impl true
  def handle_event("view_details", %{"id" => service_id}, socket) do
    service = YellowDog.Mdns.get_discovered_service(service_id)
    {:noreply, assign(socket, :selected_service, service)}
  end

  @impl true
  def handle_event("close_details", _params, socket) do
    {:noreply, assign(socket, :selected_service, nil)}
  end

  @impl true
  def handle_event("export_csv", _params, socket) do
    services = socket.assigns.services
    csv = build_csv(services)
    filename = "mdns_discovery_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}.csv"

    {:noreply, push_event(socket, "download_csv", %{content: csv, filename: filename})}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply,
     assign(socket, :services, filter_services(socket.assigns.search, socket.assigns.type_filter))}
  end

  @impl true
  def handle_info(:network_update, socket) do
    {:noreply,
     assign(socket, :services, filter_services(socket.assigns.search, socket.assigns.type_filter))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp list_discovered_services do
    safe_call(YellowDog.Mdns, fn -> YellowDog.Mdns.list_discovered_services() end, [])
  end

  defp filter_services(search, type_filter) do
    services = list_discovered_services()

    services
    |> filter_by_search(search)
    |> filter_by_type(type_filter)
  end

  defp filter_by_search(services, ""), do: services

  defp filter_by_search(services, search) do
    search_lower = String.downcase(search)

    Enum.filter(services, fn service ->
      downcase_contains?(service.name, search_lower) ||
        downcase_contains?(service.type, search_lower)
    end)
  end

  defp filter_by_type(services, "all"), do: services

  defp filter_by_type(services, type) do
    Enum.filter(services, fn service -> service.type == type end)
  end

  defp get_service_types(services) do
    services
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp count_unique_hosts(services) do
    for(s <- services, s.host != nil, into: MapSet.new(), do: s.host)
    |> MapSet.size()
  end

  defp get_most_recent_update(services) do
    Enum.reduce(services, 0, fn s, acc -> max(s.last_seen, acc) end)
  end

  defp build_csv(services) do
    header =
      "Service Name,Type,Host,Port,IP Addresses,TXT Records,Last Seen\r\n"

    rows =
      Enum.map_join(services, "\r\n", fn service ->
        [
          csv_escape(service.name),
          csv_escape(service.type),
          csv_escape(service.host || ""),
          csv_escape(to_string(service.port || "")),
          csv_escape(format_addresses_for_csv(service.addresses)),
          csv_escape(format_txt_for_csv(service.txt)),
          csv_escape(format_expiration(service.last_seen))
        ]
        |> Enum.join(",")
      end)

    header <> rows
  end
end
