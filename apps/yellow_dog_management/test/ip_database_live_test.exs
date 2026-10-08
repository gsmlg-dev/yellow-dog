defmodule YellowDog.Management.IpDatabaseLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{
    Domain,
    GeoIPArtifact,
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

  test "pending checks leave events responsive, deduplicate refreshes and reject stale results",
       context do
    first = publish_fixture(context.directory)
    pause_checks()
    {:ok, view, _html} = live(context.conn, "/system/ip-database")
    assert_receive {:check_pending, first_pid, first_digest}
    assert first_digest == first.digest
    first_monitor = Process.monitor(first_pid)
    first_check = :sys.get_state(view.pid).socket.assigns.checks["city"]
    assert has_element?(view, "#ip-database-city [data-status='Checking']")
    refute has_element?(view, "#ip-database-city [role='alert']")

    for _ <- 1..5 do
      render_click(view, "refresh")
      send(view.pid, {:task_updated, "ip_city"})
      assert render_click(view, "invalid") =~ "Invalid catalog action"
      state = :sys.get_state(view.pid).socket
      assert state.assigns.checks["city"] == first_check
      assert map_size(state.private.live_async) == 1
    end

    refute_received {:check_pending, _, _}

    second =
      publish_fixture(
        context.directory,
        :binary.replace(GeoIPFixtures.binary(), "London", "Londox")
      )

    send(view.pid, {:task_updated, "ip_city"})
    assert has_element?(view, "#ip-database-city [data-digest='#{second.digest}']")
    assert_receive {:DOWN, ^first_monitor, :process, ^first_pid, _reason}
    assert_receive {:check_pending, second_pid, second_digest}
    assert second_digest == second.digest
    socket = :sys.get_state(view.pid).socket
    assert map_size(socket.assigns.checks) == 1
    assert map_size(socket.private.live_async) <= 2

    assert {:noreply, ^socket} =
             YellowDog.ManagementUI.IpDatabaseLive.handle_async(
               {:artifact_check, "city", first_check.token},
               {:ok, {:ok, %{}}},
               socket
             )

    assert has_element?(view, "#ip-database-city [data-status='Checking']")
    send(second_pid, :finish_check)
    render_async(view)
    assert has_element?(view, "#ip-database-city [data-status='Available']")
    assert has_element?(view, "#ip-database-city [data-checked-at]")
    assert Repo.get!(GeoIPSelection, "city").digest == second.digest

    # Task updates reuse only the current selection's recent result.
    send(view.pid, {:task_updated, "ip_city"})
    assert has_element?(view, "#ip-database-city [data-status='Available']")
    refute_received {:check_pending, _, _}

    # Explicit refresh revalidates instead of treating cached availability as permanent.
    render_click(view, "refresh")
    assert_receive {:check_pending, refresh_pid, ^second_digest}
    render_click(view, "refresh")
    refute_received {:check_pending, _, _}
    send(refresh_pid, :finish_check)
    render_async(view)

    # Expired page-local results revalidate on task updates without sleeping.
    :sys.replace_state(view.pid, fn state ->
      check = state.socket.assigns.checks["city"]
      check = %{check | checked_at: DateTime.add(check.checked_at, -61, :second)}
      put_in(state.socket.assigns.checks["city"], check)
    end)

    send(view.pid, {:task_updated, "ip_city"})
    assert has_element?(view, "#ip-database-city [data-status='Checking']")
    assert_receive {:check_pending, expired_pid, ^second_digest}
    send(expired_pid, :finish_check)
    render_async(view)

    # The mounted cache cannot bypass the artifact consumer's byte check.
    File.rm!(second.path)
    assert {:error, {:file_error, :enoent}} = TaskArtifacts.get(:city, second.digest)
  end

  test "City and Country checks are bounded independently and cancellation precedes replacement",
       context do
    city = publish_fixture(context.directory)

    country = publish_fixture(context.directory, country_database(), :country)
    pause_checks()
    {:ok, view, _html} = live(context.conn, "/system/ip-database")
    assert_receive {:check_pending, first_pid, first_digest}
    assert_receive {:check_pending, second_pid, second_digest}
    assert MapSet.new([first_digest, second_digest]) == MapSet.new([city.digest, country.digest])
    city_pid = if first_digest == city.digest, do: first_pid, else: second_pid
    country_pid = if first_digest == city.digest, do: second_pid, else: first_pid
    monitor = Process.monitor(city_pid)
    assert map_size(:sys.get_state(view.pid).socket.private.live_async) == 2

    newer =
      publish_fixture(
        context.directory,
        :binary.replace(GeoIPFixtures.binary(), "London", "Londox")
      )

    send(view.pid, {:task_updated, "ip_city"})
    assert_receive {:DOWN, ^monitor, :process, ^city_pid, _reason}
    assert_receive {:check_pending, newer_pid, newer_digest}
    assert newer_digest == newer.digest
    refute Process.alive?(city_pid)
    assert Process.alive?(country_pid)
    assert map_size(:sys.get_state(view.pid).socket.private.live_async) == 2
    render_click(view, "refresh")
    refute_received {:check_pending, _, _}
    send(newer_pid, :finish_check)
    send(country_pid, :finish_check)
    render_async(view)

    for kind <- ~w(city country),
        do: assert(has_element?(view, "#ip-database-#{kind} [data-status='Available']"))
  end

  test "history navigation keeps a selected artifact outside the SQL page visible", context do
    artifact = publish_fixture(context.directory)
    timestamp = DateTime.add(DateTime.utc_now(), 10, :second)

    for number <- 1..25 do
      Repo.insert!(%GeoIPArtifact{
        digest: number |> Integer.to_string(16) |> String.pad_leading(64, "0"),
        kind: "city",
        format: "mmdb",
        path: "unverified-history-#{number}",
        size: 1,
        source_url: "https://fixture.invalid/history",
        metadata: %{},
        inserted_at: timestamp
      })
    end

    {:ok, view, _html} = live(context.conn, "/system/ip-database")
    render_async(view)
    assert has_element?(view, "#ip-database-city [data-status='Available']")
    assert has_element?(view, "#ip-database-city [data-digest='#{artifact.digest}']")
    refute has_element?(view, "#ip-database-versions-city tr[data-digest='#{artifact.digest}']")

    assert length(
             :sys.get_state(view.pid).socket.assigns.databases
             |> hd()
             |> Map.fetch!(:versions)
           ) == 20

    view |> element("#ip-database-next-city") |> render_click()
    assert has_element?(view, "#ip-database-city", "Page 2")

    assert has_element?(
             view,
             "#ip-database-versions-city tr[data-digest='#{artifact.digest}']",
             "Available"
           )

    assert has_element?(view, "#ip-database-next-city[disabled]")
    view |> element("#ip-database-previous-city") |> render_click()
    assert has_element?(view, "#ip-database-city", "Page 1")
    assert has_element?(view, "#ip-database-city [data-digest='#{artifact.digest}']")
    assert has_element?(view, "#ip-database-versions-city", "Unverified")
  end

  test "corrupt selected bytes are reported after asynchronous verification", context do
    artifact = publish_fixture(context.directory)
    File.chmod!(artifact.path, 0o644)
    File.write!(artifact.path, :binary.replace(GeoIPFixtures.binary(), "London", "Londox"))
    File.chmod!(artifact.path, 0o444)
    {:ok, view, _html} = live(context.conn, "/system/ip-database")
    render_async(view)
    assert has_element?(view, "#ip-database-city [data-status='Unavailable']")
    assert has_element?(view, "#ip-database-city [role='alert']", "artifact_digest_mismatch")
    assert has_element?(view, "#ip-database-city [data-sync-state='completed']")
    assert Repo.get!(GeoIPSelection, "city").digest == artifact.digest
  end

  test "durable catalog metadata and versions survive a fresh LiveView session", context do
    artifact = publish_fixture(context.directory)
    {:ok, view, html} = live(context.conn, "/system/ip-database")
    render_async(view)
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
    render_async(fresh)
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
    render_async(view)
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
    render_async(view)

    {:ok, _queued} =
      SyncGeoIPWorker.new(%{
        "task_key" => "ip_city",
        "source_url" => "http://127.0.0.1:1/missing"
      })
      |> Oban.insert()

    assert %{failure: 1, success: 0} =
             Oban.drain_queue(queue: :management_sync, with_safety: true)

    view |> element("#ip-database-refresh") |> render_click()
    render_async(view)

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
    render_async(view)
    File.rm!(artifact.path)
    view |> element("#ip-database-refresh") |> render_click()
    render_async(view)

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
    render_async(view)
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

  defp publish_fixture(directory, contents \\ GeoIPFixtures.binary(), type \\ :city) do
    {url, _server} = GeoIPDownloadFixture.start(200, :zlib.gzip(contents))
    {:ok, artifact} = GeoIPDownload.fetch(type, directory, url: url)

    job =
      Repo.insert!(
        %Oban.Job{
          worker: "YellowDog.Management.SyncGeoIPWorker",
          queue: "management_sync",
          args: %{"task_key" => "ip_#{type}", "source_url" => url},
          state: "executing",
          attempt: 1,
          max_attempts: 3,
          attempted_at: DateTime.utc_now()
        },
        prefix: "management_jobs"
      )

    assert :ok = TaskArtifacts.publish(job, type, artifact)

    job
    |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    artifact
  end

  defp pause_checks do
    handler = "ip-database-check-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler,
        [:yellow_dog, :management, :repo, :query],
        &__MODULE__.pause_artifact_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  # The same pointer-free synthetic Country fixture used by TaskArtifactsTest.
  # Changing strings in the real City fixture would invalidate its metadata pointers.
  defp country_database do
    metadata = %{
      "binary_format_major_version" => 2,
      "binary_format_minor_version" => 0,
      "build_epoch" => 1_750_000_000,
      "database_type" => "GeoIP2-Country",
      "description" => %{"en" => "Synthetic test database"},
      "ip_version" => 4,
      "languages" => ["en"],
      "node_count" => 1,
      "record_size" => 24
    }

    <<0, 0, 1, 0, 0, 1>> <>
      :binary.copy(<<0>>, 16) <>
      <<0xAB, 0xCD, 0xEF>> <> "MaxMind.com" <> encode_mmdb(metadata)
  end

  defp encode_mmdb(value) when is_map(value),
    do:
      <<7::3, map_size(value)::5>> <>
        Enum.map_join(value, fn {key, item} -> encode_mmdb(key) <> encode_mmdb(item) end)

  defp encode_mmdb(value) when is_binary(value), do: <<2::3, byte_size(value)::5>> <> value
  defp encode_mmdb(value) when is_integer(value), do: <<6::3, 4::5, value::32>>

  defp encode_mmdb(value) when is_list(value),
    do: <<0::3, length(value)::5, 4>> <> Enum.map_join(value, &encode_mmdb/1)

  def pause_artifact_query(_event, _measurements, metadata, owner) do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

    if metadata.source == "management_geoip_artifacts" and
         Enum.any?(stack, fn {module, _, _, _} -> module == Phoenix.LiveView.Async end) do
      send(owner, {:check_pending, self(), hd(metadata.params)})

      receive do
        :finish_check -> :ok
      after
        10_000 -> raise "artifact check was not released by test"
      end
    end
  end
end
