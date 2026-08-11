defmodule YellowDog.ServerAgent.ClientFakeSocket do
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
        if Process.alive?(pid), do: Agent.stop(pid)

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

    reply = pop(:joins, :ok)

    case reply do
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

    if is_pid(pid) and Process.alive?(pid) do
      Agent.stop(pid, :normal)
    else
      :ok
    end
  end

  def set_connected(value) when is_boolean(value) do
    Agent.update(state_pid(), &%{&1 | connected: value})
  end

  def set_starts(replies) when is_list(replies) do
    Agent.update(state_pid(), &%{&1 | starts: replies})
  end

  def set_pushes(replies) when is_list(replies) do
    Agent.update(state_pid(), &%{&1 | pushes: replies})
  end

  def channel_message(client, channel, payload) do
    send(client, {:yellow_dog_socket_message, channel, "sync", payload})
  end

  def channel_message(client, channel, event, payload) do
    send(client, {:yellow_dog_socket_message, channel, event, payload})
  end

  def provider_message(channel, payload) do
    caller = Agent.get(channel, & &1.caller)

    send(caller, %Phoenix.SocketClient.Message{
      channel_pid: caller,
      event: "sync",
      payload: payload
    })
  end

  def socket_channel_message(channel, payload) do
    Agent.get(channel, fn %{caller: caller} ->
      state = %Phoenix.SocketClient.Channel.State{
        caller: caller,
        topic: "server:control:server-east-1"
      }

      YellowDog.ServerAgent.Client.SocketChannel.handle_message("sync", payload, state)
    end)
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
