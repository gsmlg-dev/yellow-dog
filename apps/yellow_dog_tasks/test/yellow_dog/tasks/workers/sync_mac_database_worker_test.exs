defmodule YellowDog.Tasks.Workers.SyncMacDatabaseWorkerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: YellowDog.Tasks.Repo, engine: Oban.Engines.Lite

  alias YellowDog.Tasks.Workers.SyncMacDatabaseWorker

  setup do
    previous =
      save_env([
        :mac_database_ensure_started,
        :mac_database_downloader,
        :mac_database_info
      ])

    Application.put_env(:yellow_dog_tasks, :mac_database_ensure_started, fn -> :ok end)
    Application.put_env(:yellow_dog_tasks, :mac_database_downloader, fn -> {:ok, "/tmp/manuf.txt"} end)
    Application.put_env(:yellow_dog_tasks, :mac_database_info, fn -> %{entry_count: 1} end)

    on_exit(fn -> restore_env(previous) end)
  end

  test "syncs the MAC database" do
    ref = attach_telemetry()

    assert :ok = perform_job(SyncMacDatabaseWorker, %{"force" => true})

    assert_receive {^ref, [:yellow_dog, :tasks, :sync, :start],
                    %{task: :mac, source: "wireshark-manuf"}}

    assert_receive {^ref, [:yellow_dog, :tasks, :sync, :stop],
                    %{task: :mac, source: "wireshark-manuf"}}
  end

  defp attach_telemetry do
    ref = make_ref()
    handler_id = {__MODULE__, ref}
    parent = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:yellow_dog, :tasks, :sync, :start],
        [:yellow_dog, :tasks, :sync, :stop],
        [:yellow_dog, :tasks, :sync, :exception]
      ],
      fn event, _measurements, metadata, _config ->
        send(parent, {ref, event, Map.take(metadata, [:task, :source, :job_id])})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    ref
  end

  defp save_env(keys), do: Map.new(keys, &{&1, Application.get_env(:yellow_dog_tasks, &1)})

  defp restore_env(previous) do
    Enum.each(previous, fn
      {key, nil} -> Application.delete_env(:yellow_dog_tasks, key)
      {key, value} -> Application.put_env(:yellow_dog_tasks, key, value)
    end)
  end
end
