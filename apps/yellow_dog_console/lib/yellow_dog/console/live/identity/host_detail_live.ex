defmodule YellowDog.Console.IdentityLive.HostDetailLive do
  @moduledoc "Management-backed Identity host detail for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.IdentityLive.ManagementComponents
  alias YellowDog.Console.IdentityLive.ManagementSupport
  alias YellowDog.Console.Layouts
  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.ServicePaths

  @impl true
  def mount(%{"id" => host_id}, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Identity Host",
       subscribed_server_id: nil,
       host_id: host_id,
       host: nil,
       management_error: nil,
       cached_snapshot?: false,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id, "id" => host_id}, _uri, socket) do
    socket =
      socket
      |> assign(:host_id, host_id)
      |> ManagementSupport.subscribe(server_id)

    {:noreply, if(connected?(socket), do: load_host(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("approve", _params, socket), do: {:noreply, mutate_host(socket, :approve)}
  def handle_event("revoke", _params, socket), do: {:noreply, mutate_host(socket, :revoke)}
  def handle_event("delete", _params, socket), do: {:noreply, mutate_host(socket, :delete)}

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_host(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div id="identity-host-detail" class="space-y-6">
        <ManagementComponents.page_header
          title="Identity Host"
          subtitle={@host_id}
          server={@selected_server}
          online?={@service_online?}
          back={ServicePaths.server_path(@selected_server.id, :identity_hosts)}
        />

        <ManagementComponents.offline_snapshot
          :if={@cached_snapshot?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error :if={@management_error} result={@management_error} />

        <.card :if={@host}>
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="card-title">{@host["name"] || @host["host_id"]}</h2>
              <p class="mt-1 font-mono text-sm text-on-surface-variant">{@host["host_id"]}</p>
            </div>
            <.badge color={state_color(@host["state"])}>{@host["state"]}</.badge>
          </div>

          <dl class="mt-6 grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <dt class="text-sm text-on-surface-variant">Management revision</dt>
              <dd class="break-all font-mono text-sm">{@host["revision"]}</dd>
            </div>
          </dl>

          <div class="mt-6 flex gap-2">
            <button
              :if={@host["state"] == "pending"}
              phx-click="approve"
              disabled={not @service_online?}
              data-management-command="true"
              class="btn btn-success btn-sm"
            >
              Approve
            </button>
            <button
              :if={@host["state"] in ["pending", "approved"]}
              phx-click="revoke"
              disabled={not @service_online?}
              data-management-command="true"
              class="btn btn-warning btn-sm"
            >
              Revoke
            </button>
            <button
              :if={@host["state"] == "revoked"}
              phx-click="delete"
              disabled={not @service_online?}
              data-management-command="true"
              class="btn btn-error btn-sm"
            >
              Delete
            </button>
          </div>
        </.card>

        <.card :if={is_nil(@host) and is_nil(@management_error)}>
          <div class="text-on-surface-variant">The selected host was not found.</div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp load_host(socket, server_id) do
    result = ServerManagement.identity_hosts_list(server_id)
    host = Enum.find(ManagementSupport.items(result), &(&1["host_id"] == socket.assigns.host_id))

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — Identity Host",
      host: host,
      management_error: ManagementSupport.error(result),
      cached_snapshot?: ManagementSupport.cached?(result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(result, socket.assigns.selected_server.last_seen_at)
    )
  end

  defp mutate_host(socket, action) do
    with :ok <- ManagementSupport.mutable(socket),
         %{} = host <- socket.assigns.host,
         revision when is_binary(revision) and revision != "" <- host["revision"] do
      server_id = ManagementSupport.selected_id(socket)
      payload = %{"host_id" => host["host_id"]}
      opts = ManagementSupport.command_options(revision)

      result =
        case action do
          :approve -> ServerManagement.identity_hosts_approve(server_id, payload, opts)
          :revoke -> ServerManagement.identity_hosts_revoke(server_id, payload, opts)
          :delete -> ServerManagement.identity_hosts_delete(server_id, payload, opts)
        end

      apply_mutation_result(socket, action, result)
    else
      {:error, message} ->
        put_flash(socket, :error, message)

      nil ->
        put_flash(socket, :error, "The selected host was not found")

      _missing_revision ->
        put_flash(socket, :error, "The selected host has no management revision")
    end
  end

  defp apply_mutation_result(socket, :delete, %ManagementResult{status: :ok} = result) do
    socket
    |> ManagementSupport.finish(result, "Host deleted")
    |> push_navigate(
      to: ServicePaths.server_path(socket.assigns.selected_server.id, :identity_hosts)
    )
  end

  defp apply_mutation_result(
         socket,
         action,
         %ManagementResult{status: :ok, value: value} = result
       ) do
    host = if is_map(value["resource"]), do: value["resource"], else: socket.assigns.host

    socket
    |> assign(host: host, management_error: nil)
    |> ManagementSupport.finish(result, success_message(action))
  end

  defp apply_mutation_result(socket, action, %ManagementResult{} = result),
    do: ManagementSupport.finish(socket, result, success_message(action))

  defp success_message(:approve), do: "Host approved"
  defp success_message(:revoke), do: "Host revoked"

  defp state_color("approved"), do: "success"
  defp state_color("pending"), do: "warning"
  defp state_color("revoked"), do: "error"
  defp state_color(_state), do: "ghost"
end
