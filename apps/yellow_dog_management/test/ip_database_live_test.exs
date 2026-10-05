defmodule YellowDog.Management.IpDatabaseLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Domain, GeoIP, GeoIPFixtures, Repo, TaskDefinition}
  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    directory =
      Path.join(System.tmp_dir!(), "management-ipdb-ui-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    path = GeoIPFixtures.write!(directory)
    server = start_supervised!({GeoIP, name: nil, paths: %{city: path}})
    GeoIPFixtures.wait_loaded(server)
    previous = Application.fetch_env(:yellow_dog_management, :geoip_server)
    Application.put_env(:yellow_dog_management, :geoip_server, server)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:yellow_dog_management, :geoip_server, value)
        :error -> Application.delete_env(:yellow_dog_management, :geoip_server)
      end

      File.rm_rf!(directory)
    end)

    %{conn: build_conn(), server: server, path: path}
  end

  test "metadata, file details and unconfigured guidance are real, not download placeholders", %{
    conn: conn,
    path: path
  } do
    {:ok, view, html} = live(conn, "/system/ip-database")
    assert has_element?(view, "#ip-database-city", path)
    assert has_element?(view, "#ip-database-city", "22569 bytes")
    assert has_element?(view, "#ip-database-city", "GeoIP2-City")
    assert has_element?(view, "#ip-database-city [data-status='loaded']")

    for field <- [
          "Build",
          "IP Version",
          "Node Count",
          "Record Size",
          "Languages",
          "en, zh",
          "File Modified",
          "Loaded At"
        ] do
      assert html =~ field
    end

    assert has_element?(view, "#ip-database-country", "YELLOW_DOG_MANAGEMENT_GEOIP_COUNTRY_PATH")
    assert has_element?(view, "#ip-database-reload-country[disabled]")
    assert has_element?(view, "#ip-database-download-city[phx-click='download']", "Queue IP City")

    assert has_element?(
             view,
             "#ip-database-download-country[phx-click='download']",
             "Queue IP Country"
           )

    assert has_element?(view, "a[href='/system/tasks/ip_city']", "Sync History")
    assert has_element?(view, "a[href='/system/tasks/ip_country']", "Sync History")
  end

  test "direct sync buttons queue real durable jobs without enabling schedules or claiming completion",
       %{
         conn: conn,
         server: server
       } do
    tasks = Repo.all(TaskDefinition) |> Enum.sort_by(& &1.key)
    snapshots = GeoIP.info(server)
    {:ok, view, _html} = live(conn, "/system/ip-database")

    for type <- ~w(city country) do
      view |> element("#ip-database-download-#{type}") |> render_click()
      assert [job] = Domain.list_task_jobs("ip_#{type}")
      assert job["state"] == "available"
      assert job["attempt"] == 0
      assert job["result"] == nil

      assert has_element?(
               view,
               "#ip-database-download-result[data-job-id='#{job["id"]}'][data-task-key='ip_#{type}']"
             )

      assert has_element?(
               view,
               "#ip-database-download-result",
               "Queueing is not successful completion"
             )
    end

    assert Repo.all(TaskDefinition) |> Enum.sort_by(& &1.key) == tasks
    assert GeoIP.info(server) == snapshots
    assert Enum.all?(Domain.list_audit(), &(&1["operation"] == "run_task"))
  end

  test "sync selection is a strict enum and client task keys or URLs cannot retarget it", %{
    conn: conn,
    server: server
  } do
    {:ok, view, _html} = live(conn, "/system/ip-database")

    before_read =
      {Domain.list_tasks(), Domain.list_task_history(), Domain.list_audit(), GeoIP.info(server)}

    for payload <- [%{}, %{"type" => "mac"}, %{"type" => []}, %{"type" => %{}}, %{"type" => 1}] do
      assert render_click(view, "download", payload) =~ "Invalid database selection"

      assert {Domain.list_tasks(), Domain.list_task_history(), Domain.list_audit(),
              GeoIP.info(server)} == before_read
    end

    render_click(view, "download", %{
      "type" => "city",
      "key" => "mac",
      "source_url" => "http://attacker.invalid/",
      "path" => "/etc/passwd"
    })

    assert [job] = Domain.list_task_jobs("ip_city")
    assert job["task_key"] == "ip_city"
    assert Domain.list_task_jobs("ip_country") == []
    assert Domain.list_task_jobs("mac") == []
    assert hd(Domain.list_audit())["request"] == %{"key" => "ip_city"}
    assert has_element?(view, "#ip-database-download-result")
    refute has_element?(view, "#ip-database-error")
  end

  test "queue errors are shown without a fake job or a lost lookup snapshot", %{
    conn: conn,
    server: server
  } do
    Repo.query!("ALTER TABLE management_jobs.oban_jobs DROP CONSTRAINT positive_max_attempts")

    Repo.query!(
      "ALTER TABLE management_jobs.oban_jobs ADD CONSTRAINT positive_max_attempts CHECK (false)"
    )

    snapshot = GeoIP.info(server)
    {:ok, view, _html} = live(conn, "/system/ip-database")
    view |> element("#ip-database-download-country") |> render_click()
    assert has_element?(view, "#ip-database-error", "Task could not be queued")
    refute has_element?(view, "#ip-database-download-result")
    assert Domain.list_task_history() == []
    assert GeoIP.info(server) == snapshot
    assert hd(Domain.list_audit())["result"]["error"]["code"] == "invalid_request"
  end

  test "unload then async reload restores actual lookups and refresh sees external changes", %{
    conn: conn,
    server: server,
    path: path
  } do
    {:ok, view, _html} = live(conn, "/system/ip-database")

    assert has_element?(
             view,
             "#ip-database-unload-city[data-confirm='Unload this database from memory? The configured MMDB file remains on disk. Reload restores it.']"
           )

    view |> element("#ip-database-unload-city") |> render_click()
    assert File.read!(path) == GeoIPFixtures.binary()
    assert has_element?(view, "#ip-database-city [data-status='unloaded']")
    assert {:error, :not_loaded} = GeoIP.lookup("81.2.69.160", :city, server)
    view |> element("#ip-database-reload-city") |> render_click()
    render_async(view)
    assert has_element?(view, "#ip-database-city [data-status='loaded']")
    assert {:ok, %{city: "London"}} = GeoIP.lookup("81.2.69.160", :city, server)
    :ok = GeoIP.unload(:city, server)
    view |> element("#ip-database-refresh") |> render_click()
    assert has_element?(view, "#ip-database-city [data-status='unloaded']")
  end

  test "failed reload exposes error without discarding the valid snapshot", %{
    conn: conn,
    path: path,
    server: server
  } do
    {:ok, view, _html} = live(conn, "/system/ip-database")
    File.write!(path, "invalid MMDB")
    view |> element("#ip-database-reload-city") |> render_click()
    html = render_async(view)
    assert html =~ "Database operation failed"
    assert html =~ "The last valid snapshot is still available"
    assert has_element?(view, "#ip-database-city [data-status='error']")
    assert {:ok, %{city: "London"}} = GeoIP.lookup("81.2.69.160", :city, server)
    assert Process.alive?(view.pid)
  end

  test "forged enum cannot mutate either slot or add client-supplied paths", %{
    conn: conn,
    server: server,
    path: path
  } do
    {:ok, view, _html} = live(conn, "/system/ip-database")

    for event <- ["unload", "reload"] do
      assert render_click(view, event, %{"type" => "unknown", "path" => "/etc/passwd"}) =~
               "Invalid database selection"
    end

    assert [%{loaded: true, path: ^path}, %{loaded: false, path: nil}] = GeoIP.info(server)

    assert render_click(view, "reload", %{"type" => "country"})
           |> then(fn _html -> render_async(view) end) =~ "unconfigured"
  end

  test "unavailable database service reports a meaningful failure", %{conn: conn} do
    Application.put_env(:yellow_dog_management, :geoip_server, :nonexistent_management_geoip_test)
    {:ok, view, html} = live(conn, "/system/ip-database")
    assert html =~ "Database service unavailable"
    view |> element("#ip-database-refresh") |> render_click()
    assert has_element?(view, "#ip-database-error", "Database service unavailable")
  end
end
