defmodule YellowDog.ServerAgent.Status do
  @moduledoc """
  Safe local status projection for one concrete Server agent.
  """

  alias YellowDog.ServerAgent.Client
  alias YellowDog.ServerAgent.ConfigApplyStore
  alias YellowDog.ServerAgent.Heartbeat
  alias YellowDog.Sync.Identity.Server
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.Hello

  @allowed_options [:heartbeat, :identity, :client, :config_apply_store]
  @runtime_states [:unconfigured, :known, :unknown]
  @attempt_states [:delivered, :applying, :applied, :failed]

  @doc "Builds a bounded status snapshot from local supervised state only."
  def snapshot(opts \\ [])

  def snapshot([]), do: default_snapshot(Heartbeat)

  def snapshot(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- Enum.all?(keys, &(&1 in @allowed_options)),
         true <- length(keys) == length(Enum.uniq(keys)),
         {:ok, heartbeat} <- server_ref(Keyword.get(opts, :heartbeat, Heartbeat), false),
         {:ok, identity} <- identity(Keyword.get(opts, :identity)),
         {:ok, client} <- server_ref(Keyword.get(opts, :client), true),
         {:ok, config_apply_store} <-
           server_ref(Keyword.get(opts, :config_apply_store), true) do
      configured_snapshot(heartbeat, identity, client, config_apply_store)
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  def snapshot(_opts), do: {:error, :invalid_options}

  defp default_snapshot(heartbeat) do
    case heartbeat_snapshot(heartbeat) do
      {:ok, state} ->
        %{
          agent: :yellow_dog_server,
          running: true,
          status: state.status,
          agent_id: state.agent_id,
          started_at: state.started_at,
          last_heartbeat_at: state.last_heartbeat_at,
          connection_state: state.connection_state,
          capabilities: [:heartbeat, :status_snapshot]
        }

      :error ->
        %{
          agent: :yellow_dog_server,
          running: false,
          status: :stopped,
          connection_state: :unavailable,
          capabilities: [:heartbeat, :status_snapshot]
        }
    end
  end

  defp configured_snapshot(heartbeat, identity, client, config_apply_store) do
    case heartbeat_snapshot(heartbeat) do
      {:ok, %{agent_id: agent_id} = state} when agent_id == identity.id ->
        connection_state = connection_state(client, state.connection_state)
        record_connection_state(heartbeat, connection_state)

        %{
          agent: :yellow_dog_server,
          running: true,
          status: state.status,
          agent_id: state.agent_id,
          identity: %{
            target_type: :server,
            id: identity.id,
            name: identity.name,
            version: identity.version
          },
          profile: identity.profile,
          capabilities: identity.capabilities,
          config_revision: identity.config_revision,
          connection_state: connection_state,
          apply_status: apply_status(config_apply_store),
          started_at: state.started_at,
          last_heartbeat_at: state.last_heartbeat_at
        }

      {:ok, _mismatched_state} ->
        {:error, :invalid_state}

      :error ->
        %{
          agent: :yellow_dog_server,
          running: false,
          status: :stopped,
          identity: %{
            target_type: :server,
            id: identity.id,
            name: identity.name,
            version: identity.version
          },
          profile: identity.profile,
          capabilities: identity.capabilities,
          config_revision: identity.config_revision,
          connection_state: connection_state(client, :unavailable),
          apply_status: apply_status(config_apply_store)
        }
    end
  end

  defp heartbeat_snapshot(server) do
    case Heartbeat.snapshot(server) do
      %Heartbeat{} = state -> {:ok, state}
      _invalid -> :error
    end
  rescue
    _exception -> :error
  catch
    :exit, _reason -> :error
    _kind, _reason -> :error
  end

  defp connection_state(nil, _fallback), do: :disabled

  defp connection_state(client, fallback) do
    case Client.connection_state(client) do
      state when state in [:disabled, :connecting, :handshaking, :active, :backoff] -> state
      :unavailable -> :unavailable
      _invalid -> fallback
    end
  end

  defp record_connection_state(heartbeat, connection_state) do
    _result = Heartbeat.record_connection_state(heartbeat, connection_state)
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp apply_status(nil), do: nil

  defp apply_status(config_apply_store) do
    case ConfigApplyStore.snapshot(config_apply_store) do
      {:ok, %{runtime_status: runtime_status, attempt: nil}}
      when runtime_status in @runtime_states ->
        %{runtime_status: runtime_status, state: :idle, version: nil}

      {:ok,
       %{
         runtime_status: runtime_status,
         attempt: %{status: state, version: version}
       }}
      when runtime_status in @runtime_states and state in @attempt_states and is_integer(version) and
             version > 0 ->
        %{runtime_status: runtime_status, state: state, version: version}

      _invalid ->
        nil
    end
  rescue
    _exception -> nil
  catch
    :exit, _reason -> nil
    _kind, _reason -> nil
  end

  defp identity(%Server{} = identity) do
    message = %Hello{identity: identity}

    with true <- identity.capabilities == Enum.uniq(identity.capabilities),
         {:ok, encoded} <- Message.encode(message),
         {:ok, ^message} <- Message.decode(encoded) do
      {:ok, identity}
    else
      _invalid -> :error
    end
  end

  defp identity(_identity), do: :error

  defp server_ref(nil, true), do: {:ok, nil}
  defp server_ref(value, _optional?) when is_atom(value) and not is_nil(value), do: {:ok, value}
  defp server_ref({:global, _term} = value, _optional?), do: {:ok, value}

  defp server_ref({:via, module, _term} = value, _optional?)
       when is_atom(module) and not is_nil(module),
       do: {:ok, value}

  defp server_ref(_value, _optional?), do: :error
end
