defmodule Abyss.Logger do
  @moduledoc """
  Logging conveniences for Abyss servers

  Allows dynamically adding and altering the log level used to trace connections
  within a Abyss server via the use of telemetry hooks. Should you wish
  to do your own logging or tracking of these events, a complete list of the
  telemetry events emitted by Abyss is described in the module
  documentation for `Abyss.Telemetry`.
  """

  require Logger

  @typedoc "Supported log levels"
  @type log_level :: :error | :info | :debug | :trace

  @doc """
  Start logging Abyss at the specified log level. Valid values for log
  level are `:error`, `:info`, `:debug`, and `:trace`. Enabling a given log
  level implicitly enables all higher log levels as well.
  """
  @spec attach_logger(log_level()) :: :ok | {:error, :already_exists}
  def attach_logger(:error) do
    events = [
      [:abyss, :acceptor, :spawn_error],
      [:abyss, :acceptor, :econnaborted]
    ]

    :telemetry.attach_many("#{__MODULE__}.error", events, &__MODULE__.log_error/4, nil)
  end

  def attach_logger(:info) do
    _ = attach_logger(:error)

    events = [
      [:abyss, :listener, :start],
      [:abyss, :listener, :ready],
      [:abyss, :listener, :waiting],
      [:abyss, :listener, :receiving],
      [:abyss, :listener, :recv_error],
      [:abyss, :listener, :stop]
    ]

    :telemetry.attach_many("#{__MODULE__}.info", events, &__MODULE__.log_info/4, nil)
  end

  def attach_logger(:debug) do
    _ = attach_logger(:info)

    events = [
      [:abyss, :acceptor, :start],
      [:abyss, :acceptor, :stop],
      [:abyss, :connection, :start],
      [:abyss, :connection, :stop]
    ]

    :telemetry.attach_many("#{__MODULE__}.debug", events, &__MODULE__.log_debug/4, nil)
  end

  def attach_logger(:trace) do
    _ = attach_logger(:debug)

    events = [
      [:abyss, :connection, :ready],
      [:abyss, :connection, :async_recv],
      [:abyss, :connection, :recv],
      [:abyss, :connection, :recv_error],
      [:abyss, :connection, :send],
      [:abyss, :connection, :send_error],
      [:abyss, :connection, :sendfile],
      [:abyss, :connection, :sendfile_error],
      [:abyss, :connection, :socket_shutdown]
    ]

    :telemetry.attach_many("#{__MODULE__}.trace", events, &__MODULE__.log_trace/4, nil)
  end

  @doc """
  Stop logging Abyss at the specified log level. Disabling a given log
  level implicitly disables all lower log levels as well.
  """
  @spec detach_logger(log_level()) :: :ok | {:error, :not_found}
  def detach_logger(:error) do
    _ = detach_logger(:info)
    :telemetry.detach("#{__MODULE__}.error")
  end

  def detach_logger(:info) do
    _ = detach_logger(:debug)
    :telemetry.detach("#{__MODULE__}.info")
  end

  def detach_logger(:debug) do
    _ = detach_logger(:trace)
    :telemetry.detach("#{__MODULE__}.debug")
  end

  def detach_logger(:trace) do
    :telemetry.detach("#{__MODULE__}.trace")
  end

  @doc false
  @spec log_error(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          :telemetry.handler_config()
        ) :: :ok
  def log_error(event, measurements, metadata, _config) do
    Logger.error(
      "#{inspect(event)} metadata: #{inspect(metadata)}, measurements: #{inspect(measurements)}"
    )
  end

  @doc false
  @spec log_info(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          :telemetry.handler_config()
        ) :: :ok
  def log_info(event, measurements, metadata, _config) do
    Logger.info(
      "#{inspect(event)} metadata: #{inspect(metadata)}, measurements: #{inspect(measurements)}"
    )
  end

  @doc false
  @spec log_debug(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          :telemetry.handler_config()
        ) :: :ok
  def log_debug(event, measurements, metadata, _config) do
    Logger.debug(
      "#{inspect(event)} metadata: #{inspect(metadata)}, measurements: #{inspect(measurements)}"
    )
  end

  @doc false
  @spec log_trace(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          :telemetry.handler_config()
        ) :: :ok
  def log_trace(event, measurements, metadata, _config) do
    Logger.debug(
      "#{inspect(event)} metadata: #{inspect(metadata)}, measurements: #{inspect(measurements)}"
    )
  end
end
