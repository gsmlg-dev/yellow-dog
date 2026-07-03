defmodule Abyss.Handler do
  @moduledoc """
  `Abyss.Handler` defines the behaviour required of the application layer of an Abyss server.

  # Example

  A server that echoes back all data sent to it:

  ```elixir
  defmodule Echo do
    use Abyss.Handler

    @impl Abyss.Handler
    def handle_data({ip, port, data}, state) do
      Abyss.Transport.UDP.send(state.socket, ip, port, data)
      {:continue, state}
    end
  end
  ```

  Each incoming UDP packet spawns a handler process; the packet is delivered
  to `c:handle_data/2` as `{ip, port, data}`. Responses are sent through the
  shared listener socket available as `state.socket` (ownership of that
  socket stays with the listener).

  # Handler Lifecycle

  1. The listener receives a packet and starts your handler under the
     server's connection supervisor
  2. The handler process receives the packet and invokes `c:handle_data/2`
  3. The return value determines what happens next (see `c:handle_data/2`):
     continue waiting for messages/timeouts, close, or error out
  4. On termination one of `c:handle_close/1`, `c:handle_error/2`,
     `c:handle_shutdown/1`, or `c:handle_timeout/1` is invoked

  In broadcast mode (`Abyss.Transport.UDP.Broadcast`) the handler always
  terminates after processing its single packet, regardless of the
  `c:handle_data/2` return value.

  # State

  The handler state is a map seeded by Abyss with (at least) `:socket`, the
  shared listener socket; `:server_config`, the `Abyss.ServerConfig` (whose
  `handler_options` field carries the options you passed to
  `Abyss.start_link/1`); and `:read_timeout`. Any additional keys you add in
  `c:handle_data/2` are preserved across callbacks.

  # Asynchronous Messages

  The handler process is a regular `GenServer`, so you can send it messages
  and define `handle_info/2` clauses alongside the Abyss callbacks. You can
  pass options to the underlying `GenServer` via the `genserver_options` key
  of `Abyss.start_link/1`. Do not pass the `name` option; if you need to
  register handler processes, do so from within `c:handle_data/2`.

  # Custom handler modules

  Any module implementing `start_link/1` and accepting a
  `{:new_connection, socket, recv_data}` message may be used as a
  `handler_module` instead of `use Abyss.Handler`. Note that the
  `:connection` telemetry span events and metrics tracking are emitted by
  the generated implementation, so a custom module must emit its own.
  Handler processes should use a `:temporary` restart strategy so crashed
  handlers are not restarted.
  """

  @typedoc "The possible ways to indicate a timeout when returning values to Abyss"
  @type timeout_options :: timeout() | {:persistent, timeout()}

  @typedoc "The value returned by `c:handle_connection/2` and `c:handle_data/3`"
  @type handler_result ::
          {:continue, state :: term()}
          | {:continue, state :: term(), timeout_options()}
          | {:close, state :: term()}
          | {:error, term(), state :: term()}

  @doc """
  This callback is called whenever client data is received after `c:handle_connection/2` or `c:handle_data/3` have returned an
  `{:continue, state}` tuple. The data received is passed as the first argument, and handlers may choose to interact
  synchronously with the socket in this callback via calls to various `Abyss.Transport.UDP` functions.

  The value returned by this callback causes Abyss to proceed in one of several ways:

  * Returning `{:close, state}` will cause Abyss to close the socket & call the `c:handle_close/2` callback to
  allow final cleanup to be done.
  * Returning `{:continue, state}` will cause Abyss to switch the socket to an asynchronous mode. When the
  client subsequently sends data (or if there is already unread data waiting from the client), Abyss will call
  `c:handle_data/3` to allow this data to be processed.
  * Returning `{:continue, state, timeout}` is identical to the previous case with the
  addition of a timeout. If `timeout` milliseconds passes with no data being received or messages
  being sent to the process, the socket will be closed and `c:handle_timeout/2` will be called.
  Note that this timeout is not persistent; it applies only to the interval until the next message
  is received. In order to set a persistent timeout for all future messages (essentially
  overwriting the value of `read_timeout` that was set at server startup), a value of
  `{:persistent, timeout}` may be returned.
  * Returning `{:error, reason, state}` will cause Abyss to close the socket & call the `c:handle_error/3` callback to
  allow final cleanup to be done.
  """
  @callback handle_data(data :: Abyss.Transport.recv_data(), state :: term()) ::
              handler_result()

  @doc """
  This callback is called when the underlying socket is closed by the remote end; it should perform any cleanup required
  as it is the last callback called before the process backing this connection is terminated. The underlying socket
  has already been closed by the time this callback is called. The return value is ignored.

  This callback is not called if the connection is explicitly closed via `Abyss.Transport.UDP.close/1`, however it
  will be called in cases where `handle_connection/2` or `handle_data/3` return a `{:close, state}` tuple.
  """
  @callback handle_close(state :: term()) :: term()

  @doc """
  This callback is called when the underlying socket encounters an error; it should perform any cleanup required
  as it is the last callback called before the process backing this connection is terminated. The underlying socket
  has already been closed by the time this callback is called. The return value is ignored.

  In addition to socket level errors, this callback is also called in cases where `handle_connection/2` or `handle_data/3`
  return a `{:error, reason, state}` tuple, or when connection handshaking (typically TLS
  negotiation) fails.
  """
  @callback handle_error(reason :: any(), state :: term()) ::
              term()

  @doc """
  This callback is called when the server process itself is being shut down; it should perform any cleanup required
  as it is the last callback called before the process backing this connection is terminated. The underlying socket
  has NOT been closed by the time this callback is called. The return value is ignored.

  This callback is only called when the shutdown reason is `:normal`, and is subject to the same caveats described
  in `c:GenServer.terminate/2`.
  """
  @callback handle_shutdown(state :: term()) :: term()

  @doc """
  This callback is called when a handler process has gone more than `timeout` ms without receiving
  either remote data or a local message. The value used for `timeout` defaults to the
  `read_timeout` value specified at server startup, and may be overridden on a one-shot or
  persistent basis based on values returned from `c:handle_connection/2` or `c:handle_data/3`
  calls. Note that it is NOT called on explicit `Abyss.Transport.UDP.recv/3` calls as they have
  their own timeout semantics. The underlying socket has NOT been closed by the time this callback
  is called. The return value is ignored.
  """
  @callback handle_timeout(state :: term()) :: term()

  @optional_callbacks handle_data: 2,
                      handle_error: 2,
                      handle_close: 1,
                      handle_shutdown: 1,
                      handle_timeout: 1

  @spec __using__(any) :: Macro.t()
  defmacro __using__(_opts) do
    quote location: :keep do
      @behaviour Abyss.Handler

      use GenServer, restart: :temporary

      def start_link(args) do
        GenServer.start_link(__MODULE__, args)
      end

      unquote(genserver_impl())
      unquote(handler_impl())
    end
  end

  @doc false
  defmacro add_handle_info_fallback(_module) do
    quote do
      def handle_info({msg, _raw_ip, _port, _data}, _state) when msg in [:udp] do
        raise """
          The callback's `state` doesn't match the expected `{socket, state}` form.
          Please ensure that you are returning a `{socket, state}` tuple from any
          `GenServer.handle_*` callbacks you have implemented
        """
      end
    end
  end

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def genserver_impl do
    quote do
      @impl GenServer
      def init({connection_span, server_config, listener_pid, listener_socket}) do
        Process.flag(:trap_exit, true)

        # Start memory monitoring for long-running handlers
        Process.send_after(self(), :memory_check, server_config.handler_memory_check_interval)

        {:ok,
         %{
           connection_span: connection_span,
           server_config: server_config,
           listener: listener_pid,
           broadcast: server_config.broadcast,
           socket: listener_socket,
           read_timeout: server_config.read_timeout,
           # Track last 10 processing times for adaptive timeout
           processing_times: [],
           adaptive_timeout: server_config.read_timeout,
           memory_check_interval: server_config.handler_memory_check_interval
         }}
      end

      @impl GenServer
      def handle_info(
            {:new_connection, listener_socket, recv_data},
            %{broadcast: false} = state
          ) do
        Abyss.Telemetry.span_event(state.connection_span, :ready)
        {:noreply, state, {:continue, {:handle_data, recv_data}}}
      catch
        {:stop, _, _} = stop -> stop
      end

      def handle_info(
            {:new_connection, listener_socket, recv_data},
            %{broadcast: true} = state
          ) do
        {:noreply, state, {:continue, {:handle_broadcast_data, recv_data}}}
      catch
        {:stop, _, _} = stop -> stop
      end

      def handle_info(:timeout, state) do
        {:stop, {:shutdown, :timeout}, state}
      end

      def handle_info(:memory_check, %{memory_check_interval: interval} = state) do
        case :erlang.process_info(self(), :memory) do
          {:memory, memory_words} ->
            memory_mb = memory_words * :erlang.system_info(:wordsize) / (1024 * 1024)
            warning_threshold = state.server_config.handler_memory_warning_threshold
            hard_limit = state.server_config.handler_memory_hard_limit

            if memory_mb > warning_threshold do
              # Log memory warning via telemetry
              :telemetry.execute(
                [:abyss, :handler, :memory_warning],
                %{memory_mb: memory_mb},
                %{handler_pid: self(), threshold: warning_threshold}
              )

              # Trigger garbage collection
              :erlang.garbage_collect(self())

              # Check if memory is still high after GC
              case :erlang.process_info(self(), :memory) do
                {:memory, new_memory_words} ->
                  new_memory_mb =
                    new_memory_words * :erlang.system_info(:wordsize) / (1024 * 1024)

                  if new_memory_mb > hard_limit do
                    {:stop, {:shutdown, :memory_limit_exceeded}, state}
                  else
                    Process.send_after(self(), :memory_check, interval)
                    {:noreply, state}
                  end

                _ ->
                  Process.send_after(self(), :memory_check, interval)
                  {:noreply, state}
              end
            else
              Process.send_after(self(), :memory_check, interval)
              {:noreply, state}
            end

          _ ->
            Process.send_after(self(), :memory_check, interval)
            {:noreply, state}
        end
      end

      @before_compile {Abyss.Handler, :add_handle_info_fallback}

      # Use a continue pattern here so that we have committed the socket
      # to state in case the `c:handle_connection/2` callback raises an error.
      # This ensures that the `c:terminate/2` calls below are able to properly
      # close down the process
      @impl true
      def handle_continue({:handle_data, recv_data}, %{processing_times: times} = state) do
        start_time = System.monotonic_time()

        result = __MODULE__.handle_data(recv_data, state)
        processing_time = System.monotonic_time() - start_time

        # Keep last 10 processing times for adaptive timeout calculation
        new_times = [processing_time | Enum.take(times, 9)]

        # Calculate adaptive timeout based on processing history. The
        # bookkeeping is merged into the state returned by the callback so
        # that handler state changes are preserved.
        adaptive_timeout = Abyss.Handler.calculate_adaptive_timeout(state.read_timeout, new_times)

        Abyss.Handler.handle_continuation(result, %{
          processing_times: new_times,
          adaptive_timeout: adaptive_timeout
        })
      end

      def handle_continue({:handle_broadcast_data, recv_data}, state) do
        _reason = __MODULE__.handle_data(recv_data, state)
        {:stop, {:shutdown, :broadcast}, state}
      end

      @impl true
      def terminate({:shutdown, :broadcast}, %{connection_span: connection_span} = state) do
        # Track connection closure
        Abyss.Telemetry.track_connection_closed(__MODULE__)

        # Calculate response time if we have accept start time
        response_time = calculate_response_time(state)

        if response_time do
          Abyss.Telemetry.track_response_sent(response_time, %{handler: __MODULE__})
        end

        Abyss.Telemetry.stop_span(connection_span, %{}, %{reason: :broadcast})

        :ok
      end

      # Called by GenServer if we hit our read_timeout. Socket is still open
      def terminate({:shutdown, :timeout}, state) do
        out = __MODULE__.handle_timeout(state)
        terminate_cleanup(state, :timeout)
        out
      end

      # Called if we're being shutdown in an orderly manner. Socket is still open
      def terminate(:shutdown, state) do
        out = __MODULE__.handle_shutdown(state)
        terminate_cleanup(state, :shutdown)
        out
      end

      # Called if the socket encountered an error and we are configured to shutdown silently.
      # Socket is closed
      def terminate({:shutdown, {:silent_termination, reason}}, state) do
        out = __MODULE__.handle_error(reason, state)
        terminate_cleanup(state, reason)
        out
      end

      # Called if the remote end shut down the connection, or if the local end closed the
      # connection by returning a `{:close,...}` tuple (in which case the socket will be open)
      def terminate({:shutdown, reason}, state) do
        out = __MODULE__.handle_close(state)
        terminate_cleanup(state, reason)
        out
      end

      # This clause could happen if we do not have a socket defined in state (either because the
      # process crashed before setting it up, or because the user sent an invalid state)
      @impl GenServer
      def terminate(reason, state) do
        terminate_cleanup(state, reason)
        :ok
      end

      defp terminate_cleanup(%{connection_span: span} = state, reason) do
        Abyss.Telemetry.track_connection_closed(__MODULE__)

        response_time = calculate_response_time(state)

        if response_time do
          Abyss.Telemetry.track_response_sent(response_time, %{handler: __MODULE__})
        end

        Abyss.Telemetry.stop_span(span, %{}, %{reason: reason})
      end

      # Private helper functions

      defp calculate_response_time(%{
             connection_span: %{start_metadata: %{accept_start_time: start_time}}
           })
           when is_integer(start_time) do
        end_time = System.monotonic_time()
        System.convert_time_unit(end_time - start_time, :native, :millisecond)
      end

      defp calculate_response_time(_state), do: nil
    end
  end

  def handler_impl do
    quote do
      # @impl true
      # def handle_data(_data, state), do: {:close, state}

      @impl true
      def handle_close(_state), do: :ok

      @impl true
      def handle_error(_error, _state), do: :ok

      @impl true
      def handle_shutdown(_state), do: :ok

      @impl true
      def handle_timeout(_state), do: :ok

      defoverridable Abyss.Handler
    end
  end

  @doc false
  # Translates a `handler_result()` into a GenServer return value. The state
  # carried in the continuation tuple (as returned by the handler callback) is
  # preserved; `bookkeeping` holds internal updates (processing times, adaptive
  # timeout) that are merged on top of it.
  def handle_continuation(continuation, bookkeeping \\ %{}) do
    case continuation do
      {:continue, state} ->
        # Use adaptive timeout instead of fixed read_timeout
        state = merge_bookkeeping(state, bookkeeping)
        {:noreply, state, continue_timeout(state, bookkeeping)}

      {:continue, state, {:persistent, timeout}} ->
        state =
          state
          |> merge_bookkeeping(bookkeeping)
          |> persist_timeout(timeout)

        {:noreply, state, timeout}

      {:continue, state, timeout} ->
        # One-shot timeout for the next message only
        {:noreply, merge_bookkeeping(state, bookkeeping), timeout}

      {:close, state} ->
        {:stop, {:shutdown, :local_closed}, state}

      {:error, :timeout, state} ->
        {:stop, {:shutdown, :timeout}, state}

      {:error, reason, state} ->
        if silent_terminate_on_error?(state, bookkeeping) do
          {:stop, {:shutdown, {:silent_termination, reason}}, state}
        else
          {:stop, reason, state}
        end
    end
  end

  defp merge_bookkeeping(state, bookkeeping) when is_map(state),
    do: Map.merge(state, bookkeeping)

  defp merge_bookkeeping(state, _bookkeeping), do: state

  defp persist_timeout(state, timeout) when is_map(state) do
    state
    |> Map.put(:read_timeout, timeout)
    |> Map.put(:adaptive_timeout, timeout)
  end

  defp persist_timeout(state, _timeout), do: state

  defp continue_timeout(state, bookkeeping) do
    source = if is_map(state), do: state, else: bookkeeping
    Map.get(source, :adaptive_timeout) || Map.get(source, :read_timeout)
  end

  defp silent_terminate_on_error?(%{server_config: config}, _bookkeeping),
    do: config.silent_terminate_on_error

  defp silent_terminate_on_error?(_state, %{server_config: config}),
    do: config.silent_terminate_on_error

  defp silent_terminate_on_error?(_state, _bookkeeping), do: false

  @doc false
  # Add adaptive timeout calculation helper function
  # Returns timeout in milliseconds
  def calculate_adaptive_timeout(base_timeout, processing_times) do
    case processing_times do
      [] ->
        base_timeout

      times ->
        # Calculate average processing time in native time units
        avg_time_native = Enum.sum(times) / length(times)

        # Convert to milliseconds for calculation
        avg_time_ms = System.convert_time_unit(round(avg_time_native), :native, :millisecond)

        # Set timeout to 3x average processing time
        timeout_ms = round(avg_time_ms * 3)

        # Ensure timeout is between 50% and 200% of base timeout (all in milliseconds)
        min_timeout_ms = div(base_timeout, 2)
        max_timeout_ms = base_timeout * 2

        # Apply bounds and return timeout in milliseconds
        timeout_ms
        |> max(min_timeout_ms)
        |> min(max_timeout_ms)
    end
  end
end
