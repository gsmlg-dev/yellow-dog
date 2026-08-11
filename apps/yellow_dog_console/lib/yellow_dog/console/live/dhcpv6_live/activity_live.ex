defmodule YellowDog.Console.Dhcpv6Live.ActivityLive do
  @moduledoc "Management-backed DHCPv6 activity for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.DhcpLive.ManagementComponents
  alias YellowDog.Console.DhcpLive.ManagementSupport
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @family :ipv6
  @error_types ~w(error allocation_failed invalid rate_limited renew_failed rebind_failed)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DHCPv6 Activity",
       subscribed_server_id: nil,
       family_label: ManagementSupport.family_label(@family),
       base_path: nil,
       all_entries: [],
       entries: [],
       search_query: "",
       filter_type: "all",
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

    {:noreply, if(connected?(socket), do: load_activity(socket), else: socket)}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply, socket |> assign(:search_query, query) |> filter_activity()}
  end

  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, socket |> assign(:filter_type, type) |> filter_activity()}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load_activity(socket)}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_activity()}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns), do: ManagementComponents.activity(assigns)

  @doc false
  def filtered_entries(entries, search, type_filter) do
    entries
    |> filter_by_type(type_filter)
    |> filter_by_search(search)
  end

  defp load_activity(socket) do
    server_id = socket.assigns.selected_server.id
    payload = %{"family" => ManagementSupport.family_wire(@family)}
    status = ServerManagement.dhcp_status_get(server_id, payload)
    activity_result = ServerManagement.dhcp_activity_list(server_id, payload)
    results = [status, activity_result]

    socket
    |> assign(
      page_title: "#{socket.assigns.selected_server.name || server_id} — DHCPv6 Activity",
      all_entries:
        activity_result
        |> ManagementSupport.items(@family)
        |> ManagementSupport.activity_views(),
      management_error: ManagementSupport.first_error(results),
      cached_observed_at:
        ManagementSupport.cached_observed_at(results, socket.assigns.selected_server.last_seen_at)
    )
    |> filter_activity()
  end

  defp filter_activity(socket) do
    assign(
      socket,
      :entries,
      filtered_entries(
        socket.assigns.all_entries,
        socket.assigns.search_query,
        socket.assigns.filter_type
      )
    )
  end

  defp filter_by_type(entries, "all"), do: entries

  defp filter_by_type(entries, "error") do
    Enum.filter(entries, &(entry_type(&1) in @error_types))
  end

  defp filter_by_type(entries, type) do
    if known_type?(entries, type) do
      Enum.filter(entries, &(entry_type(&1) == type))
    else
      entries
    end
  end

  defp filter_by_search(entries, ""), do: entries

  defp filter_by_search(entries, query) do
    query = String.downcase(query)

    Enum.filter(entries, fn entry ->
      [:client_duid, :client_ip, :details, :activity_id, :action]
      |> Enum.map(&Map.get(entry, &1))
      |> Enum.any?(&contains?(&1, query))
    end)
  end

  defp known_type?(entries, type) do
    type in ~w(solicit advertise request reply renew rebind release decline inform lease_granted lease_renewed lease_released lease_expired) or
      Enum.any?(entries, &(entry_type(&1) == type))
  end

  defp entry_type(entry) do
    entry
    |> Map.get(:type, Map.get(entry, :action))
    |> to_string()
  end

  defp contains?(nil, _query), do: false

  defp contains?(value, query),
    do: value |> to_string() |> String.downcase() |> String.contains?(query)
end
