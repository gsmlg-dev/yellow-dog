defmodule YellowDog.ManagementUI.IpDatabaseLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Domain, TaskArtifacts}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(YellowDog.ManagementUI.PubSub, "management:tasks")

    {:ok,
     socket
     |> assign(page_title: "IP Database", databases: [], download_result: nil, error: nil)
     |> refresh()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket)}

  def handle_event("download", %{"type" => type}, socket) when type in ~w(city country) do
    socket = assign(socket, download_result: nil, error: nil)

    case Domain.mutate("run_task", %{"key" => "ip_#{type}"}, "operator", Ecto.UUID.generate()) do
      {:ok, job} -> {:noreply, socket |> refresh() |> assign(download_result: job, error: nil)}
      {:error, error} -> {:noreply, assign(socket, error: error[:message] || error["message"])}
    end
  end

  def handle_event(_event, _params, socket),
    do: {:noreply, assign(socket, error: "Invalid catalog action")}

  @impl true
  def handle_info({:task_updated, key}, socket) when key in ~w(ip_city ip_country),
    do: {:noreply, refresh(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp refresh(socket) do
    tasks = Map.new(Domain.list_tasks(), &{&1["key"], &1})
    databases = Enum.map(TaskArtifacts.catalog(), &Map.put(&1, :task, tasks["ip_#{&1.kind}"]))
    assign(socket, databases: databases, error: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <h1>IP Database</h1>
      <button id="ip-database-refresh" class="btn btn-secondary" phx-click="refresh">Refresh</button>
      <p class="management-help">
        Global, versioned database artifacts synchronized by Management. Synchronization does not mean delivery or loading on a Worker.
      </p>
      <p
        :if={@download_result}
        id="ip-database-download-result"
        data-job-id={@download_result["id"]}
        data-task-key={@download_result["task_key"]}
        role="status"
      >
        Task queued (job {@download_result["id"]}). Queueing is not successful completion.
      </p>
      <p :if={@error} id="ip-database-error" class="alert alert-error" role="alert">{@error}</p>
      <section
        :for={database <- @databases}
        id={"ip-database-#{database.kind}"}
        class="card card-bordered"
      >
        <div class="card-body">
          <h2>{String.capitalize(database.kind)} Database</h2>
          <dl>
            <dt>Source</dt><dd>{database.task["source"]}</dd>
            <dt>Schedule</dt><dd>
              {if database.task["enabled"], do: database.task["cron"], else: "Disabled"}
            </dd>
            <dt>Synchronization state</dt><dd data-sync-state={job_state(database.task)}>
              {job_state(database.task)}
            </dd>
            <dt>Last job error</dt><dd>{job_error(database.task)}</dd>
            <dt>Last successful synchronization</dt><dd>
              {if database.selected, do: display(database.selected.selected_at), else: "None"}
            </dd>
            <dt>Artifact availability</dt><dd data-status={availability(database.selected)}>
              {availability(database.selected)}
            </dd>
          </dl>
          <div :if={database.selected} data-digest={database.selected.digest}>
            <dl>
              <dt>Selected digest</dt><dd>{database.selected.digest}</dd>
              <dt>Size</dt><dd>{database.selected.size} bytes</dd>
              <dt>Format</dt><dd>{database.selected.format}</dd>
              <dt>Published</dt><dd>{display(database.selected.published_at)}</dd>
              <dt>Dataset source</dt><dd>{source(database.selected.source_url)}</dd>
              <dt>Database type</dt><dd>{database.selected.metadata["database_type"]}</dd>
              <dt>Build</dt><dd>{display(database.selected.metadata["build_epoch"])}</dd>
              <dt>Metadata</dt><dd>{Jason.encode!(database.selected.metadata)}</dd>
            </dl>
            <p :if={!database.selected.available} role="alert">
              Selected artifact unavailable: {inspect(database.selected.availability_error)}. Synchronize a valid durable file before distributing it.
            </p>
          </div>
          <p class="management-help">
            A failed new synchronization can coexist with an available previous artifact.
          </p>
          <div class="management-actions">
            <button
              id={"ip-database-download-#{database.kind}"}
              class="btn btn-primary"
              phx-click="download"
              phx-value-type={database.kind}
              phx-disable-with="Queueing…"
            >Queue IP {String.capitalize(database.kind)}</button>
            <.link navigate={"/system/tasks/ip_#{database.kind}"} class="btn btn-secondary">Source, schedule and sync history</.link>
          </div>
          <h3>Available dataset versions</h3>
          <p :if={database.versions == []}>No synchronized datasets.</p>
          <table class="table" id={"ip-database-versions-#{database.kind}"}>
            <thead>
              <tr>
                <th>Digest</th><th>Size</th><th>Published</th><th>Availability</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={version <- database.versions} data-digest={version.digest}>
                <td>{version.digest}</td><td>{version.size} bytes</td><td>
                  {display(version.published_at)}
                </td><td>{availability(version)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp availability(nil), do: "No selected artifact"
  defp availability(%{available: true}), do: "Available"
  defp availability(_artifact), do: "Unavailable"

  defp job_state(task) do
    case task["last_job"] do
      %{"state" => "available"} -> "queued"
      %{"state" => state} -> state
      _ -> "idle"
    end
  end

  defp job_error(task) do
    case task["last_job"] do
      %{"errors" => errors} when errors != [] ->
        errors |> List.last() |> Map.get("error", "Synchronization failed")

      _ ->
        "None"
    end
  end

  defp display(nil), do: "Unknown"
  defp display(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp display(value), do: to_string(value)

  defp source(url) do
    uri = URI.parse(url)
    URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil})
  end
end
