defmodule YellowDog.Console.DnsLive.MetricsLive do
  @moduledoc "Management-backed DNS metrics for one selected Server."

  use YellowDog.Console, :live_view

  alias YellowDog.Console.DnsLive.ManagementComponents
  alias YellowDog.Console.DnsLive.ManagementSupport
  alias YellowDog.Console.ServerManagement

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "DNS Metrics",
       subscribed_server_id: nil,
       metrics: %{"queries" => 0, "failures" => 0},
       management_error: nil,
       cached_observed_at: nil
     )}
  end

  @impl true
  def handle_params(%{"server_id" => server_id}, _uri, socket) do
    socket = ManagementSupport.subscribe(socket, server_id)
    {:noreply, if(connected?(socket), do: load_metrics(socket, server_id), else: socket)}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_metrics(socket, ManagementSupport.selected_id(socket))}
  end

  @impl true
  def handle_info({:server_connection, _state, %{server_id: server_id}}, socket)
      when server_id == socket.assigns.selected_server.id do
    {:noreply,
     socket
     |> ManagementSupport.refresh_selected_server(server_id)
     |> load_metrics(server_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="space-y-6" id="server-dns-metrics">
        <div class="flex items-center justify-between gap-4">
          <ManagementComponents.page_header
            title="DNS Metrics"
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

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <.card>
            <div class="text-sm text-on-surface-variant">Queries</div>
            <div class="text-3xl font-bold text-primary">{@metrics["queries"]}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Failures</div>
            <div class="text-3xl font-bold text-error">{@metrics["failures"]}</div>
          </.card>
          <.card>
            <div class="text-sm text-on-surface-variant">Success rate</div>
            <div class="text-3xl font-bold text-success">{success_rate(@metrics)}%</div>
          </.card>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp load_metrics(socket, server_id) do
    result = ServerManagement.dns_metrics_get(server_id)

    assign(socket,
      page_title: "#{socket.assigns.selected_server.name || server_id} — DNS Metrics",
      metrics: ManagementSupport.value(result, %{"queries" => 0, "failures" => 0}),
      management_error: if(ManagementSupport.error_result?(result), do: result),
      cached_observed_at:
        ManagementSupport.cached_observed_at(
          [result],
          socket.assigns.selected_server.last_seen_at
        )
    )
  end

  defp success_rate(%{"queries" => 0}), do: 100

  defp success_rate(%{"queries" => queries, "failures" => failures}) do
    max(0, round((queries - failures) * 100 / queries))
  end

  defp success_rate(_metrics), do: 0
end
