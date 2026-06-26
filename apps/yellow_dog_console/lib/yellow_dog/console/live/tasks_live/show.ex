defmodule YellowDog.Console.TasksLive.Show do
  @moduledoc """
  Detail page for a YellowDog data synchronization task.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Tasks

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Task History", task: nil, jobs: [])}
  end

  @impl true
  def handle_params(%{"task" => key}, _url, socket) do
    task = Tasks.get_task!(key)

    {:noreply,
     assign(socket,
       page_title: "#{task.label} Task",
       task: task,
       jobs: Tasks.recent_jobs(key)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-7xl">
        <div class="flex justify-between items-center mb-6">
          <div>
            <div class="breadcrumbs text-sm">
              <ul>
                <li><.link navigate="/system/tasks">Tasks</.link></li>
                <li>{@task.label}</li>
              </ul>
            </div>
            <h1 class="text-3xl font-bold">{@task.label}</h1>
            <p class="text-sm text-on-surface-variant mt-1">
              Source: <span class="font-mono">{@task.source}</span>
            </p>
          </div>
          <button phx-click="run_now" phx-value-task={@task.key} class="btn btn-primary btn-sm">
            <.dm_mdi name="play" class="h-5 w-5" /> Run Now
          </button>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-4 gap-4 mb-6">
          <.summary label="Status" value={status_label(@task.status)} />
          <.summary label="Enabled" value={if @task.enabled?, do: "Yes", else: "No"} />
          <.summary label="Schedule" value={@task.cron || "Manual only"} />
          <.summary label="Recent Jobs" value={Enum.count(@jobs)} />
        </div>

        <div class="card bg-surface shadow-xl">
          <div class="card-body">
            <h2 class="card-title text-lg">Recent Job History</h2>
            <div :if={@jobs == []} class="text-center py-12 text-on-surface-variant">
              <.dm_mdi name="history" class="w-12 h-12 mx-auto mb-3 opacity-50" />
              <p>No jobs have been queued for this task.</p>
            </div>
            <div :if={@jobs != []} class="overflow-x-auto mt-4">
              <table class="table">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>State</th>
                    <th>Attempt</th>
                    <th>Inserted</th>
                    <th>Last Error</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={job <- @jobs}>
                    <td class="font-mono">{job.id}</td>
                    <td><span class="badge badge-sm">{job.state}</span></td>
                    <td>{job.attempt}/{job.max_attempts}</td>
                    <td>{format_datetime(job.inserted_at)}</td>
                    <td class="text-sm">{format_last_error(job.errors)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("run_now", %{"task" => key}, socket) do
    case Tasks.enqueue(key) do
      {:ok, _job} ->
        task = Tasks.get_task!(key)

        {:noreply,
         socket
         |> put_flash(:info, "#{task.label} sync queued")
         |> assign(task: task, jobs: Tasks.recent_jobs(key))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unable to queue task: #{inspect(reason)}")}
    end
  end

  defp summary(assigns) do
    ~H"""
    <div class="card bg-surface shadow">
      <div class="card-body p-4">
        <div class="text-xs text-on-surface-variant">{@label}</div>
        <div class="font-semibold">{@value}</div>
      </div>
    </div>
    """
  end

  defp status_label(:active), do: "Active"
  defp status_label(:succeeded), do: "Succeeded"
  defp status_label(:failed), do: "Failed"
  defp status_label(_status), do: "Idle"

  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_datetime(_), do: "-"

  defp format_last_error([%{"error" => error} | _]), do: error
  defp format_last_error([%{error: error} | _]), do: error
  defp format_last_error(_), do: "-"
end
