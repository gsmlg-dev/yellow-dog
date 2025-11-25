defmodule YellowDog.Telemetry do
  @moduledoc """
  Centralized telemetry and logging for the YellowDog umbrella project.

  This module provides:
  - Structured logging with automatic app name detection
  - Span tracking for performance monitoring
  - Filtering capabilities by app and log level
  - Integration with the `:telemetry` library

  ## Logging API

  Use the logging functions to emit structured log events:

      alias YellowDog.Telemetry

      Telemetry.info("DNS query received", %{domain: "example.com", type: "A"})
      Telemetry.debug("Processing request", %{client_ip: "192.168.1.1"})
      Telemetry.warn("Slow query detected", %{duration_ms: 150})
      Telemetry.error("Failed to resolve domain", %{domain: "bad.example", error: :nxdomain})

  The module automatically detects which umbrella app is calling based on the module namespace:
  - `YellowDog.Dns.*` → `:yellow_dog_dns`
  - `YellowDog.Dhcpv4.*` → `:yellow_dog_dhcpv4`
  - `YellowDog.Dhcpv6.*` → `:yellow_dog_dhcpv6`
  - `YellowDog.Mdns.*` → `:yellow_dog_mdns`
  - `YellowDog.Console.*` → `:yellow_dog_console`
  - `YellowDog.*` → `:yellow_dog`

  ## Span Tracking

  Track operation durations and performance:

      # Automatic span with function wrapper
      result = Telemetry.span("dns.query.resolve", %{domain: domain}, fn ->
        resolve_domain(domain)
      end)

      # Manual span control
      span_id = Telemetry.start_span("dhcp.lease.allocate", %{mac: mac_address})
      try do
        lease = allocate_lease(mac_address)
        Telemetry.end_span(span_id, %{ip: lease.ip, status: :success})
        lease
      rescue
        error ->
          Telemetry.end_span(span_id, %{error: inspect(error), status: :failed})
          reraise error, __STACKTRACE__
      end

  Spans automatically track duration in microseconds and emit telemetry events.

  ## App Filtering

  Configure filtering in config files:

      # Show only DNS logs
      config :yellow_dog_telemetry, YellowDog.Telemetry,
        filter_apps: [:yellow_dog_dns]

      # Exclude console logs
      config :yellow_dog_telemetry, YellowDog.Telemetry,
        exclude_apps: [:yellow_dog_console]

      # Per-app log levels
      config :yellow_dog_telemetry, YellowDog.Telemetry,
        app_levels: %{
          yellow_dog_dns: :debug,
          yellow_dog_dhcpv4: :info
        }

  Or at runtime:

      Telemetry.filter_apps([:yellow_dog_dns, :yellow_dog_dhcpv4])
      Telemetry.set_app_level(:yellow_dog_dns, :debug)
      Telemetry.show_all_apps()

  ## Network Telemetry Spans

  The following telemetry spans are emitted by yellow_dog for network operations:

  ### `[:yellow_dog, :listener, *]`

  Represents a YellowDog server listening to a port

  This span is started by the following event:

  * `[:yellow_dog, :listener, :start]`

      Represents the start of the span

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
      * `local_address`: The IP address that the listener is bound to
      * `local_port`: The port that the listener is bound to
      * `transport_module`: The transport module in use
      * `transport_options`: Options passed to the transport module at startup


  This span is ended by the following event:

  * `[:yellow_dog, :listener, :stop]`

      Represents the end of the span

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units
      * `duration`: The span duration, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
      * `local_address`: The IP address that the listener is bound to
      * `local_port`: The port that the listener is bound to
      * `transport_module`: The transport module in use
      * `transport_options`: Options passed to the transport module at startup

  ## `[:yellow_dog, :acceptor, *]`

  Represents a YellowDog acceptor process listening for connections

  This span is started by the following event:

  * `[:yellow_dog, :acceptor, :start]`

      Represents the start of the span

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
      * `parent_telemetry_span_context`: The span context of the `:listener` which created this acceptor

  This span is ended by the following event:

  * `[:yellow_dog, :acceptor, :stop]`

      Represents the end of the span

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units
      * `duration`: The span duration, in `:native` units
      * `connections`: The number of client requests that the acceptor handled

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
      * `parent_telemetry_span_context`: The span context of the `:listener` which created this acceptor
      * `error`: The error that caused the span to end, if it ended in error

  The following events may be emitted within this span:

  * `[:yellow_dog, :acceptor, :spawn_error]`

      YellowDog was unable to spawn a process to handle a connection. This occurs when too
      many connections are in progress; you may want to look at increasing the `num_connections`
      configuration parameter

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:yellow_dog, :acceptor, :econnaborted]`

      YellowDog was unable to spawn a process to handle a connection since the remote end
      closed before we could accept it. This usually occurs when it takes too long for your server
      to start processing a connection; you may want to look at tuning OS-level TCP parameters or
      adding more server capacity.

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  ## `[:yellow_dog, :connection, *]`

  Represents YellowDog handling a specific client request

  This span is started by the following event:

  * `[:yellow_dog, :connection, :start]`

      Represents the start of the span

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
      * `parent_telemetry_span_context`: The span context of the `:acceptor` span which accepted
      this connection
      * `remote_address`: The IP address of the connected client
      * `remote_port`: The port of the connected client

  This span is ended by the following event:

  * `[:yellow_dog, :connection, :stop]`

      Represents the end of the span

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units
      * `duration`: The span duration, in `:native` units
      * `send_oct`: The number of octets sent on the connection
      * `send_cnt`: The number of packets sent on the connection
      * `recv_oct`: The number of octets received on the connection
      * `recv_cnt`: The number of packets received on the connection

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
      * `parent_telemetry_span_context`: The span context of the `:acceptor` span which accepted
        this connection
      * `remote_address`: The IP address of the connected client
      * `remote_port`: The port of the connected client
      * `error`: The error that caused the span to end, if it ended in error

  The following events may be emitted within this span:

  * `[:yellow_dog, :connection, :ready]`

      YellowDog has completed setting up the client connection

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:yellow_dog, :connection, :async_recv]`

      YellowDog has asynchronously received data from the client

      This event contains the following measurements:

      * `data`: The data received from the client

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:yellow_dog, :connection, :recv]`

      YellowDog has synchronously received data from the client

      This event contains the following measurements:

      * `data`: The data received from the client

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:yellow_dog, :connection, :recv_error]`

      YellowDog encountered an error reading data from the client

      This event contains the following measurements:

      * `error`: A description of the error

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:yellow_dog, :connection, :send]`

      YellowDog has sent data to the client

      This event contains the following measurements:

      * `data`: The data sent to the client

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:yellow_dog, :connection, :send_error]`

      YellowDog encountered an error sending data to the client

      This event contains the following measurements:

      * `data`: The data that was being sent to the client
      * `error`: A description of the error

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:yellow_dog, :connection, :sendfile]`

      YellowDog has sent a file to the client

      This event contains the following measurements:

      * `filename`: The filename containing data sent to the client
      * `offset`: The offset (in bytes) within the file sending started from
      * `bytes_written`: The number of bytes written

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:yellow_dog, :connection, :sendfile_error]`

      YellowDog encountered an error sending a file to the client

      This event contains the following measurements:

      * `filename`: The filename containing data that was being sent to the client
      * `offset`: The offset (in bytes) within the file where sending started from
      * `length`: The number of bytes that were attempted to send
      * `error`: A description of the error

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:yellow_dog, :connection, :socket_shutdown]`

      YellowDog has shutdown the client connection

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units
      * `way`: The direction in which the socket was shut down

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
  """

  @enforce_keys [:span_name, :telemetry_span_context, :start_time, :start_metadata]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          span_name: span_name(),
          telemetry_span_context: reference(),
          start_time: integer(),
          start_metadata: metadata()
        }

  @type span_name :: :listener | :sender | :connection
  @type metadata :: :telemetry.event_metadata()

  @typedoc false
  @type measurements :: :telemetry.event_measurements()

  @typedoc false
  @type event_name ::
          :ready
          | :spawn_error
          | :econnaborted
          | :recv_error
          | :send_error
          | :sendfile_error
          | :socket_shutdown

  @typedoc false
  @type untimed_event_name ::
          :async_recv
          | :stop
          | :recv
          | :send
          | :sendfile
          | :waiting
          | :receiving

  @app_name :yellow_dog

  @doc false
  @spec start_span(span_name(), measurements(), metadata()) :: t()
  def start_span(span_name, measurements, metadata) do
    measurements = Map.put_new_lazy(measurements, :monotonic_time, &monotonic_time/0)
    telemetry_span_context = make_ref()
    metadata = Map.put(metadata, :telemetry_span_context, telemetry_span_context)
    _ = event([span_name, :start], measurements, metadata)

    %__MODULE__{
      span_name: span_name,
      telemetry_span_context: telemetry_span_context,
      start_time: measurements[:monotonic_time],
      start_metadata: metadata
    }
  end

  @doc false
  @spec start_child_span(t(), span_name(), measurements(), metadata()) :: t()
  def start_child_span(parent_span, span_name, measurements \\ %{}, metadata \\ %{}) do
    metadata =
      metadata
      |> Map.put(:parent_telemetry_span_context, parent_span.telemetry_span_context)
      |> Map.put(:handler, parent_span.start_metadata.handler)

    start_span(span_name, measurements, metadata)
  end

  @doc false
  @spec stop_span(t(), measurements(), metadata()) :: :ok
  def stop_span(span, measurements \\ %{}, metadata \\ %{}) do
    measurements = Map.put_new_lazy(measurements, :monotonic_time, &monotonic_time/0)

    measurements =
      Map.put(measurements, :duration, measurements[:monotonic_time] - span.start_time)

    metadata = Map.merge(span.start_metadata, metadata)

    untimed_span_event(span, :stop, measurements, metadata)
  end

  @doc false
  @spec span_event(t(), event_name(), measurements(), metadata()) :: :ok
  def span_event(span, name, measurements \\ %{}, metadata \\ %{}) do
    measurements = Map.put_new_lazy(measurements, :monotonic_time, &monotonic_time/0)
    untimed_span_event(span, name, measurements, metadata)
  end

  @doc false
  @spec untimed_span_event(t(), event_name() | untimed_event_name(), measurements(), metadata()) ::
          :ok
  def untimed_span_event(span, name, measurements \\ %{}, metadata \\ %{}) do
    metadata =
      metadata
      |> Map.put(:telemetry_span_context, span.telemetry_span_context)
      |> Map.put(:handler, span.start_metadata.handler)

    event([span.span_name, name], measurements, metadata)
  end

  @spec monotonic_time() :: integer
  defdelegate monotonic_time, to: System

  defp event(suffix, measurements, metadata) do
    :telemetry.execute([@app_name | suffix], measurements, metadata)
  end

  # ============================================================================
  # Logging API
  # ============================================================================

  @type log_level :: :debug | :info | :warning | :error
  @type log_metadata :: %{optional(atom()) => any()}
  @type span_id :: reference()
  @type app_name ::
          :yellow_dog
          | :yellow_dog_dns
          | :yellow_dog_dhcpv4
          | :yellow_dog_dhcpv6
          | :yellow_dog_mdns
          | :yellow_dog_console
          | :unknown

  @doc """
  Emit a debug level log event.

  ## Examples

      Telemetry.debug("Processing DNS query", %{domain: "example.com"})
      Telemetry.debug("Cache hit", %{key: "dns:example.com:A"})
  """
  @spec debug(String.t() | (-> String.t()), log_metadata()) :: :ok
  def debug(message, metadata \\ %{}) do
    log(:debug, message, metadata)
  end

  @doc """
  Emit an info level log event.

  ## Examples

      Telemetry.info("DNS server started", %{port: 53})
      Telemetry.info("Query resolved", %{domain: "example.com", ip: "93.184.216.34"})
  """
  @spec info(String.t() | (-> String.t()), log_metadata()) :: :ok
  def info(message, metadata \\ %{}) do
    log(:info, message, metadata)
  end

  @doc """
  Emit a warning level log event.

  ## Examples

      Telemetry.warning("Slow query detected", %{duration_ms: 150})
      Telemetry.warning("Rate limit approaching", %{current: 950, limit: 1000})
  """
  @spec warning(String.t() | (-> String.t()), log_metadata()) :: :ok
  def warning(message, metadata \\ %{}) do
    log(:warning, message, metadata)
  end

  @doc """
  Deprecated: Use `warning/2` instead.
  Emit a warning level log event using deprecated `:warn` level.
  """
  @spec warn(String.t() | (-> String.t()), log_metadata()) :: :ok
  def warn(message, metadata \\ %{}) do
    log(:warning, message, metadata)
  end

  @doc """
  Emit an error level log event.

  ## Examples

      Telemetry.error("Failed to resolve domain", %{domain: "bad.example", error: :nxdomain})
      Telemetry.error("Connection timeout", %{host: "8.8.8.8", timeout: 5000})
  """
  @spec error(String.t() | (-> String.t()), log_metadata()) :: :ok
  def error(message, metadata \\ %{}) do
    log(:error, message, metadata)
  end

  @doc false
  @spec log(log_level(), String.t() | (-> String.t()), log_metadata()) :: :ok
  def log(level, message, metadata) do
    # Get caller information
    caller = get_caller_info()

    # Detect app from caller module
    app = detect_app(caller.module)

    # Check if this log should be emitted based on filtering
    if should_emit_log?(level, app) do
      # Evaluate lazy message if needed
      message = if is_function(message, 0), do: message.(), else: message

      # Build full metadata
      full_metadata =
        metadata
        |> Map.put(:app, app)
        |> Map.put(:module, caller.module)
        |> Map.put(:function, caller.function)
        |> Map.put(:line, caller.line)
        |> maybe_add_span_context()

      # Emit telemetry event
      :telemetry.execute(
        [:yellow_dog, :log, level],
        %{monotonic_time: System.monotonic_time()},
        Map.merge(%{message: message}, full_metadata)
      )
    end

    :ok
  end

  # ============================================================================
  # Span Tracking API
  # ============================================================================

  @doc """
  Start a named span for duration tracking.

  Returns a span ID that should be passed to `end_span/2` when the operation completes.

  ## Examples

      span_id = Telemetry.start_span("dns.query.resolve", %{domain: "example.com"})
      # ... perform operation ...
      Telemetry.end_span(span_id, %{result: :success})
  """
  @spec start_span(String.t(), log_metadata()) :: span_id()
  def start_span(name, metadata \\ %{}) do
    caller = get_caller_info()
    app = detect_app(caller.module)

    span_id = make_ref()
    parent_span_id = get_current_span()

    span_data = %{
      id: span_id,
      name: name,
      parent_id: parent_span_id,
      start_time: System.monotonic_time(:microsecond),
      metadata: metadata,
      app: app,
      module: caller.module
    }

    # Store in process dictionary
    put_span(span_id, span_data)
    set_current_span(span_id)

    # Emit start event
    :telemetry.execute(
      [:yellow_dog, :span, :start],
      %{monotonic_time: span_data.start_time},
      %{
        span_id: span_id,
        parent_span_id: parent_span_id,
        name: name,
        app: app,
        module: caller.module
      }
      |> Map.merge(metadata)
    )

    span_id
  end

  @doc """
  End a span and emit duration metrics.

  ## Examples

      span_id = Telemetry.start_span("dhcp.lease.allocate")
      lease = allocate_lease()
      Telemetry.end_span(span_id, %{ip: lease.ip, status: :success})
  """
  @spec end_span(span_id(), log_metadata()) :: :ok
  def end_span(span_id, metadata \\ %{}) do
    case get_span(span_id) do
      nil ->
        warn("Attempted to end unknown span", %{span_id: inspect(span_id)})
        :ok

      span_data ->
        end_time = System.monotonic_time(:microsecond)
        duration_us = end_time - span_data.start_time
        duration_ms = duration_us / 1000

        # Reset current span to parent
        set_current_span(span_data.parent_id)

        # Clean up span data
        delete_span(span_id)

        # Check if we should emit based on threshold
        if should_emit_span?(duration_ms, span_data.app) do
          # Emit stop event
          :telemetry.execute(
            [:yellow_dog, :span, :stop],
            %{
              monotonic_time: end_time,
              duration_us: duration_us,
              duration_ms: duration_ms
            },
            %{
              span_id: span_id,
              parent_span_id: span_data.parent_id,
              name: span_data.name,
              app: span_data.app,
              module: span_data.module
            }
            |> Map.merge(span_data.metadata)
            |> Map.merge(metadata)
          )
        end

        :ok
    end
  end

  @doc """
  Convenience function to wrap a function in a span.

  The span is automatically ended when the function completes, even if it raises an error.

  ## Examples

      result = Telemetry.span("dns.zone.load", %{zone: "example.com"}, fn ->
        load_zone_records("example.com")
      end)
  """
  @spec span(String.t(), log_metadata(), (-> result)) :: result when result: any()
  def span(name, metadata \\ %{}, fun) do
    span_id = start_span(name, metadata)

    try do
      result = fun.()
      end_span(span_id, %{status: :success})
      result
    rescue
      error ->
        end_span(span_id, %{status: :failed, error: inspect(error)})
        reraise error, __STACKTRACE__
    catch
      kind, value ->
        end_span(span_id, %{status: :failed, kind: kind, value: inspect(value)})
        :erlang.raise(kind, value, __STACKTRACE__)
    end
  end

  # ============================================================================
  # Filtering API
  # ============================================================================

  @doc """
  Filter logs to only show specified apps.

  ## Examples

      Telemetry.filter_apps([:yellow_dog_dns, :yellow_dog_dhcpv4])
  """
  @spec filter_apps([app_name()]) :: :ok
  def filter_apps(apps) when is_list(apps) do
    Application.put_env(:yellow_dog_telemetry, :filter_apps, apps)
    :ok
  end

  @doc """
  Exclude logs from specified apps.

  ## Examples

      Telemetry.exclude_apps([:yellow_dog_console])
  """
  @spec exclude_apps([app_name()]) :: :ok
  def exclude_apps(apps) when is_list(apps) do
    Application.put_env(:yellow_dog_telemetry, :exclude_apps, apps)
    :ok
  end

  @doc """
  Set log level for a specific app.

  ## Examples

      Telemetry.set_app_level(:yellow_dog_dns, :debug)
  """
  @spec set_app_level(app_name(), log_level()) :: :ok
  def set_app_level(app, level) do
    current = Application.get_env(:yellow_dog_telemetry, :app_levels, %{})
    Application.put_env(:yellow_dog_telemetry, :app_levels, Map.put(current, app, level))
    :ok
  end

  @doc """
  Reset filtering to show all apps.

  ## Examples

      Telemetry.show_all_apps()
  """
  @spec show_all_apps() :: :ok
  def show_all_apps do
    Application.delete_env(:yellow_dog_telemetry, :filter_apps)
    Application.delete_env(:yellow_dog_telemetry, :exclude_apps)
    :ok
  end

  # ============================================================================
  # Private Helper Functions
  # ============================================================================

  # Detect app name from module namespace
  @spec detect_app(module()) :: app_name()
  defp detect_app(module) when is_atom(module) do
    # Convert module to string for pattern matching
    module_str = to_string(module)

    cond do
      String.starts_with?(module_str, "Elixir.YellowDog.Dns") -> :yellow_dog_dns
      String.starts_with?(module_str, "Elixir.YellowDog.Dhcpv4") -> :yellow_dog_dhcpv4
      String.starts_with?(module_str, "Elixir.YellowDog.Dhcpv6") -> :yellow_dog_dhcpv6
      String.starts_with?(module_str, "Elixir.YellowDog.Mdns") -> :yellow_dog_mdns
      String.starts_with?(module_str, "Elixir.YellowDog.Console") -> :yellow_dog_console
      String.starts_with?(module_str, "Elixir.YellowDog") -> :yellow_dog
      true -> :unknown
    end
  end

  defp detect_app(_), do: :unknown

  # Get caller information from the stacktrace
  defp get_caller_info do
    # Get a more accurate stacktrace using try/catch
    try do
      throw(:get_stacktrace)
    catch
      :throw, :get_stacktrace ->
        stacktrace = __STACKTRACE__

        # Skip frames from this module
        caller =
          stacktrace
          |> Enum.drop_while(fn
            {YellowDog.Telemetry, _, _, _} -> true
            _ -> false
          end)
          |> List.first()

        case caller do
          {module, function, arity, opts} when is_atom(module) ->
            %{
              module: module,
              function: "#{function}/#{arity}",
              line: Keyword.get(opts, :line, 0)
            }

          _ ->
            %{module: __MODULE__, function: "unknown/0", line: 0}
        end
    end
  end

  # Check if log should be emitted based on level and app filtering
  defp should_emit_log?(level, app) do
    config_level = get_config_level()
    app_level = get_app_level(app)
    effective_level = app_level || config_level

    level_meets_threshold?(level, effective_level) and app_allowed?(app)
  end

  # Check if span should be emitted based on duration and app
  defp should_emit_span?(duration_ms, app) do
    threshold = get_span_threshold(app)
    duration_ms >= threshold and app_allowed?(app)
  end

  # Check if app is allowed based on filter/exclude configuration
  defp app_allowed?(app) do
    filter_apps = Application.get_env(:yellow_dog_telemetry, :filter_apps)
    exclude_apps = Application.get_env(:yellow_dog_telemetry, :exclude_apps)

    cond do
      filter_apps != nil -> app in filter_apps
      exclude_apps != nil -> app not in exclude_apps
      true -> true
    end
  end

  # Get configured log level
  defp get_config_level do
    Application.get_env(:yellow_dog_telemetry, :level, :info)
  end

  # Get log level for specific app
  defp get_app_level(app) do
    app_levels = Application.get_env(:yellow_dog_telemetry, :app_levels, %{})
    Map.get(app_levels, app)
  end

  # Get span duration threshold for app
  defp get_span_threshold(app) do
    app_thresholds = Application.get_env(:yellow_dog_telemetry, :span_thresholds, %{})
    default_threshold = Application.get_env(:yellow_dog_telemetry, :span_threshold_ms, 0)
    Map.get(app_thresholds, app, default_threshold)
  end

  # Check if log level meets threshold
  @level_priority %{debug: 0, info: 1, warning: 2, error: 3}

  defp level_meets_threshold?(level, threshold) do
    Map.get(@level_priority, level, 0) >= Map.get(@level_priority, threshold, 1)
  end

  # Process dictionary helpers for span tracking
  @span_prefix :yellow_dog_telemetry_span
  @current_span_key :yellow_dog_telemetry_current_span

  defp put_span(span_id, data) do
    Process.put({@span_prefix, span_id}, data)
  end

  defp get_span(span_id) do
    Process.get({@span_prefix, span_id})
  end

  defp delete_span(span_id) do
    Process.delete({@span_prefix, span_id})
  end

  defp get_current_span do
    Process.get(@current_span_key)
  end

  defp set_current_span(span_id) do
    if span_id do
      Process.put(@current_span_key, span_id)
    else
      Process.delete(@current_span_key)
    end
  end

  # Add current span context to metadata if available
  defp maybe_add_span_context(metadata) do
    case get_current_span() do
      nil -> metadata
      span_id -> Map.put(metadata, :span_id, span_id)
    end
  end
end
