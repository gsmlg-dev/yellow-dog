defmodule YellowDog.Tasks.TaskStatus do
  @moduledoc """
  Oban-backed status queries for known YellowDog task jobs.
  """

  import Ecto.Query

  alias YellowDog.Tasks.DataSync
  alias YellowDog.Tasks.Repo

  @terminal_success "completed"
  @terminal_failure ~w(cancelled discarded)
  @active ~w(available executing retryable scheduled)

  @spec put_status(map()) :: map()
  def put_status(task) do
    jobs = recent_jobs(task.key, limit: 20)

    task
    |> Map.put(:status, status(jobs))
    |> Map.put(:last_success, Enum.find(jobs, &(&1.state == @terminal_success)))
    |> Map.put(:last_failure, Enum.find(jobs, &(&1.state in @terminal_failure)))
    |> Map.put(:recent_jobs, jobs)
  end

  @spec recent_jobs(atom() | String.t(), keyword()) :: [Oban.Job.t()]
  def recent_jobs(key, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    %{worker: worker, args: args} = DataSync.task_filter(key)

    Oban.Job
    |> where([job], job.worker == ^worker)
    |> order_by([job], desc: job.inserted_at, desc: job.id)
    |> limit(^max(limit * 4, limit))
    |> Repo.all()
    |> Enum.filter(&args_match?(&1.args, args))
    |> Enum.take(limit)
  rescue
    KeyError -> []
  end

  defp status([%Oban.Job{state: state} | _jobs]) when state in @active, do: :active
  defp status([%Oban.Job{state: @terminal_success} | _jobs]), do: :succeeded
  defp status([%Oban.Job{state: state} | _jobs]) when state in @terminal_failure, do: :failed
  defp status(_jobs), do: :idle

  defp args_match?(job_args, expected_args) do
    Enum.all?(expected_args, fn {key, value} -> Map.get(job_args, key) == value end)
  end
end
