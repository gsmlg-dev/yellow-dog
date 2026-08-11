defmodule YellowDog.Console.IdentityLive.HostsLive do
  @moduledoc "Management-backed Identity hosts for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.IdentityLive.ManagementComponents
  alias YellowDog.Console.IdentityLive.ManagementSupport
  alias YellowDog.Console.Layouts
  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Identity Hosts",
       subscribed_server_id: nil,
       hosts: [],
       management_error: nil,
       cached_snapshot?: false,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_hosts(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_hosts(socket, ManagementSupport.selected_id(socket))}
  end

  def handle_event("approve", %{"id" => host_id}, socket),
    do: {:noreply, mutate_host(socket, host_id, :approve)}

  def handle_event("revoke", %{"id" => host_id}, socket),
    do: {:noreply, mutate_host(socket, host_id, :revoke)}

  def handle_event("delete", %{"id" => host_id}, socket),
    do: {:noreply, mutate_host(socket, host_id, :delete)}

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_hosts(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="identity-hosts" class="space-y-6">
        <div class="flex items-center justify-between gap-4">
          <ManagementComponents.page_header
            title="Identity Hosts"
            subtitle="Managed host registry"
            server={@selected_server}
            online?={@service_online?}
            back={ServicePaths.server_path(@selected_server.id, :identity)}
          />
          <button phx-click="refresh" class="btn btn-outline btn-sm">Refresh</button>
        </div>

        <ManagementComponents.offline_snapshot
          :if={@cached_snapshot?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error :if={@management_error} result={@management_error} />

        <.card>
          <div class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th>Name</th><th>Host ID</th><th>State</th><th class="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@hosts == []}>
                  <td colspan="4" class="py-8 text-center text-on-surface-variant">
                    No hosts in this Server snapshot
                  </td>
                </tr>
                <tr :for={host <- @hosts} id={"identity-host-#{host["host_id"]}"}>
                  <td>
                    <.link
                      navigate={
                        ServicePaths.server_path(
                          @selected_server.id,
                          {:identity_host, host["host_id"]}
                        )
                      }
                      class="link link-primary font-semibold"
                    >
                      {host["name"] || host["host_id"]}
                    </.link>
                  </td>
                  <td class="font-mono text-sm">{host["host_id"]}</td>
                  <td>
                    <.badge color={state_color(host["state"])}>{host["state"]}</.badge>
                  </td>
                  <td>
                    <div class="flex justify-end gap-2">
                      <button
                        :if={host["state"] == "pending"}
                        phx-click="approve"
                        phx-value-id={host["host_id"]}
                        disabled={not @service_online?}
                        data-management-command="true"
                        class="btn btn-success btn-xs"
                      >
                        Approve
                      </button>
                      <button
                        :if={host["state"] in ["pending", "approved"]}
                        phx-click="revoke"
                        phx-value-id={host["host_id"]}
                        disabled={not @service_online?}
                        data-management-command="true"
                        class="btn btn-warning btn-xs"
                      >
                        Revoke
                      </button>
                      <button
                        :if={host["state"] == "revoked"}
                        phx-click="delete"
                        phx-value-id={host["host_id"]}
                        disabled={not @service_online?}
                        data-management-command="true"
                        class="btn btn-error btn-xs"
                      >
                        Delete
                      </button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp load_hosts(socket, server_id) do
    result = ServerManagement.identity_hosts_list(server_id)

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — Identity Hosts",
      hosts: ManagementSupport.items(result),
      management_error: ManagementSupport.error(result),
      cached_snapshot?: ManagementSupport.cached?(result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(result, socket.assigns.selected_server.last_seen_at)
    )
  end

  defp mutate_host(socket, host_id, action) do
    with :ok <- ManagementSupport.mutable(socket),
         %{} = host <- Enum.find(socket.assigns.hosts, &(&1["host_id"] == host_id)),
         revision when is_binary(revision) and revision != "" <- host["revision"] do
      server_id = ManagementSupport.selected_id(socket)
      opts = ManagementSupport.command_options(revision)

      result =
        case action do
          :approve ->
            ServerManagement.identity_hosts_approve(server_id, %{"host_id" => host_id}, opts)

          :revoke ->
            ServerManagement.identity_hosts_revoke(server_id, %{"host_id" => host_id}, opts)

          :delete ->
            ServerManagement.identity_hosts_delete(server_id, %{"host_id" => host_id}, opts)
        end

      apply_mutation_result(socket, host_id, action, result)
    else
      {:error, message} ->
        put_flash(socket, :error, message)

      nil ->
        put_flash(socket, :error, "The selected host was not found")

      _missing_revision ->
        put_flash(socket, :error, "The selected host has no management revision")
    end
  end

  defp apply_mutation_result(socket, host_id, action, %ManagementResult{status: :ok} = result) do
    hosts =
      case {action, result.value} do
        {:delete, _value} ->
          Enum.reject(socket.assigns.hosts, &(&1["host_id"] == host_id))

        {_action, %{"resource" => resource}} ->
          ManagementSupport.replace(socket.assigns.hosts, resource)

        _other ->
          socket.assigns.hosts
      end

    socket
    |> assign(hosts: hosts, management_error: nil)
    |> ManagementSupport.finish(result, success_message(action))
  end

  defp apply_mutation_result(socket, _host_id, action, %ManagementResult{} = result),
    do: ManagementSupport.finish(socket, result, success_message(action))

  defp success_message(:approve), do: "Host approved"
  defp success_message(:revoke), do: "Host revoked"
  defp success_message(:delete), do: "Host deleted"

  defp state_color("approved"), do: "success"
  defp state_color("pending"), do: "warning"
  defp state_color("revoked"), do: "error"
  defp state_color(_state), do: "ghost"
end
