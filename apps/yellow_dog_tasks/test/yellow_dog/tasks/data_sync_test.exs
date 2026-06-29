defmodule YellowDog.Tasks.DataSyncTest do
  use ExUnit.Case, async: false

  alias YellowDog.Tasks
  alias YellowDog.Tasks.Job
  alias YellowDog.Tasks.Store
  alias YellowDog.Tasks.Workers.SyncIpDatabaseWorker
  alias YellowDog.Tasks.Workers.SyncMacDatabaseWorker

  setup do
    YellowDog.StoreHelper.setup_store()
    Store.clear_all()
    previous = save_env([:ip_database_downloader, :ip_database_metadata, :ip_database_file_info])

    Application.put_env(:yellow_dog_tasks, :ip_database_downloader, fn
      :city -> {:ok, "/tmp/city.mmdb"}
      :country -> {:ok, "/tmp/country.mmdb"}
    end)

    Application.put_env(:yellow_dog_tasks, :ip_database_metadata, fn _type -> {:ok, %{}} end)
    Application.put_env(:yellow_dog_tasks, :ip_database_file_info, fn _type -> {:ok, %{size: 1}} end)

    on_exit(fn -> restore_env(previous) end)

    :ok
  end

  test "lists known tasks without accepting arbitrary workers" do
    tasks = Tasks.list_tasks()

    assert Enum.map(tasks, & &1.key) == [:region, :ip_country, :ip_city, :mac]
    assert Enum.all?(tasks, &Map.has_key?(&1, :status))
  end

  test "enqueues and records a known IP database task in Store" do
    assert {:ok, %Job{worker: SyncIpDatabaseWorker, queue: "data_sync"} = job} =
             Tasks.enqueue(:ip_city)

    assert job.args == %{"type" => "city", "force" => true}
    assert [%Job{id: id, state: "completed"}] = Tasks.recent_jobs(:ip_city)
    assert id == job.id
  end

  test "enqueues a known MAC database task without using SQL storage" do
    previous =
      save_env([
        :mac_database_ensure_started,
        :mac_database_downloader,
        :mac_database_info
      ])

    Application.put_env(:yellow_dog_tasks, :mac_database_ensure_started, fn -> :ok end)
    Application.put_env(:yellow_dog_tasks, :mac_database_downloader, fn -> {:ok, "/tmp/manuf.txt"} end)
    Application.put_env(:yellow_dog_tasks, :mac_database_info, fn -> %{entry_count: 1} end)

    try do
      assert {:ok, %Job{worker: SyncMacDatabaseWorker}} = Tasks.enqueue("mac")
      assert [%Job{state: "completed"}] = Tasks.recent_jobs(:mac)
    after
      restore_env(previous)
    end
  end

  test "rejects unknown tasks" do
    assert {:error, :unknown_task} = Tasks.enqueue(:unknown)
  end

  defp save_env(keys), do: Map.new(keys, &{&1, Application.get_env(:yellow_dog_tasks, &1)})

  defp restore_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:yellow_dog_tasks, key)
      {key, value} -> Application.put_env(:yellow_dog_tasks, key, value)
    end)
  end
end
