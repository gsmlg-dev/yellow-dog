defmodule YellowDog.Console.MdnsLive.DiscoveryLive do
  @moduledoc "Management-backed mDNS discovery for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.MdnsLive.ManagementSupport
  alias YellowDog.Console.ServerManagement

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "mDNS Discovery",
       subscribed_server_id: nil,
       services: [],
       search: "",
       type_filter: "all",
       selected_service: nil,
       management_error: nil,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_discovery(socket), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_discovery(socket)}

  def handle_event("search", %{"search" => search}, socket),
    do: {:noreply, assign(socket, :search, search)}

  def handle_event("filter_by_type", %{"type" => type}, socket),
    do: {:noreply, assign(socket, :type_filter, type)}

  def handle_event("view_details", %{"name" => name}, socket) do
    service = Enum.find(socket.assigns.services, &(&1["name"] == name))
    {:noreply, assign(socket, :selected_service, service)}
  end

  def handle_event("close_details", _params, socket),
    do: {:noreply, assign(socket, :selected_service, nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_discovery()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_discovery(socket) do
    result = ServerManagement.mdns_discovery_list(socket.assigns.selected_server.id)

    case result do
      %ManagementResult{status: :ok, value: %{"items" => services}} when is_list(services) ->
        assign(socket,
          page_title:
            "#{socket.assigns.selected_server.name || socket.assigns.selected_server.id} — mDNS Discovery",
          services: services,
          management_error: nil,
          cached_observed_at: result.observed_at
        )

      %ManagementResult{status: :error} ->
        assign(socket, services: [], management_error: result)
    end
  end

  defp filtered_services(services, search, type_filter) do
    term = String.downcase(search)

    Enum.filter(services, fn service ->
      matches_search =
        term == "" or String.contains?(String.downcase(service["name"] || ""), term) or
          String.contains?(String.downcase(service["address"] || ""), term)

      matches_type = type_filter == "all" or service["service_type"] == type_filter
      matches_search and matches_type
    end)
  end

  defp service_types(services) do
    services
    |> Enum.map(& &1["service_type"])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
