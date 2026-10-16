defmodule YellowDog.Management.BackupWorker do
  use Styx.Worker, queue: :management_backups, max_attempts: 3
  alias YellowDog.Management.Backups

  @impl Styx.Worker
  def timeout(_job), do: 240_000

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"backup_id" => id, "operation" => operation}} = job)
      when operation in ~w(create delete) do
    Backups.broadcast(id)
    result = Backups.perform(job, operation, id)
    if match?({:error, _reason}, result), do: Backups.record_error(job, elem(result, 1))
    Backups.broadcast(id)
    result
  end
end
