defmodule YellowDog.Console.TestManagementTransport do
  @moduledoc false

  use GenServer

  @behaviour YellowDog.Management.Transport

  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  def connect(target_type, target_id),
    do: GenServer.call(__MODULE__, {:connect, target_type, target_id})

  def disconnect(target_type, target_id),
    do: GenServer.call(__MODULE__, {:disconnect, target_type, target_id})

  def script_request(responses) when is_list(responses),
    do: GenServer.call(__MODULE__, {:script_request, responses})

  def script_config(responses) when is_list(responses),
    do: GenServer.call(__MODULE__, {:script_config, responses})

  def recorded, do: GenServer.call(__MODULE__, :recorded)

  @impl true
  def connected?(target_type, target_id),
    do: GenServer.call(__MODULE__, {:connected?, target_type, target_id})

  @impl true
  def request(%Envelope{} = envelope, timeout),
    do: GenServer.call(__MODULE__, {:request, envelope, timeout})

  @impl true
  def deliver_config(%Envelope{} = envelope),
    do: GenServer.call(__MODULE__, {:deliver_config, envelope})

  @impl true
  def init(:ok) do
    {:ok,
     %{
       connected: MapSet.new(),
       request_responses: :queue.new(),
       config_responses: :queue.new(),
       recorded: []
     }}
  end

  @impl true
  def handle_call({:connect, target_type, target_id}, _from, state) do
    connected = MapSet.put(state.connected, {target_type, target_id})
    {:reply, :ok, %{state | connected: connected}}
  end

  def handle_call({:disconnect, target_type, target_id}, _from, state) do
    connected = MapSet.delete(state.connected, {target_type, target_id})
    {:reply, :ok, %{state | connected: connected}}
  end

  def handle_call({:connected?, target_type, target_id}, _from, state) do
    {:reply, MapSet.member?(state.connected, {target_type, target_id}), state}
  end

  def handle_call({:script_request, responses}, _from, state) do
    {:reply, :ok, %{state | request_responses: :queue.from_list(responses)}}
  end

  def handle_call({:script_config, responses}, _from, state) do
    {:reply, :ok, %{state | config_responses: :queue.from_list(responses)}}
  end

  def handle_call(:recorded, _from, state) do
    {:reply, Enum.reverse(state.recorded), state}
  end

  def handle_call({:request, envelope, timeout}, _from, state) do
    {response, request_responses} = pop(state.request_responses)
    recorded = [{:request, envelope, timeout} | state.recorded]

    {:reply, response, %{state | request_responses: request_responses, recorded: recorded}}
  end

  def handle_call({:deliver_config, envelope}, _from, state) do
    {response, config_responses} = pop(state.config_responses, :ok)
    recorded = [{:config, envelope} | state.recorded]

    {:reply, response, %{state | config_responses: config_responses, recorded: recorded}}
  end

  defp pop(queue, default \\ {:error, Error.new(:internal, "missing test response", %{})}) do
    case :queue.out(queue) do
      {{:value, response}, remaining} -> {response, remaining}
      {:empty, remaining} -> {default, remaining}
    end
  end
end
