defmodule YellowDog.Tasks.Workers.SyncCloudZoneWorker do
  @moduledoc """
  Worker for Cloud DNS zone synchronization.
  """

  alias YellowDog.Tasks.DataSync
  alias YellowDog.Tasks.Job

  @spec perform(Job.t()) :: :ok | {:ok, map()} | {:error, term()}
  def perform(%Job{
        id: job_id,
        task_key: task_key,
        args: %{"view_name" => view_name, "zone_name" => zone_name}
      }) do
    DataSync.with_telemetry(task_key, "cloud-dns", job_id, fn ->
      DataSync.sync_cloud_zone(view_name, zone_name)
    end)
  end

  def perform(%Job{} = job) do
    {:error, {:invalid_cloud_zone_args, job.args}}
  end
end
