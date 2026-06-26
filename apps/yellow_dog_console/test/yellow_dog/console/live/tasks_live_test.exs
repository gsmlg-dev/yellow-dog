defmodule YellowDog.Console.TasksLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Tasks.Repo

  setup_all do
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_tasks)
    :ok = YellowDog.Tasks.Migrator.migrate()
    :ok
  end

  setup do
    Repo.delete_all(Oban.Job)
    :ok
  end

  test "renders the task overview", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/system/tasks")

    assert html =~ "Data Sync Tasks"
    assert has_element?(view, "button[phx-click='run_now'][phx-value-task='ip_city']", "Run Now")
    assert has_element?(view, "a[href='/system/tasks/ip_city']", "View History")
  end

  test "queues a task from the overview", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/system/tasks")

    html = render_click(element(view, "button[phx-click='run_now'][phx-value-task='mac']"))

    assert html =~ "MAC/OUI sync queued"
    assert Repo.exists?(Oban.Job)
  end

  test "renders task history detail", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/system/tasks/ip_city")

    assert html =~ "IP City"
    assert html =~ "Recent Job History"
  end

  test "ip database page links to task history and queues downloads", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/system/ip-database")

    assert html =~ "IP City sync"
    assert has_element?(view, "a[href='/system/tasks/ip_city']")

    html = render_click(element(view, "button[phx-click='download'][phx-value-type='city']"))

    assert html =~ "IP City sync queued"
  end

  test "mac database page links to task history and queues downloads", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/system/mac-database")

    assert html =~ "MAC/OUI sync"
    assert html =~ "/system/tasks/mac"

    html = render_click(element(view, "button[phx-click='download']"))

    assert html =~ "MAC/OUI sync queued"
  end
end
