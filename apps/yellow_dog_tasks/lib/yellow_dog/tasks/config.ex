defmodule YellowDog.Tasks.Config do
  @moduledoc """
  Runtime configuration for YellowDog background task processing.
  """

  alias YellowDog.Tasks.Cron
  alias YellowDog.Config.TomlHelpers

  @cloud_zone_prefix "cloud_zone:"

  @type t :: %__MODULE__{
          enabled?: boolean(),
          timezone: Calendar.time_zone(),
          sync: map()
        }

  defstruct enabled?: true,
            timezone: "Etc/UTC",
            sync: %{}

  @sync_tasks [
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

    validate_config!(config)

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

  @doc """
  Updates a task's schedule in the standalone task configuration.
  """
  @spec update_sync_task(atom() | String.t(), map()) :: {:ok, t()} | {:error, term()}
  def update_sync_task(task_key, attrs) when is_map(attrs) do
    task_key = task_key_to_string(task_key)
    current_config = load()
    writable_config = writable_config()
    current_schedule = Map.get(current_config.sync, task_key, default_dynamic_schedule(task_key))

    with {:ok, schedule} <- schedule_from_attrs(current_schedule, attrs),
         updated_config <- put_sync_schedule(writable_config, task_key, schedule),
         :ok <- validate_for_update(updated_config),
         :ok <- persist_config(updated_config) do
      Application.put_env(:yellow_dog_tasks, :tasks_config, updated_config)
      {:ok, load()}
    end
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

  defp validate_config!(config) do
    validate_boolean!("tasks.enabled", Map.get(config, "enabled"))
    validate_timezone!(Map.get(config, "timezone"))
    validate_sync!(Map.get(config, "sync"))
  end

  defp validate_sync!(sync) when is_map(sync) do
    known_tasks = @sync_tasks |> Enum.map(fn {name, _cron} -> name end) |> MapSet.new()

    sync
    |> Map.keys()
    |> Enum.reject(&(MapSet.member?(known_tasks, &1) or dynamic_task_key?(&1)))
    |> case do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "tasks.sync contains unknown task key(s): #{unknown |> Enum.sort() |> Enum.join(", ")}"
    end

    Enum.each(sync, fn {name, schedule} ->
      validate_schedule!("tasks.sync.#{name}", schedule)
    end)
  end

  defp validate_sync!(sync) do
    raise ArgumentError, "tasks.sync must be a map, got #{inspect(sync)}"
  end

  defp validate_schedule!(path, schedule) when is_map(schedule) do
    validate_boolean!("#{path}.enabled", Map.get(schedule, "enabled"))
    validate_cron!("#{path}.cron", Map.get(schedule, "cron"))
    validate_max_attempts!("#{path}.max_attempts", Map.get(schedule, "max_attempts"))
  end

  defp validate_schedule!(path, schedule) do
    raise ArgumentError, "#{path} must be a map, got #{inspect(schedule)}"
  end

  defp validate_boolean!(_path, value) when is_boolean(value), do: :ok

  defp validate_boolean!(path, value) do
    raise ArgumentError, "#{path} must be a boolean, got #{inspect(value)}"
  end

  defp validate_timezone!(timezone) when is_binary(timezone) do
    case DateTime.now(timezone, time_zone_database()) do
      {:ok, _now} -> :ok
      {:error, reason} -> raise ArgumentError, "tasks.timezone is invalid: #{inspect(reason)}"
    end
  end

  defp validate_timezone!(timezone) do
    raise ArgumentError, "tasks.timezone must be a string, got #{inspect(timezone)}"
  end

  defp validate_cron!(path, cron) when is_binary(cron) do
    case Cron.parse(cron) do
      {:ok, _expression} -> :ok
      {:error, error} -> raise ArgumentError, "#{path} is invalid: #{error}"
    end
  end

  defp validate_cron!(path, _cron) do
    raise ArgumentError, "#{path} must be a cron expression string"
  end

  defp validate_max_attempts!(_path, attempts) when is_integer(attempts) and attempts >= 1,
    do: :ok

  defp validate_max_attempts!(path, attempts) when is_integer(attempts) do
    raise ArgumentError, "#{path} must be greater than or equal to 1, got #{attempts}"
  end

  defp validate_max_attempts!(path, attempts) do
    raise ArgumentError, "#{path} must be an integer, got #{inspect(attempts)}"
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

  defp writable_config do
    file_config =
      :yellow_dog_tasks
      |> Application.get_env(:config_file_path)
      |> load_file_config()

    app_config =
      :yellow_dog_tasks
      |> Application.get_env(:tasks_config, %{})
      |> normalize_keys()

    file_config
    |> deep_merge(app_config)
    |> Map.put_new("enabled", true)
    |> Map.put_new("timezone", "Etc/UTC")
    |> Map.put_new("sync", %{})
  end

  defp put_sync_schedule(config, task_key, schedule) do
    sync =
      config
      |> Map.get("sync", %{})
      |> Map.put(task_key, schedule)

    Map.put(config, "sync", sync)
  end

  defp schedule_from_attrs(current_schedule, attrs) do
    attrs = normalize_keys(attrs)

    enabled =
      attrs |> Map.get("enabled", Map.get(current_schedule, "enabled", true)) |> to_boolean()

    cron = attrs |> Map.get("cron", Map.get(current_schedule, "cron")) |> normalize_cron()
    max_attempts = Map.get(current_schedule, "max_attempts", 3)
    schedule = %{"enabled" => enabled, "cron" => cron, "max_attempts" => max_attempts}

    try do
      validate_schedule!("tasks.sync.task", schedule)
      {:ok, schedule}
    rescue
      exception in ArgumentError -> {:error, Exception.message(exception)}
    end
  end

  defp normalize_cron(cron) when is_binary(cron), do: String.trim(cron)
  defp normalize_cron(cron), do: cron

  defp to_boolean(value) when is_list(value), do: value |> List.last() |> to_boolean()
  defp to_boolean(value) when value in [true, "true", "1", 1, "on"], do: true
  defp to_boolean(_value), do: false

  defp validate_for_update(config) do
    try do
      config
      |> deep_merge(%{})
      |> validate_config!()

      :ok
    rescue
      exception in ArgumentError -> {:error, Exception.message(exception)}
    end
  end

  defp persist_config(config) do
    case Application.get_env(:yellow_dog_tasks, :config_file_path) do
      path when is_binary(path) ->
        TomlHelpers.atomic_write(path, encode_tasks_config(config))

      _path ->
        :ok
    end
  end

  defp encode_tasks_config(config) do
    sync = Map.get(config, "sync", %{})

    header = [
      "# Yellow Dog Task Scheduler Configuration",
      "# Job records and schedule reservations are stored in YellowDog.Store/Concord.",
      "",
      "[tasks]",
      "enabled = #{TomlHelpers.encode_toml_value(Map.get(config, "enabled", true))}",
      "timezone = #{TomlHelpers.encode_toml_value(Map.get(config, "timezone", "Etc/UTC"))}"
    ]

    sections =
      sync
      |> Enum.sort_by(fn {key, _schedule} -> key end)
      |> Enum.flat_map(fn {task_key, schedule} ->
        [
          "",
          "[tasks.sync.#{toml_key(task_key)}]",
          "enabled = #{TomlHelpers.encode_toml_value(Map.get(schedule, "enabled", true))}",
          "cron = #{TomlHelpers.encode_toml_value(Map.get(schedule, "cron"))}",
          "max_attempts = #{TomlHelpers.encode_toml_value(Map.get(schedule, "max_attempts", 3))}"
        ]
      end)

    Enum.join(header ++ sections, "\n") <> "\n"
  end

  defp toml_key(key) do
    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, key) do
      key
    else
      TomlHelpers.encode_toml_string(key)
    end
  end

  defp default_dynamic_schedule(task_key) do
    if dynamic_task_key?(task_key) do
      %{"enabled" => true, "cron" => "0 * * * *", "max_attempts" => 3}
    else
      %{}
    end
  end

  defp dynamic_task_key?(key) when is_binary(key),
    do: String.starts_with?(key, @cloud_zone_prefix)

  defp dynamic_task_key?(_key), do: false

  defp task_key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp task_key_to_string(key) when is_binary(key), do: key

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp time_zone_database do
    Application.get_env(:yellow_dog_tasks, :time_zone_database, Calendar.UTCOnlyTimeZoneDatabase)
  end
end
