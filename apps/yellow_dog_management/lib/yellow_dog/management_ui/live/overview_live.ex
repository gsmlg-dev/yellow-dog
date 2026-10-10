defmodule YellowDog.ManagementUI.OverviewLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.Domain

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Management") |> load_overview()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_overview(socket)}
  end

  defp load_overview(socket) do
    assign(socket,
      workers: Domain.list_workers(),
      netmans: Domain.list_netmans(),
      zones: Domain.list_zones(),
      recent_events: Enum.take(Domain.list_audit(), 5)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-7xl space-y-6" id="management-overview">
        <div>
          <h1 class="text-3xl font-bold">Management</h1>
          <p class="mt-1 text-sm text-on-surface-variant">
            PostgreSQL-owned configuration for independent Workers. Actual runtime state is unknown.
          </p>
          <button
            id="management-overview-refresh"
            type="button"
            phx-click="refresh"
            class="btn btn-outline"
          >Refresh</button>
        </div>
        <div class="grid gap-6 md:grid-cols-2">
          <.card title="Registered Servers">
            <p class="text-3xl font-bold" id="management-worker-count">{length(@workers)}</p>
            <p class="mb-4 text-on-surface-variant">
              Logical Workers; no live connection is assumed.
            </p>
            <.link navigate="/management/servers" class="btn btn-primary">Manage Servers</.link>
          </.card>
          <.card title="DNS Zones">
            <p class="text-3xl font-bold" id="management-zone-count">{length(@zones)}</p>
            <p class="mb-4 text-on-surface-variant">Shared drafts and immutable resource versions.</p>
            <.link navigate="/management/zones" class="btn btn-primary">Manage DNS Zones</.link>
          </.card>
          <.card title="Registered Netman Nodes">
            <p class="text-3xl font-bold" id="management-netman-count">{length(@netmans)}</p>
            <p class="mb-4 text-on-surface-variant">
              Logical network managers; actual runtime state remains unknown.
            </p>
            <.link navigate="/management/netman" class="btn btn-primary">Manage Netman</.link>
          </.card>
          <.card title="Recent Events">
            <p class="text-3xl font-bold" id="management-recent-event-count">
              {length(@recent_events)}
            </p>
            <p class="mb-4 text-on-surface-variant">
              Latest five durable management audit events, not runtime observations.
            </p>
            <.link navigate="/management/events" class="btn btn-primary">View All Events</.link>
          </.card>
        </div>
        <.card title="Latest Management Events">
          <p
            :if={@recent_events == []}
            id="management-recent-events-empty"
            class="text-on-surface-variant"
          >
            No management events yet.
          </p>
          <table class="table table-striped" id="management-recent-events">
            <thead>
              <tr>
                <th>Operation</th><th>Actor</th><th>Time</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={event <- @recent_events}
                data-event-id={event["id"]}
                data-operation={event["operation"]}
              >
                <td>{event["operation"]}</td>
                <td>{event["actor"]}</td>
                <td>{event["inserted_at"]}</td>
              </tr>
            </tbody>
          </table>
        </.card>
        <.card title="Configuration">
          <p class="mb-4 text-on-surface-variant">
            Review desired configuration and prepare targets. Preparing a target does not apply it to a Worker.
          </p>
          <.link navigate="/management/config" class="btn btn-outline">Manage Configuration</.link>
        </.card>
      </div>
    </Layouts.app>
    """
  end
end
