defmodule YellowDog.ManagementUI.ConfigLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.Domain

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Management Config",
       versions: Domain.list_target_history(),
       netman_versions: Domain.list_netman_history()
     )}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply,
     assign(socket,
       versions: Domain.list_target_history(),
       netman_versions: Domain.list_netman_history()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="management-actions">
        <h1 class="text-3xl font-bold">Management Config</h1>
        <button id="management-config-refresh" class="btn btn-ghost" phx-click="refresh">
          Refresh
        </button>
      </div>
      <.card title="Published Config Versions">
        <p class="management-help">
          These are immutable prepared configurations in PostgreSQL, not delivered or applied
          configurations. Actual Worker state, state-change time, failure phase and rollback are
          unknown. Netman history records prepared desired configurations, not applied network changes.
        </p>
        <p :if={@versions == [] && @netman_versions == []} id="management-config-empty">
          No configuration versions published yet.
        </p>
        <div class="overflow-x-auto">
          <table id="management-config-versions" class="table table-striped">
            <thead>
              <tr>
                <th>Target</th><th>Version</th><th>Operation</th><th>State</th><th>Digest</th>
                <th>Prepared</th><th>State Changed</th><th>Failure Phase</th><th>Rollback</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={version <- @versions}
                id={"config-version-#{version["id"]}"}
                data-worker-id={version["worker_id"]}
                data-revision={version["revision"]}
                data-actual-state={version["actual_state"]}
              >
                <td>
                  <.link navigate={ServicePaths.server_path(version["worker_id"], :dashboard)}>
                    {version["worker_name"]} ({version["worker_id"]})
                  </.link>
                </td>
                <td>{version["revision"]}</td><td>confirm_target</td>
                <td><span class="badge badge-info">{version["status"]}</span></td>
                <td><code>{version["digest"]}</code></td>
                <td><time datetime={version["prepared_at"]}>{version["prepared_at"]}</time></td>
                <td>unknown</td><td>unknown</td><td>unknown</td>
              </tr>
              <tr
                :for={version <- @netman_versions}
                id={"config-version-#{version["id"]}"}
                data-netman-id={version["netman_id"]}
                data-revision={version["version"]}
                data-actual-state={version["actual_state"]}
              >
                <td>
                  <.link navigate={ServicePaths.netman_path(version["netman_id"], :config)}>
                    {version["netman_name"]} ({version["netman_id"]})
                  </.link>
                </td>
                <td>{version["version"]}</td><td>{version["operation"]}</td>
                <td><span class="badge badge-info">{version["status"]}</span></td>
                <td><code>{version["digest"]}</code></td>
                <td><time datetime={version["inserted_at"]}>{version["inserted_at"]}</time></td>
                <td>unknown</td><td>unknown</td><td>unknown</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.card>
    </Layouts.app>
    """
  end
end
