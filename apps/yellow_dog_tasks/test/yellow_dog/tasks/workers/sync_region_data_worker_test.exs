defmodule YellowDog.Tasks.Workers.SyncRegionDataWorkerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: YellowDog.Tasks.Repo, engine: Oban.Engines.Lite

  alias YellowDog.Tasks.RegionData.Store
  alias YellowDog.Tasks.Workers.SyncRegionDataWorker

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous_data_dir = Application.get_env(:yellow_dog, :data_dir)
    Application.put_env(:yellow_dog, :data_dir, tmp_dir)

    on_exit(fn ->
      if previous_data_dir do
        Application.put_env(:yellow_dog, :data_dir, previous_data_dir)
      else
        Application.delete_env(:yellow_dog, :data_dir)
      end
    end)
  end

  test "syncs region data", %{tmp_dir: tmp_dir} do
    ref = attach_telemetry()

    assert :ok = perform_job(SyncRegionDataWorker, %{"force" => true})
    assert Store.info(data_dir: tmp_dir).record_count > 0

    assert_receive {^ref, [:yellow_dog, :tasks, :sync, :start],
                    %{task: :region, source: "geo-ip-countries"}}

    assert_receive {^ref, [:yellow_dog, :tasks, :sync, :stop],
                    %{task: :region, source: "geo-ip-countries"}}
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
end
