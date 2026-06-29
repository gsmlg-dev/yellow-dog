defmodule YellowDog.Console.TasksLive.Index do
  @moduledoc """
  Overview of Concord-backed YellowDog data synchronization tasks.
  """

  use YellowDog.Console, :live_view

  alias YellowDog.Console.Layouts
  alias YellowDog.Tasks

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Data Sync Tasks", tasks: [])}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :tasks, Tasks.list_tasks())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-7xl">
        <div class="flex justify-between items-center mb-6">
          <div>
            <h1 class="text-3xl font-bold">Data Sync Tasks</h1>
            <p class="text-sm text-on-surface-variant mt-1">
              Monitor and run scheduled provider data synchronization jobs
            </p>
          </div>
          <button phx-click="refresh" class="btn btn-ghost btn-sm">
            <.dm_mdi name="refresh" class="h-5 w-5" /> Refresh
          </button>
        </div>

        <div class="card bg-surface shadow-xl">
          <div class="card-body">
            <h2 class="card-title text-lg">Task Overview</h2>
            <div class="overflow-x-auto mt-4">
              <table class="table">
                <thead>
                  <tr>
                    <th>Task</th>
                    <th>Status</th>
                    <th>Schedule</th>
                    <th>Source</th>
                    <th class="text-right">Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={task <- @tasks}>
                    <td>
                      <div class="font-semibold">{task.label}</div>
                      <div class="text-xs text-on-surface-variant font-mono">{task.key}</div>
                    </td>
                    <td><.status_badge status={task.status} enabled?={task.enabled?} /></td>
                    <td class="font-mono text-sm">{task.cron || "Manual only"}</td>
                    <td>{task.source}</td>
                    <td>
                      <div class="flex justify-end gap-2">
                        <button
                          phx-click="run_now"
                          phx-value-task={task.key}
                          class="btn btn-primary btn-sm"
                        >
                          <.dm_mdi name="play" class="h-4 w-4" /> Run Now
                        </button>
                        <.link navigate={"/system/tasks/#{task.key}"} class="btn btn-ghost btn-sm">
                          <.dm_mdi name="history" class="h-4 w-4" /> View History
                        </.link>
                      </div>
                    </td>
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
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :tasks, Tasks.list_tasks())}
  end

  def handle_event("run_now", %{"task" => key}, socket) do
    case Tasks.enqueue(key) do
      {:ok, _job} ->
        task = Tasks.get_task!(key)

        {:noreply,
         socket
         |> put_flash(:info, "#{task.label} sync queued")
         |> assign(:tasks, Tasks.list_tasks())}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unable to queue task: #{inspect(reason)}")}
    end
  end

  defp status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm", status_class(@status)]}>
      {if @enabled?, do: status_label(@status), else: "Disabled"}
    </span>
    """
  end

  defp status_class(:active), do: "badge-info"
  defp status_class(:succeeded), do: "badge-success"
  defp status_class(:failed), do: "badge-error"
  defp status_class(_status), do: "badge-ghost"

  defp status_label(:active), do: "Active"
  defp status_label(:succeeded), do: "Succeeded"
  defp status_label(:failed), do: "Failed"
  defp status_label(_status), do: "Idle"
end
