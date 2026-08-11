defmodule YellowDog.Console.Dhcpv6Live.Index do
  @moduledoc "Management-backed DHCPv6 overview for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.DhcpLive.ManagementComponents
  alias YellowDog.Console.DhcpLive.ManagementSupport
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @family :ipv6

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DHCPv6 Overview",
       subscribed_server_id: nil,
       family_label: ManagementSupport.family_label(@family),
       base_path: nil,
       leases_path: nil,
       pools_path: nil,
       activity_path: nil,
       service_running: false,
       pools: [],
       leases: [],
       activities: [],
       management_error: nil,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket =
      socket
      |> ManagementSupport.subscribe(server_id)
      |> assign_paths(server_id)

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

  @impl true
  def render(assigns), do: ManagementComponents.overview(assigns)

  defp load_overview(socket) do
    server_id = socket.assigns.selected_server.id
    payload = %{"family" => ManagementSupport.family_wire(@family)}
    status = ServerManagement.dhcp_status_get(server_id, payload)
    pools = ServerManagement.dhcp_pools_list(server_id, payload)
    leases = ServerManagement.dhcp_leases_list(server_id, payload)
    activity = ServerManagement.dhcp_activity_list(server_id, payload)
    results = [status, pools, leases, activity]

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — DHCPv6",
      service_running: ManagementSupport.service_running?(status, @family),
      pools: pools |> ManagementSupport.items(@family) |> ManagementSupport.pool_views(),
      leases: leases |> ManagementSupport.items(@family) |> ManagementSupport.lease_views(),
      activities:
        activity |> ManagementSupport.items(@family) |> ManagementSupport.activity_views(),
      management_error: ManagementSupport.first_error(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at)
    )
  end

  defp assign_paths(socket, server_id) do
    assign(socket,
      base_path: ServicePaths.server_path(server_id, :dhcpv6),
      leases_path: ServicePaths.server_path(server_id, :dhcpv6_leases),
      pools_path: ServicePaths.server_path(server_id, :dhcpv6_pools),
      activity_path: ServicePaths.server_path(server_id, :dhcpv6_activity)
    )
  end
end
