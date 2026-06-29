defmodule YellowDog.Tasks.Store do
  @moduledoc """
  Concord-backed persistence for task jobs and scheduler reservations.
  """

  alias YellowDog.Tasks.Job
  alias YellowDog.Store.Key
  alias YellowDog.Store.Backend.Cluster, as: ConcordBackend

  @job_retention_limit 500
  @terminal_states ~w(completed discarded)

  @doc false
  @spec backend() :: module()
  def backend do
    Application.get_env(:yellow_dog_tasks, :store_backend, ConcordBackend)
  end

  @spec create_job(map(), map()) :: {:ok, Job.t()} | {:error, term()}
  def create_job(task, args) do
    now = DateTime.utc_now()

    job = %Job{
      id: new_job_id(),
      task_key: task.key,
      worker: task.worker,
      args: args,
      max_attempts: Map.get(task, :max_attempts, 3),
      inserted_at: now,
      scheduled_at: now
    }

    case backend().put(Key.task_job(job.task_key, job.id), job, consistency: :strong) do
      :ok ->
        prune_old_jobs(job.task_key)
        {:ok, job}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec get_job(atom() | String.t(), String.t()) :: {:ok, Job.t()} | {:error, :not_found}
  def get_job(task_key, id), do: backend().get(Key.task_job(task_key, id), consistency: :leader)

  @spec delete_job(Job.t()) :: :ok | {:error, term()}
  def delete_job(%Job{} = job), do: backend().delete(Key.task_job(job.task_key, job.id))

  @spec mark_executing(Job.t()) :: {:ok, Job.t()} | {:error, term()}
  def mark_executing(%Job{} = job) do
    updated = %{
      job
      | state: "executing",
        attempt: job.attempt + 1,
        started_at: DateTime.utc_now()
    }

    case put_if_current(job, updated, &match?(%Job{state: "available"}, &1)) do
      :ok -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec mark_completed(Job.t()) :: {:ok, Job.t()} | {:error, term()}
  def mark_completed(%Job{} = job) do
    updated = %{job | state: "completed", completed_at: DateTime.utc_now()}

    case put_if_current(job, updated, &match?(%Job{state: "executing"}, &1)) do
      :ok -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec mark_failed(Job.t(), term(), list()) :: {:ok, Job.t()} | {:error, term()}
  def mark_failed(%Job{} = job, reason, stacktrace \\ []) do
    now = DateTime.utc_now()

    error = %{
      "at" => now,
      "error" => Exception.format_banner(:error, reason),
      "stacktrace" => Enum.map(stacktrace, &Exception.format_stacktrace_entry/1)
    }

    updated = retry_or_discard(job, now, [error | job.errors])

    case put_if_current(job, updated, &match?(%Job{state: "executing"}, &1)) do
      :ok -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec recent_jobs(atom() | String.t(), keyword()) :: [Job.t()]
  def recent_jobs(task_key, opts \\ []) do
    case recent_jobs_result(task_key, opts) do
      {:ok, jobs} -> jobs
      {:error, _reason} -> []
    end
  end

  @spec recent_jobs_result(atom() | String.t(), keyword()) :: {:ok, [Job.t()]} | {:error, term()}
  def recent_jobs_result(task_key, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    normalized = normalize_key(task_key)

    case backend().prefix_scan(Key.task_job_prefix(normalized), consistency: :eventual) do
      {:ok, entries} ->
        jobs =
          entries
          |> Enum.map(fn {_key, job} -> job end)
          |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
          |> Enum.take(limit)

        {:ok, jobs}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    ArgumentError -> {:error, :unknown_task}
  end

  @spec last_job(atom() | String.t(), [String.t()]) :: Job.t() | nil
  def last_job(task_key, states) do
    case last_job_result(task_key, states) do
      {:ok, job} -> job
      {:error, _reason} -> nil
    end
  end

  @spec last_job_result(atom() | String.t(), [String.t()]) ::
          {:ok, Job.t() | nil} | {:error, term()}
  def last_job_result(task_key, states) do
    normalized = normalize_key(task_key)

    case backend().prefix_scan(Key.task_job_prefix(normalized), consistency: :eventual) do
      {:ok, entries} ->
        job =
          entries
          |> Enum.map(fn {_key, job} -> job end)
          |> Enum.filter(&(&1.state in states))
          |> Enum.sort_by(&terminal_at/1, {:desc, DateTime})
          |> List.first()

        {:ok, job}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    ArgumentError -> {:error, :unknown_task}
  end

  @spec reserve_schedule(atom() | String.t(), String.t()) :: :ok | {:error, term()}
  def reserve_schedule(task_key, minute_id) do
    key = Key.task_schedule(task_key)
    reservation = %{task_key: task_key, minute_id: minute_id, reserved_at: DateTime.utc_now()}

    reserve_schedule(backend(), key, reservation, minute_id)
  end

  @spec release_schedule(atom() | String.t(), String.t()) :: :ok | {:error, term()}
  def release_schedule(task_key, minute_id) do
    key = Key.task_schedule(task_key)
    release_schedule(backend(), key, minute_id)
  end

  @spec put_task_config(atom() | String.t(), map()) :: :ok | {:error, term()}
  def put_task_config(task_key, schedule) when is_map(schedule) do
    backend().put(Key.task_config(task_key), schedule, consistency: :strong)
  end

  @spec task_configs() :: {:ok, map()} | {:error, term()}
  def task_configs do
    prefix = Key.task_config_prefix()

    case backend().prefix_scan(prefix, consistency: :eventual) do
      {:ok, entries} ->
        configs =
          Map.new(entries, fn {key, schedule} ->
            {String.replace_prefix(key, prefix, ""), schedule}
          end)

        {:ok, configs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec clear_all() :: :ok
  def clear_all do
    with {:ok, jobs} <- backend().prefix_scan(Key.task_job_prefix(), []),
         {:ok, schedules} <- backend().prefix_scan(Key.task_schedule_prefix(), []),
         {:ok, configs} <- backend().prefix_scan(Key.task_config_prefix(), []) do
      Enum.each(jobs ++ schedules ++ configs, fn {key, _value} -> backend().delete(key) end)
    end

    :ok
  end

  defp put_if_current(%Job{} = current, %Job{} = updated, state_predicate) do
    backend().put_if(
      Key.task_job(current.task_key, current.id),
      updated,
      condition: fn stored ->
        stored == current and state_predicate.(stored)
      end,
      consistency: :strong
    )
  end

  defp reserve_schedule(backend, key, reservation, minute_id) do
    if function_exported?(backend, :txn, 2) do
      reserve_schedule_txn(backend, key, reservation, minute_id)
    else
      reserve_schedule_put_if(backend, key, reservation, minute_id)
    end
  end

  defp reserve_schedule_txn(backend, key, reservation, minute_id) do
    case backend.txn(%{
           compare: [{:field, key, [:minute_id], :!=, minute_id}],
           success: [{:put, key, reservation, %{}}],
           failure: []
         }) do
      {:ok, %{succeeded: true}} -> :ok
      {:ok, %{succeeded: false}} -> {:error, :condition_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reserve_schedule_put_if(backend, key, reservation, minute_id) do
    backend.put_if(
      key,
      reservation,
      condition: fn
        nil -> true
        %{minute_id: ^minute_id} -> false
        _existing -> true
      end
    )
  end

  defp release_schedule(backend, key, minute_id) do
    if function_exported?(backend, :txn, 2) do
      release_schedule_txn(backend, key, minute_id)
    else
      release_schedule_get_delete(backend, key, minute_id)
    end
  end

  defp release_schedule_txn(backend, key, minute_id) do
    case backend.txn(%{
           compare: [{:field, key, [:minute_id], :==, minute_id}],
           success: [{:delete, {:key, key}, %{}}],
           failure: []
         }) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_schedule_get_delete(backend, key, minute_id) do
    case backend.get(key, consistency: :leader) do
      {:ok, %{minute_id: ^minute_id}} -> backend.delete(key)
      {:ok, _other} -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: key

  defp new_job_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  defp retry_or_discard(%Job{attempt: attempt, max_attempts: max_attempts} = job, now, errors)
       when attempt < max_attempts do
    %{
      job
      | state: "available",
        scheduled_at: now,
        started_at: nil,
        errors: errors
    }
  end

  defp retry_or_discard(%Job{} = job, now, errors) do
    %{
      job
      | state: "discarded",
        discarded_at: now,
        errors: errors
    }
  end

  defp prune_old_jobs(task_key) do
    task_key = normalize_key(task_key)

    case backend().prefix_scan(Key.task_job_prefix(task_key), consistency: :eventual) do
      {:ok, entries} -> Enum.map(entries, fn {_key, job} -> job end)
      {:error, _reason} -> []
    end
    |> Enum.filter(&(&1.state in @terminal_states))
    |> Enum.sort_by(&terminal_at/1, {:desc, DateTime})
    |> Enum.drop(@job_retention_limit)
    |> Enum.each(fn job ->
      backend().delete(Key.task_job(job.task_key, job.id))
    end)
  end

  defp terminal_at(%Job{state: "completed", completed_at: %DateTime{} = completed_at}),
    do: completed_at

  defp terminal_at(%Job{state: "discarded", discarded_at: %DateTime{} = discarded_at}),
    do: discarded_at

  defp terminal_at(%Job{inserted_at: inserted_at}), do: inserted_at
end
