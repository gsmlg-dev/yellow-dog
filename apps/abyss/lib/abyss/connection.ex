defmodule Abyss.Connection do
  @moduledoc """
  Connection management for creating and retrying handler processes.

  This module is responsible for:
  - Creating handler processes for incoming UDP packets
  - Managing connection limits and retry logic
  - Transferring socket ownership to handler processes
  - Handling non-blocking retries when connection supervisor is at capacity

  ## Connection Lifecycle

  1. Receive UDP packet and metadata from listener
  2. Create child specification for handler process
  3. Attempt to start handler via DynamicSupervisor
  4. Transfer socket ownership to handler
  5. Send connection data to handler process
  6. Handle retry logic if connection limit is reached

  ## Retry Strategy

  Uses non-blocking retry with `Process.send_after/3` to prevent
  listener process blocking during connection retries:
  - Configurable retry count (`max_connections_retry_count`)
  - Configurable retry wait time (`max_connections_retry_wait`)
  - Graceful degradation when connection supervisor is at capacity

  This module is primarily used internally by `Abyss.Listener`.
  """

  @doc """
  Start a handler process for an incoming UDP packet (passive mode).

  This function creates a handler process to process the received packet
  and transfers socket ownership to the handler. Implements non-blocking
  retry logic when the connection supervisor is at capacity.

  ## Parameters
  - `sup_pid` - Server supervisor PID
  - `listener_pid` - Listener process PID
  - `listener_socket` - UDP socket from listener
  - `recv_data` - Received packet data `{ip, port, data}`
  - `server_config` - Server configuration
  - `connection_span` - Telemetry span for tracking

  ## Returns
  - `:ok` - Handler started successfully
  - `{:error, :too_many_connections}` - Connection limit reached, retries exhausted
  - Other error tuples from DynamicSupervisor
  """
  @spec start(
          Supervisor.supervisor(),
          pid(),
          Abyss.Transport.socket(),
          Abyss.Transport.recv_data(),
          Abyss.ServerConfig.t(),
          Abyss.Telemetry.t()
        ) ::
          :ignore
          | :ok
          | {:ok, pid, info :: term}
          | {:error, :too_many_connections | {:already_started, pid} | term}
  def start(
        sup_pid,
        listener_pid,
        listener_socket,
        recv_data,
        %Abyss.ServerConfig{} = server_config,
        connection_span
      ) do
    # This is a multi-step process since we need to do a bit of work from within
    # the process which owns the socket (us, at this point).
    # {ip, port, _data} = recv_data

    # Start by defining the worker process which will eventually handle this socket
    child_spec =
      {server_config.handler_module,
       {connection_span, server_config, listener_pid, listener_socket}}
      |> Supervisor.child_spec(
        # id: {:connection, ip, port},
        shutdown: server_config.shutdown_timeout
      )

    connection_sup_pid = Abyss.Server.connection_sup_pid(sup_pid)

    # Then try to create it
    do_start(
      connection_sup_pid,
      child_spec,
      listener_pid,
      listener_socket,
      recv_data,
      server_config,
      connection_span,
      server_config.max_connections_retry_count
    )
  end

  defp do_start(
         sup_pid,
         child_spec,
         listener_pid,
         listener_socket,
         recv_data,
         server_config,
         connection_span,
         retries
       ) do
    do_start_with_backoff(
      sup_pid,
      child_spec,
      listener_pid,
      listener_socket,
      recv_data,
      server_config,
      connection_span,
      retries
    )
  end

  defp do_start_with_backoff(
         sup_pid,
         child_spec,
         listener_pid,
         listener_socket,
         recv_data,
         server_config,
         connection_span,
         retries
       ) do
    case DynamicSupervisor.start_child(sup_pid, child_spec) do
      {:ok, pid} ->
        Abyss.Transport.UDP.controlling_process(listener_socket, pid)
        send(pid, {:new_connection, listener_socket, recv_data})
        :ok

      {:error, :max_children} when retries > 0 ->
        # Exponential backoff with jitter
        base_delay = server_config.max_connections_retry_wait
        backoff_multiplier = :math.pow(1.5, server_config.max_connections_retry_count - retries)
        delay = round(base_delay * backoff_multiplier)
        # 25% jitter
        jitter = :rand.uniform(div(delay, 4))

        # Use Task for non-blocking retry to avoid blocking the listener
        Task.start(fn ->
          Process.sleep(delay + jitter)

          do_start_with_backoff(
            sup_pid,
            child_spec,
            listener_pid,
            listener_socket,
            recv_data,
            server_config,
            connection_span,
            retries - 1
          )
        end)

        {:retry, :connection_limit}

        :ok

      {:error, :max_children} ->
        # Log connection limit exceeded via telemetry
        :telemetry.execute(
          [:abyss, :connection, :limit_exceeded],
          %{retries_attempted: server_config.max_connections_retry_count - retries},
          %{listener_pid: listener_pid, socket: listener_socket}
        )

        {:error, :too_many_connections}

      other ->
        other
    end
  end

  @doc """
  Start a handler process for an incoming UDP packet (active mode).

  Similar to `start/6` but optimized for active socket mode where
  the listener socket is already set to active: true.

  ## Parameters
  - `sup_pid` - Server supervisor PID
  - `listener_pid` - Listener process PID
  - `listener_socket` - UDP socket from listener
  - `recv_data` - Received packet data `{ip, port, data}`
  - `server_config` - Server configuration
  - `connection_span` - Telemetry span for tracking

  ## Returns
  - `:ok` - Handler started successfully
  - `{:error, :too_many_connections}` - Connection limit reached, retries exhausted
  - Other error tuples from DynamicSupervisor
  """
  @spec start_active(
          Supervisor.supervisor(),
          pid(),
          Abyss.Transport.socket(),
          Abyss.Transport.recv_data(),
          Abyss.ServerConfig.t(),
          Abyss.Telemetry.t()
        ) ::
          :ignore
          | :ok
          | {:ok, pid, info :: term}
          | {:error, :too_many_connections | {:already_started, pid} | term}
  def start_active(
        sup_pid,
        listener_pid,
        listener_socket,
        recv_data,
        %Abyss.ServerConfig{} = server_config,
        connection_span
      ) do
    # This is a multi-step process since we need to do a bit of work from within
    # the process which owns the socket (us, at this point).
    # {ip, port, _data} = recv_data

    # Start by defining the worker process which will eventually handle this socket
    child_spec =
      {server_config.handler_module,
       {connection_span, server_config, listener_pid, listener_socket}}
      |> Supervisor.child_spec(
        # id: {:connection, ip, port},
        shutdown: server_config.shutdown_timeout
      )

    connection_sup_pid = Abyss.Server.connection_sup_pid(sup_pid)

    # Then try to create it
    do_start_active(
      connection_sup_pid,
      child_spec,
      listener_pid,
      listener_socket,
      recv_data,
      server_config,
      connection_span,
      server_config.max_connections_retry_count
    )
  end

  defp do_start_active(
         sup_pid,
         child_spec,
         listener_pid,
         listener_socket,
         recv_data,
         server_config,
         connection_span,
         retries
       ) do
    do_start_active_with_backoff(
      sup_pid,
      child_spec,
      listener_pid,
      listener_socket,
      recv_data,
      server_config,
      connection_span,
      retries
    )
  end

  defp do_start_active_with_backoff(
         sup_pid,
         child_spec,
         listener_pid,
         listener_socket,
         recv_data,
         server_config,
         connection_span,
         retries
       ) do
    case DynamicSupervisor.start_child(sup_pid, child_spec) do
      {:ok, pid} ->
        send(pid, {:new_connection, listener_socket, recv_data})
        :ok

      {:error, :max_children} when retries > 0 ->
        # Exponential backoff with jitter
        base_delay = server_config.max_connections_retry_wait
        backoff_multiplier = :math.pow(1.5, server_config.max_connections_retry_count - retries)
        delay = round(base_delay * backoff_multiplier)
        # 25% jitter
        jitter = :rand.uniform(div(delay, 4))

        # Use Task for non-blocking retry to avoid blocking the listener
        Task.start(fn ->
          Process.sleep(delay + jitter)

          do_start_active_with_backoff(
            sup_pid,
            child_spec,
            listener_pid,
            listener_socket,
            recv_data,
            server_config,
            connection_span,
            retries - 1
          )
        end)

        {:retry, :connection_limit}

        :ok

      {:error, :max_children} ->
        # Log connection limit exceeded via telemetry
        :telemetry.execute(
          [:abyss, :connection, :limit_exceeded],
          %{retries_attempted: server_config.max_connections_retry_count - retries},
          %{listener_pid: listener_pid, socket: listener_socket}
        )

        {:error, :too_many_connections}

      other ->
        other
    end
  end

  @doc """
  Handle a retry message for regular connection start.

  This function is called by the listener process when it receives a
  `{:retry_connection, args}` message from the scheduled retry.

  ## Parameters
  - `args` - List of arguments needed for retry:
    - `sup_pid` - Server supervisor PID
    - `child_spec` - Handler process child specification
    - `listener_pid` - Listener process PID
    - `listener_socket` - UDP socket
    - `recv_data` - Original packet data
    - `server_config` - Server configuration
    - `connection_span` - Telemetry span
    - `retries` - Remaining retry attempts

  ## Returns
  - Same as `start/6` - connection start result
  """
  @spec retry_start(list()) :: :ok | {:error, :too_many_connections | term}
  def retry_start([
        sup_pid,
        child_spec,
        listener_pid,
        listener_socket,
        recv_data,
        server_config,
        connection_span,
        retries
      ]) do
    do_start(
      sup_pid,
      child_spec,
      listener_pid,
      listener_socket,
      recv_data,
      server_config,
      connection_span,
      retries
    )
  end

  @doc """
  Handle a retry message for active connection start.

  This function is called by the listener process when it receives a
  `{:retry_active_connection, args}` message from the scheduled retry.

  ## Parameters
  - `args` - List of arguments needed for retry:
    - `sup_pid` - Server supervisor PID
    - `child_spec` - Handler process child specification
    - `listener_pid` - Listener process PID
    - `listener_socket` - UDP socket
    - `recv_data` - Original packet data
    - `server_config` - Server configuration
    - `connection_span` - Telemetry span
    - `retries` - Remaining retry attempts

  ## Returns
  - Same as `start_active/6` - connection start result
  """
  @spec retry_start_active(list()) :: :ok | {:error, :too_many_connections | term}
  def retry_start_active([
        sup_pid,
        child_spec,
        listener_pid,
        listener_socket,
        recv_data,
        server_config,
        connection_span,
        retries
      ]) do
    do_start_active(
      sup_pid,
      child_spec,
      listener_pid,
      listener_socket,
      recv_data,
      server_config,
      connection_span,
      retries
    )
  end
end
