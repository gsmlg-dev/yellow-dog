defmodule YellowDog.Tasks.TaskStatus do
  @moduledoc """
  Concord-backed status queries for known YellowDog task jobs.
  """

  alias YellowDog.Tasks.Store

  @terminal_success "completed"
  @terminal_failure ~w(discarded)
  @active ~w(available executing scheduled)

  @spec put_status(map()) :: map()
  def put_status(task) do
    jobs = recent_jobs(task.key, limit: 20)

    task
    |> Map.put(:status, status(jobs))
    |> Map.put(:last_success, Enum.find(jobs, &(&1.state == @terminal_success)))
    |> Map.put(:last_failure, Enum.find(jobs, &(&1.state in @terminal_failure)))
    |> Map.put(:recent_jobs, jobs)
  end

  @spec recent_jobs(atom() | String.t(), keyword()) :: [YellowDog.Tasks.Job.t()]
  def recent_jobs(key, opts \\ []) do
    Store.recent_jobs(key, opts)
  end

  defp status([%{state: state} | _jobs]) when state in @active, do: :active
  defp status([%{state: @terminal_success} | _jobs]), do: :succeeded
  defp status([%{state: state} | _jobs]) when state in @terminal_failure, do: :failed
  defp status(_jobs), do: :idle
end
