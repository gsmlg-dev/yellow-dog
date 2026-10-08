defmodule YellowDog.ManagementUI.IpDatabaseLive do
  use YellowDog.ManagementUI, :live_view

  alias YellowDog.Management.{Domain, TaskArtifacts}

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
       error: nil,
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
        {available, reason} =
          case outcome do
            {:ok, {:ok, _artifact}} -> {true, nil}
            {:ok, {:error, reason}} -> {false, reason}
            {:exit, _reason} -> {false, :verification_interrupted}
          end

        check =
          Map.merge(check, %{
            state: :verified,
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
    tasks = Map.new(Domain.list_tasks(), &{&1["key"], &1})

    databases =
      Enum.map(
        TaskArtifacts.catalog(pages: socket.assigns.pages),
        &Map.put(&1, :task, tasks["ip_#{&1.kind}"])
      )

    socket = assign(socket, databases: databases, error: nil)

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
          |> start_async({:artifact_check, kind, token}, fn -> TaskArtifacts.get(kind, digest) end)
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
            <p :if={database.selected.available == false} role="alert">
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
    </Layouts.app>
    """
  end

  defp availability(nil), do: "No selected artifact"
  defp availability(%{verification: :checking}), do: "Checking"
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
