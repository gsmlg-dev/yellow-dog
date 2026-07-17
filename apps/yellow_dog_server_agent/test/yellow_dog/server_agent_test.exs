defmodule YellowDog.ServerAgentTest do
  use ExUnit.Case, async: false

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

  defp unique_name do
    :"missing-client-#{System.unique_integer([:positive])}"
  end
end
