defmodule YellowDog.Tasks.Config do
  @moduledoc """
  Runtime configuration for YellowDog background task processing.
  """

  alias YellowDog.Tasks.Cron
  alias YellowDog.Config.TomlHelpers

  @type t :: %__MODULE__{
          enabled?: boolean(),
          timezone: Calendar.time_zone(),
          sync: map()
        }

  defstruct enabled?: true,
            timezone: "Etc/UTC",
            sync: %{}

  @sync_tasks [
    {"region", "0 2 * * SUN"},
    {"ip_country", "0 3 2 * *"},
    {"ip_city", "30 3 2 * *"},
    {"mac", "0 4 * * SUN"}
  ]

  @defaults %{
    "enabled" => true,
    "timezone" => "Etc/UTC",
    "sync" =>
      Map.new(@sync_tasks, fn {name, cron} ->
        {name, %{"enabled" => true, "cron" => cron, "max_attempts" => 3}}
      end)
  }

  @doc """
  Loads task config from application env and validates configured cron expressions.
  """
  @spec load() :: t()
  def load do
    file_config =
      :yellow_dog_tasks
      |> Application.get_env(:config_file_path)
      |> load_file_config()

    app_config =
      :yellow_dog_tasks
      |> Application.get_env(:tasks_config, %{})
      |> normalize_keys()

    config =
      @defaults
      |> deep_merge(file_config)
      |> deep_merge(app_config)

    validate_sync_tasks!(config)
    validate_crons!(config)

    %__MODULE__{
      enabled?: truthy?(Map.get(config, "enabled")),
      timezone: Map.get(config, "timezone", "Etc/UTC"),
      sync: Map.get(config, "sync", %{})
    }
  end

  @doc """
  Returns configured cron entries for enabled fixed YellowDog sync tasks.
  """
  @spec cron_entries(t()) :: [{String.t(), atom()}]
  def cron_entries(%__MODULE__{enabled?: false}), do: []

  def cron_entries(%__MODULE__{} = config) do
    Enum.flat_map(@sync_tasks, &cron_entry(&1, config.sync))
  end

  defp enabled?(%{"enabled" => enabled}), do: truthy?(enabled)
  defp enabled?(_schedule), do: false

  defp load_file_config(nil), do: %{}

  defp load_file_config(path) when is_binary(path) do
    if File.exists?(path) do
      case TomlHelpers.read_toml_file(path) do
        {:ok, parsed} ->
          parsed
          |> normalize_keys()
          |> unwrap_tasks_root()

        {:error, reason} ->
          raise ArgumentError, "failed to load task config #{path}: #{inspect(reason)}"
      end
    else
      %{}
    end
  end

  defp unwrap_tasks_root(%{"tasks" => tasks}) when is_map(tasks), do: tasks
  defp unwrap_tasks_root(config), do: config

  defp cron_entry({name, _default_cron}, sync) do
    schedule = Map.get(sync, name)

    if enabled?(schedule) do
      [{Map.fetch!(schedule, "cron"), String.to_existing_atom(name)}]
    else
      []
    end
  end

  defp validate_sync_tasks!(%{"sync" => sync}) when is_map(sync) do
    known_tasks = @sync_tasks |> Enum.map(fn {name, _cron} -> name end) |> MapSet.new()

    sync
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(known_tasks, &1))
    |> case do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "tasks.sync contains unknown task key(s): #{unknown |> Enum.sort() |> Enum.join(", ")}"
    end
  end

  defp validate_sync_tasks!(_config), do: :ok

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
    case Cron.parse(cron) do
      {:ok, _expression} -> :ok
      {:error, error} -> raise ArgumentError, "#{path} is invalid: #{error}"
    end
  end

  defp validate_cron!(path, _cron) do
    raise ArgumentError, "#{path} must be a cron expression string"
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
