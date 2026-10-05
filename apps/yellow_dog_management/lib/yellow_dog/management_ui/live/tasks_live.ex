defmodule YellowDog.ManagementUI.TasksLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.Domain
  alias YellowDog.ManagementUI.Hooks.CurrentPath

  @task_keys ~w(ip_city ip_country mac)
  @poll_interval 2_000
  @active_job_states ~w(available scheduled executing retryable)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(YellowDog.ManagementUI.PubSub, "management:tasks")

    {:ok,
     assign(socket,
       page_title: "Data Sync Tasks",
       tasks: [],
       task: nil,
       task_key: nil,
       jobs: [],
       schedules: %{},
       scope_error: nil,
       action_error: nil,
       action_result: nil,
       poll_timer: nil
     )}
  end

  @impl true
  def handle_params(_params, uri, socket) do
    key = CurrentPath.route_path_params(socket, uri)["task"]
    {:noreply, socket |> assign(:task_key, key) |> refresh(false)}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket, false)}

  def handle_event("save_task_config", %{"task" => params} = payload, socket)
      when is_map(params) do
    with {:ok, task} <- selected_task(socket, payload["task_key"]),
         {:ok, enabled} <- enabled(params["enabled"]),
         true <- is_binary(params["cron"]) do
      key = task["key"]
      schedule = socket.assigns.schedules[key]
      socket = retain_schedule(socket, key, enabled, params["cron"])

      command = %{
        "key" => key,
        "expected_revision" => schedule.revision,
        "enabled" => enabled,
        "cron" => params["cron"]
      }

      case Domain.mutate("update_task", command, "operator", Ecto.UUID.generate()) do
        {:ok, _task} ->
          socket = refresh(socket, true)
          current = Enum.find(socket.assigns.tasks, &(&1["key"] == key))

          {:noreply,
           socket
           |> assign(:schedules, Map.put(socket.assigns.schedules, key, schedule(current)))
           |> assign(action_error: nil, action_result: "Task schedule updated.")}

        {:error, error} ->
          failure(socket, message(error))
      end
    else
      {:error, reason} -> failure(socket, reason)
      false -> failure(socket, "Cron must be standard five-field UTC text")
    end
  end

  def handle_event("run_now", payload, socket) do
    with {:ok, task} <- selected_task(socket, payload["task"]),
         true <- task["available"] do
      case Domain.mutate("run_task", %{"key" => task["key"]}, "operator", Ecto.UUID.generate()) do
        {:ok, job} ->
          {:noreply,
           socket
           |> refresh(true)
           |> assign(
             action_error: nil,
             action_result:
               "Task queued (job #{job["id"]}). Queueing is not successful completion."
           )}

        {:error, error} ->
          failure(socket, message(error))
      end
    else
      {:error, reason} -> failure(socket, reason)
      false -> failure(socket, "Task is unavailable; no job was queued.")
    end
  end

  def handle_event(_event, _params, socket), do: failure(socket, "Invalid task action")

  @impl true
  def handle_info({:task_updated, key}, socket) when key in @task_keys do
    if socket.assigns.live_action != :show or socket.assigns.task_key == key do
      {:noreply, refresh(socket, true)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:poll_tasks, token}, %{assigns: %{poll_timer: {_timer, token}}} = socket) do
    {:noreply, socket |> assign(:poll_timer, nil) |> refresh(true)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp selected_task(%{assigns: %{live_action: :show, task: task}}, _key) when not is_nil(task),
    do: {:ok, task}

  defp selected_task(%{assigns: %{live_action: :index, tasks: tasks}}, key)
       when key in @task_keys do
    case Enum.find(tasks, &(&1["key"] == key)) do
      nil -> {:error, "Task not found"}
      task -> {:ok, task}
    end
  end

  defp selected_task(_socket, _key), do: {:error, "Task not found or this page is read-only"}

  defp refresh(socket, preserve_schedule) do
    socket =
      if preserve_schedule,
        do: socket,
        else: assign(socket, action_error: nil, action_result: nil)

    socket =
      case socket.assigns.live_action do
        :index ->
          tasks = Domain.list_tasks()

          assign(socket,
            page_title: "Data Sync Tasks",
            tasks: tasks,
            task: nil,
            jobs: [],
            scope_error: nil,
            schedules: schedules(socket, tasks, preserve_schedule)
          )

        :show ->
          load_task(socket, preserve_schedule)

        :logs ->
          assign(socket,
            page_title: "Task Logs",
            tasks: Domain.list_tasks(),
            task: nil,
            jobs: Domain.list_task_history(),
            scope_error: nil,
            schedules: %{}
          )
      end

    schedule_poll(socket)
  end

  defp schedule_poll(socket) do
    active =
      Enum.any?(socket.assigns.tasks, &(&1["status"] == "active")) or
        Enum.any?(socket.assigns.jobs, &(&1["state"] in @active_job_states))

    case {connected?(socket) and active, socket.assigns.poll_timer} do
      {true, nil} ->
        token = make_ref()
        timer = Process.send_after(self(), {:poll_tasks, token}, @poll_interval)
        assign(socket, :poll_timer, {timer, token})

      {false, {timer, _token}} ->
        Process.cancel_timer(timer)
        assign(socket, :poll_timer, nil)

      _unchanged ->
        socket
    end
  end

  defp load_task(socket, preserve_schedule) do
    key = socket.assigns.task_key

    if key in @task_keys do
      case Domain.get_task(key) do
        {:ok, task} ->
          assign(socket,
            page_title: task["label"],
            task: task,
            tasks: [task],
            jobs: Domain.list_task_jobs(key),
            scope_error: nil,
            schedules: schedules(socket, [task], preserve_schedule)
          )

        {:error, _error} ->
          not_found(socket)
      end
    else
      not_found(socket)
    end
  end

  defp not_found(socket),
    do:
      assign(socket,
        page_title: "Task not found",
        task: nil,
        tasks: [],
        jobs: [],
        schedules: %{},
        scope_error: "Task not found"
      )

  defp schedules(socket, tasks, preserve) do
    Map.new(tasks, fn task ->
      key = task["key"]

      {key,
       if(preserve,
         do: Map.get(socket.assigns.schedules, key, schedule(task)),
         else: schedule(task)
       )}
    end)
  end

  defp schedule(task),
    do: %{
      revision: task["revision"],
      form: to_form(%{"enabled" => task["enabled"], "cron" => task["cron"] || ""}, as: "task")
    }

  defp retain_schedule(socket, key, enabled, cron) do
    entry = %{
      socket.assigns.schedules[key]
      | form: to_form(%{"enabled" => enabled, "cron" => cron}, as: "task")
    }

    assign(socket, :schedules, Map.put(socket.assigns.schedules, key, entry))
  end

  defp enabled("true"), do: {:ok, true}
  defp enabled("false"), do: {:ok, false}
  defp enabled(_value), do: {:error, "Enabled must be true or false"}

  defp failure(socket, reason),
    do: {:noreply, assign(socket, action_error: reason, action_result: nil)}

  defp message(error), do: error[:message] || error["message"]
  defp timestamp(nil), do: "—"
  defp timestamp(value), do: value
  defp json(value), do: Jason.encode!(value, pretty: true)

  attr :task, :map, required: true
  attr :schedule, :map, required: true

  defp schedule_form(assigns) do
    ~H"""
    <.form
      for={@schedule.form}
      id={"task-schedule-#{@task["key"]}"}
      phx-submit="save_task_config"
      class="space-y-3"
    >
      <input type="hidden" name="task_key" value={@task["key"]} />
      <input type="hidden" name="task[enabled]" value="false" />
      <label class="flex items-center gap-2">
        <input
          type="checkbox"
          name="task[enabled]"
          value="true"
          checked={@schedule.form[:enabled].value}
          class="checkbox checkbox-primary"
        />
        <span>Enabled</span>
      </label>
      <label class="form-control">
        <span class="label">Schedule (UTC)</span>
        <input
          name="task[cron]"
          value={@schedule.form[:cron].value}
          class="input input-bordered font-mono"
          aria-label={"Schedule for #{@task["label"]}"}
          required
        />
      </label>
      <p class="text-sm text-on-surface-variant">
        Five fields: minute hour day-of-month month day-of-week. Disabled schedules can still be run manually when available.
      </p>
      <p :if={@schedule.revision != @task["revision"]} class="text-warning">
        Schedule changed elsewhere. Refresh before saving; your current form is preserved.
      </p>
      <button type="submit" class="btn btn-secondary btn-sm" phx-disable-with="Saving…">Save Schedule</button>
    </.form>
    """
  end

  attr :jobs, :list, required: true

  defp job_history(assigns) do
    ~H"""
    <p :if={@jobs == []} id="task-jobs-empty" class="text-on-surface-variant">
      No jobs have been queued.
    </p>
    <div class="overflow-x-auto">
      <table id="task-jobs" class="table table-striped">
        <thead>
          <tr>
            <th>ID / Task</th><th>State</th><th>Attempts</th><th>Timestamps</th><th>
              Result / Errors
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={job <- @jobs} id={"task-job-#{job["id"]}"}>
            <td>
              <code>{job["id"]}</code><div>
                <.link navigate={"/system/tasks/#{job["task_key"]}"}>{job["task_key"]}</.link>
              </div>
            </td>
            <td><span class="badge badge-sm">{job["state"]}</span></td><td>
              {job["attempt"]}/{job["max_attempts"]}
            </td>
            <td>
              <dl>
                <dt>Inserted</dt><dd>{timestamp(job["inserted_at"])}</dd><dt>Attempted</dt><dd>
                  {timestamp(job["attempted_at"])}
                </dd><dt>Completed</dt><dd>{timestamp(job["completed_at"])}</dd><dt>Discarded</dt><dd>
                  {timestamp(job["discarded_at"])}
                </dd>
              </dl>
            </td>
            <td>
              <details :if={job["result"] != nil}>
                <summary>Recorded result</summary><pre>{json(job["result"])}</pre>
              </details>
              <p :if={job["result"] == nil}>No result receipt recorded</p>
              <details :if={job["errors"] not in [nil, []]}>
                <summary>Attempt errors</summary><pre>{json(job["errors"])}</pre>
              </details>
              <p :if={job["errors"] in [nil, []]}>No attempt errors recorded</p>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_path={@current_path}>
      <div class="max-w-7xl space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="text-3xl font-bold">{@page_title}</h1>
          <div class="flex flex-wrap gap-2">
            <.link :if={@live_action != :index} navigate="/system/tasks" class="btn btn-ghost">Tasks</.link>
            <.link :if={@live_action != :logs} navigate="/system/logs/tasks" class="btn btn-ghost">Task Logs</.link>
            <button id="tasks-refresh" class="btn btn-secondary" phx-click="refresh">Refresh</button>
          </div>
        </div>
        <p class="text-on-surface-variant">
          PostgreSQL schedules and durable Oban jobs. Queue states and result receipts report real attempts, not invented stdout or runtime success. Cloud-provider synchronization is not implemented.
        </p>
        <div :if={@scope_error} id="task-scope-error" role="alert" class="alert alert-error">
          {@scope_error}
        </div>
        <div :if={@action_error} id="task-action-error" role="alert" class="alert alert-error">
          {@action_error}
        </div>
        <p :if={@action_result} id="task-action-result" role="status" class="alert alert-info">
          {@action_result}
        </p>
        <section :if={@live_action == :index} id="tasks-overview">
          <.card title="Task Overview">
            <div class="overflow-x-auto">
              <table id="tasks-table" class="table table-striped">
                <thead>
                  <tr>
                    <th>Task</th><th>Status</th><th>Schedule</th><th>Source</th><th>Actions</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={task <- @tasks} id={"task-row-#{task["key"]}"}>
                    <td>
                      <div class="font-semibold">{task["label"]}</div><code>{task["key"]}</code>
                    </td>
                    <td>
                      <span class="badge badge-sm">{task["status"]}</span><div>
                        Schedule: {if task["enabled"], do: "Enabled", else: "Disabled"}
                      </div>
                      <p :if={!task["available"]} class="text-warning">
                        {task["unavailable_reason"] || "Task unavailable"}
                      </p>
                      <div :if={task["last_job"]}>
                        Last job #{task["last_job"]["id"]}: {task["last_job"]["state"]}
                      </div>
                    </td>
                    <td><.schedule_form task={task} schedule={@schedules[task["key"]]} /></td><td>
                      {task["source"]}
                    </td>
                    <td>
                      <div class="flex flex-wrap gap-2">
                        <button
                          id={"task-run-#{task["key"]}"}
                          class="btn btn-primary btn-sm"
                          phx-click="run_now"
                          phx-value-task={task["key"]}
                          disabled={!task["available"]}
                        >Run Now</button>
                        <.link navigate={"/system/tasks/#{task["key"]}"} class="btn btn-ghost btn-sm">View History</.link>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.card>
        </section>
        <section :if={@task} id="task-detail" data-task-key={@task["key"]} class="space-y-6">
          <.card title="Task Configuration">
            <dl class="space-y-2">
              <dt>Source</dt><dd>{@task["source"]}</dd><dt>Status</dt><dd>{@task["status"]}</dd><dt>
                Schedule Enabled
              </dt><dd>{if @task["enabled"], do: "Yes", else: "No"}</dd><dt>Revision</dt><dd>
                {@task["revision"]}
              </dd><dt>Recent Jobs</dt><dd>{length(@jobs)}</dd>
            </dl>
            <p :if={!@task["available"]} class="alert alert-warning mt-4">
              {@task["unavailable_reason"] || "Task unavailable"}
            </p>
            <div class="mt-4">
              <.schedule_form task={@task} schedule={@schedules[@task["key"]]} />
            </div>
            <button
              id={"task-run-#{@task["key"]}"}
              class="btn btn-primary mt-4"
              phx-click="run_now"
              disabled={!@task["available"]}
            >Run Now</button>
          </.card>
          <.card title="Recent Job History"><.job_history jobs={@jobs} /></.card>
        </section>
        <section :if={@live_action == :logs} id="task-logs">
          <.card title="Task Attempt History"><.job_history jobs={@jobs} /></.card>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
