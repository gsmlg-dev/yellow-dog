defmodule YellowDog.Tasks.Runner do
  @moduledoc """
  Supervises scheduled and manually queued YellowDog background tasks.
  """

  use GenServer

  require Logger

  alias YellowDog.Tasks.{Config, Cron, DataSync, Store}

  @tick_interval_ms :timer.seconds(60)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enqueue(atom() | String.t(), keyword()) :: {:ok, YellowDog.Tasks.Job.t()} | {:error, term()}
  def enqueue(key, opts \\ []) do
    with {:ok, task} <- DataSync.fetch_task(key) do
      force? = Keyword.get(opts, :force, true)
      args = Map.put(task.args, "force", force?)

      with {:ok, job} <- Store.create_job(task, args) do
        run_async(job.id)
        {:ok, job}
      end
    end
  end

  @spec run_due_schedules(DateTime.t()) :: [YellowDog.Tasks.Job.t()]
  def run_due_schedules(%DateTime{} = now) do
    config = Config.load()

    if config.enabled? do
      minute_id = Cron.minute_id(now)

      config
      |> DataSync.list_tasks()
      |> Enum.filter(&due?(&1, now))
      |> Enum.flat_map(fn task ->
        case Store.reserve_schedule(task.key, minute_id) do
          :ok ->
            case enqueue(task.key, force: false) do
              {:ok, job} -> [job]
              {:error, reason} ->
                Logger.warning("Task scheduler failed to enqueue #{task.key}: #{inspect(reason)}")
                []
            end

          {:error, :condition_failed} ->
            []
        end
      end)
    else
      []
    end
  end

  @spec run_job(pos_integer()) :: :ok
  def run_job(job_id) do
    with {:ok, job} <- Store.get_job(job_id),
         {:ok, executing_job} <- Store.mark_executing(job) do
      try do
        case executing_job.worker.perform(executing_job) do
          :ok ->
            mark_completed(executing_job)

          {:ok, _result} ->
            mark_completed(executing_job)

          {:error, reason} ->
            mark_failed(executing_job, reason)

          other ->
            mark_failed(executing_job, {:unexpected_result, other})
        end
      rescue
        exception ->
          mark_failed(executing_job, exception, __STACKTRACE__)
          reraise exception, __STACKTRACE__
      end
    else
      {:error, :not_found} ->
        :ok

      {:error, :condition_failed} ->
        :ok
    end
  end

  @impl true
  def init(_opts) do
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    run_due_schedules(DateTime.utc_now())
    schedule_tick()
    {:noreply, state}
  end

  defp run_async(job_id) do
    case Process.whereis(YellowDog.Tasks.TaskSupervisor) do
      nil ->
        run_job(job_id)

      _pid ->
        Task.Supervisor.start_child(YellowDog.Tasks.TaskSupervisor, fn -> run_job(job_id) end)
        :ok
    end
  end

  defp due?(task, now) do
    task.enabled? and is_binary(task.cron) and Cron.due?(task.cron, now)
  end

  defp mark_completed(job) do
    case Store.mark_completed(job) do
      {:ok, _job} -> :ok
      {:error, :condition_failed} -> :ok
    end
  end

  defp mark_failed(job, reason, stacktrace \\ []) do
    case Store.mark_failed(job, reason, stacktrace) do
      {:ok, _job} -> :ok
      {:error, :condition_failed} -> :ok
    end
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end
end
