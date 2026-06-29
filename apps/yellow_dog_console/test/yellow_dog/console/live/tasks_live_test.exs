defmodule YellowDog.Console.TasksLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Tasks
  alias YellowDog.Tasks.Store

  defmodule UnavailableTaskBackend do
    @moduledoc false

    def prefix_scan(_prefix, _opts), do: {:error, :cluster_not_ready}
    def put(_key, _value, _opts), do: {:error, :cluster_not_ready}
    def put_if(_key, _value, _opts), do: {:error, :cluster_not_ready}
    def get(_key, _opts), do: {:error, :cluster_not_ready}
    def delete(_key), do: {:error, :cluster_not_ready}
  end

  setup do
    EtsBackend.create_table()
    Backend.set_active(EtsBackend)

    previous =
      save_env([
        :ip_database_downloader,
        :ip_database_metadata,
        :ip_database_file_info,
        :mac_database_ensure_started,
        :mac_database_downloader,
        :mac_database_info,
        :store_backend
      ])

    Application.put_env(:yellow_dog_tasks, :store_backend, EtsBackend)
    Store.clear_all()

    Application.put_env(:yellow_dog_tasks, :ip_database_downloader, fn
      :city -> {:ok, "/tmp/city.mmdb"}
      :country -> {:ok, "/tmp/country.mmdb"}
    end)

    Application.put_env(:yellow_dog_tasks, :ip_database_metadata, fn _type -> {:ok, %{}} end)

    Application.put_env(:yellow_dog_tasks, :ip_database_file_info, fn _type ->
      {:ok, %{size: 1}}
    end)

    Application.put_env(:yellow_dog_tasks, :mac_database_ensure_started, fn -> :ok end)

    Application.put_env(:yellow_dog_tasks, :mac_database_downloader, fn ->
      {:ok, "/tmp/manuf.txt"}
    end)

    Application.put_env(:yellow_dog_tasks, :mac_database_info, fn -> %{entry_count: 1} end)

    on_exit(fn ->
      Store.clear_all()
      restore_env(previous)
    end)

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
    assert [_job | _] = Tasks.recent_jobs(:mac)
  end

  test "renders task history detail", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/system/tasks/ip_city")

    assert html =~ "IP City"
    assert html =~ "Recent Job History"
  end

  test "renders task ledger outages in the overview", %{conn: conn} do
    Application.put_env(:yellow_dog_tasks, :store_backend, UnavailableTaskBackend)

    {:ok, _view, html} = live(conn, ~p"/system/tasks")

    assert html =~ "Unavailable"
  end

  test "renders task ledger outages in the history detail", %{conn: conn} do
    Application.put_env(:yellow_dog_tasks, :store_backend, UnavailableTaskBackend)

    {:ok, _view, html} = live(conn, ~p"/system/tasks/ip_city")

    assert html =~ "Unavailable"
    assert html =~ "Task ledger unavailable."
    assert html =~ "cluster_not_ready"
    refute html =~ "No jobs have been queued for this task."
  end

  test "ip database page links to task history and queues downloads", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/system/ip-database")

    assert html =~ "IP City sync"
    assert has_element?(view, "a[href='/system/tasks/ip_city']")

    html = render_click(element(view, "button[phx-click='download'][phx-value-type='city']"))

    assert html =~ "IP City sync queued"
    assert [_job | _] = Tasks.recent_jobs(:ip_city)
  end

  test "mac database page links to task history and queues downloads", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/system/mac-database")

    assert html =~ "MAC/OUI sync"
    assert html =~ "/system/tasks/mac"

    html = render_click(element(view, "button[phx-click='download']"))

    assert html =~ "MAC/OUI sync queued"
    assert [_job | _] = Tasks.recent_jobs(:mac)
  end

  defp save_env(keys), do: Map.new(keys, &{&1, Application.get_env(:yellow_dog_tasks, &1)})

  defp restore_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:yellow_dog_tasks, key)
      {key, value} -> Application.put_env(:yellow_dog_tasks, key, value)
    end)
  end
end
