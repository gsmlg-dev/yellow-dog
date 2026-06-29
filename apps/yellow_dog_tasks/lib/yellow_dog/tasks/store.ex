defmodule YellowDog.Tasks.Store do
  @moduledoc """
  Concord-backed persistence for task jobs and scheduler reservations.
  """

  alias YellowDog.Tasks.Job
  alias YellowDog.Store.Key

  @spec create_job(map(), map()) :: {:ok, Job.t()}
  def create_job(task, args) do
    now = DateTime.utc_now()

    job = %Job{
      id: System.unique_integer([:positive, :monotonic]),
      task_key: task.key,
      worker: task.worker,
      args: args,
      max_attempts: Map.get(task, :max_attempts, 3),
      inserted_at: now,
      scheduled_at: now
    }

    :ok = YellowDog.Store.backend_put(Key.task_job(job.id), job, consistency: :strong)
    {:ok, job}
  end

  @spec get_job(pos_integer()) :: {:ok, Job.t()} | {:error, :not_found}
  def get_job(id), do: YellowDog.Store.backend_get(Key.task_job(id), consistency: :leader)

  @spec mark_executing(Job.t()) :: {:ok, Job.t()} | {:error, :condition_failed}
  def mark_executing(%Job{} = job) do
    updated = %{job | state: "executing", attempt: job.attempt + 1, started_at: DateTime.utc_now()}

    case put_if_current(job, updated, &match?(%Job{state: "available"}, &1)) do
      :ok -> {:ok, updated}
      {:error, :condition_failed} -> {:error, :condition_failed}
    end
  end

  @spec mark_completed(Job.t()) :: {:ok, Job.t()} | {:error, :condition_failed}
  def mark_completed(%Job{} = job) do
    updated = %{job | state: "completed", completed_at: DateTime.utc_now()}

    case put_if_current(job, updated, &match?(%Job{state: "executing"}, &1)) do
      :ok -> {:ok, updated}
      {:error, :condition_failed} -> {:error, :condition_failed}
    end
  end

  @spec mark_failed(Job.t(), term(), list()) :: {:ok, Job.t()} | {:error, :condition_failed}
  def mark_failed(%Job{} = job, reason, stacktrace \\ []) do
    error = %{
      "at" => DateTime.utc_now(),
      "error" => Exception.format_banner(:error, reason),
      "stacktrace" => Enum.map(stacktrace, &Exception.format_stacktrace_entry/1)
    }

    updated =
      %{
        job
        | state: "discarded",
          discarded_at: DateTime.utc_now(),
          errors: [error | job.errors]
      }

    case put_if_current(job, updated, &match?(%Job{state: "executing"}, &1)) do
      :ok -> {:ok, updated}
      {:error, :condition_failed} -> {:error, :condition_failed}
    end
  end

  @spec recent_jobs(atom() | String.t(), keyword()) :: [Job.t()]
  def recent_jobs(task_key, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    normalized = normalize_key(task_key)

    case YellowDog.Store.backend_prefix_scan(Key.task_job_prefix(), consistency: :eventual) do
      {:ok, entries} ->
        entries
        |> Enum.map(fn {_key, job} -> job end)
        |> Enum.filter(&match?(%Job{task_key: ^normalized}, &1))
        |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
        |> Enum.take(limit)

      {:error, _reason} ->
        []
    end
  rescue
    ArgumentError -> []
  end

  @spec reserve_schedule(atom(), String.t()) :: :ok | {:error, :condition_failed}
  def reserve_schedule(task_key, minute_id) do
    key = Key.task_schedule(task_key)

    YellowDog.Store.backend_put_if(
      key,
      %{task_key: task_key, minute_id: minute_id, reserved_at: DateTime.utc_now()},
      condition: fn
        nil -> true
        %{minute_id: ^minute_id} -> false
        _existing -> true
      end
    )
  end

  @spec clear_all() :: :ok
  def clear_all do
    with {:ok, jobs} <- YellowDog.Store.backend_prefix_scan(Key.task_job_prefix()),
         {:ok, schedules} <- YellowDog.Store.backend_prefix_scan(Key.task_schedule_prefix()) do
      Enum.each(jobs ++ schedules, fn {key, _value} -> YellowDog.Store.backend_delete(key) end)
    end

    :ok
  end

  defp put_if_current(%Job{} = current, %Job{} = updated, state_predicate) do
    YellowDog.Store.backend_put_if(
      Key.task_job(current.id),
      updated,
      condition: fn stored ->
        stored == current and state_predicate.(stored)
      end,
      consistency: :strong
    )
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_existing_atom(key)
end
