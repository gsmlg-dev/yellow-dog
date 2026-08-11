defmodule YellowDog.NetmanAgentTest do
  use ExUnit.Case, async: false

  test "starts heartbeat under supervision" do
    assert :ok = Application.ensure_started(:yellow_dog_netman_agent)
    assert Process.whereis(YellowDog.NetmanAgent.Heartbeat) |> Process.alive?()
  end

  test "returns a local status snapshot without network calls" do
    assert :ok = Application.ensure_started(:yellow_dog_netman_agent)

    assert %{
             agent: :yellow_dog_netman,
             running: true,
             status: :idle,
             management_core: :disabled,
             connection_state: :disabled,
             config_runtime_status: :unavailable,
             config_revision: nil,
             capabilities: capabilities
           } = YellowDog.NetmanAgent.status_snapshot()

    assert :heartbeat in capabilities
    assert :status_snapshot in capabilities
    assert :management_connection in capabilities
  end

  test "starts the explicitly disabled management client through the public facade" do
    refute YellowDog.NetmanAgent.connected?()
    assert YellowDog.NetmanAgent.connection_state() == :disabled
  end

  test "status snapshot reflects a configured disabled client" do
    name = {:global, {__MODULE__, System.unique_integer([:positive])}}
    assert {:ok, client} = YellowDog.NetmanAgent.Client.start_link(enabled: false, name: name)

    assert %{management_core: :disabled, connection_state: :disabled} =
             YellowDog.NetmanAgent.status_snapshot(client)
  end
end
