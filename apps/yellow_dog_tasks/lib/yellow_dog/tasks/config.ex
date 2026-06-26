defmodule YellowDog.Tasks.Config do
  @moduledoc """
  Runtime configuration for YellowDog background task processing.
  """

  alias YellowDog.Tasks.Repo

  @type t :: %__MODULE__{
          enabled?: boolean(),
          timezone: Calendar.time_zone(),
          sync: map(),
          data_dir: Path.t()
        }

  defstruct enabled?: true,
            timezone: "Etc/UTC",
            sync: %{},
            data_dir: "data"

  @sync_tasks [
    {"region", "0 2 * * SUN", YellowDog.Tasks.Workers.SyncRegionDataWorker, []},
    {"ip_country", "0 3 2 * *", YellowDog.Tasks.Workers.SyncIpDatabaseWorker,
     [args: %{type: "country"}]},
    {"ip_city", "30 3 2 * *", YellowDog.Tasks.Workers.SyncIpDatabaseWorker,
     [args: %{type: "city"}]},
    {"mac", "0 4 * * SUN", YellowDog.Tasks.Workers.SyncMacDatabaseWorker, []}
  ]

  @defaults %{
    "enabled" => true,
    "timezone" => "Etc/UTC",
    "sync" =>
      Map.new(@sync_tasks, fn {name, cron, _worker, _opts} ->
        {name, %{"enabled" => true, "cron" => cron}}
      end)
  }

  @doc """
  Loads task config from application env and validates configured cron expressions.
  """
  @spec load() :: t()
  def load do
    app_config =
      :yellow_dog_tasks
      |> Application.get_env(:tasks_config, %{})
      |> normalize_keys()

    config = deep_merge(@defaults, app_config)

    validate_crons!(config)

    %__MODULE__{
      enabled?: truthy?(Map.get(config, "enabled")),
      timezone: Map.get(config, "timezone", "Etc/UTC"),
      sync: Map.get(config, "sync", %{}),
      data_dir: yellow_dog_data_dir()
    }
  end

  @doc """
  Builds the SQLite-backed Oban configuration for YellowDog task processing.
  """
  @spec oban_config(t()) :: keyword()
  def oban_config(%__MODULE__{} = config) do
    [
      engine: Oban.Engines.Lite,
      repo: Repo,
      queues: [data_sync: 1],
      plugins: cron_plugins(config)
    ]
  end

  @doc """
  Returns the SQLite database path under the YellowDog data directory.
  """
  @spec database_path(t()) :: Path.t()
  def database_path(%__MODULE__{data_dir: data_dir}) do
    Path.join([data_dir, "tasks", "yellow_dog_tasks.db"])
  end

  defp cron_plugins(%__MODULE__{enabled?: false}), do: []

  defp cron_plugins(%__MODULE__{} = config) do
    crontab = Enum.flat_map(@sync_tasks, &cron_entry(&1, config.sync))

    case crontab do
      [] -> []
      _ -> [{Oban.Plugins.Cron, crontab: crontab, timezone: config.timezone}]
    end
  end

  defp enabled?(%{"enabled" => enabled}), do: truthy?(enabled)
  defp enabled?(_schedule), do: false

  defp cron_entry({name, _default_cron, worker, opts}, sync) do
    schedule = Map.get(sync, name)

    if enabled?(schedule) do
      [cron_entry_tuple(Map.fetch!(schedule, "cron"), worker, opts)]
    else
      []
    end
  end

  defp cron_entry_tuple(cron, worker, []), do: {cron, worker}
  defp cron_entry_tuple(cron, worker, opts), do: {cron, worker, opts}

  defp validate_crons!(%{"sync" => sync}) when is_map(sync) do
    Enum.each(sync, fn {name, schedule} ->
      case schedule do
        %{"cron" => cron} -> validate_cron!("tasks.sync.#{name}.cron", cron)
        _ -> :ok
      end
    end)
  end

  defp validate_crons!(_config), do: :ok

  defp validate_cron!(path, cron) when is_binary(cron) do
    case Oban.Plugins.Cron.parse(cron) do
      {:ok, _expression} ->
        :ok

      {:error, error} ->
        raise ArgumentError, "#{path} is invalid: #{Exception.message(error)}"
    end
  end

  defp validate_cron!(path, _cron) do
    raise ArgumentError, "#{path} must be a cron expression string"
  end

  defp yellow_dog_data_dir do
    Application.get_env(:yellow_dog, :data_dir) || "data"
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp normalize_keys(config) when is_map(config) do
    Map.new(config, fn {key, value} -> {to_string(key), normalize_keys(value)} end)
  end

  defp normalize_keys(config), do: config

  defp truthy?(value), do: value in [true, "true", "1", 1]
end
