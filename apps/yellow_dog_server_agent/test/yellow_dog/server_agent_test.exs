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
             management_core: :not_configured,
             capabilities: capabilities
           } = YellowDog.ServerAgent.status_snapshot()

    assert :heartbeat in capabilities
    assert :status_snapshot in capabilities
  end
end
