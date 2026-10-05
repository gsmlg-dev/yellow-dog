defmodule YellowDog.Management.IpDatabaseLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{
    Domain,
    GeoIPDownload,
    GeoIPDownloadFixture,
    GeoIPFixtures,
    GeoIPSelection,
    Repo,
    SyncGeoIPWorker,
    TaskArtifacts,
    TaskDefinition
  }

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    directory = Path.join(System.tmp_dir!(), "management-ipdb-ui-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    assert is_nil(Process.whereis(YellowDog.Management.GeoIP))
    %{conn: build_conn(), directory: directory}
  end

  test "durable catalog metadata and versions survive a fresh LiveView session", context do
    artifact = publish_fixture(context.directory)
    {:ok, view, html} = live(context.conn, "/system/ip-database")
    assert has_element?(view, "#ip-database-city [data-status='Available']")
    assert has_element?(view, "#ip-database-city [data-digest='#{artifact.digest}']")
    assert has_element?(view, "#ip-database-city", "#{artifact.size} bytes")
    assert has_element?(view, "#ip-database-city", "GeoIP2-City")
    assert has_element?(view, "#ip-database-city", "mmdb")
    assert has_element?(view, "#ip-database-city [data-sync-state='completed']")
    assert has_element?(view, "#ip-database-versions-city tr[data-digest='#{artifact.digest}']")
    assert has_element?(view, "#ip-database-country [data-status='No selected artifact']")
    assert has_element?(view, "#ip-database-country", "No synchronized datasets")
    assert has_element?(view, "a[href='/system/tasks/ip_city']", "sync history")
    assert has_element?(view, "a[href='/system/tasks/ip_country']", "sync history")

    for label <- [
          "Source",
          "Schedule",
          "Last successful synchronization",
          "Selected digest",
          "Published",
          "Metadata"
        ] do
      assert html =~ label
    end

    refute html =~ artifact.path
    refute html =~ "Loaded snapshot"
    refute has_element?(view, "button[phx-click='reload']")
    refute has_element?(view, "button[phx-click='unload']")
    refute has_element?(view, "select[name*='worker']")
    assert html =~ "Synchronization does not mean delivery or loading on a Worker"

    {:ok, fresh, _html} = live(build_conn(), "/system/ip-database")
    assert has_element?(fresh, "#ip-database-city [data-digest='#{artifact.digest}']")
    assert has_element?(fresh, "#ip-database-city [data-status='Available']")
  end

  test "direct sync buttons queue durable jobs while schedules and availability stay separate", %{
    conn: conn
  } do
    tasks = Repo.all(TaskDefinition) |> Enum.sort_by(& &1.key)
    before_audit = Domain.list_audit()
    {:ok, view, _html} = live(conn, "/system/ip-database")

    for type <- ~w(city country) do
      view |> element("#ip-database-download-#{type}") |> render_click()
      assert [job] = Domain.list_task_jobs("ip_#{type}")
      assert job["state"] == "available"
      assert job["attempt"] == 0
      assert is_nil(job["result"])

      assert has_element?(
               view,
               "#ip-database-download-result[data-job-id='#{job["id"]}'][data-task-key='ip_#{type}']"
             )

      assert has_element?(
               view,
               "#ip-database-download-result",
               "Queueing is not successful completion"
             )

      assert has_element?(view, "#ip-database-#{type} [data-sync-state='queued']")
      assert has_element?(view, "#ip-database-#{type} [data-status='No selected artifact']")
    end

    assert Repo.all(TaskDefinition) |> Enum.sort_by(& &1.key) == tasks
    assert [first, second] = Domain.list_audit() -- before_audit
    assert Enum.all?([first, second], &(&1["operation"] == "run_task"))
    assert is_nil(Process.whereis(YellowDog.Management.GeoIP))
  end

  test "server-selected task keys reject forged types and ignore client URLs and paths", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/system/ip-database")

    before_read =
      {Domain.list_tasks(), Domain.list_task_history(), Domain.list_audit(),
       TaskArtifacts.catalog()}

    for payload <- [%{}, %{"type" => "mac"}, %{"type" => []}, %{"type" => %{}}, %{"type" => 1}] do
      assert render_click(view, "download", payload) =~ "Invalid catalog action"

      assert {Domain.list_tasks(), Domain.list_task_history(), Domain.list_audit(),
              TaskArtifacts.catalog()} == before_read
    end

    render_click(view, "download", %{
      "type" => "city",
      "key" => "mac",
      "source_url" => "http://attacker.invalid/",
      "path" => "/etc/passwd"
    })

    assert [job] = Domain.list_task_jobs("ip_city")
    canonical = Repo.get!(Oban.Job, job["id"], prefix: "management_jobs")
    assert canonical.args["source_url"] != "http://attacker.invalid/"
    refute Map.has_key?(canonical.args, "path")
    assert Domain.list_task_jobs("ip_country") == []
    assert Domain.list_task_jobs("mac") == []
    assert [audit] = Domain.list_audit() -- elem(before_read, 2)
    assert audit["request"] == %{"key" => "ip_city"}
    assert has_element?(view, "#ip-database-download-result")
    refute has_element?(view, "#ip-database-error")
  end

  test "queue insertion failure cannot report success or replace available artifacts", context do
    artifact = publish_fixture(context.directory)
    catalog = TaskArtifacts.catalog()
    {:ok, view, _html} = live(context.conn, "/system/ip-database")
    view |> element("#ip-database-download-city") |> render_click()
    assert has_element?(view, "#ip-database-download-result")
    before_failure = Domain.list_audit()
    Repo.query!("ALTER TABLE management_jobs.oban_jobs DROP CONSTRAINT positive_max_attempts")

    Repo.query!(
      "ALTER TABLE management_jobs.oban_jobs ADD CONSTRAINT positive_max_attempts CHECK (false) NOT VALID"
    )

    view |> element("#ip-database-download-country") |> render_click()
    assert has_element?(view, "#ip-database-error", "Task could not be queued")
    refute has_element?(view, "#ip-database-download-result")
    assert TaskArtifacts.catalog() == catalog
    assert has_element?(view, "#ip-database-city [data-digest='#{artifact.digest}']")
    assert has_element?(view, "#ip-database-city [data-status='Available']")
    assert Domain.list_task_jobs("ip_country") == []
    assert [audit] = Domain.list_audit() -- before_failure
    assert audit["result"]["error"]["code"] == "invalid_request"
  end

  test "a failed real synchronization retains the prior available digest and displays its error",
       context do
    artifact = publish_fixture(context.directory)
    {:ok, view, _html} = live(context.conn, "/system/ip-database")

    {:ok, _queued} =
      SyncGeoIPWorker.new(%{
        "task_key" => "ip_city",
        "source_url" => "http://127.0.0.1:1/missing"
      })
      |> Oban.insert()

    assert %{failure: 1, success: 0} =
             Oban.drain_queue(queue: :management_sync, with_safety: true)

    view |> element("#ip-database-refresh") |> render_click()

    assert has_element?(view, "#ip-database-city [data-sync-state='retryable']")
    assert has_element?(view, "#ip-database-city [data-status='Available']")
    assert has_element?(view, "#ip-database-city [data-digest='#{artifact.digest}']")
    assert has_element?(view, "#ip-database-city", "Last job error")
    assert has_element?(view, "#ip-database-city", "http_error")
    assert has_element?(view, "#ip-database-city", "Last successful synchronization")
    assert Repo.get!(GeoIPSelection, "city").digest == artifact.digest
    assert is_nil(Process.whereis(YellowDog.Management.GeoIP))
  end

  test "missing selected bytes become unavailable while completed job metadata stays visible",
       context do
    artifact = publish_fixture(context.directory)
    {:ok, view, _html} = live(context.conn, "/system/ip-database")
    File.rm!(artifact.path)
    view |> element("#ip-database-refresh") |> render_click()

    assert has_element?(view, "#ip-database-city [data-sync-state='completed']")
    assert has_element?(view, "#ip-database-city [data-status='Unavailable']")
    assert has_element?(view, "#ip-database-city [role='alert']", "enoent")

    assert has_element?(
             view,
             "#ip-database-versions-city tr[data-digest='#{artifact.digest}']",
             "Unavailable"
           )

    assert Repo.get!(GeoIPSelection, "city").digest == artifact.digest
  end

  test "pubsub refresh exposes new versions without changing immutable historical metadata",
       context do
    first = publish_fixture(context.directory)
    {:ok, view, _html} = live(context.conn, "/system/ip-database")
    changed = :binary.replace(GeoIPFixtures.binary(), "London", "Londox")
    second = publish_fixture(context.directory, changed)
    send(view.pid, {:task_updated, "ip_city"})
    assert has_element?(view, "#ip-database-city [data-digest='#{second.digest}']")
    assert has_element?(view, "#ip-database-versions-city tr[data-digest='#{first.digest}']")
    assert has_element?(view, "#ip-database-versions-city tr[data-digest='#{second.digest}']")
    assert File.read!(first.path) == GeoIPFixtures.binary()

    for event <- ~w(reload unload) do
      assert render_click(view, event, %{"type" => "city", "path" => "/etc/passwd"}) =~
               "Invalid catalog action"
    end

    assert {:ok, %{available: true}} = TaskArtifacts.get(:city, second.digest)
  end

  defp publish_fixture(directory, contents \\ GeoIPFixtures.binary()) do
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(contents))
    {:ok, artifact} = GeoIPDownload.fetch(:city, directory, url: url)

    job =
      Repo.insert!(
        %Oban.Job{
          worker: "YellowDog.Management.SyncGeoIPWorker",
          queue: "management_sync",
          args: %{"task_key" => "ip_city", "source_url" => url},
          state: "executing",
          attempt: 1,
          max_attempts: 3,
          attempted_at: DateTime.utc_now()
        },
        prefix: "management_jobs"
      )

    assert :ok = TaskArtifacts.publish(job, :city, artifact)

    job
    |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    artifact
  end
end
