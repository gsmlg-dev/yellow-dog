defmodule YellowDog.ServerAgentTest do
  use ExUnit.Case, async: false

  defmodule CrossWiredClient do
    @moduledoc false

    use GenServer

    def start_link(connected_reply, connection_state_reply) do
      GenServer.start_link(__MODULE__, {connected_reply, connection_state_reply})
    end

    @impl true
    def init(replies), do: {:ok, replies}

    @impl true
    def handle_call(:connected?, _from, {connected_reply, _state_reply} = state),
      do: {:reply, connected_reply, state}

    def handle_call(:connection_state, _from, {_connected_reply, state_reply} = state),
      do: {:reply, state_reply, state}
  end

  test "starts heartbeat under supervision" do
    assert :ok = Application.ensure_started(:yellow_dog_server_agent)
    assert Process.whereis(YellowDog.ServerAgent.Heartbeat) |> Process.alive?()
  end

  test "returns a local status snapshot without network calls" do
    assert :ok = Application.ensure_started(:yellow_dog_server_agent)

    assert %{
             agent: :yellow_dog_server,
             running: true,
             status: :idle,
             connection_state: :disabled,
             capabilities: capabilities
           } = YellowDog.ServerAgent.status_snapshot()

    assert :heartbeat in capabilities
    assert :status_snapshot in capabilities
  end

  test "exposes only safe Client inspection through the facade" do
    assert YellowDog.ServerAgent.connected?(unique_name()) == false
    assert YellowDog.ServerAgent.connection_state(unique_name()) == :unavailable

    exported = YellowDog.ServerAgent.__info__(:functions)
    refute {:connect, 0} in exported
    refute {:disconnect, 0} in exported
    refute {:apply_config, 1} in exported
    refute {:dispatch, 1} in exported
  end

  test "normalizes arbitrary successful Client replies at the safe facade" do
    {:ok, map_client} = CrossWiredClient.start_link(%{active: true}, %{state: :active})
    {:ok, tuple_client} = CrossWiredClient.start_link({:ok, true}, {:ok, :active})
    {:ok, true_client} = CrossWiredClient.start_link(true, :active)

    refute YellowDog.ServerAgent.connected?(map_client)
    refute YellowDog.ServerAgent.connected?(tuple_client)
    assert YellowDog.ServerAgent.connected?(true_client)

    assert YellowDog.ServerAgent.connection_state(map_client) == :unavailable
    assert YellowDog.ServerAgent.connection_state(tuple_client) == :unavailable
    assert YellowDog.ServerAgent.connection_state(true_client) == :active
  end

  defp unique_name do
    :"missing-client-#{System.unique_integer([:positive])}"
  end
end
