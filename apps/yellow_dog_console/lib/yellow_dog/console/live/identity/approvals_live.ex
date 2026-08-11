defmodule YellowDog.Console.IdentityLive.ApprovalsLive do
  @moduledoc "Read-only management view of Identity approvals for one selected Server."

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
       page_title: "Identity Approvals",
       subscribed_server_id: nil,
       approvals: [],
       management_error: nil,
       cached_snapshot?: false,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_approvals(socket, server_id), else: socket)}
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_approvals(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="identity-approvals" class="space-y-6">
        <ManagementComponents.page_header
          title="Identity Approvals"
          subtitle="Read-only management owner"
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
          <div :if={@approvals == [] and is_nil(@management_error)} class="text-on-surface-variant">
            No approvals in this Server snapshot
          </div>
          <div
            :for={approval <- @approvals}
            class="flex items-center justify-between border-b border-outline-variant py-3 last:border-0"
          >
            <div>
              <div class="font-mono">{approval["host_id"]}</div>
              <div class="text-sm text-on-surface-variant">{approval["approval_id"]}</div>
            </div>
            <.badge color={state_color(approval["state"])}>{approval["state"]}</.badge>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp load_approvals(socket, server_id) do
    result = ServerManagement.identity_approvals_list(server_id)

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — Identity Approvals",
      approvals: ManagementSupport.items(result),
      management_error: ManagementSupport.error(result),
      cached_snapshot?: ManagementSupport.cached?(result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(result, socket.assigns.selected_server.last_seen_at)
    )
  end

  defp state_color("approved"), do: "success"
  defp state_color("pending"), do: "warning"
  defp state_color("revoked"), do: "error"
  defp state_color(_state), do: "ghost"
end
