defmodule YellowDog.Dns.CloudDnsSyncJob do
  @moduledoc """
  Background job boundary for pulling Cloud DNS records into a local zone.

  Arguments use string keys so this module can move behind an Oban worker without
  changing callers when Oban is introduced to the umbrella.
  """

  require Logger

  alias YellowDog.Dns.CloudDnsSync

  @task_supervisor __MODULE__.TaskSupervisor

  @type args :: %{required(String.t()) => String.t()}

  @spec enqueue(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def enqueue(view_name, zone_name, opts \\ [])
      when is_binary(view_name) and is_binary(zone_name) do
    runner = Application.get_env(:yellow_dog_dns, :cloud_dns_sync_job_runner, &task_runner/3)
    runner.(view_name, zone_name, opts)
  end

  @spec perform(args() | map(), keyword()) :: {:ok, map()} | {:error, term()}
  def perform(args, opts \\ [])

  def perform(%{"view_name" => view_name, "zone_name" => zone_name}, opts)
      when is_binary(view_name) and is_binary(zone_name) do
    {sync_fun, sync_opts} = Keyword.pop(opts, :sync_fun, &CloudDnsSync.sync_zone_from_cloud/3)
    sync_fun.(view_name, zone_name, sync_opts)
  end

  def perform(%{view_name: view_name, zone_name: zone_name}, opts) do
    perform(%{"view_name" => view_name, "zone_name" => zone_name}, opts)
  end

  def perform(_args, _opts), do: {:error, :invalid_args}

  @spec task_runner(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def task_runner(view_name, zone_name, opts) do
    if Process.whereis(@task_supervisor) do
      case Task.Supervisor.start_child(@task_supervisor, fn ->
             run_sync(view_name, zone_name, opts)
           end) do
        {:ok, _pid} -> :ok
        {:error, _reason} = error -> error
      end
    else
      {:error, :task_supervisor_not_started}
    end
  end

  defp run_sync(view_name, zone_name, opts) do
    case perform(%{"view_name" => view_name, "zone_name" => zone_name}, opts) do
      {:ok, result} ->
        Logger.info("Cloud DNS sync finished",
          view: view_name,
          zone: zone_name,
          result: inspect(result)
        )

      {:error, :cloud_sync_disabled} ->
        :ok

      {:error, reason} ->
        Logger.warning("Cloud DNS sync failed: #{inspect(reason)}",
          view: view_name,
          zone: zone_name
        )
    end
  rescue
    error ->
      Logger.error("Cloud DNS sync crashed: #{Exception.message(error)}",
        view: view_name,
        zone: zone_name
      )
  catch
    kind, reason ->
      Logger.error("Cloud DNS sync exited: #{inspect({kind, reason})}",
        view: view_name,
        zone: zone_name
      )
  end
end
