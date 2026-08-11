defmodule YellowDog.Console.Dhcpv4Live.PoolLive do
  @moduledoc "Management-backed DHCPv4 pool details for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.DhcpLive.ManagementComponents
  alias YellowDog.Console.DhcpLive.ManagementSupport
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @family :ipv4

  @impl true
  def mount(%{"pool_name" => pool_name}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DHCPv4 Pool: #{pool_name}",
       subscribed_server_id: nil,
       family_label: ManagementSupport.family_label(@family),
       pool_name: pool_name,
       pools_path: nil,
       pool: nil,
       management_error: nil,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id, "pool_name" => pool_name}, _uri, socket) do
    socket =
      socket
      |> ManagementSupport.subscribe(server_id)
      |> assign(
        pool_name: pool_name,
        pools_path: ServicePaths.server_path(server_id, :dhcpv4_pools)
      )

    {:noreply, if(connected?(socket), do: load_pool(socket), else: socket)}
  end

  @impl true
  def handle_event("search", _params, socket), do: {:noreply, socket}
  def handle_event("filter_state", _params, socket), do: {:noreply, socket}

  def handle_event("release_lease", _params, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Pool-scoped lease revision is unavailable; no command was sent"
     )}
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_pool()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns), do: ManagementComponents.pool(assigns)

  defp load_pool(socket) do
    server_id = socket.assigns.selected_server.id
    payload = %{"family" => ManagementSupport.family_wire(@family)}
    status = ServerManagement.dhcp_status_get(server_id, payload)
    pools_result = ServerManagement.dhcp_pools_list(server_id, payload)
    pools = pools_result |> ManagementSupport.items(@family) |> ManagementSupport.pool_views()
    results = [status, pools_result]

    assign(socket,
      page_title:
        "#{socket.assigns.selected_server.name || server_id} — #{socket.assigns.pool_name}",
      pool: ManagementSupport.find_pool(pools, socket.assigns.pool_name),
      management_error: ManagementSupport.first_error(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at)
    )
  end
end
