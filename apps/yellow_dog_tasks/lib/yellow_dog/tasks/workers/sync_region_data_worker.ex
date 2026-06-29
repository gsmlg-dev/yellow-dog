defmodule YellowDog.Tasks.Workers.SyncRegionDataWorker do
  @moduledoc """
  Worker for country and region metadata synchronization.
  """

  alias YellowDog.Tasks.DataSync
  alias YellowDog.Tasks.Job

  @spec perform(Job.t()) :: :ok | {:error, term()}
  def perform(%Job{id: job_id}) do
    DataSync.with_telemetry(:region, "geo-ip-countries", job_id, fn ->
      DataSync.sync_region_data()
    end)
  end
end
