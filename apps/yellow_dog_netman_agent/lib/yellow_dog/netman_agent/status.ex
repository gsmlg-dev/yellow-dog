defmodule YellowDog.NetmanAgent.Status do
  @moduledoc """
  Local status snapshot builder for the Netman agent skeleton.
  """

  alias YellowDog.NetmanAgent.Client
  alias YellowDog.NetmanAgent.ConfigApplyStore
  alias YellowDog.NetmanAgent.Heartbeat

  @doc "Builds a status snapshot from local supervised state only."
  def snapshot(client \\ Client, config_apply_store \\ ConfigApplyStore) do
    connection_state = Client.connection_state(client)
    config_state = config_state(config_apply_store)

    case Process.whereis(Heartbeat) do
      nil ->
        base_snapshot(false, :stopped, connection_state, config_state)

      pid ->
        running_snapshot(pid, connection_state, config_state)
    end
  end

  defp running_snapshot(pid, connection_state, config_state) do
    heartbeat = Heartbeat.snapshot(pid)

    true
    |> base_snapshot(heartbeat.status, connection_state, config_state)
    |> Map.merge(%{
      agent_id: heartbeat.agent_id,
      started_at: heartbeat.started_at,
      last_heartbeat_at: heartbeat.last_heartbeat_at
    })
  catch
    :exit, _reason -> base_snapshot(false, :stopped, connection_state, config_state)
  end

  defp base_snapshot(running?, status, connection_state, config_state) do
    %{
      agent: :yellow_dog_netman,
      running: running?,
      status: status,
      management_core: management_core_state(connection_state),
      connection_state: connection_state,
      config_runtime_status: config_state.runtime_status,
      config_revision: config_state.revision,
      capabilities: [:heartbeat, :status_snapshot, :management_connection]
    }
  end

  defp config_state(config_apply_store) do
    case ConfigApplyStore.snapshot(config_apply_store) do
      {:ok, %{runtime_status: runtime_status, known_good: known_good}}
      when runtime_status in [:unconfigured, :known, :unknown] ->
        %{runtime_status: runtime_status, revision: known_good_revision(known_good)}

      _unavailable ->
        %{runtime_status: :unavailable, revision: nil}
    end
  rescue
    _exception -> %{runtime_status: :unavailable, revision: nil}
  catch
    :exit, _reason -> %{runtime_status: :unavailable, revision: nil}
  end

  defp known_good_revision(%{revision: revision}) when is_binary(revision), do: revision
  defp known_good_revision(_known_good), do: nil

  defp management_core_state(:active), do: :connected
  defp management_core_state(:disabled), do: :disabled
  defp management_core_state(:connecting), do: :connecting
  defp management_core_state(:handshaking), do: :connecting
  defp management_core_state(:backoff), do: :reconnecting
  defp management_core_state(:unavailable), do: :not_configured
end
