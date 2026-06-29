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
  Updates schedule settings for a known task.
  """
  @spec update_task(atom() | String.t(), map()) :: {:ok, map()} | {:error, term()}
  def update_task(key, attrs) when is_map(attrs) do
    with {:ok, task} <- DataSync.fetch_task(key),
         {:ok, _config} <- Config.update_sync_task(task.key, attrs),
         {:ok, updated_task} <- DataSync.fetch_task(task.key) do
      {:ok, TaskStatus.put_status(updated_task)}
    end
  end

  @doc """
  Returns the task key for a view-scoped cloud zone sync task.
  """
  @spec cloud_zone_task_key(String.t(), String.t()) :: String.t()
  def cloud_zone_task_key(view_name, zone_name),
    do: DataSync.cloud_zone_task_key(view_name, zone_name)

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
