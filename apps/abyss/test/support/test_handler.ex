defmodule Abyss.TestHandler do
  @moduledoc """
  Test handler module for testing Abyss.Handler behaviour
  """
  use Abyss.Handler

  @impl true
  def handle_data({ip, port, data}, state) do
    send(self(), {:packet_received, data, {ip, port}})
    {:continue, state}
  end

  @impl true
  def handle_info({:packet_received, _data, {_ip, _port}}, state) do
    # Handle the packet received message sent by handle_data
    {:noreply, state}
  end
end

defmodule Abyss.TestEchoHandler do
  @moduledoc """
  Test echo handler for integration testing
  """
  use Abyss.Handler

  @impl true
  def handle_data({ip, port, data}, state) do
    Abyss.Transport.UDP.send(state.socket, ip, port, data)
    {:continue, state}
  end
end
