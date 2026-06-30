defmodule YellowDog.Console.TaskLogsLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Store.Backend
  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Tasks.DataSync
  alias YellowDog.Tasks.Store

  setup do
    EtsBackend.create_table()
    :ets.delete_all_objects(EtsBackend.table())
    Backend.set_active(EtsBackend)

    previous_store_backend = Application.get_env(:yellow_dog_tasks, :store_backend)
    previous_tasks_config = Application.get_env(:yellow_dog_tasks, :tasks_config)
    previous_config_file_path = Application.get_env(:yellow_dog_tasks, :config_file_path)

    Application.put_env(:yellow_dog_tasks, :store_backend, EtsBackend)
    Application.delete_env(:yellow_dog_tasks, :tasks_config)
    Application.delete_env(:yellow_dog_tasks, :config_file_path)
    Store.clear_all()

    on_exit(fn ->
      Store.clear_all()
      restore_env(:store_backend, previous_store_backend)
      restore_env(:tasks_config, previous_tasks_config)
      restore_env(:config_file_path, previous_config_file_path)
    end)

    :ok
  end

  test "shows persisted task start and stop logs without level or module filters", %{conn: conn} do
    task = DataSync.get_task!(:mac)

    assert {:ok, job} = Store.create_job(task, %{})
    assert {:ok, executing_job} = Store.mark_executing(job)
    assert {:ok, _completed_job} = Store.mark_completed(executing_job)

    {:ok, view, html} = live(conn, "/system/logs/tasks")

    assert html =~ "Task Log"
    refute has_element?(view, "button[phx-click='set_level']")
    refute has_element?(view, "input[phx-click='toggle_app']")
    assert html =~ "Task started: mac from wireshark-manuf"
    assert html =~ "Task stopped: mac from wireshark-manuf"
    refute html =~ "Level:"
    refute html =~ "Modules:"
  end

  defp restore_env(key, nil), do: Application.delete_env(:yellow_dog_tasks, key)
  defp restore_env(key, value), do: Application.put_env(:yellow_dog_tasks, key, value)
end
