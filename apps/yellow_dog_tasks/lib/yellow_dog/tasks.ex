defmodule YellowDog.Tasks do
  @moduledoc """
  Foundation entry point for YellowDog background task processing.
  """

  alias YellowDog.Tasks.Config
  alias YellowDog.Tasks.DataSync
  alias YellowDog.Tasks.Runner
  alias YellowDog.Tasks.TaskStatus

  @doc """
  Loads the current task processing configuration.
  """
  @spec config() :: Config.t()
  def config, do: Config.load()

  @doc """
  Lists known data synchronization tasks with recent status.
  """
  @spec list_tasks() :: [map()]
  def list_tasks do
    DataSync.list_tasks()
    |> Enum.map(&TaskStatus.put_status/1)
  end

  @doc """
  Fetches a known task by key.
  """
  @spec get_task!(atom() | String.t()) :: map()
  def get_task!(key) do
    key
    |> DataSync.get_task!()
    |> TaskStatus.put_status()
  end

  @doc """
  Enqueues a manual sync job for a known task.
  """
  @spec enqueue(atom() | String.t(), keyword()) ::
          {:ok, YellowDog.Tasks.Job.t()} | {:error, term()}
  def enqueue(key, opts \\ []), do: Runner.enqueue(key, opts)

  @doc """
  Returns recent jobs for a known task.
  """
  @spec recent_jobs(atom() | String.t(), keyword()) :: [YellowDog.Tasks.Job.t()]
  def recent_jobs(key, opts \\ []), do: TaskStatus.recent_jobs(key, opts)
end
