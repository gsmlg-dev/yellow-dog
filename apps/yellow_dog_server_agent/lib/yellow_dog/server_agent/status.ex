defmodule YellowDog.ServerAgent.Status do
  @moduledoc """
  Local status snapshot builder for the server agent skeleton.
  """

  alias YellowDog.ServerAgent.Heartbeat

  @doc "Builds a status snapshot from local supervised state only."
  def snapshot do
    case Process.whereis(Heartbeat) do
      nil ->
        base_snapshot(false, :stopped)

      _pid ->
        heartbeat = Heartbeat.snapshot()

        true
        |> base_snapshot(heartbeat.status)
        |> Map.merge(%{
          agent_id: heartbeat.agent_id,
          started_at: heartbeat.started_at,
          last_heartbeat_at: heartbeat.last_heartbeat_at
        })
    end
  end

  defp base_snapshot(running?, status) do
    %{
      agent: :yellow_dog_server,
      running: running?,
      status: status,
      management_core: :not_configured,
      capabilities: [:heartbeat, :status_snapshot]
    }
  end
end
