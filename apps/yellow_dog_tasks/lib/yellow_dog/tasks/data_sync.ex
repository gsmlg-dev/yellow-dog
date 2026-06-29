defmodule YellowDog.Tasks.DataSync do
  @moduledoc """
  Registry and execution helpers for YellowDog data synchronization tasks.
  """

  alias YellowDog.Tasks.Config
  alias YellowDog.Tasks.Workers.SyncIpDatabaseWorker
  alias YellowDog.Tasks.Workers.SyncMacDatabaseWorker

  @telemetry_prefix [:yellow_dog, :tasks, :sync]

  @tasks %{
    ip_country: %{
      key: :ip_country,
      label: "IP Country",
      source: "db-ip",
      worker: SyncIpDatabaseWorker,
      args: %{"type" => "country"},
      max_attempts: 3
    },
    ip_city: %{
      key: :ip_city,
      label: "IP City",
      source: "db-ip",
      worker: SyncIpDatabaseWorker,
      args: %{"type" => "city"},
      max_attempts: 3
    },
    mac: %{
      key: :mac,
      label: "MAC/OUI",
      source: "wireshark-manuf",
      worker: SyncMacDatabaseWorker,
      args: %{},
      max_attempts: 3
    }
  }

  @spec list_tasks() :: [map()]
  def list_tasks do
    Config.load()
    |> list_tasks()
  end

  @spec list_tasks(Config.t()) :: [map()]
  def list_tasks(%Config{} = config) do
    Enum.map([:ip_country, :ip_city, :mac], &task_with_config!(&1, config))
  end

  @spec get_task!(atom() | String.t()) :: map()
  def get_task!(key) do
    key
    |> normalize_key!()
    |> task_with_config!(Config.load())
  end

  @spec fetch_task(atom() | String.t()) :: {:ok, map()} | {:error, :unknown_task}
  def fetch_task(key) do
    {:ok, get_task!(key)}
  rescue
    KeyError -> {:error, :unknown_task}
  end

  @spec sync_ip_database(String.t()) :: :ok | {:error, term()}
  def sync_ip_database(type) when type in ["city", "country"] do
    type_atom = ip_database_type(type)
    downloader = Application.get_env(:yellow_dog_tasks, :ip_database_downloader, &GeoIpDb.Database.download/1)
    metadata = Application.get_env(:yellow_dog_tasks, :ip_database_metadata, &GeoIpDb.Database.get_metadata/1)
    file_info = Application.get_env(:yellow_dog_tasks, :ip_database_file_info, &GeoIpDb.Database.file_info/1)

    with {:ok, _path} <- downloader.(type_atom),
         {:ok, _metadata} <- metadata.(type_atom),
         {:ok, _file_info} <- file_info.(type_atom) do
      :ok
    end
  end

  def sync_ip_database(type), do: {:error, {:invalid_type, type}}

  @spec sync_mac_database() :: :ok | {:error, term()}
  def sync_mac_database do
    ensure_started =
      Application.get_env(
        :yellow_dog_tasks,
        :mac_database_ensure_started,
        &ensure_oui_database_started/0
      )

    downloader =
      Application.get_env(:yellow_dog_tasks, :mac_database_downloader, fn ->
        YellowDog.Fingerprint.OuiDatabase.download()
      end)

    info = Application.get_env(:yellow_dog_tasks, :mac_database_info, fn ->
      YellowDog.Fingerprint.OuiDatabase.info()
    end)

    with :ok <- ensure_started.(),
         {:ok, _path} <- downloader.(),
         %{entry_count: count} when count > 0 <- info.() do
      :ok
    else
      %{entry_count: count} -> {:error, {:empty_database, count}}
      other -> other
    end
  end

  @spec with_telemetry(atom(), String.t(), String.t() | nil, (-> term())) :: term()
  def with_telemetry(task, source, job_id, fun) when is_function(fun, 0) do
    started_at = System.monotonic_time()
    metadata = %{task: task, source: source, job_id: job_id}

    :telemetry.execute(@telemetry_prefix ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      case fun.() do
        {:error, reason} = error ->
          emit_exception(started_at, metadata, :error, reason, [])
          error

        result ->
          duration = System.monotonic_time() - started_at
          :telemetry.execute(@telemetry_prefix ++ [:stop], %{duration: duration}, metadata)
          result
      end
    rescue
      exception ->
        emit_exception(started_at, metadata, :error, exception, __STACKTRACE__)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        emit_exception(started_at, metadata, kind, reason, __STACKTRACE__)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit_exception(started_at, metadata, kind, reason, stacktrace) do
    duration = System.monotonic_time() - started_at

    :telemetry.execute(
      @telemetry_prefix ++ [:exception],
      %{duration: duration},
      Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
    )
  end

  defp task_with_config!(key, config) do
    task = Map.fetch!(@tasks, key)
    schedule = Map.get(config.sync, Atom.to_string(key), %{})
    max_attempts = Map.get(schedule, "max_attempts", task.max_attempts)

    task
    |> Map.put(:enabled?, config.enabled? and enabled?(schedule))
    |> Map.put(:cron, Map.get(schedule, "cron"))
    |> Map.put(:max_attempts, max_attempts)
  end

  defp normalize_key!(key) when is_atom(key) do
    if Map.has_key?(@tasks, key), do: key, else: raise(KeyError, key: key, term: @tasks)
  end

  defp normalize_key!(key) when is_binary(key) do
    key
    |> String.to_existing_atom()
    |> normalize_key!()
  rescue
    ArgumentError -> raise KeyError, key: key, term: @tasks
  end

  defp enabled?(%{"enabled" => enabled}), do: enabled in [true, "true", "1", 1]
  defp enabled?(_schedule), do: false

  defp ip_database_type("city"), do: :city
  defp ip_database_type("country"), do: :country

  defp ensure_oui_database_started do
    case GenServer.whereis(YellowDog.Fingerprint.OuiDatabase) do
      nil ->
        data_dir = Path.join(YellowDog.Config.get_data_dir(), "fingerprint")

        case YellowDog.Fingerprint.OuiDatabase.start_link(data_dir: data_dir) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end
end
