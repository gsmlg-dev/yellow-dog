defmodule YellowDog.Console.DnsLive.ProviderLive.ConflictLive do
  @moduledoc "Management-backed DNS provider conflict status for one selected Server."

  use YellowDog.Console, :live_view

  import YellowDog.Console.DnsLive.ManagementComponents, only: [input: 1]

  alias YellowDog.Console.DnsLive.ManagementComponents
  alias YellowDog.Console.DnsLive.ManagementSupport
  alias YellowDog.Console.ServerManagement

  @unavailable_message "Conflict resolution is unavailable because its revision is not exposed by the management API"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS Provider Conflicts",
       subscribed_server_id: nil,
       provider_id: nil,
       provider: nil,
       conflict_form:
         to_form(%{"conflict_id" => "", "resolution" => "use_local"}, as: "conflict"),
       management_error: nil,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id, "name" => provider_id}, _uri, socket) do
    socket =
      socket
      |> ManagementSupport.subscribe(server_id)
      |> assign(:provider_id, provider_id)

    {:noreply, if(connected?(socket), do: load_provider(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_provider(socket, ManagementSupport.selected_id(socket))}
  end

  def handle_event("resolve_conflict", _params, socket) do
    {:noreply, put_flash(socket, :error, @unavailable_message)}
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_provider(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_provider(socket, server_id) do
    result = ServerManagement.dns_providers_list(server_id)

    provider =
      result
      |> ManagementSupport.items()
      |> Enum.find(&(&1["provider_id"] == socket.assigns.provider_id))

    assign(socket,
      page_title:
        "#{socket.assigns.selected_server.name || server_id} — #{socket.assigns.provider_id} conflicts",
      provider: provider,
      management_error: if(ManagementSupport.error_result?(result), do: result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(
          [result],
          socket.assigns.selected_server.last_seen_at
        )
    )
  end
end
