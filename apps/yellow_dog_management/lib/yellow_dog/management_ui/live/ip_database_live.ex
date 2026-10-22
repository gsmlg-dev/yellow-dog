defmodule YellowDog.ManagementUI.IpDatabaseLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Database, Domain, TaskArtifacts}

  @verification_ttl 60

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(YellowDog.ManagementUI.PubSub, "management:tasks")

    {:ok,
     socket
     |> assign(
       page_title: "IP Database",
       databases: [],
       download_result: nil,
       sync_intents: new_sync_intents(),
       schedules: %{},
       error: nil,
       refresh_error: nil,
       pages: %{},
       checks: %{}
     )
     |> refresh()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, refresh(socket, true)}

  def handle_event("history_page", %{"type" => kind, "direction" => direction}, socket)
      when kind in ~w(city country) and direction in ~w(previous next) do
    database = Enum.find(socket.assigns.databases, &(&1.kind == kind))
    page = database.page

    page =
      case direction do
        "next" when database.has_more -> page + 1
        "previous" -> max(page - 1, 1)
        _ -> page
      end

    {:noreply, socket |> assign(:pages, Map.put(socket.assigns.pages, kind, page)) |> refresh()}
  end

  def handle_event("download", %{"type" => type, "_submission" => token}, socket)
      when type in ~w(city country) do
    intent = socket.assigns.sync_intents[type]

    if token == intent.token do
      intents = Map.put(socket.assigns.sync_intents, type, %{intent | attempted: true})
      socket = assign(socket, sync_intents: intents, download_result: nil, error: nil)

      case YellowDog.ManagementUI.Commands.command(
             socket,
             "run_task",
             %{"key" => "ip_#{type}"},
             intent.key
           ) do
        {:ok, job} ->
          intents = Map.put(socket.assigns.sync_intents, type, sync_intent())
          {:noreply, socket |> assign(sync_intents: intents, download_result: job) |> refresh()}

        {:error, error} ->
          {:noreply, assign(socket, error: error[:message] || error["message"])}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("new_sync", %{"type" => type, "_submission" => token}, socket)
      when type in ~w(city country) do
    if socket.assigns.sync_intents[type].token == token do
      intent = sync_intent()
      socket = assign(socket, :sync_intents, Map.put(socket.assigns.sync_intents, type, intent))
      handle_event("download", %{"type" => type, "_submission" => intent.token}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate_schedule", %{"task" => params, "type" => kind}, socket)
      when kind in ~w(city country) and is_map(params) do
    {:noreply, retain_schedule(socket, kind, params)}
  end

  def handle_event(
        "save_schedule",
        %{"task" => params, "type" => kind, "_submission" => token},
        socket
      )
      when kind in ~w(city country) and is_map(params) do
    schedule = socket.assigns.schedules[kind]

    if token == schedule.token or
         (is_binary(token) and token == schedule.previous_token and
            Map.take(params, ~w(enabled cron)) == schedule.form.params) do
      socket = retain_schedule(socket, kind, params)
      schedule = socket.assigns.schedules[kind]
      fields = schedule.form.params

      enabled =
        case fields["enabled"] do
          "true" -> true
          "false" -> false
          _ -> nil
        end

      payload = %{
        "key" => "ip_#{kind}",
        "expected_revision" => schedule.revision,
        "enabled" => enabled,
        "cron" => fields["cron"]
      }

      {request, key} =
        case schedule.request do
          {^payload, key} ->
            {schedule.request, key}

          _ ->
            key = Ecto.UUID.generate()
            {{payload, key}, key}
        end

      schedule = %{schedule | request: request}
      socket = assign(socket, :schedules, Map.put(socket.assigns.schedules, kind, schedule))

      case YellowDog.ManagementUI.Commands.command(socket, "update_task", payload, key) do
        {:ok, task} ->
          schedules = Map.put(socket.assigns.schedules, kind, schedule(task))

          {:noreply,
           socket
           |> assign(schedules: schedules)
           |> refresh()
           |> put_flash(:info, "Synchronization settings saved in Management.")}

        {:error, error} ->
          {:noreply, assign(socket, error: error[:message] || error["message"])}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("reload_schedule", %{"type" => kind}, socket) when kind in ~w(city country) do
    case Database.read(fn -> Domain.get_task("ip_#{kind}") end) do
      {:ok, {:ok, task}} ->
        {:noreply,
         assign(socket, schedules: Map.put(socket.assigns.schedules, kind, schedule(task)))}

      {:error, _error} ->
        {:noreply, refresh_unavailable(socket)}
    end
  end

  def handle_event(_event, _params, socket),
    do: {:noreply, assign(socket, error: "Invalid catalog action")}

  @impl true
  def handle_info({:task_updated, key}, socket) when key in ~w(ip_city ip_country),
    do: {:noreply, refresh(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async({:artifact_check, kind, token}, outcome, socket) do
    case socket.assigns.checks[kind] do
      %{token: ^token, state: :cancelling} ->
        # Start the latest selection only after the old task exits or finishes.
        selected = Enum.find(socket.assigns.databases, &(&1.kind == kind)).selected

        {:noreply,
         socket
         |> assign(:checks, Map.delete(socket.assigns.checks, kind))
         |> verify_selection(kind, selected, false)
         |> apply_checks()}

      %{token: ^token, state: :checking} = check ->
        {state, available, reason} =
          case outcome do
            {:ok, {:ok, {:ok, _artifact}}} ->
              {:verified, true, nil}

            {:ok, {:ok, {:error, reason}}} ->
              {:verified, false, reason}

            {:ok, {:error, %{code: "database_unavailable"}}} ->
              {:unavailable, nil, :database_unavailable}

            {:exit, _reason} ->
              {:unavailable, nil, :verification_interrupted}
          end

        check =
          Map.merge(check, %{
            state: state,
            available: available,
            availability_error: reason,
            checked_at: DateTime.utc_now()
          })

        {:noreply,
         socket
         |> assign(:checks, Map.put(socket.assigns.checks, kind, check))
         |> apply_checks()}

      _ ->
        {:noreply, socket}
    end
  end

  defp refresh(socket, revalidate \\ false) do
    case Database.read(fn -> refresh_data(socket) end) do
      {:ok, {databases, schedules, result}} ->
        apply_refresh(socket, databases, schedules, result, revalidate)

      {:error, _error} ->
        refresh_unavailable(socket)
    end
  end

  defp refresh_unavailable(socket) do
    detail =
      if socket.assigns.databases == [],
        do: "No catalog data has been loaded. Refresh to retry.",
        else:
          "Showing last known catalog and synchronization data; retained settings have not been discarded."

    assign(
      socket,
      :refresh_error,
      "Data refresh unavailable: Management could not read PostgreSQL. " <> detail
    )
  end

  defp refresh_data(socket) do
    tasks = Map.new(Domain.list_tasks(), &{&1["key"], &1})

    databases =
      Enum.map(
        TaskArtifacts.catalog(pages: socket.assigns.pages),
        &Map.put(&1, :task, tasks["ip_#{&1.kind}"])
      )

    schedules =
      Enum.reduce(databases, socket.assigns.schedules, fn database, schedules ->
        Map.put_new_lazy(schedules, database.kind, fn -> schedule(database.task) end)
      end)

    result = socket.assigns.download_result

    result =
      if result do
        Enum.find(Domain.list_task_jobs(result["task_key"]), &(&1["id"] == result["id"])) ||
          result
      end

    {databases, schedules, result}
  end

  defp apply_refresh(socket, databases, schedules, result, revalidate) do
    socket =
      assign(socket,
        databases: databases,
        schedules: schedules,
        download_result: result,
        refresh_error: nil
      )

    socket =
      if connected?(socket) do
        Enum.reduce(databases, socket, fn database, socket ->
          verify_selection(socket, database.kind, database.selected, revalidate)
        end)
      else
        socket
      end

    apply_checks(socket)
  end

  # At most one task and one cached result per kind, scoped to this mounted page.
  # Explicit refresh rechecks bytes; task updates reuse a result for at most 60 seconds.
  defp verify_selection(socket, kind, selected, revalidate) do
    identity =
      if selected, do: {selected.digest, selected.selected_at, selected.job_id, selected.attempt}

    check = socket.assigns.checks[kind]
    same = check && check.identity == identity

    fresh =
      same && check.state == :verified &&
        DateTime.diff(DateTime.utc_now(), check.checked_at) < @verification_ttl

    cond do
      check && check.state == :cancelling ->
        socket

      same && check.state == :checking ->
        socket

      fresh && !revalidate ->
        socket

      check && check.state == :checking ->
        socket
        |> cancel_async({:artifact_check, kind, check.token})
        |> assign(:checks, Map.put(socket.assigns.checks, kind, %{check | state: :cancelling}))

      true ->
        socket = assign(socket, :checks, Map.delete(socket.assigns.checks, kind))

        if selected do
          token = make_ref()
          digest = selected.digest

          check = %{
            identity: identity,
            token: token,
            state: :checking,
            available: nil,
            availability_error: nil,
            checked_at: nil
          }

          socket
          |> assign(:checks, Map.put(socket.assigns.checks, kind, check))
          |> start_async({:artifact_check, kind, token}, fn ->
            Database.read(fn -> TaskArtifacts.get(kind, digest) end)
          end)
        else
          socket
        end
    end
  end

  defp apply_checks(socket) do
    databases =
      Enum.map(socket.assigns.databases, fn database ->
        check = socket.assigns.checks[database.kind]
        selected = database.selected

        if selected && check &&
             (check.state == :cancelling ||
                check.identity ==
                  {selected.digest, selected.selected_at, selected.job_id, selected.attempt}) do
          status = %{
            verification: if(check.state == :cancelling, do: :checking, else: check.state),
            available: check.available,
            availability_error: check.availability_error,
            checked_at: check.checked_at
          }

          %{
            database
            | selected: Map.merge(selected, status),
              versions:
                Enum.map(database.versions, fn version ->
                  if version.digest == selected.digest,
                    do: Map.merge(version, status),
                    else: version
                end)
          }
        else
          database
        end
      end)

    assign(socket, :databases, databases)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app caller={@caller} flash={@flash} current_path={@current_path}>
      <div id="ip-database-workflow" phx-hook="EditorGuard">
        <h1>IP Database</h1>
        <button id="ip-database-refresh" class="btn btn-secondary" phx-click="refresh">Refresh</button>
        <p class="management-help">
          Global, versioned database artifacts synchronized by Management. Saved in Management; not included in the current Worker target/export. Synchronization does not mean delivery or loading on a Worker.
        </p>
        <p
          :if={@download_result}
          id="ip-database-download-result"
          data-job-id={@download_result["id"]}
          data-task-key={@download_result["task_key"]}
          role="status"
        >
          Synchronization {result_state(@download_result)} (job {@download_result["id"]}). Queueing is not successful completion.
          <.link navigate={"/system/tasks/#{@download_result["task_key"]}#task-job-#{@download_result["id"]}"}>View this job in Monitoring</.link>
        </p>
        <p :if={@refresh_error} id="ip-database-refresh-error" role="alert">{@refresh_error}</p>
        <p :if={@error} id="ip-database-error" class="alert alert-error" role="alert">{@error}</p>
        <section
          :for={database <- @databases}
          id={"ip-database-#{database.kind}"}
          class="card card-bordered"
        >
          <div class="card-body">
            <h2>{String.capitalize(database.kind)} Database</h2>
            <h3>Source and synchronization settings</h3>
            <p class="management-help">
              The source is configured by Management deployment. Schedule uses five-field UTC cron.
            </p>
            <.form
              for={@schedules[database.kind].form}
              id={"ip-database-settings-#{database.kind}"}
              phx-change="validate_schedule"
              phx-submit="save_schedule"
              data-editor="true"
              data-editor-dirty={to_string(@schedules[database.kind].dirty)}
              data-editor-reset={@schedules[database.kind].reset}
            >
              <input type="hidden" name="type" value={database.kind} />
              <input type="hidden" name="_submission" value={@schedules[database.kind].token} />
              <label class="management-field">
                <span>Scheduled synchronization</span>
                <select class="select" name="task[enabled]">
                  <option
                    value="false"
                    selected={@schedules[database.kind].form.params["enabled"] == "false"}
                  >
                    Disabled
                  </option>
                  <option
                    value="true"
                    selected={@schedules[database.kind].form.params["enabled"] == "true"}
                  >
                    Enabled
                  </option>
                </select>
              </label>
              <label class="management-field">
                <span>UTC cron</span>
                <input
                  class="input"
                  name="task[cron]"
                  value={@schedules[database.kind].form.params["cron"]}
                  maxlength="128"
                  required
                />
              </label>
              <p>Saved settings revision {@schedules[database.kind].revision}.</p>
              <button class="btn btn-secondary" type="submit" phx-disable-with="Saving…">Save synchronization settings</button>
              <button
                class="btn btn-ghost"
                type="button"
                phx-click="reload_schedule"
                phx-value-type={database.kind}
                data-editor-discard={"ip-database-settings-#{database.kind}"}
              >Discard changes and reload settings</button>
            </.form>
            <h3>Current selected artifact and synchronization result</h3>
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
              <dt>Last integrity check</dt><dd data-checked-at={checked_at(database.selected)}>
                {checked_at(database.selected) || "Not checked"}
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
              <p :if={database.selected.verification == :unavailable} role="alert">
                Integrity check unavailable; selected bytes have not been verified. Refresh to retry.
              </p>
              <p :if={database.selected.available == false} role="alert">
                Selected artifact unavailable: {inspect(database.selected.availability_error)}. Synchronize a valid durable file before distributing it.
              </p>
            </div>
            <p class="management-help">
              A failed new synchronization can coexist with an available previous artifact. Requests while a job is active reuse that job; a later request after completion starts a new synchronization.
            </p>
            <div class="management-actions">
              <button
                id={"ip-database-download-#{database.kind}"}
                class="btn btn-primary"
                phx-click="download"
                phx-value-type={database.kind}
                phx-value-_submission={@sync_intents[database.kind].token}
                phx-disable-with="Queueing…"
              >{if @sync_intents[database.kind].attempted,
                do: "Retry synchronization",
                else: "Queue IP #{String.capitalize(database.kind)}"}</button>
              <button
                :if={@sync_intents[database.kind].attempted}
                class="btn btn-secondary"
                phx-click="new_sync"
                phx-value-type={database.kind}
                phx-value-_submission={@sync_intents[database.kind].token}
              >Start a new synchronization intent</button>
              <.link navigate={"/system/tasks/ip_#{database.kind}"} class="btn btn-secondary">Synchronization history in Monitoring (sync history)</.link>
            </div>
            <h3>Dataset versions</h3>
            <p class="management-help">
              Historical metadata is unverified. Refresh checks selected files.
            </p>
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
            <div class="management-actions">
              <button
                id={"ip-database-previous-#{database.kind}"}
                class="btn btn-secondary"
                phx-click="history_page"
                phx-value-type={database.kind}
                phx-value-direction="previous"
                disabled={database.page == 1}
              >Previous versions</button>
              <span>Page {database.page}</span>
              <button
                id={"ip-database-next-#{database.kind}"}
                class="btn btn-secondary"
                phx-click="history_page"
                phx-value-type={database.kind}
                phx-value-direction="next"
                disabled={!database.has_more}
              >Next versions</button>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp sync_intent,
    do: %{token: Ecto.UUID.generate(), key: Ecto.UUID.generate(), attempted: false}

  defp new_sync_intents, do: Map.new(~w(city country), &{&1, sync_intent()})

  defp schedule(task),
    do: %{
      revision: task["revision"],
      token: Ecto.UUID.generate(),
      previous_token: nil,
      reset: Ecto.UUID.generate(),
      request: nil,
      dirty: false,
      form:
        to_form(%{"enabled" => to_string(task["enabled"]), "cron" => task["cron"] || ""},
          as: "task"
        )
    }

  defp retain_schedule(socket, kind, params) do
    schedule = socket.assigns.schedules[kind]
    fields = Map.merge(schedule.form.params, Map.take(params, ~w(enabled cron)))

    updated = %{
      schedule
      | form: to_form(fields, as: "task"),
        dirty: schedule.dirty || fields != schedule.form.params
    }

    updated =
      if fields != schedule.form.params and schedule.request do
        %{updated | token: Ecto.UUID.generate(), previous_token: schedule.token, request: nil}
      else
        updated
      end

    assign(socket, :schedules, Map.put(socket.assigns.schedules, kind, updated))
  end

  defp result_state(%{"state" => state}) when state in ~w(available scheduled retryable),
    do: "queued"

  defp result_state(%{"state" => "completed"}), do: "succeeded"
  defp result_state(%{"state" => "discarded"}), do: "failed"
  defp result_state(%{"state" => state}), do: state

  defp availability(nil), do: "No selected artifact"
  defp availability(%{verification: :checking}), do: "Checking"
  defp availability(%{verification: :unavailable}), do: "Check unavailable"
  defp availability(%{verification: :unverified}), do: "Unverified"
  defp availability(%{available: true}), do: "Available"
  defp availability(_artifact), do: "Unavailable"

  defp checked_at(nil), do: nil
  defp checked_at(%{checked_at: nil}), do: nil
  defp checked_at(%{checked_at: value}), do: display(value)

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
