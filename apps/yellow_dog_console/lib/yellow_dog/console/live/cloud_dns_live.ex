defmodule YellowDog.Console.CloudDnsLive do
  @moduledoc "Legacy management-backed DNS provider page for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.DnsLive.ManagementComponents
  alias YellowDog.Console.DnsLive.ManagementSupport
  alias YellowDog.Console.ServerManagement

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Cloud DNS",
       subscribed_server_id: nil,
       providers: [],
       management_error: nil,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_providers(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_providers(socket, ManagementSupport.selected_id(socket))}
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_providers(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="server-cloud-dns">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <ManagementComponents.page_header
            title="Cloud DNS"
            subtitle="Legacy provider entry point"
            server={@selected_server}
            online?={@service_online?}
            back={ServicePaths.server_path(@selected_server.id, :dns)}
          />
          <div class="flex gap-2">
            <.link
              navigate={ServicePaths.server_path(@selected_server.id, :dns_providers)}
              class="btn btn-primary btn-sm"
            >
              Manage providers
            </.link>
            <button phx-click="refresh" class="btn btn-ghost btn-sm">Refresh</button>
          </div>
        </div>

        <ManagementComponents.offline_snapshot
          :if={not @service_online?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error
          :if={ManagementSupport.error_result?(@management_error)}
          result={@management_error}
        />

        <.card title="Selected Server providers">
          <p :if={@providers == []} class="text-sm text-on-surface-variant">
            No providers reported.
          </p>
          <div
            :for={provider <- @providers}
            class="flex items-center justify-between gap-3 border-b border-outline-variant py-3 last:border-0"
          >
            <div>
              <div class="font-semibold">{provider["provider_id"]}</div>
              <div class="text-xs text-on-surface-variant">{provider["provider_type"]}</div>
            </div>
            <.link
              navigate={
                ServicePaths.server_path(
                  @selected_server.id,
                  {:dns_provider, provider["provider_id"]}
                )
              }
              class="btn btn-ghost btn-xs"
            >
              Details
            </.link>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp load_providers(socket, server_id) do
    result = ServerManagement.dns_providers_list(server_id)

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — Cloud DNS",
      providers: ManagementSupport.items(result),
      management_error: if(ManagementSupport.error_result?(result), do: result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(
          [result],
          socket.assigns.selected_server.last_seen_at
        )
    )
  end
end
