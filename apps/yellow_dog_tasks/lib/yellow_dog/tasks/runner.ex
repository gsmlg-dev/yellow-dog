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
        case run_async(job.task_key, job.id) do
          :ok ->
            {:ok, job}

          {:error, reason} ->
            Store.delete_job(job)
            {:error, reason}
        end
      end
    end
  end

  @spec run_due_schedules(DateTime.t()) :: [YellowDog.Tasks.Job.t()]
  def run_due_schedules(%DateTime{} = now) do
    config = Config.load()

    if config.enabled? do
      scheduled_now = scheduled_now(now, config.timezone)
      minute_id = "#{config.timezone}:#{Cron.minute_id(scheduled_now)}"

      config
      |> DataSync.list_tasks()
      |> Enum.filter(&due?(&1, scheduled_now))
      |> Enum.flat_map(fn task ->
        case Store.reserve_schedule(task.key, minute_id) do
          :ok ->
            case enqueue(task.key, force: false) do
              {:ok, job} -> [job]
              {:error, reason} ->
                release_schedule(task.key, minute_id)
                Logger.warning("Task scheduler failed to enqueue #{task.key}: #{inspect(reason)}")
                []
            end

          {:error, :condition_failed} ->
            []

          {:error, reason} ->
            Logger.warning("Task scheduler failed to reserve #{task.key}: #{inspect(reason)}")
            []
        end
      end)
    else
      []
    end
  end

  @spec run_job(atom() | String.t(), String.t()) :: :ok | {:error, term()}
  def run_job(task_key, job_id) do
    with {:ok, job} <- Store.get_job(task_key, job_id),
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
          case mark_failed(executing_job, exception, __STACKTRACE__) do
            :retry -> :ok
            {:error, reason} -> {:error, reason}
            _other -> reraise exception, __STACKTRACE__
          end
      catch
        kind, reason ->
          case mark_failed(executing_job, {kind, reason}, __STACKTRACE__) do
            :retry -> :ok
            {:error, reason} -> {:error, reason}
            _other -> :erlang.raise(kind, reason, __STACKTRACE__)
          end
      end
    else
      {:error, :not_found} ->
        :ok

      {:error, :condition_failed} ->
        :ok

      {:error, reason} ->
        Logger.warning("Task runner failed to start job #{job_id}: #{inspect(reason)}")
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

  defp run_async(task_key, job_id) do
    case Application.get_env(:yellow_dog_tasks, :task_starter) do
      starter when is_function(starter, 2) ->
        starter.(task_key, job_id)

      _starter ->
        case Process.whereis(task_supervisor()) do
          nil ->
            run_job(task_key, job_id)

          _pid ->
            case Task.Supervisor.start_child(task_supervisor(), fn -> run_job(task_key, job_id) end) do
              {:ok, _pid} -> :ok
              {:error, reason} -> {:error, reason}
            end
        end
    end
  end

  defp task_supervisor do
    Application.get_env(:yellow_dog_tasks, :task_supervisor, YellowDog.Tasks.TaskSupervisor)
  end

  defp due?(task, now) do
    task.enabled? and is_binary(task.cron) and Cron.due?(task.cron, now)
  end

  defp mark_completed(job) do
    case Store.mark_completed(job) do
      {:ok, _job} -> :ok
      {:error, :condition_failed} -> :ok
      {:error, reason} ->
        Logger.warning("Task #{job.task_key} failed to mark job #{job.id} completed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp mark_failed(job, reason, stacktrace \\ []) do
    case Store.mark_failed(job, reason, stacktrace) do
      {:ok, %{state: "available"} = retry_job} ->
        case run_async(retry_job.task_key, retry_job.id) do
          :ok ->
            :retry

          {:error, reason} ->
            Logger.warning("Task #{job.task_key} failed to retry job #{job.id}: #{inspect(reason)}")
            {:error, reason}
        end

      {:ok, _job} ->
        :discarded

      {:error, :condition_failed} -> :ok
      {:error, reason} ->
        Logger.warning("Task #{job.task_key} failed to mark job #{job.id} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp scheduled_now(now, "Etc/UTC"), do: now

  defp scheduled_now(now, timezone) do
    case DateTime.shift_zone(now, timezone, time_zone_database()) do
      {:ok, shifted} ->
        shifted

      {:error, reason} ->
        raise ArgumentError, "task scheduler timezone #{inspect(timezone)} is invalid: #{inspect(reason)}"
    end
  end

  defp time_zone_database do
    Application.get_env(:yellow_dog_tasks, :time_zone_database, Calendar.UTCOnlyTimeZoneDatabase)
  end

  defp release_schedule(task_key, minute_id) do
    case Store.release_schedule(task_key, minute_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Task scheduler failed to release reservation for #{task_key}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp schedule_tick do
    Process.send_after(self(), :tick, @tick_interval_ms)
  end
end
