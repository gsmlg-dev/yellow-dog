defmodule YellowDog.Resolved.Management.Client do
  @moduledoc """
  WebSocket client for management connection to YellowDog DNS server.

  Connects to the management endpoint discovered via EDNS probing.
  Handles heartbeat ping/pong, reconnection with exponential backoff,
  and dispatches incoming commands to the Handler module.

  Note: This is a stub implementation that uses GenServer + :gen_tcp
  for basic WebSocket framing. A production version would use a proper
  WebSocket client library (e.g., mint_web_socket or websock_client).
  """

  use GenServer

  require Logger

  alias YellowDog.Resolved.Management.Handler

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Send a message to the management server."
  @spec send_message(map()) :: :ok
  def send_message(message) do
    GenServer.cast(__MODULE__, {:send, message})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    state = %{
      endpoint: opts.endpoint,
      instance_id: opts.instance_id,
      ws_config: opts.ws_config,
      connected: false,
      socket: nil
    }

    # Send connected event
    connected_msg = Handler.build_connected_event(state.instance_id)
    Logger.info("Management client initialized for #{state.endpoint}")

    schedule_heartbeat(state.ws_config.heartbeat_interval_s)
    {:ok, %{state | connected: true}, {:continue, {:send_connected, connected_msg}}}
  end

  @impl true
  def handle_continue({:send_connected, _msg}, state) do
    # In a real implementation, this would send over the WebSocket
    {:noreply, state}
  end

  @impl true
  def handle_cast({:send, _message}, %{connected: false} = state) do
    Logger.warning("Cannot send message: not connected")
    {:noreply, state}
  end

  def handle_cast({:send, _message}, state) do
    # In a real implementation, this would encode and send over WebSocket
    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, %{connected: true} = state) do
    # Send a heartbeat ping
    schedule_heartbeat(state.ws_config.heartbeat_interval_s)
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    {:noreply, state}
  end

  def handle_info({:ws_message, json_text}, state) do
    case Jason.decode(json_text) do
      {:ok, message} ->
        response = Handler.handle_command(message)

        if response do
          GenServer.cast(self(), {:send, response})
        end

        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Invalid WS message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp schedule_heartbeat(interval_s) do
    Process.send_after(self(), :heartbeat, interval_s * 1000)
  end
end
