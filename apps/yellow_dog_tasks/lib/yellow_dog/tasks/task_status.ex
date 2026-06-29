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
    with {:ok, jobs} <- Store.recent_jobs_result(task.key, limit: 20),
         {:ok, last_success} <- Store.last_job_result(task.key, [@terminal_success]),
         {:ok, last_failure} <- Store.last_job_result(task.key, @terminal_failure) do
      task
      |> Map.put(:status, status(jobs))
      |> Map.put(:last_success, last_success)
      |> Map.put(:last_failure, last_failure)
      |> Map.put(:recent_jobs, jobs)
    else
      {:error, reason} ->
        task
        |> Map.put(:status, :unavailable)
        |> Map.put(:status_error, reason)
        |> Map.put(:last_success, nil)
        |> Map.put(:last_failure, nil)
        |> Map.put(:recent_jobs, [])
    end
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
