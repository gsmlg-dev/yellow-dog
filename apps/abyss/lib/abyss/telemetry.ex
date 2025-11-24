defmodule Abyss.Telemetry do
  @moduledoc """
  The following telemetry spans and metrics are emitted by abyss

  ## Telemetry Metrics

  In addition to span events, Abyss provides real-time metrics tracking through
  the `Abyss.Telemetry` module:

  ### Connection Metrics
  - `connections_active`: Number of currently active connections
  - `connections_total`: Total number of connections since server start
  - `accepts_total`: Total number of accepted connections
  - `responses_total`: Total number of responses sent
  - `accepts_per_second`: Current accepts per second rate
  - `responses_per_second`: Current responses per second rate

  ### Response Time Metrics
  - `[:abyss, :metrics, :response_time]`: Event emitted for each response with timing

  ### Using Metrics
  ```elixir
  # Get current metrics
  metrics = Abyss.Telemetry.get_metrics()
  # => %{
  #   connections_active: 15,
  #   connections_total: 1250,
  #   accepts_total: 1250,
  #   responses_total: 1198,
  #   accepts_per_second: 25,
  #   responses_per_second: 23
  # }

  # Reset all metrics
  Abyss.Telemetry.reset_metrics()

  # Listen for response time events
  :telemetry.attach_many(
    "response-time-listener",
    [[:abyss, :metrics, :response_time]],
    &handle_response_time/4,
    %{}
  )
  ```

  ## Telemetry Spans

  The following telemetry spans are emitted by abyss

  ## `[:abyss, :listener, *]`

  Represents a Abyss server listening to a port

  This span is started by the following event:

  * `[:abyss, :listener, :start]`

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

  * `[:abyss, :listener, :stop]`

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

  ## `[:abyss, :acceptor, *]`

  Represents a Abyss acceptor process listening for connections

  This span is started by the following event:

  * `[:abyss, :acceptor, :start]`

      Represents the start of the span

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span
      * `parent_telemetry_span_context`: The span context of the `:listener` which created this acceptor

  This span is ended by the following event:

  * `[:abyss, :acceptor, :stop]`

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

  * `[:abyss, :acceptor, :spawn_error]`

      Abyss was unable to spawn a process to handle a connection. This occurs when too
      many connections are in progress; you may want to look at increasing the `num_connections`
      configuration parameter

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:abyss, :acceptor, :econnaborted]`

      Abyss was unable to spawn a process to handle a connection since the remote end
      closed before we could accept it. This usually occurs when it takes too long for your server
      to start processing a connection; you may want to look at tuning OS-level TCP parameters or
      adding more server capacity.

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  ## `[:abyss, :connection, *]`

  Represents Abyss handling a specific client request

  This span is started by the following event:

  * `[:abyss, :connection, :start]`

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

  * `[:abyss, :connection, :stop]`

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

  * `[:abyss, :connection, :ready]`

      Abyss has completed setting up the client connection

      This event contains the following measurements:

      * `monotonic_time`: The time of this event, in `:native` units

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:abyss, :connection, :async_recv]`

      Abyss has asynchronously received data from the client

      This event contains the following measurements:

      * `data`: The data received from the client

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:abyss, :connection, :recv]`

      Abyss has synchronously received data from the client

      This event contains the following measurements:

      * `data`: The data received from the client

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:abyss, :connection, :recv_error]`

      Abyss encountered an error reading data from the client

      This event contains the following measurements:

      * `error`: A description of the error

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:abyss, :connection, :send]`

      Abyss has sent data to the client

      This event contains the following measurements:

      * `data`: The data sent to the client

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:abyss, :connection, :send_error]`

      Abyss encountered an error sending data to the client

      This event contains the following measurements:

      * `data`: The data that was being sent to the client
      * `error`: A description of the error

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:abyss, :connection, :sendfile]`

      Abyss has sent a file to the client

      This event contains the following measurements:

      * `filename`: The filename containing data sent to the client
      * `offset`: The offset (in bytes) within the file sending started from
      * `bytes_written`: The number of bytes written

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:abyss, :connection, :sendfile_error]`

      Abyss encountered an error sending a file to the client

      This event contains the following measurements:

      * `filename`: The filename containing data that was being sent to the client
      * `offset`: The offset (in bytes) within the file where sending started from
      * `length`: The number of bytes that were attempted to send
      * `error`: A description of the error

      This event contains the following metadata:

      * `telemetry_span_context`: A unique identifier for this span

  * `[:abyss, :connection, :socket_shutdown]`

      Abyss has shutdown the client connection

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

  @app_name :abyss

  # Default sampling rates for different span types
  # 10% sampling for connections
  @default_connection_sample_rate 0.1
  # 100% sampling for listeners (they're few)
  @default_listener_sample_rate 1.0

  # Metrics tracking
  @metrics_table :abyss_telemetry_metrics

  @doc """
  Initialize telemetry metrics tracking
  """
  @spec init_metrics() :: :ok
  def init_metrics do
    case :ets.whereis(@metrics_table) do
      :undefined ->
        # Use try/catch to handle race condition when multiple processes
        # attempt to create the table simultaneously
        try do
          table_id =
            :ets.new(@metrics_table, [
              :set,
              :public,
              :named_table,
              {:read_concurrency, true},
              {:write_concurrency, true}
            ])

          # Initialize metrics counters
          :ets.insert(table_id, {:connections_active, 0})
          :ets.insert(table_id, {:connections_total, 0})
          :ets.insert(table_id, {:accepts_total, 0})
          :ets.insert(table_id, {:responses_total, 0})

          :ets.insert(
            table_id,
            {:accept_rate_window_start, System.monotonic_time(:millisecond)}
          )

          :ets.insert(table_id, {:accepts_in_window, 0})

          :ets.insert(
            table_id,
            {:response_rate_window_start, System.monotonic_time(:millisecond)}
          )

          :ets.insert(table_id, {:responses_in_window, 0})
        catch
          :error, :badarg ->
            # Table was created by another process, that's fine
            :ok
        end

      _ ->
        :ok
    end

    :ok
  end

  # Helper function to get ETS table
  defp get_metrics_table do
    case :ets.whereis(@metrics_table) do
      :undefined ->
        init_metrics()
        :ets.whereis(@metrics_table)

      table_id ->
        table_id
    end
  end

  @doc """
  Track a new connection being accepted
  """
  @spec track_connection_accepted() :: :ok
  def track_connection_accepted do
    init_metrics()
    table = get_metrics_table()

    # Increment total accepts
    case :ets.lookup(table, :accepts_total) do
      [{:accepts_total, count}] ->
        :ets.insert(table, {:accepts_total, count + 1})

      [] ->
        :ets.insert(table, {:accepts_total, 1})
    end

    # Update accepts in current window
    update_accept_rate_window()

    # Increment active connections
    case :ets.lookup(table, :connections_active) do
      [{:connections_active, count}] ->
        :ets.insert(table, {:connections_active, count + 1})

      [] ->
        :ets.insert(table, {:connections_active, 1})
    end

    # Increment total connections
    case :ets.lookup(table, :connections_total) do
      [{:connections_total, count}] ->
        :ets.insert(table, {:connections_total, count + 1})

      [] ->
        :ets.insert(table, {:connections_total, 1})
    end

    :ok
  end

  @doc """
  Track a connection being closed
  """
  @spec track_connection_closed() :: :ok
  def track_connection_closed do
    init_metrics()
    table = get_metrics_table()

    # Decrement active connections
    case :ets.lookup(table, :connections_active) do
      [{:connections_active, count}] when count > 0 ->
        :ets.insert(table, {:connections_active, count - 1})

      _ ->
        :ok
    end

    :ok
  end

  @doc """
  Track a response being sent
  """
  @spec track_response_sent(response_time :: integer()) :: :ok
  def track_response_sent(response_time) when is_integer(response_time) do
    init_metrics()
    table = get_metrics_table()

    # Increment total responses
    case :ets.lookup(table, :responses_total) do
      [{:responses_total, count}] ->
        :ets.insert(table, {:responses_total, count + 1})

      [] ->
        :ets.insert(table, {:responses_total, 1})
    end

    # Update responses in current window
    update_response_rate_window()

    # Emit response time event
    :telemetry.execute(
      [:abyss, :metrics, :response_time],
      %{response_time: response_time},
      %{}
    )

    :ok
  end

  @doc """
  Get current telemetry metrics
  """
  @spec get_metrics() :: map()
  def get_metrics do
    init_metrics()
    table = get_metrics_table()

    connections_active =
      case :ets.lookup(table, :connections_active) do
        [{:connections_active, count}] -> count
        [] -> 0
      end

    connections_total =
      case :ets.lookup(table, :connections_total) do
        [{:connections_total, count}] -> count
        [] -> 0
      end

    accepts_total =
      case :ets.lookup(table, :accepts_total) do
        [{:accepts_total, count}] -> count
        [] -> 0
      end

    responses_total =
      case :ets.lookup(table, :responses_total) do
        [{:responses_total, count}] -> count
        [] -> 0
      end

    accepts_per_sec = get_accept_rate()
    responses_per_sec = get_response_rate()

    %{
      connections_active: connections_active,
      connections_total: connections_total,
      accepts_total: accepts_total,
      responses_total: responses_total,
      accepts_per_second: accepts_per_sec,
      responses_per_second: responses_per_sec
    }
  end

  @doc """
  Reset telemetry metrics
  """
  @spec reset_metrics() :: :ok
  def reset_metrics do
    case :ets.whereis(@metrics_table) do
      :undefined ->
        init_metrics()

      _table_id ->
        :ets.delete_all_objects(@metrics_table)
        init_metrics()
    end

    :ok
  end

  # Private functions

  defp update_accept_rate_window do
    table = get_metrics_table()
    current_time = System.monotonic_time(:millisecond)

    # Use try/rescue for atomic increment
    try do
      # Atomically increment counter
      :ets.update_counter(table, :accepts_in_window, {2, 1})

      # Check if window needs reset (non-atomic read is acceptable here)
      case :ets.lookup(table, :accept_rate_window_start) do
        [{:accept_rate_window_start, window_start}] ->
          if current_time - window_start >= 1000 do
            # Reset window - these operations are eventually consistent
            :ets.insert(table, {:accept_rate_window_start, current_time})
            :ets.insert(table, {:accepts_in_window, 1})
          end

        [] ->
          # Initialize window
          :ets.insert(table, {:accept_rate_window_start, current_time})
          :ets.insert(table, {:accepts_in_window, 1})
      end
    rescue
      ArgumentError ->
        # Counter doesn't exist, initialize it
        :ets.insert(table, {:accept_rate_window_start, current_time})
        :ets.insert(table, {:accepts_in_window, 1})
    end
  end

  defp update_response_rate_window do
    table = get_metrics_table()
    current_time = System.monotonic_time(:millisecond)

    # Use try/rescue for atomic increment
    try do
      # Atomically increment counter
      :ets.update_counter(table, :responses_in_window, {2, 1})

      # Check if window needs reset (non-atomic read is acceptable here)
      case :ets.lookup(table, :response_rate_window_start) do
        [{:response_rate_window_start, window_start}] ->
          if current_time - window_start >= 1000 do
            # Reset window - these operations are eventually consistent
            :ets.insert(table, {:response_rate_window_start, current_time})
            :ets.insert(table, {:responses_in_window, 1})
          end

        [] ->
          # Initialize window
          :ets.insert(table, {:response_rate_window_start, current_time})
          :ets.insert(table, {:responses_in_window, 1})
      end
    rescue
      ArgumentError ->
        # Counter doesn't exist, initialize it
        :ets.insert(table, {:response_rate_window_start, current_time})
        :ets.insert(table, {:responses_in_window, 1})
    end
  end

  defp get_accept_rate do
    table = get_metrics_table()
    current_time = System.monotonic_time(:millisecond)

    case :ets.lookup(table, :accept_rate_window_start) do
      [{:accept_rate_window_start, window_start}] ->
        time_diff = current_time - window_start

        if time_diff > 0 do
          case :ets.lookup(table, :accepts_in_window) do
            [{:accepts_in_window, count}] ->
              # Calculate rate per second
              round(count * 1000 / time_diff)

            [] ->
              0
          end
        else
          0
        end

      [] ->
        0
    end
  end

  defp get_response_rate do
    table = get_metrics_table()
    current_time = System.monotonic_time(:millisecond)

    case :ets.lookup(table, :response_rate_window_start) do
      [{:response_rate_window_start, window_start}] ->
        time_diff = current_time - window_start

        if time_diff > 0 do
          case :ets.lookup(table, :responses_in_window) do
            [{:responses_in_window, count}] ->
              # Calculate rate per second
              round(count * 1000 / time_diff)

            [] ->
              0
          end
        else
          0
        end

      [] ->
        0
    end
  end

  @doc false
  @spec start_span(span_name(), measurements(), metadata()) :: t()
  def start_span(span_name, measurements, metadata) do
    start_span_with_sampling(span_name, measurements, metadata)
  end

  @doc false
  @spec start_span_with_sampling(span_name(), measurements(), metadata(), keyword()) :: t()
  def start_span_with_sampling(span_name, measurements, metadata, opts \\ []) do
    sample_rate = get_sample_rate(span_name, opts)

    if should_sample?(sample_rate) do
      measurements = Map.put_new_lazy(measurements, :monotonic_time, &monotonic_time/0)
      telemetry_span_context = make_ref()
      metadata = Map.put(metadata, :telemetry_span_context, telemetry_span_context)
      metadata = Map.put(metadata, :sampled, true)
      _ = event([span_name, :start], measurements, metadata)

      %__MODULE__{
        span_name: span_name,
        telemetry_span_context: telemetry_span_context,
        start_time: measurements[:monotonic_time],
        start_metadata: metadata
      }
    else
      # Create unsampled span
      measurements = Map.put_new_lazy(measurements, :monotonic_time, &monotonic_time/0)
      telemetry_span_context = make_ref()
      metadata = Map.put(metadata, :telemetry_span_context, telemetry_span_context)
      metadata = Map.put(metadata, :sampled, false)

      %__MODULE__{
        span_name: span_name,
        telemetry_span_context: telemetry_span_context,
        start_time: measurements[:monotonic_time],
        start_metadata: metadata
      }
    end
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
  @spec start_child_span_with_sampling(t(), span_name(), measurements(), metadata(), keyword()) ::
          t()
  def start_child_span_with_sampling(
        parent_span,
        span_name,
        measurements \\ %{},
        metadata \\ %{},
        opts \\ []
      ) do
    metadata =
      metadata
      |> Map.put(:parent_telemetry_span_context, parent_span.telemetry_span_context)
      |> Map.put(:handler, parent_span.start_metadata.handler)

    start_span_with_sampling(span_name, measurements, metadata, opts)
  end

  # Private helper functions

  defp get_sample_rate(:connection, opts) do
    Keyword.get(opts, :sample_rate, @default_connection_sample_rate)
  end

  defp get_sample_rate(:listener, _opts) do
    @default_listener_sample_rate
  end

  defp get_sample_rate(_span_name, opts) do
    # Default to no sampling for unknown spans
    Keyword.get(opts, :sample_rate, 1.0)
  end

  defp should_sample?(sample_rate) when sample_rate >= 1.0, do: true
  defp should_sample?(sample_rate) when sample_rate <= 0.0, do: false
  defp should_sample?(sample_rate), do: :rand.uniform() <= sample_rate

  @doc false
  @spec stop_span(t(), measurements(), metadata()) :: :ok
  def stop_span(span, measurements \\ %{}, metadata \\ %{}) do
    # Only emit events if this span was sampled
    if span.start_metadata[:sampled] != false do
      measurements = Map.put_new_lazy(measurements, :monotonic_time, &monotonic_time/0)

      measurements =
        Map.put(measurements, :duration, measurements[:monotonic_time] - span.start_time)

      metadata = Map.merge(span.start_metadata, metadata)

      untimed_span_event(span, :stop, measurements, metadata)
    else
      :ok
    end
  end

  @doc false
  @spec span_event(t(), event_name(), measurements(), metadata()) :: :ok
  def span_event(span, name, measurements \\ %{}, metadata \\ %{}) do
    # Only emit events if this span was sampled
    if span.start_metadata[:sampled] != false do
      measurements = Map.put_new_lazy(measurements, :monotonic_time, &monotonic_time/0)
      untimed_span_event(span, name, measurements, metadata)
    else
      :ok
    end
  end

  @doc false
  @spec untimed_span_event(t(), event_name() | untimed_event_name(), measurements(), metadata()) ::
          :ok
  def untimed_span_event(span, name, measurements \\ %{}, metadata \\ %{}) do
    # Only emit events if this span was sampled
    if span.start_metadata[:sampled] != false do
      metadata =
        metadata
        |> Map.put(:telemetry_span_context, span.telemetry_span_context)
        |> Map.put_new(:handler, span.start_metadata[:handler] || :unknown)

      event([span.span_name, name], measurements, metadata)
    else
      :ok
    end
  end

  @spec monotonic_time() :: integer
  defdelegate monotonic_time, to: System

  defp event(suffix, measurements, metadata) do
    :telemetry.execute([@app_name | suffix], measurements, metadata)
  end
end
