defmodule YellowDog.NetmanAgent.ClientFakeSocket do
  @moduledoc false

  use Agent

  def configure(owner, opts \\ []) do
    state = %{
      owner: owner,
      connected: Keyword.get(opts, :connected, true),
      starts: Keyword.get(opts, :starts, []),
      joins: Keyword.get(opts, :joins, []),
      pushes: Keyword.get(opts, :pushes, [])
    }

    {:ok, pid} = Agent.start_link(fn -> state end)
    :persistent_term.put({__MODULE__, :state}, pid)
    pid
  end

  def clear do
    case :persistent_term.get({__MODULE__, :state}, nil) do
      pid when is_pid(pid) ->
        stop_if_running(pid)

      _other ->
        :ok
    end

    :persistent_term.erase({__MODULE__, :state})
  end

  def start_link(opts) do
    state = state()
    send(state.owner, {:socket_start, opts})

    case pop(:starts, :ok) do
      :ok -> Agent.start_link(fn -> %{owner: state.owner} end)
      other -> other
    end
  end

  def connected?(_socket) do
    Agent.get_and_update(state_pid(), fn state ->
      case state.connected do
        [value | rest] -> {value, %{state | connected: rest}}
        value -> {value, state}
      end
    end)
  end

  def join(socket, topic, params, timeout) do
    state = state()
    send(state.owner, {:socket_join, socket, topic, params, timeout})

    case pop(:joins, :ok) do
      :ok ->
        caller = self()
        {:ok, channel} = Agent.start_link(fn -> %{owner: state.owner, caller: caller} end)
        send(state.owner, {:socket_channel, channel})
        {:ok, %{}, channel}

      other ->
        other
    end
  end

  def push(channel, event, payload, timeout) do
    send(state().owner, {:socket_push, channel, event, payload, timeout})
    pop(:pushes, {:ok, %{"accepted" => true}})
  end

  def stop(pid) do
    send(state().owner, {:socket_stop, pid})

    if is_pid(pid), do: stop_if_running(pid), else: :ok
  end

  defp stop_if_running(pid) do
    try do
      Agent.stop(pid)
    catch
      :exit, {:noproc, _call} -> :ok
    end
  end

  def channel_message(client, channel, payload) do
    send(client, {:yellow_dog_socket_message, channel, "sync", payload})
  end

  def channel_message(client, channel, event, payload) do
    send(client, {:yellow_dog_socket_message, channel, event, payload})
  end

  defp pop(key, default) do
    Agent.get_and_update(state_pid(), fn state ->
      case Map.fetch!(state, key) do
        [value | rest] -> {value, Map.put(state, key, rest)}
        [] -> {default, state}
      end
    end)
  end

  defp state, do: Agent.get(state_pid(), & &1)
  defp state_pid, do: :persistent_term.get({__MODULE__, :state})
end
