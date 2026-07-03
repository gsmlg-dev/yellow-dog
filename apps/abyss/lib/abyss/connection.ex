defmodule Abyss.Connection do
  @moduledoc """
  Connection management for creating and retrying handler processes.

  This module is responsible for:
  - Creating handler processes for incoming UDP packets
  - Managing connection limits and retry logic
  - Handling non-blocking retries when the connection supervisor is at capacity

  ## Connection Lifecycle

  1. Receive UDP packet and metadata from listener
  2. Create child specification for handler process
  3. Attempt to start handler via DynamicSupervisor
  4. Send connection data to handler process
  5. Handle retry logic if the connection limit is reached

  Handlers send responses through the shared listener socket; socket
  ownership stays with the listener at all times.

  ## Retry Strategy

  Uses non-blocking retries via `Task.start/1` with exponential backoff and
  jitter, so the listener process is never blocked while the connection
  supervisor is at capacity:
  - Configurable retry count (`max_connections_retry_count`)
  - Configurable base wait time (`max_connections_retry_wait`)
  - Emits `[:abyss, :connection, :limit_exceeded]` when retries are exhausted

  This module is primarily used internally by `Abyss.Listener`.
  """

  @doc """
  Start a handler process for an incoming UDP packet.

  Creates a handler process under the server's connection supervisor and
  sends it the received packet as a `{:new_connection, socket, recv_data}`
  message. Implements non-blocking retry logic when the connection
  supervisor is at capacity.

  ## Parameters
  - `sup_pid` - Server supervisor PID
  - `listener_pid` - Listener process PID
  - `listener_socket` - UDP socket from listener
  - `recv_data` - Received packet data `{ip, port, data}`
  - `server_config` - Server configuration
  - `connection_span` - Telemetry span for tracking

  ## Returns
  - `:ok` - Handler started (or retry scheduled)
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
    child_spec =
      {server_config.handler_module,
       {connection_span, server_config, listener_pid, listener_socket}}
      |> Supervisor.child_spec(shutdown: server_config.shutdown_timeout)

    connection_sup_pid = Abyss.Server.connection_sup_pid(sup_pid)

    do_start_with_backoff(
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
end
