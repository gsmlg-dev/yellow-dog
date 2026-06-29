defmodule YellowDog.Tasks.Workers.SyncMacDatabaseWorker do
  @moduledoc """
  Worker for Wireshark manuf MAC/OUI database synchronization.
  """

  alias YellowDog.Tasks.DataSync
  alias YellowDog.Tasks.Job

  @spec perform(Job.t()) :: :ok | {:error, term()}
  def perform(%Job{id: job_id}) do
    DataSync.with_telemetry(:mac, "wireshark-manuf", job_id, fn ->
      DataSync.sync_mac_database()
    end)
  end
end
