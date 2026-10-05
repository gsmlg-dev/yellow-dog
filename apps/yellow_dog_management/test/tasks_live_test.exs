defmodule YellowDog.Management.TasksLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Domain, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "overview, detail and logs read real task state without writes or login", %{conn: conn} do
    before_visit = snapshot()
    {:ok, index, html} = live(conn, "/system/tasks?task[]=mac")
    assert has_element?(index, "#tasks-overview")
    assert Enum.sort(Enum.map(Domain.list_tasks(), & &1["key"])) == ~w(ip_city ip_country mac)

    for task <- Domain.list_tasks() do
      assert has_element?(index, "#task-row-#{task["key"]}", task["label"])
      assert has_element?(index, "#task-schedule-#{task["key"]}")
      assert has_element?(index, "a[href='/system/tasks/#{task["key"]}']", "View History")
    end

    refute html =~ "type=\"password\""
    assert html =~ "UTC"
    assert html =~ "Cloud-provider synchronization is not implemented"

    {:ok, detail, _html} = live(conn, "/system/tasks/ip_city")
    assert has_element?(detail, "#task-detail[data-task-key='ip_city']")
    assert has_element?(detail, "#task-jobs-empty", "No jobs have been queued")
    {:ok, logs, _html} = live(conn, "/system/logs/tasks")
    assert has_element?(logs, "#task-logs")
    refute has_element?(logs, "form[phx-submit='save_task_config']")
    assert snapshot() == before_visit
    render_click(index, "refresh", %{})
    render_click(detail, "refresh", %{})
    render_click(logs, "refresh", %{})
    assert snapshot() == before_visit
  end

  test "inline schedule edits persist enabled and standard UTC cron", %{conn: conn} do
    {:ok, original} = Domain.get_task("ip_city")
    {:ok, view, _html} = live(conn, "/system/tasks")

    view
    |> form("#task-schedule-ip_city", task: %{enabled: "true", cron: "15 3 * * 1-5"})
    |> render_submit()

    assert {:ok, updated} = Domain.get_task("ip_city")
    assert updated["enabled"] == true
    assert updated["cron"] == "15 3 * * 1-5"
    assert updated["revision"] == original["revision"] + 1

    assert has_element?(
             view,
             "#task-schedule-ip_city input[name='task[enabled]'][type='checkbox'][checked]"
           )

    assert Domain.list_task_history() == []

    view |> form("#task-schedule-ip_city", task: %{enabled: "false"}) |> render_submit()
    assert {:ok, disabled} = Domain.get_task("ip_city")
    assert disabled["enabled"] == false
  end

  test "invalid cron records rejection while malformed forms preserve tasks, jobs and audit", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/system/tasks/ip_city")
    before_invalid = snapshot()

    for task_params <- [
          %{"enabled" => "true", "cron" => "not a cron"},
          %{"enabled" => "true", "cron" => "0 0 0 * * *"},
          %{"enabled" => "true", "cron" => %{}},
          %{"enabled" => ["true"], "cron" => "0 0 * * *"},
          %{"enabled" => "yes", "cron" => "0 0 * * *"}
        ] do
      before_request = Domain.list_audit()

      render_submit(view, "save_task_config", %{"task_key" => "ip_country", "task" => task_params})

      assert has_element?(view, "#task-action-error")
      assert Process.alive?(view.pid)
      {tasks, jobs, _audit} = before_invalid
      assert Domain.list_tasks() == tasks
      assert Domain.list_task_history() == jobs

      if task_params["enabled"] == "true" and is_binary(task_params["cron"]) do
        assert_rejected_schedule(before_request, task_params["cron"])
      else
        assert Domain.list_audit() == before_request
      end
    end

    before_request = Domain.list_audit()

    view
    |> form("#task-schedule-ip_city", task: %{enabled: "true", cron: "bad"})
    |> render_submit()

    assert has_element?(view, "#task-schedule-ip_city input[name='task[cron]'][value='bad']")
    {tasks, jobs, _audit} = before_invalid
    assert Domain.list_tasks() == tasks
    assert Domain.list_task_history() == jobs
    assert_rejected_schedule(before_request, "bad")
  end

  test "matched detail identity ignores query and forged task keys", %{conn: conn} do
    {:ok, other} = Domain.get_task("ip_country")

    for query <- ["task=ip_country", "task[]=ip_country", "task[key]=ip_country"] do
      {:ok, view, _html} = live(conn, "/system/tasks/ip_city?" <> query)
      assert has_element?(view, "#task-detail[data-task-key='ip_city']")

      render_submit(view, "save_task_config", %{
        "task_key" => "ip_country",
        "task" => %{
          "key" => "ip_country",
          "enabled" => "false",
          "cron" => "20 4 * * *",
          "expected_revision" => "999999"
        }
      })

      assert {:ok, selected} = Domain.get_task("ip_city")
      assert selected["cron"] == "20 4 * * *"
      assert {:ok, ^other} = Domain.get_task("ip_country")
    end
  end

  test "unknown scoped task fails closed for queries, refresh and forged events", %{conn: conn} do
    before_visit = snapshot()

    for query <- ["task=ip_city", "task[]=ip_city", "task[key]=ip_city"] do
      {:ok, view, _html} = live(conn, "/system/tasks/missing?" <> query)
      assert has_element?(view, "#task-scope-error", "Task not found")
      refute has_element?(view, "#task-detail")
      refute has_element?(view, "form[phx-submit='save_task_config']")

      render_submit(view, "save_task_config", %{
        "task_key" => "ip_city",
        "task" => %{"enabled" => "true", "cron" => "0 0 * * *"}
      })

      render_click(view, "run_now", %{"task" => "ip_city"})
      render_click(view, "refresh", %{})
      assert snapshot() == before_visit
      assert Process.alive?(view.pid)
    end
  end

  test "stale schedule CAS preserves the operator form until explicit refresh", %{conn: conn} do
    {:ok, original} = Domain.get_task("ip_city")
    {:ok, view, _html} = live(conn, "/system/tasks/ip_city")

    concurrent =
      mutate("update_task", %{
        "key" => "ip_city",
        "expected_revision" => original["revision"],
        "enabled" => false,
        "cron" => "10 2 * * *"
      })

    view
    |> form("#task-schedule-ip_city", task: %{enabled: "true", cron: "45 6 * * *"})
    |> render_submit()

    assert has_element?(view, "#task-action-error", "refresh")

    assert has_element?(
             view,
             "#task-schedule-ip_city input[name='task[cron]'][value='45 6 * * *']"
           )

    assert {:ok, ^concurrent} = Domain.get_task("ip_city")
    render_click(view, "refresh", %{})

    assert has_element?(
             view,
             "#task-schedule-ip_city input[name='task[cron]'][value='10 2 * * *']"
           )

    refute has_element?(view, "#task-action-error")
  end

  test "manual run is durable even when schedule disabled and does not report success", %{
    conn: conn
  } do
    {:ok, task} = Domain.get_task("ip_city")
    assert task["available"]

    mutate("update_task", %{
      "key" => "ip_city",
      "expected_revision" => task["revision"],
      "enabled" => false,
      "cron" => "0 0 * * *"
    })

    {:ok, view, _html} = live(conn, "/system/tasks/ip_city?task[]=mac")
    refute has_element?(view, "#task-run-ip_city[disabled]")
    render_click(view, "run_now", %{"task" => "ip_country", "key" => "mac"})

    [job] = Domain.list_task_jobs("ip_city")
    assert job["task_key"] == "ip_city"
    assert job["state"] in ~w(available scheduled)
    assert job["result"] == nil
    assert has_element?(view, "#task-job-#{job["id"]}", job["state"])
    assert has_element?(view, "#task-action-result", "queued")
    refute has_element?(view, "#task-action-result", "succeeded")
    assert Domain.list_task_jobs("ip_country") == []
    assert Domain.list_task_jobs("mac") == []

    {:ok, index, _html} = live(conn, "/system/tasks")
    assert has_element?(index, "#task-row-ip_city", "active")
    {:ok, logs, _html} = live(conn, "/system/logs/tasks")
    assert has_element?(logs, "#task-job-#{job["id"]}", "ip_city")
    assert has_element?(logs, "#task-job-#{job["id"]}", job["inserted_at"])
  end

  test "unavailable MAC cannot be queued and logs cannot mutate any task", %{conn: conn} do
    {:ok, task} = Domain.get_task("mac")
    assert task["available"] == false
    {:ok, view, html} = live(conn, "/system/tasks/mac")
    assert has_element?(view, "#task-run-mac[disabled]")
    assert html =~ task["unavailable_reason"]
    before_actions = snapshot()
    render_click(view, "run_now", %{"task" => "ip_city"})
    assert has_element?(view, "#task-action-error")
    assert snapshot() == before_actions

    {:ok, index, _html} = live(conn, "/system/tasks")

    for key <- ["missing", ["ip_city"], %{"key" => "ip_city"}] do
      render_click(index, "run_now", %{"task" => key})
      assert snapshot() == before_actions
    end

    {:ok, logs, _html} = live(conn, "/system/logs/tasks")
    render_click(logs, "run_now", %{"task" => "ip_city"})

    render_submit(logs, "save_task_config", %{
      "task_key" => "ip_city",
      "task" => %{"enabled" => "true", "cron" => "0 0 * * *"}
    })

    assert snapshot() == before_actions
  end

  test "PubSub updates current status and history without replacing schedule CAS", %{conn: conn} do
    {:ok, original} = Domain.get_task("ip_city")
    {:ok, view, _html} = live(conn, "/system/tasks/ip_city")

    mutate("update_task", %{
      "key" => "ip_city",
      "expected_revision" => original["revision"],
      "enabled" => false,
      "cron" => "5 1 * * *"
    })

    Phoenix.PubSub.broadcast(
      YellowDog.ManagementUI.PubSub,
      "management:tasks",
      {:task_updated, "ip_city"}
    )

    assert render(view) =~ "Schedule changed elsewhere"

    assert has_element?(
             view,
             "#task-schedule-ip_city input[name='task[cron]'][value='#{original["cron"]}']"
           )

    before_render = snapshot()

    Phoenix.PubSub.broadcast(
      YellowDog.ManagementUI.PubSub,
      "management:tasks",
      {:task_updated, "ip_country"}
    )

    render(view)
    assert snapshot() == before_render
  end

  test "history renders persisted attempt errors, timestamps and separate result receipts", %{
    conn: conn
  } do
    queued = mutate("run_task", %{"key" => "ip_city"})
    attempted_at = DateTime.utc_now()

    job =
      Repo.get!(Oban.Job, queued["id"], prefix: "management_jobs")
      |> Ecto.Changeset.change(
        state: "retryable",
        attempt: 1,
        attempted_at: attempted_at,
        errors: [
          %{
            "attempt" => 1,
            "at" => DateTime.to_iso8601(attempted_at),
            "error" => "Fixture download failed <script>"
          }
        ]
      )
      |> Repo.update!()

    {:ok, detail, html} = live(conn, "/system/tasks/ip_city")
    assert has_element?(detail, "#task-job-#{job.id}", "retryable")
    assert has_element?(detail, "#task-job-#{job.id}", "Fixture download failed <script>")
    assert html =~ "&lt;script&gt;"
    refute has_element?(detail, "#task-job-#{job.id} script")
    assert has_element?(detail, "#task-job-#{job.id}", "No result receipt recorded")

    completed_at = DateTime.utc_now()
    job |> Ecto.Changeset.change(state: "completed", completed_at: completed_at) |> Repo.update!()

    Repo.insert!(%YellowDog.Management.TaskReceipt{
      job_id: job.id,
      task_key: "ip_city",
      result: %{"digest" => "fixture-artifact-digest", "database_type" => "GeoIP2-City"}
    })

    before_refresh = snapshot()

    Phoenix.PubSub.broadcast(
      YellowDog.ManagementUI.PubSub,
      "management:tasks",
      {:task_updated, "ip_city"}
    )

    render(detail)
    [completed] = Domain.list_task_jobs("ip_city")
    assert has_element?(detail, "#task-job-#{job.id}", "completed")
    assert has_element?(detail, "#task-job-#{job.id}", "fixture-artifact-digest")
    assert has_element?(detail, "#task-job-#{job.id}", completed["attempted_at"])
    assert has_element?(detail, "#task-job-#{job.id}", completed["completed_at"])

    {:ok, logs, _html} = live(conn, "/system/logs/tasks")
    assert has_element?(logs, "#task-job-#{job.id}", "GeoIP2-City")
    assert snapshot() == before_refresh
  end

  test "active pages observe completion after the final broadcast and stop polling", %{conn: conn} do
    queued = mutate("run_task", %{"key" => "ip_city"})

    job =
      Repo.get!(Oban.Job, queued["id"], prefix: "management_jobs")
      |> Ecto.Changeset.change(state: "executing", attempt: 1, attempted_at: DateTime.utc_now())
      |> Repo.update!()

    views =
      for path <- ["/system/tasks", "/system/tasks/ip_city", "/system/logs/tasks"] do
        {:ok, view, _html} = live(conn, path)
        view
      end

    Phoenix.PubSub.broadcast(
      YellowDog.ManagementUI.PubSub,
      "management:tasks",
      {:task_updated, "ip_city"}
    )

    Enum.each(views, &render/1)

    job
    |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    Repo.insert!(%YellowDog.Management.TaskReceipt{
      job_id: job.id,
      task_key: "ip_city",
      result: %{"digest" => "completion-without-broadcast"}
    })

    before_poll = snapshot()
    [index, detail, logs] = views

    assert eventually(fn ->
             has_element?(index, "#task-row-ip_city", "succeeded") and
               has_element?(detail, "#task-job-#{job.id}", "completed") and
               has_element?(logs, "#task-job-#{job.id}", "completion-without-broadcast")
           end)

    for view <- views do
      assert :sys.get_state(view.pid).socket.assigns.poll_timer == nil
    end

    assert snapshot() == before_poll
  end

  defp eventually(predicate, attempts \\ 50)
  defp eventually(_predicate, 0), do: false

  defp eventually(predicate, attempts) do
    if predicate.() do
      true
    else
      Process.sleep(100)
      eventually(predicate, attempts - 1)
    end
  end

  defp snapshot, do: {Domain.list_tasks(), Domain.list_task_history(), Domain.list_audit()}

  defp assert_rejected_schedule(before_request, cron) do
    audit = Domain.list_audit()
    assert length(audit) == length(before_request) + 1
    receipt = Enum.find(audit, &(&1 not in before_request))
    assert receipt["operation"] == "update_task"
    assert receipt["actor"] == "operator"

    assert receipt["request"] == %{
             "key" => "ip_city",
             "expected_revision" => 1,
             "enabled" => true,
             "cron" => cron
           }

    assert receipt["result"]["error"]["code"] == "invalid_request"
  end

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
