defmodule YellowDog.ManagementUI.Redesign.Current.DnsLive.Index do
  @moduledoc "Management-backed DNS overview for one selected Server."

  use YellowDog.ManagementUI.Redesign, :live_view

  alias YellowDog.ManagementUI.Redesign.DnsLive.ManagementComponents
  alias YellowDog.ManagementUI.Redesign.DnsLive.ManagementSupport
  alias YellowDog.ManagementUI.Redesign.ServerManagement

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS Overview",
       subscribed_server_id: nil,
       views: [],
       metrics: %{"queries" => 0, "failures" => 0},
       management_error: nil,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_overview(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_overview(socket, ManagementSupport.selected_id(socket))}
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_overview(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_overview(socket, server_id) do
    views_result = Function.capture(ServerManagement, :dns_views_list, 1).(server_id)
    metrics_result = Function.capture(ServerManagement, :dns_metrics_get, 1).(server_id)
    results = [views_result, metrics_result]

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — DNS",
      views: ManagementSupport.items(views_result),
      metrics: ManagementSupport.value(metrics_result, %{"queries" => 0, "failures" => 0}),
      management_error: ManagementSupport.first_error(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(
          results,
          socket.assigns.selected_server.last_seen_at
        )
    )
  end
end
