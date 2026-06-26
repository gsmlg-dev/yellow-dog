defmodule YellowDog.Tasks.DataSyncTest do
  use YellowDog.Tasks.RepoCase, async: false
  use Oban.Testing, repo: YellowDog.Tasks.Repo, engine: Oban.Engines.Lite

  alias YellowDog.Tasks
  alias YellowDog.Tasks.Workers.SyncIpDatabaseWorker
  alias YellowDog.Tasks.Workers.SyncMacDatabaseWorker

  test "lists known tasks without accepting arbitrary workers" do
    tasks = Tasks.list_tasks()

    assert Enum.map(tasks, & &1.key) == [:region, :ip_country, :ip_city, :mac]
    assert Enum.all?(tasks, &Map.has_key?(&1, :status))
  end

  test "enqueues a known IP database task" do
    assert {:ok, %Oban.Job{worker: worker, queue: "data_sync"}} = Tasks.enqueue(:ip_city)
    assert worker == "YellowDog.Tasks.Workers.SyncIpDatabaseWorker"

    assert_enqueued worker: SyncIpDatabaseWorker,
                    args: %{"type" => "city", "force" => true}
  end

  test "enqueues a known MAC database task" do
    assert {:ok, %Oban.Job{worker: worker, queue: "data_sync"}} = Tasks.enqueue("mac")
    assert worker == "YellowDog.Tasks.Workers.SyncMacDatabaseWorker"

    assert_enqueued worker: SyncMacDatabaseWorker, args: %{"force" => true}
  end

  test "rejects unknown tasks" do
    assert {:error, :unknown_task} = Tasks.enqueue(:unknown)
  end

  test "returns recent jobs for a task" do
    assert {:ok, %Oban.Job{id: id}} = Tasks.enqueue(:ip_city)

    assert [%Oban.Job{id: ^id}] = Tasks.recent_jobs(:ip_city)
    assert [] = Tasks.recent_jobs(:ip_country)
  end
end
