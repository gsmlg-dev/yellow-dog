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
      websocket: nil,
      websocket_monitor: nil,
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

  def handle_info(
        {HTTP.WebSocket, socket, %HTTP.WebSocket.Event.Open{}},
        %{websocket: socket} = state
      ) do
    Logger.info("[Resolved] Management WebSocket connected to #{state.endpoint}")

    :telemetry.execute(
      [:yellow_dog, :resolved, :management, :connected],
      %{},
      %{endpoint: state.endpoint}
    )

    state = %{state | connected: true, last_pong_at: System.monotonic_time(:millisecond)}
    state = send_message(state, Handler.connected_event(state.instance_id))
    timer = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
    {:noreply, %{state | heartbeat_timer: timer}}
  end

  def handle_info(
        {HTTP.WebSocket, socket, %HTTP.WebSocket.Event.Frame{} = frame, delivery},
        %{websocket: socket} = state
      ) do
    state = handle_frames([{frame.opcode, frame.data}], state)
    HTTP.WebSocket.acknowledge(socket, delivery)
    {:noreply, state}
  end

  def handle_info(
        {HTTP.WebSocket, socket, %HTTP.WebSocket.Event.Error{reason: reason}},
        %{websocket: socket} = state
      ) do
    handle_disconnect(state, reason)
  end

  def handle_info(
        {HTTP.WebSocket, socket, %HTTP.WebSocket.Event.Close{code: code, reason: reason}},
        %{websocket: socket} = state
      ) do
    handle_disconnect(state, {:ws_closed, {code, reason}})
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{websocket_monitor: monitor} = state
      ) do
    handle_disconnect(state, {:websocket_down, reason})
  end

  def handle_info({:send_failed, reason}, state) do
    handle_disconnect(state, {:send_failed, reason})
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)
    if state.websocket, do: HTTP.WebSocket.close(state.websocket)
    :ok
  end

  # Private

  defp connect(state) do
    headers = [
      {"x-instance-id", Base.encode16(state.instance_id, case: :lower)}
    ]

    case HTTP.WebSocket.new(state.endpoint, [],
           headers: headers,
           mode: :proxy,
           http_version: :http1,
           delivery: :ack
         ) do
      %HTTP.WebSocket{} = websocket ->
        monitor = Process.monitor(websocket.pid)
        {:ok, %{state | websocket: websocket, websocket_monitor: monitor}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp handle_frames(frames, state) do
    Enum.reduce(frames, state, fn
      {:text, data}, state ->
        handle_text_frame(data, state)

      {:ping, _data}, state ->
        # The WebSocket transport automatically replies to control pings.
        state

      {:pong, _data}, state ->
        %{state | last_pong_at: System.monotonic_time(:millisecond)}

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
    case HTTP.WebSocket.send(state.websocket, Jason.encode!(message)) do
      :ok ->
        state

      {:error, reason} ->
        send(self(), {:send_failed, reason})
        state
    end
  end

  defp send_ws_ping(state) do
    case HTTP.WebSocket.send_frame(state.websocket, {:ping, ""}) do
      :ok ->
        state

      {:error, reason} ->
        send(self(), {:send_failed, reason})
        state
    end
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
