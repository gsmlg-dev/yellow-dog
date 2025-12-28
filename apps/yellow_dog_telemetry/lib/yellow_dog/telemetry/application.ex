defmodule YellowDog.Telemetry.Application do
  @moduledoc """
  Application module for YellowDog.Telemetry.

  Sets up telemetry event handlers for logging and span tracking based on
  environment configuration.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Attach telemetry handlers
    attach_handlers()

    children = []

    opts = [strategy: :one_for_one, name: YellowDog.Telemetry.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp attach_handlers do
    # Attach log handlers
    :telemetry.attach_many(
      "yellow-dog-log-handler",
      [
        [:yellow_dog, :log, :debug],
        [:yellow_dog, :log, :info],
        [:yellow_dog, :log, :warning],
        [:yellow_dog, :log, :error]
      ],
      &handle_log_event/4,
      nil
    )

    # Attach span handlers
    :telemetry.attach_many(
      "yellow-dog-span-handler",
      [
        [:yellow_dog, :span, :start],
        [:yellow_dog, :span, :stop]
      ],
      &handle_span_event/4,
      nil
    )

    :ok
  end

  # Handle log events
  defp handle_log_event([:yellow_dog, :log, level], _measurements, metadata, _config) do
    format = get_format()
    show_colors = get_config(:console_colors, false)

    case format do
      :pretty -> log_pretty(level, metadata, show_colors)
      :json -> log_json(level, metadata)
      :minimal -> log_minimal(level, metadata)
      _ -> log_default(level, metadata)
    end
  end

  # Handle span events
  defp handle_span_event([:yellow_dog, :span, event], measurements, metadata, _config) do
    show_spans = get_config(:show_spans, true)

    if show_spans do
      case event do
        :start -> handle_span_start(measurements, metadata)
        :stop -> handle_span_stop(measurements, metadata)
      end
    end
  end

  # Pretty formatter for development
  defp log_pretty(level, metadata, show_colors) do
    %{message: message, app: app, module: module, function: function, line: line} = metadata

    level_str = format_level(level, show_colors)
    app_str = format_app(app, show_colors)
    location = "#{inspect(module)}.#{function}:#{line}"

    # Extract additional metadata (excluding standard fields)
    extra_metadata =
      metadata
      |> Map.drop([:message, :app, :module, :function, :line, :span_id])
      |> case do
        map when map_size(map) == 0 -> ""
        map -> " " <> inspect(map, pretty: true, limit: :infinity)
      end

    Logger.log(
      level,
      "[#{level_str}] [#{app_str}] #{message}#{extra_metadata}\n    at #{location}"
    )
  end

  # JSON formatter for production
  defp log_json(level, metadata) do
    %{message: message, app: app, module: module} = metadata

    if Code.ensure_loaded?(Jason) do
      json =
        Jason.encode!(%{
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          level: level,
          app: app,
          module: module,
          message: message,
          metadata: Map.drop(metadata, [:message, :app, :module])
        })

      Logger.log(level, json)
    else
      # Fallback to default formatter if Jason is not available
      log_default(level, metadata)
    end
  end

  # Minimal formatter for tests
  defp log_minimal(level, %{message: message}) do
    Logger.log(level, message)
  end

  # Default formatter
  defp log_default(level, %{message: message, app: app}) do
    Logger.log(level, "[#{app}] #{message}")
  end

  # Span start handler
  defp handle_span_start(_measurements, metadata) do
    %{span_id: _span_id, name: name, app: app} = metadata

    if get_config(:show_span_start, false) do
      Logger.debug("[SPAN START] [#{app}] #{name}")
    end
  end

  # Span stop handler
  defp handle_span_stop(measurements, metadata) do
    %{duration_ms: duration_ms} = measurements
    %{name: name, app: app} = metadata

    status = Map.get(metadata, :status, :success)
    status_icon = if status == :success, do: "✓", else: "✗"

    # Check threshold
    threshold = get_config(:span_threshold_ms, 0)

    if duration_ms >= threshold do
      Logger.info("[SPAN #{status_icon}] [#{app}] #{name} (#{format_duration(duration_ms)})")
    end
  end

  # Helper functions

  defp get_format do
    get_config(:format, default_format())
  end

  defp default_format do
    if function_exported?(Mix, :env, 0) do
      case Mix.env() do
        :dev -> :pretty
        :test -> :minimal
        :prod -> :json
      end
    else
      :json
    end
  end

  defp get_config(key, default) do
    Application.get_env(:yellow_dog_telemetry, key, default)
  end

  defp format_level(level, show_colors) do
    level_str = level |> to_string() |> String.upcase()

    if show_colors do
      case level do
        :debug -> IO.ANSI.cyan() <> level_str <> IO.ANSI.reset()
        :info -> IO.ANSI.green() <> level_str <> IO.ANSI.reset()
        :warn -> IO.ANSI.yellow() <> level_str <> IO.ANSI.reset()
        :error -> IO.ANSI.red() <> level_str <> IO.ANSI.reset()
      end
    else
      level_str
    end
  end

  defp format_app(app, show_colors) do
    app_str = to_string(app)

    if show_colors do
      # Different colors for different apps
      color =
        case app do
          :yellow_dog_dns -> IO.ANSI.blue()
          :yellow_dog_dhcpv4 -> IO.ANSI.magenta()
          :yellow_dog_dhcpv6 -> IO.ANSI.cyan()
          :yellow_dog_mdns -> IO.ANSI.green()
          :yellow_dog_console -> IO.ANSI.yellow()
          :yellow_dog -> IO.ANSI.light_blue()
          _ -> IO.ANSI.white()
        end

      color <> app_str <> IO.ANSI.reset()
    else
      app_str
    end
  end

  defp format_duration(ms) when ms < 1, do: "#{Float.round(ms * 1000, 2)}μs"
  defp format_duration(ms) when ms < 1000, do: "#{Float.round(ms, 2)}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 2)}s"
end
