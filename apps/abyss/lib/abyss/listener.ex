defmodule Abyss.Listener do
  @moduledoc """
  UDP listener process that accepts incoming packets and creates handler processes.

  Each listener process is responsible for:
  - Binding to a UDP port and receiving packets
  - Applying packet size validation
  - Creating handler processes for valid packets
  - Managing connection lifecycle and telemetry events

  ## Modes of Operation

  - **Regular Mode**: Passively receives packets and creates handler processes
  - **Broadcast Mode**: Actively receives packets with `active: true`

  ## Security Features

  - **Packet Size Validation**: Rejects oversized packets
  - **Telemetry Events**: Comprehensive monitoring and logging

  ## Process Flow

  1. Initialize UDP socket with transport options
  2. Start receiving packets (passive or active mode)
  3. Apply security checks (packet size)
  4. Create handler process via `Abyss.Connection`
  5. Emit telemetry events for monitoring

  This module is primarily used internally by `Abyss.ListenerPool`.

  ## Critical Implementation Note - DO NOT CHANGE

  The UDP recv pattern MUST use `:infinity` timeout:

      transport.recv(listener_socket, 0, :infinity)

  **Why this is correct:**
  - UDP is connectionless - there is no "connection" to maintain
  - The recv call blocks efficiently at the OS level waiting for packets
  - Using finite timeouts (e.g., 100ms) causes busy-polling which wastes CPU
  - The BEAM scheduler handles this blocking call properly in a dedicated thread
  - While blocked in recv, GenServer calls will timeout - use `listener_info_cached/1` instead

  **Do NOT "optimize" by:**
  - Adding timeout with polling loops (wastes CPU, adds latency)
  - Using `active: true` for unicast mode (loses backpressure control)
  - Adding {:error, :timeout} handling (unnecessary for UDP)

  This pattern has been validated for high-performance UDP servers.
  """

  use GenServer, restart: :transient

  # ETS table name for caching listener info (accessible while listener is blocked in recv)
  @listener_info_table :abyss_listener_info

  @typedoc """
  Internal state of a listener process.
  """
  @type state :: %{
          is_active: boolean(),
          is_listening: boolean(),
          server_pid: pid(),
          server_config: Abyss.ServerConfig.t(),
          listener_id: binary(),
          listener_socket: Abyss.Transport.socket(),
          listener_span: Abyss.Telemetry.t(),
          local_info: Abyss.Transport.socket_info(),
          transport: module()
        }

  @doc """
  Start a listener process.

  ## Parameters
  - `id` - Unique identifier for this listener
  - `server_pid` - PID of the server supervisor
  - `config` - Server configuration

  ## Returns
  - Standard GenServer start result
  """
  @spec start_link({id :: binary(), server_pid :: pid(), Abyss.ServerConfig.t()}) ::
          GenServer.on_start()
  def start_link({id, server_pid, config}),
    do: GenServer.start_link(__MODULE__, {id, server_pid, config})

  @doc """
  Stop a listener process gracefully.

  Closes the listener socket first to unblock any pending recv(:infinity)
  call, then stops the GenServer. Without closing the socket first,
  GenServer.stop/1 would time out because the process cannot handle
  system messages while blocked in recv.

  ## Parameters
  - `server` - The listener process PID or name
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    # Close the socket first to unblock recv(:infinity), then stop the
    # GenServer. A unicast listener blocked in recv stops itself with
    # :normal once the socket closes; a broadcast (active mode) listener
    # is never blocked and is stopped by GenServer.stop/3 directly.
    pid = if is_pid(server), do: server, else: Process.whereis(server)

    if pid && Process.alive?(pid) do
      ensure_info_table_exists()

      case :ets.lookup(@listener_info_table, pid) do
        [{^pid, _local_info, socket}] -> :gen_udp.close(socket)
        _ -> :ok
      end

      try do
        GenServer.stop(pid, :normal, 5000)
      catch
        # Already stopped after the socket close (:noproc), stopped with a
        # different reason, or unresponsive within the timeout.
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  @doc """
  Get information about the listener's local socket endpoint.

  ## Parameters
  - `server` - The listener process PID or name

  ## Returns
  - `{ip_address, port}` tuple with local endpoint information
  """
  @spec listener_info(GenServer.server()) :: Abyss.Transport.socket_info()
  def listener_info(server), do: GenServer.call(server, :listener_info)

  @doc """
  Get listener info from the ETS cache without making a GenServer call.

  This is useful when the listener may be blocked in recv(:infinity) and
  unable to respond to GenServer calls. The info is cached during init.

  ## Parameters
  - `listener_pid` - The listener process PID

  ## Returns
  - `{:ok, {ip_address, port}}` if found
  - `:error` if not found in cache
  """
  @spec listener_info_cached(pid()) :: {:ok, Abyss.Transport.socket_info()} | :error
  def listener_info_cached(listener_pid) when is_pid(listener_pid) do
    ensure_info_table_exists()

    case :ets.lookup(@listener_info_table, listener_pid) do
      [{^listener_pid, local_info, _socket}] -> {:ok, local_info}
      [{^listener_pid, local_info}] -> {:ok, local_info}
      [] -> :error
    end
  end

  @doc false
  # Ensure the ETS table exists. Creation is routed through Abyss.TableOwner
  # so the table is owned by a long-lived process regardless of which process
  # first needs it.
  @spec ensure_info_table_exists() :: :ok
  def ensure_info_table_exists do
    Abyss.TableOwner.ensure_table(@listener_info_table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true
    ])
  end

  # Store listener info and socket in ETS cache
  defp cache_listener_info(listener_pid, local_info, socket) do
    ensure_info_table_exists()
    :ets.insert(@listener_info_table, {listener_pid, local_info, socket})
  end

  # Remove listener info from ETS cache
  defp uncache_listener_info(listener_pid) do
    case :ets.whereis(@listener_info_table) do
      :undefined -> :ok
      _ref -> :ets.delete(@listener_info_table, listener_pid)
    end
  end

  @doc """
  Get the listener's socket and telemetry span.

  ## Parameters
  - `server` - The listener process PID or name

  ## Returns
  - `{socket, telemetry_span}` tuple
  """
  @spec socket_info(GenServer.server()) ::
          {Abyss.Transport.listener_socket(), Abyss.Telemetry.t()}
  def socket_info(server), do: GenServer.call(server, :socket_info)

  @impl GenServer
  @spec init({listener_id :: neg_integer(), server_pid :: pid(), Abyss.ServerConfig.t()}) ::
          {:ok, state} | {:stop, term}
  def init({listener_id, server_pid, server_config}) do
    broadcast = server_config.broadcast

    transport_options =
      if broadcast do
        server_config.transport_options
        |> Keyword.put(:active, true)
        |> Keyword.put(:broadcast, true)
        |> Keyword.put(:recbuf, server_config.udp_buffer_size)
        |> Keyword.put(:sndbuf, server_config.udp_buffer_size)
      else
        server_config.transport_options
        |> Keyword.put(:active, false)
        |> Keyword.put(:broadcast, false)
        |> Keyword.put(:recbuf, server_config.udp_buffer_size)
        |> Keyword.put(:sndbuf, server_config.udp_buffer_size)
      end

    transport = server_config.transport_module

    with {:ok, listener_socket} <-
           transport.listen(
             server_config.port,
             transport_options
           ),
         {:ok, {ip, port}} <-
           :inet.sockname(listener_socket) do
      active =
        case transport.getopts(listener_socket, [:active]) do
          {:ok, [active: true]} -> true
          _ -> false
        end

      span_metadata = %{
        listener_id: listener_id,
        listener_socket: listener_socket,
        handler: server_config.handler_module,
        local_address: ip,
        local_port: port,
        broadcast: broadcast,
        transport_options: transport_options
      }

      listener_span = Abyss.Telemetry.start_span(:listener, %{}, span_metadata)

      state = %{
        broadcast: broadcast,
        is_active: active,
        is_listening: false,
        server_config: server_config,
        server_pid: server_pid,
        listener_id: listener_id,
        listener_socket: listener_socket,
        listener_span: listener_span,
        local_info: {ip, port},
        transport: transport
      }

      # Cache listener info and socket in ETS for queries while blocked in recv.
      # The socket is stored so stop/1 can close it to unblock recv(:infinity).
      cache_listener_info(self(), {ip, port}, listener_socket)

      # Start listening immediately for non-broadcast mode
      unless broadcast do
        Process.send_after(self(), :start_listening, 0)
      end

      {:ok, state}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_info(
        :start_listening,
        %{listener_socket: listener_socket, transport: transport} = state
      ) do
    if state.is_listening do
      {:noreply, state}
    else
      case transport.getopts(listener_socket, [:active]) do
        {:ok, [{:active, false}]} ->
          Abyss.Telemetry.span_event(state.listener_span, :ready, %{}, %{
            listener_id: state.listener_id,
            listener_socket: state.listener_socket,
            local_info: state.local_info
          })

          Process.send_after(self(), :do_recv, 0)
          {:noreply, state |> Map.put(:is_listening, true)}

        {:ok, [active: true]} ->
          {:noreply, state}

        {:error, reason} ->
          # Socket was closed externally (e.g., stop/1 called before :start_listening ran).
          # :einval = closed socket; treat as normal shutdown to avoid propagating to linked processes.
          {:stop, if(reason in [:einval, :closed], do: :normal, else: reason), state}
      end
    end
  end

  @impl true
  def handle_info({:udp, socket, ip, port, data}, %{listener_span: listener_span} = state) do
    # Check packet size
    if byte_size(data) > state.server_config.max_packet_size do
      Abyss.Telemetry.span_event(listener_span, :packet_too_large, %{
        remote_address: ip,
        remote_port: port,
        packet_size: byte_size(data),
        max_size: state.server_config.max_packet_size
      })

      {:noreply, state}
    else
      start_time = Abyss.Telemetry.monotonic_time()

      # Track connection acceptance
      Abyss.Telemetry.track_connection_accepted()

      connection_span =
        Abyss.Telemetry.start_child_span_with_sampling(
          listener_span,
          :connection,
          %{monotonic_time: start_time},
          %{remote_address: ip, remote_port: port, accept_start_time: start_time},
          sample_rate: state.server_config.connection_telemetry_sample_rate
        )

      Abyss.Connection.start_active(
        state.server_pid,
        self(),
        socket,
        {ip, port, data},
        state.server_config,
        connection_span
      )

      {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        :do_recv,
        %{listener_span: listener_span, listener_socket: listener_socket, transport: transport} =
          state
      ) do
    Abyss.Telemetry.untimed_span_event(state.listener_span, :waiting, %{}, %{
      listener_id: state.listener_id,
      listener_socket: state.listener_socket,
      local_info: state.local_info
    })

    # CRITICAL: Use :infinity timeout - DO NOT CHANGE to finite timeout!
    # See moduledoc "Critical Implementation Note" for explanation.
    # UDP recv blocks efficiently at OS level; finite timeouts cause CPU-wasting busy loops.
    case transport.recv(listener_socket, 0, :infinity) do
      {:ok, {ip, port, data}} ->
        Abyss.Telemetry.untimed_span_event(state.listener_span, :receiving, %{}, %{
          listener_id: state.listener_id,
          listener_socket: state.listener_socket,
          local_info: state.local_info
        })

        # Check packet size
        if byte_size(data) > state.server_config.max_packet_size do
          Abyss.Telemetry.span_event(listener_span, :packet_too_large, %{
            remote_address: ip,
            remote_port: port,
            packet_size: byte_size(data),
            max_size: state.server_config.max_packet_size
          })

          Process.send_after(self(), :do_recv, 0)
          {:noreply, state}
        else
          start_time = Abyss.Telemetry.monotonic_time()

          # Track connection acceptance
          Abyss.Telemetry.track_connection_accepted()

          connection_span =
            Abyss.Telemetry.start_child_span_with_sampling(
              listener_span,
              :connection,
              %{monotonic_time: start_time},
              %{remote_address: ip, remote_port: port, accept_start_time: start_time},
              sample_rate: state.server_config.connection_telemetry_sample_rate
            )

          Abyss.Connection.start(
            state.server_pid,
            self(),
            listener_socket,
            {ip, port, data},
            state.server_config,
            connection_span
          )

          Process.send_after(self(), :do_recv, 0)

          {:noreply, state}
        end

      {:ok, {ip, port, _anc_data, data}} ->
        Abyss.Telemetry.untimed_span_event(state.listener_span, :receiving, %{}, %{
          listener_id: state.listener_id,
          listener_socket: state.listener_socket,
          local_info: state.local_info
        })

        # Check packet size
        if byte_size(data) > state.server_config.max_packet_size do
          Abyss.Telemetry.span_event(listener_span, :packet_too_large, %{
            remote_address: ip,
            remote_port: port,
            packet_size: byte_size(data),
            max_size: state.server_config.max_packet_size
          })

          Process.send_after(self(), :do_recv, 0)
          {:noreply, state}
        else
          start_time = Abyss.Telemetry.monotonic_time()

          # Track connection acceptance
          Abyss.Telemetry.track_connection_accepted()

          connection_span =
            Abyss.Telemetry.start_child_span_with_sampling(
              listener_span,
              :connection,
              %{monotonic_time: start_time},
              %{remote_address: ip, remote_port: port, accept_start_time: start_time},
              sample_rate: state.server_config.connection_telemetry_sample_rate
            )

          Abyss.Connection.start(
            state.server_pid,
            self(),
            listener_socket,
            {ip, port, data},
            state.server_config,
            connection_span
          )

          Process.send_after(self(), :do_recv, 0)

          {:noreply, state}
        end

      {:error, reason} ->
        Abyss.Telemetry.span_event(listener_span, :recv_error, %{
          reason: reason,
          listener_socket: listener_socket
        })

        # :einval/:closed = socket closed by stop/1; treat as normal shutdown.
        {:stop, if(reason in [:einval, :closed], do: :normal, else: reason), state}
    end
  end

  @impl true
  def handle_info({:retry_connection, retry_args}, state) do
    Abyss.Connection.retry_start(retry_args)
    {:noreply, state}
  end

  @impl true
  def handle_info({:retry_active_connection, retry_args}, state) do
    Abyss.Connection.retry_start_active(retry_args)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_continue(
        :listening,
        %{listener_span: listener_span, listener_socket: listener_socket, transport: transport} =
          state
      ) do
    Abyss.Telemetry.untimed_span_event(state.listener_span, :waiting, %{}, %{
      listener_id: state.listener_id,
      listener_socket: state.listener_socket,
      local_info: state.local_info
    })

    # CRITICAL: Use :infinity timeout - DO NOT CHANGE to finite timeout!
    # See moduledoc "Critical Implementation Note" for explanation.
    # UDP recv blocks efficiently at OS level; finite timeouts cause CPU-wasting busy loops.
    case transport.recv(listener_socket, 0, :infinity) do
      {:ok, recv_data} ->
        {ip, port, anc_data} =
          case recv_data do
            {ip, port, anc_data, _data} ->
              {ip, port, anc_data}

            {ip, port, _data} ->
              {ip, port, nil}
          end

        Abyss.Telemetry.untimed_span_event(state.listener_span, :receiving, %{}, %{
          listener_id: state.listener_id,
          listener_socket: state.listener_socket,
          local_info: state.local_info
        })

        start_time = Abyss.Telemetry.monotonic_time()

        connection_span =
          Abyss.Telemetry.start_child_span(
            listener_span,
            :connection,
            %{monotonic_time: start_time},
            %{remote_address: ip, remote_port: port, anc_data: anc_data}
          )

        Abyss.Connection.start(
          state.server_pid,
          self(),
          listener_socket,
          recv_data,
          state.server_config,
          connection_span
        )

        {:noreply, state, {:continue, :listening}}

      {:error, reason} ->
        Abyss.Telemetry.span_event(listener_span, :recv_error, %{
          reason: reason,
          listener_socket: listener_socket
        })

        # :einval/:closed = socket closed by stop/1; treat as normal shutdown.
        {:stop, if(reason in [:einval, :closed], do: :normal, else: reason), state}
    end
  end

  @impl GenServer
  @spec handle_call(:listener_info | :socket_info, any, state) ::
          {:reply,
           Abyss.Transport.socket_info()
           | {Abyss.Transport.listener_socket(), Abyss.Telemetry.t()}, state}
  def handle_call(:listener_info, _from, state) do
    {:reply, state.local_info, state}
  end

  @impl true
  def handle_call(:socket_info, _from, state),
    do: {:reply, {state.listener_socket, state.listener_span}, state}

  @impl GenServer
  @spec terminate(reason, state) :: :ok
        when reason: :normal | :shutdown | {:shutdown, term} | term
  def terminate(_reason, state) do
    # Clean up cached listener info
    uncache_listener_info(self())
    state.transport.close(state.listener_socket)
    Abyss.Telemetry.stop_span(state.listener_span)
  end
end
