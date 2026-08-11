defmodule YellowDog.Console.MdnsLive.Index do
  @moduledoc "Management-backed mDNS overview for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.MdnsLive.ManagementSupport
  alias YellowDog.Console.ServerManagement

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "mDNS",
       subscribed_server_id: nil,
       registered_count: 0,
       discovered_count: 0,
       cache_count: 0,
       management_error: nil,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_overview(socket), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load_overview(socket)}

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_overview()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_overview(socket) do
    server_id = socket.assigns.selected_server.id
    services = ServerManagement.mdns_services_list(server_id)
    discovery = ServerManagement.mdns_discovery_list(server_id)
    cache = ServerManagement.mdns_cache_get(server_id)
    results = [services, discovery, cache]

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — mDNS",
      registered_count: length(items(services)),
      discovered_count: length(items(discovery)),
      cache_count: length(cache_entries(cache)),
      management_error: first_error(results),
      cached_observed_at: latest_observed_at(results)
    )
  end

  defp items(%ManagementResult{status: :ok, value: %{"items" => items}}) when is_list(items),
    do: items

  defp items(_result), do: []

  defp cache_entries(%ManagementResult{status: :ok, value: %{"entries" => entries}})
       when is_list(entries),
       do: entries

  defp cache_entries(_result), do: []

  defp first_error(results) do
    Enum.find_value(results, fn
      %ManagementResult{status: :error, message: message} -> message
      _result -> nil
    end)
  end

  defp latest_observed_at(results) do
    results
    |> Enum.flat_map(fn
      %ManagementResult{observed_at: %DateTime{} = observed_at} -> [observed_at]
      _result -> []
    end)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end
end
