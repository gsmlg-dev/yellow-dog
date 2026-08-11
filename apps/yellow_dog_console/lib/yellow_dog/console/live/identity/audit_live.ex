defmodule YellowDog.Console.IdentityLive.AuditLive do
  @moduledoc "Management-backed Identity audit for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.IdentityLive.ManagementComponents
  alias YellowDog.Console.IdentityLive.ManagementSupport
  alias YellowDog.Console.Layouts
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Identity Audit",
       subscribed_server_id: nil,
       audit_entries: [],
       management_error: nil,
       cached_snapshot?: false,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_audit(socket, server_id), else: socket)}
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_audit(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="identity-audit" class="space-y-6">
        <ManagementComponents.page_header
          title="Identity Audit"
          subtitle="Runtime audit snapshot"
          server={@selected_server}
          online?={@service_online?}
          back={ServicePaths.server_path(@selected_server.id, :identity)}
        />

        <ManagementComponents.offline_snapshot
          :if={@cached_snapshot?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error :if={@management_error} result={@management_error} />

        <.card>
          <div
            :if={@audit_entries == [] and is_nil(@management_error)}
            class="text-on-surface-variant"
          >
            No audit entries in this Server snapshot
          </div>
          <div
            :for={entry <- @audit_entries}
            class="grid grid-cols-1 gap-2 border-b border-outline-variant py-3 last:border-0 sm:grid-cols-3"
          >
            <div class="font-semibold">{entry["action"]}</div>
            <.link
              navigate={
                ServicePaths.server_path(@selected_server.id, {:identity_host, entry["subject_id"]})
              }
              class="link link-primary font-mono text-sm"
            >
              {entry["subject_id"]}
            </.link>
            <time class="text-sm text-on-surface-variant">{entry["occurred_at"]}</time>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp load_audit(socket, server_id) do
    result = ServerManagement.identity_audit_list(server_id)

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — Identity Audit",
      audit_entries: ManagementSupport.items(result),
      management_error: ManagementSupport.error(result),
      cached_snapshot?: ManagementSupport.cached?(result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(result, socket.assigns.selected_server.last_seen_at)
    )
  end
end
