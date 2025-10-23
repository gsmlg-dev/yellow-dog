defmodule Abyss.TestTransport do
  @moduledoc """
  Mock transport module for testing transport behaviour
  """
  @behaviour Abyss.Transport

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def simulate_packet(data, client_info) do
    GenServer.cast(__MODULE__, {:simulate_packet, data, client_info})
  end

  def get_received_data do
    GenServer.call(__MODULE__, :get_received_data)
  end

  def get_sent_data do
    GenServer.call(__MODULE__, :get_sent_data)
  end

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    {:ok, %{received: [], sent: [], socket: nil}}
  end

  @impl true
  def handle_call(:get_received_data, _from, state) do
    {:reply, state.received, state}
  end

  @impl true
  def handle_call(:get_sent_data, _from, state) do
    {:reply, state.sent, state}
  end

  ## Transport callbacks

  @impl true
  def listen(_port, _opts) do
    {:ok, make_ref()}
  end

  @impl true
  def controlling_process(_socket, _pid) do
    :ok
  end

  @impl true
  def recv(_socket, _bytes, _timeout) do
    {:ok, {"127.0.0.1", 12345, "test data"}}
  end

  @impl true
  def send(_socket, data) do
    GenServer.cast(__MODULE__, {:send, data})
    :ok
  end

  @impl true
  def getopts(_socket, _opts) do
    {:ok, []}
  end

  @impl true
  def setopts(_socket, _opts) do
    :ok
  end

  @impl true
  def close(_socket) do
    :ok
  end

  @impl true
  def sockname(_socket) do
    {:ok, {{127, 0, 0, 1}, 8080}}
  end

  @impl true
  def peername(_socket) do
    {:ok, {{127, 0, 0, 1}, 12345}}
  end

  @impl true
  def getstat(_socket) do
    {:ok, [recv_oct: 100, send_oct: 100]}
  end

  ## GenServer handlers

  @impl true
  def handle_cast({:simulate_packet, data, client_info}, state) do
    {:noreply, %{state | received: [{data, client_info} | state.received]}}
  end

  @impl true
  def handle_cast({:send, data}, state) do
    {:noreply, %{state | sent: [data | state.sent]}}
  end
end
