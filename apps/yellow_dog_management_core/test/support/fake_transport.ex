defmodule YellowDog.Management.FakeTransport do
  @moduledoc false

  use GenServer

  @behaviour YellowDog.Management.Transport

  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  def connect(target_type, target_id) do
    GenServer.call(__MODULE__, {:connect, target_type, target_id})
  end

  def disconnect(target_type, target_id) do
    GenServer.call(__MODULE__, {:disconnect, target_type, target_id})
  end

  def script(replies) when is_list(replies) do
    GenServer.call(__MODULE__, {:script, replies})
  end

  def recorded do
    GenServer.call(__MODULE__, :recorded)
  end

  def reply(ref, response) do
    GenServer.call(__MODULE__, {:reply, ref, response})
  end

  @impl true
  def connected?(target_type, target_id) do
    GenServer.call(__MODULE__, {:connected?, target_type, target_id})
  end

  @impl true
  def request(%Envelope{} = envelope, timeout) do
    GenServer.call(__MODULE__, {:request, envelope, timeout}, timeout)
  catch
    :exit, {:timeout, _reason} ->
      {:error, Error.new(:timeout, "transport request timed out", %{})}
  end

  @impl true
  def deliver_config(%Envelope{} = envelope) do
    GenServer.call(__MODULE__, {:deliver_config, envelope})
  end

  @impl true
  def init(:ok) do
    {:ok, empty_state()}
  end

  @impl true
  def handle_call(:reset, _from, _state), do: {:reply, :ok, empty_state()}

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

  def handle_call({:script, replies}, _from, state) do
    {:reply, :ok, %{state | replies: :queue.from_list(replies)}}
  end

  def handle_call(:recorded, _from, state) do
    {:reply, Enum.reverse(state.recorded), state}
  end

  def handle_call({:request, envelope, timeout}, from, state) do
    with {:ok, operation} <- Operation.lookup(envelope.operation),
         {:ok, ^envelope} <- Operation.validate_envelope(envelope, operation.kind) do
      recorded = [
        %{envelope: envelope, timeout: timeout, kind: operation.kind, caller: elem(from, 0)}
        | state.recorded
      ]

      {reply, replies} = pop_reply(state.replies)
      state = %{state | recorded: recorded, replies: replies}
      handle_scripted_reply(reply, envelope, from, state)
    else
      {:error, %Error{}} = error -> {:reply, error, state}
    end
  end

  def handle_call({:deliver_config, envelope}, _from, state) do
    case Operation.validate_envelope(envelope, :config) do
      {:ok, ^envelope} ->
        recorded = [%{envelope: envelope, timeout: nil, kind: :config} | state.recorded]
        {:reply, :ok, %{state | recorded: recorded}}

      {:error, %Error{}} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:reply, ref, response}, _from, state) do
    case Map.pop(state.deferred, ref) do
      {nil, _deferred} ->
        {:reply, {:error, :not_found}, state}

      {from, deferred} ->
        GenServer.reply(from, response)
        {:reply, :ok, %{state | deferred: deferred}}
    end
  end

  defp handle_scripted_reply({:defer, owner, ref}, envelope, from, state) do
    send(owner, {:fake_transport_deferred, ref, envelope})
    {:noreply, %{state | deferred: Map.put(state.deferred, ref, from)}}
  end

  defp handle_scripted_reply({:disconnect_after_delivery, response}, envelope, _from, state) do
    {:ok, _result} = ManagementCore.runtime_disconnected(envelope.target_type, envelope.target_id)
    {:reply, response, state}
  end

  defp handle_scripted_reply(response, _envelope, _from, state), do: {:reply, response, state}

  defp pop_reply(replies) do
    case :queue.out(replies) do
      {{:value, reply}, rest} -> {reply, rest}
      {:empty, rest} -> {{:error, Error.new(:internal, "no scripted transport reply", %{})}, rest}
    end
  end

  defp empty_state do
    %{connected: MapSet.new(), recorded: [], replies: :queue.new(), deferred: %{}}
  end
end
