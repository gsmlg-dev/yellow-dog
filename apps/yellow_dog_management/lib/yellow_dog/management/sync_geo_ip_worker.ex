defmodule YellowDog.Management.SyncGeoIPWorker do
  use Oban.Worker,
    queue: :management_sync,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:task_key],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias YellowDog.Management.{GeoIPDownload, Settings, TaskArtifacts, Tasks}

  @impl Oban.Worker
  def timeout(_job), do: 180_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"task_key" => key, "source_url" => url}} = job)
      when key in ~w(ip_city ip_country) do
    Tasks.broadcast(key)

    result =
      case TaskArtifacts.receipt(job) do
        nil ->
          type = if key == "ip_city", do: :city, else: :country

          with {:ok, artifact} <-
                 GeoIPDownload.fetch(type, Settings.artifact_directory(), url: url),
               :ok <- TaskArtifacts.activate(job, type, artifact),
               do: :ok

        receipt ->
          TaskArtifacts.restore_receipt(job, receipt)
      end

    Tasks.broadcast(key)
    result
  end
end
