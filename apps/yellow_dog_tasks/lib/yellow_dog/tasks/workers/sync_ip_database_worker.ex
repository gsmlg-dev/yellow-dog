defmodule YellowDog.Tasks.Workers.SyncIpDatabaseWorker do
  @moduledoc """
  Worker for DB-IP city and country database synchronization.
  """

  alias YellowDog.Tasks.DataSync
  alias YellowDog.Tasks.Job

  @spec perform(Job.t()) :: :ok | {:error, term()}
  def perform(%Job{id: job_id, args: %{"type" => type}}) when type in ["city", "country"] do
    task = if type == "city", do: :ip_city, else: :ip_country

    DataSync.with_telemetry(task, "db-ip", job_id, fn ->
      DataSync.sync_ip_database(type)
    end)
  end

  def perform(%Job{args: %{"type" => type}}), do: {:error, {:invalid_type, type}}
  def perform(%Job{}), do: {:error, {:invalid_type, nil}}
end
