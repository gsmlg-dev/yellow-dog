defmodule YellowDog.Console.ServerConnections do
  @moduledoc """
  Serializes Server channel candidates, activation, replacement, and presence.
  """

  use GenServer

  alias YellowDog.ManagementCore

  @pubsub YellowDog.Console.PubSub
  @max_id_bytes 128

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @spec begin_candidate(String.t(), pid()) :: :ok | {:error, :invalid}
  def begin_candidate(server_id, channel_pid) do
    GenServer.call(__MODULE__, {:begin_candidate, server_id, channel_pid})
  end

  @spec join_candidate(String.t(), pid()) :: :ok | {:error, :invalid}
  def join_candidate(server_id, channel_pid), do: begin_candidate(server_id, channel_pid)

  @spec activate(String.t(), pid(), map(), map()) ::
          {:ok, pid() | nil} | {:error, :invalid | :not_candidate}
  def activate(server_id, channel_pid, identity, status) do
    GenServer.call(__MODULE__, {:activate, server_id, channel_pid, identity, status})
  end

  @spec touch(String.t(), pid()) :: :ok
  def touch(server_id, channel_pid) do
    GenServer.call(__MODULE__, {:touch, server_id, channel_pid})
  end

  @spec disconnect(String.t(), pid()) :: :ok
  def disconnect(server_id, channel_pid) do
    GenServer.call(__MODULE__, {:disconnect, server_id, channel_pid})
  end

  @spec get(String.t()) :: {:ok, map()} | :error
  def get(server_id), do: GenServer.call(__MODULE__, {:get, server_id})

  @spec list() :: [map()]
  def list, do: GenServer.call(__MODULE__, :list)

  @spec connected?(String.t()) :: boolean()
  def connected?(server_id), do: GenServer.call(__MODULE__, {:connected?, server_id})

  @doc false
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl true
  def init(_opts), do: {:ok, initial_state()}

  @impl true
  def handle_call({:begin_candidate, server_id, channel_pid}, _from, state) do
    if valid_candidate?(server_id, channel_pid) do
      key = {server_id, channel_pid}

      case Map.fetch(state.candidates, key) do
        {:ok, _candidate} ->
          {:reply, :ok, state}

        :error ->
          monitor_ref = Process.monitor(channel_pid)
          candidate = %{server_id: server_id, channel_pid: channel_pid, monitor_ref: monitor_ref}

          state =
            state
            |> put_in([:candidates, key], candidate)
            |> put_in([:monitors, monitor_ref], {:candidate, server_id, channel_pid})

          {:reply, :ok, state}
      end
    else
      {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call(
        {:activate, server_id, channel_pid, identity, status},
        _from,
        state
      ) do
    key = {server_id, channel_pid}

    with {:ok, candidate} <- Map.fetch(state.candidates, key),
         true <- valid_identity?(identity, server_id),
         true <- valid_status?(status, server_id) do
      {state, replaced_pid} = replace_active(state, server_id)
      now = DateTime.utc_now(:second)

      connection = %{
        server_id: server_id,
        channel_pid: channel_pid,
        monitor_ref: candidate.monitor_ref,
        identity: identity,
        status: status,
        connected?: true,
        connected_at: now,
        last_seen_at: now
      }

      state =
        state
        |> update_in([:candidates], &Map.delete(&1, key))
        |> put_in([:connections, server_id], connection)
        |> put_in(
          [:monitors, candidate.monitor_ref],
          {:active, server_id, channel_pid}
        )

      if replaced_pid, do: send(replaced_pid, {:server_connection_replaced, channel_pid})
      broadcast(server_id, {:server_connection, :online, public_connection(connection)})

      {:reply, {:ok, replaced_pid}, state}
    else
      :error -> {:reply, {:error, :not_candidate}, state}
      false -> {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call({:touch, server_id, channel_pid}, _from, state) do
    case Map.fetch(state.connections, server_id) do
      {:ok, %{channel_pid: ^channel_pid, connected?: true} = connection} ->
        updated = %{connection | last_seen_at: DateTime.utc_now(:second)}
        state = put_in(state, [:connections, server_id], updated)
        broadcast(server_id, {:server_connection, :updated, public_connection(updated)})
        {:reply, :ok, state}

      _not_active ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:disconnect, server_id, channel_pid}, _from, state) do
    {state, disconnected?} = disconnect_pid(state, server_id, channel_pid, true)
    if disconnected?, do: management_disconnected(server_id)
    {:reply, :ok, state}
  end

  def handle_call({:get, server_id}, _from, state) do
    reply =
      case Map.fetch(state.connections, server_id) do
        {:ok, connection} -> {:ok, public_connection(connection)}
        :error -> :error
      end

    {:reply, reply, state}
  end

  def handle_call(:list, _from, state) do
    connections =
      state.connections
      |> Map.values()
      |> Enum.map(&public_connection/1)
      |> Enum.sort_by(& &1.server_id)

    {:reply, connections, state}
  end

  def handle_call({:connected?, server_id}, _from, state) do
    connected? =
      case Map.get(state.connections, server_id) do
        %{connected?: true, channel_pid: channel_pid} -> Process.alive?(channel_pid)
        _connection -> false
      end

    {:reply, connected?, state}
  end

  def handle_call(:reset, _from, state) do
    Enum.each(Map.keys(state.monitors), &Process.demonitor(&1, [:flush]))
    {:reply, :ok, initial_state()}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, channel_pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {{:candidate, server_id, ^channel_pid}, monitors} ->
        candidates = Map.delete(state.candidates, {server_id, channel_pid})
        {:noreply, %{state | candidates: candidates, monitors: monitors}}

      {{:active, server_id, ^channel_pid}, monitors} ->
        state = %{state | monitors: monitors}
        {state, disconnected?} = disconnect_pid(state, server_id, channel_pid, false)
        if disconnected?, do: management_disconnected(server_id)
        {:noreply, state}
    end
  end

  defp replace_active(state, server_id) do
    case Map.get(state.connections, server_id) do
      %{connected?: true, channel_pid: old_pid, monitor_ref: monitor_ref} ->
        Process.demonitor(monitor_ref, [:flush])
        {%{state | monitors: Map.delete(state.monitors, monitor_ref)}, old_pid}

      _connection ->
        {state, nil}
    end
  end

  defp disconnect_pid(state, server_id, channel_pid, demonitor?) do
    candidate_key = {server_id, channel_pid}

    case Map.pop(state.candidates, candidate_key) do
      {%{monitor_ref: monitor_ref}, candidates} ->
        if demonitor?, do: Process.demonitor(monitor_ref, [:flush])

        state = %{
          state
          | candidates: candidates,
            monitors: Map.delete(state.monitors, monitor_ref)
        }

        {state, false}

      {nil, _candidates} ->
        disconnect_active(state, server_id, channel_pid, demonitor?)
    end
  end

  defp disconnect_active(state, server_id, channel_pid, demonitor?) do
    case Map.get(state.connections, server_id) do
      %{channel_pid: ^channel_pid, connected?: true, monitor_ref: monitor_ref} = connection ->
        if demonitor?, do: Process.demonitor(monitor_ref, [:flush])

        updated = %{
          connection
          | channel_pid: nil,
            monitor_ref: nil,
            connected?: false
        }

        state = %{
          state
          | connections: Map.put(state.connections, server_id, updated),
            monitors: Map.delete(state.monitors, monitor_ref)
        }

        broadcast(server_id, {:server_connection, :offline, public_connection(updated)})
        {state, true}

      _not_active ->
        {state, false}
    end
  end

  defp public_connection(connection), do: Map.drop(connection, [:monitor_ref])

  defp broadcast(server_id, message) do
    Phoenix.PubSub.broadcast(@pubsub, "management:server:#{server_id}", message)
  end

  defp management_disconnected(server_id) do
    ManagementCore.runtime_disconnected(:server, server_id)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp valid_candidate?(server_id, channel_pid) do
    valid_id?(server_id) and is_pid(channel_pid) and Process.alive?(channel_pid)
  end

  defp valid_identity?(
         %{
           id: server_id,
           name: name,
           version: version,
           profile: profile,
           capabilities: capabilities,
           config_revision: config_revision
         },
         server_id
       ) do
    is_binary(name) and is_binary(version) and is_binary(profile) and
      is_list(capabilities) and is_binary(config_revision)
  end

  defp valid_identity?(_identity, _server_id), do: false

  defp valid_status?(
         %{
           target_type: :server,
           target_id: server_id,
           state: state,
           details: details,
           observed_at: %DateTime{}
         },
         server_id
       ) do
    is_atom(state) and is_map(details)
  end

  defp valid_status?(_status, _server_id), do: false

  defp valid_id?(value) do
    is_binary(value) and value != "" and byte_size(value) <= @max_id_bytes and
      String.valid?(value)
  end

  defp initial_state, do: %{connections: %{}, candidates: %{}, monitors: %{}}
end
