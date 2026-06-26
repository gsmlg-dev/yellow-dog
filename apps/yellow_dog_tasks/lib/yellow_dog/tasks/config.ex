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

  @defaults %{
    "enabled" => true,
    "timezone" => "Etc/UTC",
    "sync" => %{
      "ip_city" => %{
        "enabled" => false,
        "cron" => "0 3 * * *",
        "worker" => "YellowDog.Tasks.Workers.IpCitySync"
      }
    }
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
    crontab =
      config.sync
      |> Enum.flat_map(&cron_entry/1)

    case crontab do
      [] -> []
      _ -> [{Oban.Plugins.Cron, crontab: crontab, timezone: config.timezone}]
    end
  end

  defp cron_entry({_name, %{"enabled" => enabled} = schedule}) do
    if truthy?(enabled) do
      [{Map.fetch!(schedule, "cron"), worker_module(schedule)}]
    else
      []
    end
  end

  defp cron_entry(_schedule), do: []

  defp worker_module(schedule) do
    schedule
    |> Map.fetch!("worker")
    |> String.split(".")
    |> Module.concat()
  end

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
