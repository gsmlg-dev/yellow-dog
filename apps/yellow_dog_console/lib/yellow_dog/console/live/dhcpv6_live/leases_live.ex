defmodule YellowDog.Console.Dhcpv6Live.LeasesLive do
  @moduledoc "Management-backed DHCPv6 leases for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.DhcpLive.ManagementComponents
  alias YellowDog.Console.DhcpLive.ManagementSupport
  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @family :ipv6

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DHCPv6 Leases",
       subscribed_server_id: nil,
       family_label: ManagementSupport.family_label(@family),
       base_path: nil,
       service_running: false,
       all_leases: [],
       leases: [],
       search_query: "",
       filter_state: "all",
       commands_enabled?: false,
       management_error: nil,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket =
      socket
      |> ManagementSupport.subscribe(server_id)
      |> assign(:base_path, ServicePaths.server_path(server_id, :dhcpv6))

    {:noreply, if(connected?(socket), do: load_leases(socket), else: socket)}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> filter_leases()}
  end

  def handle_event("filter_state", %{"state" => state}, socket) do
    state = if state in ["all", "active", "released", "expired"], do: state, else: "all"
    {:noreply, socket |> assign(:filter_state, state) |> filter_leases()}
  end

  def handle_event("filter_ia_type", _params, socket), do: {:noreply, socket}
  def handle_event("filter_pool", _params, socket), do: {:noreply, socket}

  def handle_event("release_lease", %{"lease-id" => lease_id}, socket) do
    with :ok <- ManagementSupport.mutable(socket),
         lease when not is_nil(lease) <-
           ManagementSupport.find_lease(socket.assigns.all_leases, lease_id),
         opts when is_list(opts) <- ManagementSupport.command_options(lease.resource) do
      result =
        ServerManagement.dhcp_leases_release(
          socket.assigns.selected_server.id,
          %{"family" => ManagementSupport.family_wire(@family), "lease_id" => lease_id},
          opts
        )

      finish_release(socket, result, lease_id)
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
      nil -> {:noreply, put_flash(socket, :error, "Lease revision is unavailable")}
      _invalid -> {:noreply, put_flash(socket, :error, "Lease revision is unavailable")}
    end
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load_leases(socket)}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_leases()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns), do: ManagementComponents.leases(assigns)

  defp load_leases(socket) do
    server_id = socket.assigns.selected_server.id
    payload = %{"family" => ManagementSupport.family_wire(@family)}
    status = ServerManagement.dhcp_status_get(server_id, payload)
    leases_result = ServerManagement.dhcp_leases_list(server_id, payload)
    results = [status, leases_result]
    management_error = ManagementSupport.first_error(results)

    socket
    |> assign(
      page_title: "#{socket.assigns.selected_server.name || server_id} — DHCPv6 Leases",
      service_running: ManagementSupport.service_running?(status, @family),
      all_leases:
        leases_result
        |> ManagementSupport.items(@family)
        |> ManagementSupport.lease_views(),
      commands_enabled?:
        socket.assigns.service_online? and is_nil(management_error) and
          not ManagementSupport.cached?(results),
      management_error: management_error,
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at)
    )
    |> filter_leases()
  end

  defp filter_leases(socket) do
    assign(
      socket,
      :leases,
      ManagementSupport.filter_leases(
        socket.assigns.all_leases,
        socket.assigns.search_query,
        socket.assigns.filter_state
      )
    )
  end

  defp finish_release(socket, %ManagementResult{status: :ok}, lease_id) do
    {:noreply,
     socket
     |> assign(:all_leases, ManagementSupport.release_lease(socket.assigns.all_leases, lease_id))
     |> filter_leases()
     |> put_flash(:info, "Lease released successfully")}
  end

  defp finish_release(socket, %ManagementResult{status: :error, message: message}, _lease_id),
    do: {:noreply, put_flash(socket, :error, message)}
end
