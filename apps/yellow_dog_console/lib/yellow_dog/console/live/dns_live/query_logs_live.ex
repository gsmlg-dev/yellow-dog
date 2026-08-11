defmodule YellowDog.Console.DnsLive.QueryLogsLive do
  @moduledoc "Management-backed DNS query logs for one selected Server and view."

  use YellowDog.Console, :live_view

  import YellowDog.Console.DnsLive.ManagementComponents, only: [input: 1]

  alias YellowDog.Console.DnsLive.ManagementComponents
  alias YellowDog.Console.DnsLive.ManagementSupport
  alias YellowDog.Console.ServerManagement

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS Query Logs",
       subscribed_server_id: nil,
       view_name: "default",
       selection_form: to_form(%{"view_name" => "default"}, as: "selection"),
       logs: [],
       management_error: nil,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id} = params, _uri, socket) do
    view_name = params["view_name"] || "default"

    socket =
      socket
      |> ManagementSupport.subscribe(server_id)
      |> assign(
        view_name: view_name,
        selection_form: to_form(%{"view_name" => view_name}, as: "selection")
      )

    {:noreply, if(connected?(socket), do: load_logs(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_logs(socket, ManagementSupport.selected_id(socket))}
  end

  def handle_event("select_view", %{"selection" => %{"view_name" => view_name}}, socket) do
    path =
      ServicePaths.server_path(ManagementSupport.selected_id(socket), :dns_logs) <>
        "?" <> URI.encode_query(%{"view_name" => view_name})

    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_logs(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="server-dns-logs">
        <div class="flex items-center justify-between gap-4">
          <ManagementComponents.page_header
            title="DNS Query Logs"
            subtitle={"View #{@view_name}"}
            server={@selected_server}
            online?={@service_online?}
            back={ServicePaths.server_path(@selected_server.id, :dns)}
          />
          <button phx-click="refresh" class="btn btn-ghost btn-sm">Refresh</button>
        </div>

        <ManagementComponents.offline_snapshot
          :if={not @service_online?}
          observed_at={@cached_observed_at}
        />
        <ManagementComponents.operation_error
          :if={ManagementSupport.error_result?(@management_error)}
          result={@management_error}
        />

        <.form for={@selection_form} id="dns-log-view" phx-change="select_view" class="max-w-md">
          <.input field={@selection_form[:view_name]} label="View" phx-debounce="300" />
        </.form>

        <.card title="Recent queries">
          <p :if={@logs == []} class="text-sm text-on-surface-variant">No query logs reported</p>
          <div :if={@logs != []} class="overflow-x-auto">
            <table class="table table-striped">
              <thead>
                <tr>
                  <th>Time</th><th>Query</th><th>Action</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @logs}>
                  <td>{entry["occurred_at"]}</td>
                  <td class="font-mono">{entry["query_name"]}</td>
                  <td>
                    <.badge color={action_color(entry["action"])} size="sm">{entry["action"]}</.badge>
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

  defp load_logs(socket, server_id) do
    result = ServerManagement.dns_logs_list(server_id, %{"view_name" => socket.assigns.view_name})

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — DNS Query Logs",
      logs: ManagementSupport.items(result),
      management_error: if(ManagementSupport.error_result?(result), do: result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(
          [result],
          socket.assigns.selected_server.last_seen_at
        )
    )
  end

  defp action_color("answered"), do: "success"
  defp action_color("forwarded"), do: "info"
  defp action_color("refused"), do: "warning"
  defp action_color(_action), do: "error"
end
