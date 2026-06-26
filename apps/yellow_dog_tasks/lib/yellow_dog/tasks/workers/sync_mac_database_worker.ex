defmodule YellowDog.Tasks.Workers.SyncMacDatabaseWorker do
  @moduledoc """
  Oban worker for Wireshark manuf MAC/OUI database synchronization.
  """

  use Oban.Worker,
    queue: :data_sync,
    max_attempts: 3,
    tags: ["sync", "mac-database"],
    unique: [period: :infinity, states: :incomplete, fields: [:worker, :args]]

  alias YellowDog.Tasks.DataSync

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id}) do
    DataSync.with_telemetry(:mac, "wireshark-manuf", job_id, fn ->
      DataSync.sync_mac_database()
    end)
  end
end
