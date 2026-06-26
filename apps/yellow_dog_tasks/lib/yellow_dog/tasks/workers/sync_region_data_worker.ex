defmodule YellowDog.Tasks.Workers.SyncRegionDataWorker do
  @moduledoc """
  Oban worker for country and region metadata synchronization.
  """

  use Oban.Worker,
    queue: :data_sync,
    max_attempts: 3,
    tags: ["sync", "region-data"],
    unique: [period: :infinity, states: :incomplete, fields: [:worker, :args]]

  alias YellowDog.Tasks.DataSync

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id}) do
    DataSync.with_telemetry(:region, "geo-ip-countries", job_id, fn ->
      DataSync.sync_region_data()
    end)
  end
end
