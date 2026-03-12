defmodule YellowDog.Resolved.Management.Client do
  @moduledoc """
  WebSocket client for management connection to YellowDog DNS server.
  Handles commands: cache_flush, cache_stats, ping.
  """
  use GenServer

  require Logger

  alias YellowDog.Resolved.Management.Handler

  # Client API

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  # Server callbacks

  @impl true
  def init(config) do
    state = %{
      endpoint: config.endpoint,
      instance_id: config.instance_id,
      parent: config.parent,
      ws_config: config.ws_config,
      conn: nil,
      websocket: nil,
      ref: nil,
      heartbeat_interval: Map.get(config.ws_config, :heartbeat_interval_s, 30) * 1000,
      heartbeat_timer: nil,
      connected: false,
      last_pong_at: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state) do
      {:ok, state} ->
        # Upgrade request sent; the connected event is emitted after the
        # 101 Switching Protocols response arrives on the TCP socket.
        Logger.debug("[Resolved] Management upgrade request sent to #{state.endpoint}")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[Resolved] Management connection failed: #{inspect(reason)}")
        send(state.parent, {:management_down, reason})
        {:stop, :normal, state}
    end
  end

  def handle_info(:heartbeat, %{connected: true} = state) do
    # Pong watchdog: if no pong has arrived within 2× the heartbeat interval
    # the TCP session is likely half-open (silently dead).  Disconnect so that
    # Discovery can re-probe and establish a fresh connection.
    now = System.monotonic_time(:millisecond)
    deadline = state.heartbeat_interval * 2

    if state.last_pong_at != nil and now - state.last_pong_at > deadline do
      Logger.warning("[Resolved] Management heartbeat timeout — no pong received; reconnecting")
      handle_disconnect(state, :heartbeat_timeout)
    else
      state = send_ws_ping(state)
      timer = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
      {:noreply, %{state | heartbeat_timer: timer}}
    end
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  # Complete the WebSocket handshake when the HTTP 101 response arrives.
  # websocket is nil until Mint.WebSocket.new/4 succeeds.
  def handle_info({:tcp, _socket, _data} = msg, %{websocket: nil} = state) do
    case Mint.WebSocket.stream(state.conn, msg) do
      {:ok, conn, responses} ->
        ref = state.ref

        status =
          Enum.find_value(responses, fn
            {:status, ^ref, s} -> s
            _ -> nil
          end)

        headers =
          Enum.find_value(responses, fn
            {:headers, ^ref, h} -> h
            _ -> nil
          end)

        # Guard: Mint buffers HTTP headers internally until the complete header
        # block arrives (status line + all headers + "\r\n\r\n").  If only a
        # partial TCP segment was received, responses is empty and both status
        # and headers are nil — calling Mint.WebSocket.new/4 with nil arguments
        # would fail and trigger a spurious disconnect.  Wait for the next TCP
        # message instead.
        if status == nil do
          {:noreply, %{state | conn: conn}}
        else
          case Mint.WebSocket.new(conn, state.ref, status, headers) do
            {:ok, conn, websocket} ->
              Logger.info("[Resolved] Management WebSocket connected to #{state.endpoint}")

              :telemetry.execute(
                [:yellow_dog, :resolved, :management, :connected],
                %{},
                %{endpoint: state.endpoint}
              )

              state = %{
                state
                | conn: conn,
                  websocket: websocket,
                  connected: true,
                  last_pong_at: System.monotonic_time(:millisecond)
              }

              connected_msg = Handler.connected_event(state.instance_id)
              state = send_message(state, connected_msg)
              timer = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
              {:noreply, %{state | heartbeat_timer: timer}}

            {:error, conn, reason} ->
              Logger.warning("[Resolved] WebSocket upgrade failed: #{inspect(reason)}")
              handle_disconnect(%{state | conn: conn}, {:upgrade_failed, reason})
          end
        end

      {:error, _conn, reason, _responses} ->
        Logger.warning("[Resolved] HTTP stream error during upgrade: #{inspect(reason)}")
        handle_disconnect(state, {:upgrade_error, reason})

      :unknown ->
        {:noreply, state}
    end
  end

  # Receive WebSocket frames via Mint.WebSocket.stream → Mint.WebSocket.decode.
  def handle_info({:tcp, _socket, _data} = msg, state) do
    case Mint.WebSocket.stream(state.conn, msg) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        {websocket, frames} = extract_ws_frames(responses, state.ref, state.websocket)
        state = %{state | websocket: websocket}
        state = handle_frames(frames, state)
        {:noreply, state}

      {:error, _conn, reason, _responses} ->
        Logger.warning("[Resolved] WebSocket stream error: #{inspect(reason)}")
        handle_disconnect(state, reason)

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, _socket}, state) do
    handle_disconnect(state, :tcp_closed)
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    handle_disconnect(state, reason)
  end

  def handle_info({:send_failed, reason}, state) do
    handle_disconnect(state, {:send_failed, reason})
  end

  # Server-initiated WebSocket close: close echo was already sent in handle_frames;
  # now cleanly disconnect so Discovery can re-probe (RFC 6455 §5.5.1).
  def handle_info({:ws_closed, reason}, state) do
    handle_disconnect(state, {:ws_closed, reason})
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)
    if state.conn, do: Mint.HTTP.close(state.conn)
    :ok
  end

  # Private

  defp connect(state) do
    uri = URI.parse(state.endpoint)
    host = uri.host || "localhost"
    port = uri.port || 4000
    path = uri.path || "/ws/resolved"

    headers = [
      {"x-instance-id", Base.encode16(state.instance_id, case: :lower)}
    ]

    with {:ok, conn} <- Mint.HTTP.connect(:http, host, port),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, headers) do
      {:ok, %{state | conn: conn, ref: ref}}
    end
  rescue
    e -> {:error, e}
  end

  defp handle_frames(frames, state) do
    Enum.reduce(frames, state, fn
      {:text, data}, state ->
        handle_text_frame(data, state)

      {:ping, data}, state ->
        send_ws_pong(state, data)

      {:pong, _data}, state ->
        %{state | last_pong_at: System.monotonic_time(:millisecond)}

      {:close, code, data}, state ->
        # RFC 6455 §5.5.1: echo the close frame before disconnecting.
        state = send_ws_close(state, code, data)
        send(self(), {:ws_closed, :normal})
        state

      _, state ->
        state
    end)
  end

  defp handle_text_frame(data, state) do
    case Jason.decode(data) do
      {:ok, message} ->
        response = Handler.handle_command(message)

        if response do
          send_message(state, response)
        else
          state
        end

      {:error, _} ->
        Logger.warning("[Resolved] Invalid JSON from management server")
        state
    end
  end

  defp send_message(state, message) do
    json = Jason.encode!(message)

    case Mint.WebSocket.encode(state.websocket, {:text, json}) do
      {:ok, websocket, data} ->
        case Mint.HTTP.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} ->
            %{state | conn: conn, websocket: websocket}

          {:error, _conn, reason} ->
            Logger.warning("[Resolved] Failed to send WS message: #{inspect(reason)}")
            send(self(), {:send_failed, reason})
            state
        end

      {:error, reason} ->
        Logger.warning("[Resolved] Failed to encode WS message: #{inspect(reason)}")
        send(self(), {:send_failed, reason})
        state
    end
  end

  defp send_ws_ping(state) do
    case Mint.WebSocket.encode(state.websocket, {:ping, ""}) do
      {:ok, websocket, data} ->
        case Mint.HTTP.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} ->
            %{state | conn: conn, websocket: websocket}

          {:error, _conn, reason} ->
            send(self(), {:send_failed, reason})
            state
        end

      {:error, reason} ->
        send(self(), {:send_failed, reason})
        state
    end
  end

  defp send_ws_pong(state, data) do
    case Mint.WebSocket.encode(state.websocket, {:pong, data}) do
      {:ok, websocket, out} ->
        case Mint.HTTP.stream_request_body(state.conn, state.ref, out) do
          {:ok, conn} ->
            %{state | conn: conn, websocket: websocket}

          {:error, _conn, reason} ->
            send(self(), {:send_failed, reason})
            state
        end

      {:error, reason} ->
        send(self(), {:send_failed, reason})
        state
    end
  end

  defp send_ws_close(state, code, data) do
    case Mint.WebSocket.encode(state.websocket, {:close, code, data}) do
      {:ok, websocket, out} ->
        case Mint.HTTP.stream_request_body(state.conn, state.ref, out) do
          {:ok, conn} ->
            %{state | conn: conn, websocket: websocket}

          {:error, _conn, _reason} ->
            state
        end

      {:error, _reason} ->
        state
    end
  end

  defp extract_ws_frames(responses, ref, websocket) do
    Enum.reduce(responses, {websocket, []}, fn
      {:data, ^ref, data}, {ws, frames} ->
        case Mint.WebSocket.decode(ws, data) do
          {:ok, ws, new_frames} -> {ws, frames ++ new_frames}
          {:error, ws, _reason} -> {ws, frames}
        end

      _other, acc ->
        acc
    end)
  end

  defp handle_disconnect(state, reason) do
    Logger.info("[Resolved] Management WebSocket disconnected: #{inspect(reason)}")

    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)

    # Notify Discovery to re-probe (PRD: always re-discover, don't cache endpoint)
    send(state.parent, {:management_down, reason})

    # Stop self — Discovery will start a new Client after re-probing
    {:stop, :normal, %{state | connected: false, heartbeat_timer: nil}}
  end
end
