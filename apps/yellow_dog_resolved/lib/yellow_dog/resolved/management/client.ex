defmodule YellowDog.Resolved.Management.Client do
  @moduledoc """
  WebSocket client for management connection to YellowDog DNS server.
  Handles commands: cache_flush, cache_stats, ping.
  """
  use GenServer

  require Logger

  alias YellowDog.Resolved.Management.Handler

  @reconnect_base_ms 5_000
  @reconnect_max_ms 60_000

  # Client API

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
      reconnect_delay: Map.get(config.ws_config, :reconnect_base_s, 5) * 1000,
      heartbeat_interval: Map.get(config.ws_config, :heartbeat_interval_s, 30) * 1000,
      heartbeat_timer: nil,
      connected: false
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state) do
      {:ok, state} ->
        Logger.info("[Resolved] Management WebSocket connected to #{state.endpoint}")

        :telemetry.execute(
          [:yellow_dog, :resolved, :management, :connected],
          %{},
          %{endpoint: state.endpoint}
        )

        # Send connected event
        connected_msg = Handler.connected_event(state.instance_id)
        state = send_message(state, connected_msg)

        # Start heartbeat
        timer = Process.send_after(self(), :heartbeat, state.heartbeat_interval)

        {:noreply,
         %{state | connected: true, heartbeat_timer: timer, reconnect_delay: @reconnect_base_ms}}

      {:error, reason} ->
        Logger.warning("[Resolved] Management connection failed: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  def handle_info(:heartbeat, %{connected: true} = state) do
    # WebSocket ping/pong
    state = send_ws_ping(state)
    timer = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    {:noreply, %{state | heartbeat_timer: timer}}
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info({:tcp, _socket, data}, state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        state = handle_frames(frames, state)
        {:noreply, state}

      {:error, _websocket, reason} ->
        Logger.warning("[Resolved] WebSocket decode error: #{inspect(reason)}")
        handle_disconnect(state, reason)
    end
  end

  def handle_info({:tcp_closed, _socket}, state) do
    handle_disconnect(state, :tcp_closed)
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    handle_disconnect(state, reason)
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
        state

      {:close, _code, _reason}, state ->
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
            state
        end

      {:error, _reason} ->
        state
    end
  end

  defp send_ws_ping(state) do
    case Mint.WebSocket.encode(state.websocket, {:ping, ""}) do
      {:ok, websocket, data} ->
        case Mint.HTTP.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} -> %{state | conn: conn, websocket: websocket}
          _ -> state
        end

      _ ->
        state
    end
  end

  defp send_ws_pong(state, data) do
    case Mint.WebSocket.encode(state.websocket, {:pong, data}) do
      {:ok, websocket, out} ->
        case Mint.HTTP.stream_request_body(state.conn, state.ref, out) do
          {:ok, conn} -> %{state | conn: conn, websocket: websocket}
          _ -> state
        end

      _ ->
        state
    end
  end

  defp handle_disconnect(state, reason) do
    Logger.info("[Resolved] Management WebSocket disconnected: #{inspect(reason)}")

    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)

    send(state.parent, {:management_down, reason})

    schedule_reconnect(state)
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :connect, state.reconnect_delay)
    new_delay = min(state.reconnect_delay * 2, @reconnect_max_ms)
    {:noreply, %{state | connected: false, reconnect_delay: new_delay, heartbeat_timer: nil}}
  end
end
