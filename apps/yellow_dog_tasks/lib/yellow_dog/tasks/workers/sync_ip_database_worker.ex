defmodule YellowDog.Tasks.Workers.SyncIpDatabaseWorker do
  @moduledoc """
  Oban worker for DB-IP city and country database synchronization.
  """

  use Oban.Worker,
    queue: :data_sync,
    max_attempts: 3,
    tags: ["sync", "ip-database"],
    unique: [period: :infinity, states: :incomplete, fields: [:worker, :args]]

  alias YellowDog.Tasks.DataSync

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: %{"type" => type}}) when type in ["city", "country"] do
    task = if type == "city", do: :ip_city, else: :ip_country

    DataSync.with_telemetry(task, "db-ip", job_id, fn ->
      DataSync.sync_ip_database(type)
    end)
  end

  def perform(%Oban.Job{args: %{"type" => type}}), do: {:error, {:invalid_type, type}}
  def perform(%Oban.Job{}), do: {:error, {:invalid_type, nil}}
end
