defmodule YellowDog.Management.WorkersConnectionLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias YellowDog.Management.{Domain, Repo, WorkerConnections}
  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    {:ok, connection} = WorkerConnections.create("Office Worker")
    %{conn: build_conn(), worker: connection["worker"], token: connection["token"]}
  end

  test "list and detail refresh observed state without discarding unsaved edits", %{
    conn: conn,
    worker: worker,
    token: token
  } do
    {:ok, list, _} = live(conn, "/management/servers")
    {:ok, detail, _} = live(conn, "/server/#{worker["id"]}/dashboard")

    render_change(detail, "validate_worker", %{
      "worker" => %{"name" => "Unsaved name", "profile_name" => "custom"}
    })

    assert {:ok, _} = WorkerConnections.connect(token, report(worker["id"]))
    send(list.pid, :refresh_workers)
    send(detail.pid, :refresh_connection)
    assert render(list) =~ "Online"
    assert has_element?(detail, "#worker-connection-status", "Online")
    assert has_element?(detail, "#worker-edit-form input[value='Unsaved name']")
    assert has_element?(detail, "#worker-applied-revision", "None")
  end

  test "anonymous initialization defaults off, persists on reload and ignores stale submission",
       %{conn: conn} do
    {:ok, view, _} = live(conn, "/management/servers")
    refute has_element?(view, "#worker-enrollment-form input[type=checkbox][checked]")

    intent =
      view
      |> element("#worker-enrollment-form input[name='_submission']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

    view
    |> form("#worker-enrollment-form", enrollment: %{allow_anonymous: "true"})
    |> render_submit()

    assert Domain.worker_enrollment_settings() == %{"allow_anonymous" => true}
    {:ok, reloaded, _} = live(conn, "/management/servers")
    assert has_element?(reloaded, "#worker-enrollment-form input[type=checkbox][checked]")

    render_submit(view, "save_enrollment", %{
      "_submission" => intent,
      "enrollment" => %{"allow_anonymous" => "false"}
    })

    assert Domain.worker_enrollment_settings() == %{"allow_anonymous" => true}

    reloaded
    |> form("#worker-enrollment-form", enrollment: %{allow_anonymous: "false"})
    |> render_submit()

    assert Domain.worker_enrollment_settings() == %{"allow_anonymous" => false}
    send(view.pid, :refresh_workers)
    refute has_element?(view, "#worker-enrollment-form input[type=checkbox][checked]")
  end

  test "invalid enrollment checkbox value leaves persisted setting unchanged", %{conn: conn} do
    {:ok, view, _} = live(conn, "/management/servers")

    intent =
      view
      |> element("#worker-enrollment-form input[name='_submission']")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

    render_submit(view, "save_enrollment", %{
      "_submission" => intent,
      "enrollment" => %{"allow_anonymous" => "invalid"}
    })

    assert Domain.worker_enrollment_settings() == %{"allow_anonymous" => false}
    assert render(view) =~ "Invalid initialization setting"
  end

  test "reset generates one-time configuration and invalidates the old token", %{
    conn: conn,
    worker: worker,
    token: token
  } do
    {:ok, view, _} = live(conn, "/management/servers")

    view
    |> element("#server-selector-#{worker["id"]} button[phx-click='rotate_token']")
    |> render_click()

    assert has_element?(view, "#worker-bootstrap")

    assert {:ok, config} =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#worker-bootstrap")
             |> LazyHTML.text()
             |> Toml.decode()

    assert config["worker_id"] == worker["id"]
    assert config["token"] != token

    assert {:error, %{code: "unauthorized"}} =
             WorkerConnections.connect(token, report(worker["id"]))

    assert {:ok, _} = WorkerConnections.connect(config["token"], report(worker["id"]))
    render_click(view, "dismiss_connection")
    refute has_element?(view, "#worker-bootstrap")
    refute Jason.encode!(Domain.list_audit()) =~ config["token"]
  end

  test "invalid name leaves the table unchanged and retains input", %{conn: conn} do
    before = Domain.list_workers()
    {:ok, view, _} = live(conn, "/management/servers")
    view |> form("#worker-form", worker: %{name: "   "}) |> render_submit()
    assert render(view) =~ "Name must"
    assert Domain.list_workers() == before
    assert has_element?(view, "#worker-form input[value='   ']")
  end

  test "one-time configuration is redacted in actual LiveView crash logs", %{conn: conn} do
    {:ok, view, _} = live(conn, "/management/servers")
    view |> form("#worker-form", worker: %{name: "Secret log test"}) |> render_submit()

    {:ok, config} =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#worker-bootstrap")
      |> LazyHTML.text()
      |> Toml.decode()

    refute inspect(:sys.get_state(view.pid), limit: :infinity) =~ config["token"]

    previous = Process.flag(:trap_exit, true)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        monitor = Process.monitor(view.pid)
        send(view.pid, :unexpected_message)
        assert_receive {:DOWN, ^monitor, :process, _, _}, 2000
      end)

    Process.flag(:trap_exit, previous)
    assert log =~ "terminating"
    refute log =~ config["token"]
  end

  defp report(id) do
    %{
      "worker_id" => id,
      "capabilities" => ["dns"],
      "services" => %{},
      "applied_revision" => nil,
      "applied_digest" => nil,
      "apply_error" => nil
    }
  end
end
