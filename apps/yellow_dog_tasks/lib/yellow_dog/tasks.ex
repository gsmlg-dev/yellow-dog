defmodule YellowDog.Tasks do
  @moduledoc """
  Foundation entry point for YellowDog background task processing.
  """

  alias YellowDog.Tasks.Config
  alias YellowDog.Tasks.DataSync
  alias YellowDog.Tasks.Runner
  alias YellowDog.Tasks.TaskStatus
  alias YellowDog.Store.Key
  alias YellowDog.Store.Provider
  alias YellowDog.Store.Zone

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
  Enqueues a validated manual cloud-zone synchronization job.
  """
  @spec enqueue_cloud_zone_sync(String.t(), String.t(), String.t()) ::
          {:ok, YellowDog.Tasks.Job.t()}
          | {:error, :invalid | :not_found | :conflict | :unsupported | :apply_failed}
  def enqueue_cloud_zone_sync(view_name, zone_name, provider_id)
      when is_binary(view_name) and is_binary(zone_name) and is_binary(provider_id) do
    with {:ok, {view_name, zone_name}} <- canonical_zone_scope(view_name, zone_name),
         {:ok, zone} <- fetch_zone(view_name, zone_name),
         :ok <- authoritative_zone(zone),
         {:ok, mirror} <- enabled_mirror(zone),
         {:ok, mirror_type} <- supported_mirror_provider(mirror),
         :ok <- matching_provider(mirror, provider_id),
         {:ok, provider} <- fetch_provider(provider_id),
         :ok <- enabled_supported_provider(provider, mirror_type) do
      case Runner.enqueue(DataSync.cloud_zone_task_key(view_name, zone_name), force: true) do
        {:ok, job} -> {:ok, job}
        {:error, _reason} -> {:error, :apply_failed}
      end
    end
  end

  def enqueue_cloud_zone_sync(_view_name, _zone_name, _provider_id), do: {:error, :invalid}

  @doc """
  Returns recent jobs for a known task.
  """
  @spec recent_jobs(atom() | String.t(), keyword()) :: [YellowDog.Tasks.Job.t()]
  def recent_jobs(key, opts \\ []), do: TaskStatus.recent_jobs(key, opts)

  defp canonical_zone_scope(view_name, zone_name) do
    case Key.canonical_zone_scope(view_name, zone_name) do
      {:ok, scope} -> {:ok, scope}
      {:error, _reason} -> {:error, :invalid}
    end
  end

  defp fetch_zone(view_name, zone_name) do
    case Zone.get_zone(view_name, zone_name) do
      {:ok, zone} when is_map(zone) -> {:ok, zone}
      {:error, :not_found} -> {:error, :not_found}
      _error -> {:error, :apply_failed}
    end
  end

  defp authoritative_zone(zone) do
    if value(zone, :zone_type) in [:auth, :authoritative, "auth", "authoritative"] do
      :ok
    else
      {:error, :unsupported}
    end
  end

  defp enabled_mirror(zone) do
    case value(zone, :cloud_mirror) do
      mirror when is_map(mirror) ->
        if truthy?(value(mirror, :enabled)), do: {:ok, mirror}, else: {:error, :unsupported}

      _mirror ->
        {:error, :unsupported}
    end
  end

  defp matching_provider(mirror, provider_id) do
    if value(mirror, :connector_name) == provider_id, do: :ok, else: {:error, :conflict}
  end

  defp supported_mirror_provider(mirror) do
    case normalize_provider(value(mirror, :provider)) do
      provider when provider in [:cloudflare, :route53] -> {:ok, provider}
      _provider -> {:error, :unsupported}
    end
  end

  defp fetch_provider(provider_id) do
    case Provider.get_config(provider_id) do
      {:ok, provider} when is_map(provider) -> {:ok, provider}
      {:error, :not_found} -> {:error, :not_found}
      _error -> {:error, :apply_failed}
    end
  end

  defp enabled_supported_provider(provider, mirror_type) do
    provider_type = normalize_provider(value(provider, :type))

    cond do
      not truthy?(value(provider, :enabled)) ->
        {:error, :unsupported}

      provider_type not in [:cloudflare, :route53] ->
        {:error, :unsupported}

      provider_type == mirror_type ->
        :ok

      true ->
        {:error, :conflict}
    end
  end

  defp normalize_provider(:aws), do: :route53
  defp normalize_provider("aws"), do: :route53
  defp normalize_provider(:route53), do: :route53
  defp normalize_provider("route53"), do: :route53
  defp normalize_provider(:cloudflare), do: :cloudflare
  defp normalize_provider("cloudflare"), do: :cloudflare
  defp normalize_provider(_provider), do: :unsupported

  defp value(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
