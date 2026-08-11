defmodule YellowDog.ServerAgent.Client do
  @moduledoc """
  Serialized outbound Server management client.

  Enabled clients require an HTTPS management URL, token, canonical Server
  identity, owner references for durable command/config state, injected
  socket/timer/clock modules, and positive connection and publication timing
  values. Disabled clients accept only `:enabled` and `:name`.
  """

  use GenServer

  alias YellowDog.ServerAgent.CommandJournal
  alias YellowDog.ServerAgent.Client.CredentialProvider
  alias YellowDog.ServerAgent.ConfigApplier
  alias YellowDog.ServerAgent.ConfigApplyStore
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Identity.Server
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.Command
  alias YellowDog.Sync.Message.ConfigDelivery
  alias YellowDog.Sync.Message.ConfigState
  alias YellowDog.Sync.Message.Heartbeat
  alias YellowDog.Sync.Message.Hello
  alias YellowDog.Sync.Message.Query
  alias YellowDog.Sync.Message.Result
  alias YellowDog.Sync.Message.Status

  @event "sync"
  @disabled_options [:enabled, :name]
  @credential_options [:management_url, :token, :server_id, :socket]
  @enabled_options [
    :enabled,
    :name,
    :credential_ref,
    :credential_owner,
    :identity,
    :dispatcher,
    :dispatcher_runtime_adapter,
    :query_dispatcher,
    :query_runtime_adapter,
    :command_journal,
    :config_applier,
    :config_apply_store,
    :timer,
    :monotonic_clock,
    :wall_clock,
    :connection_poll_interval,
    :connect_timeout,
    :join_timeout,
    :push_timeout,
    :heartbeat_interval,
    :status_interval,
    :initial_backoff,
    :max_backoff
  ]
  @required_enabled_options @enabled_options -- [:name]
  @socket_callbacks [start_link: 1, connected?: 1, join: 4, push: 4, stop: 1]
  @timer_callbacks [send_after: 3, cancel: 1]
  @clock_callbacks [now: 0]
  @receipt_keys ~w(publication_sequence state_revision target_id target_type)
  @timer_keys [:check, :rejoin, :heartbeat, :status, :config]

  @type connection_state :: :disabled | :connecting | :handshaking | :active | :backoff
  @type credential_ref :: {pid(), reference()}

  @spec prepare_credentials(keyword()) :: {:ok, credential_ref()} | {:error, :invalid_options}
  def prepare_credentials(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- length(keys) == length(Enum.uniq(keys)),
         true <- Enum.sort(keys) == Enum.sort(@credential_options),
         {:ok, endpoint} <- management_url(Keyword.get(opts, :management_url)),
         {:ok, token} <- token(Keyword.get(opts, :token)),
         {:ok, server_id} <- server_id(Keyword.get(opts, :server_id)),
         {:ok, socket} <- callback_module(Keyword.get(opts, :socket), @socket_callbacks),
         {:ok, credential_ref} <-
           CredentialProvider.start_owner(token, server_id, endpoint, socket) do
      {:ok, credential_ref}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  def prepare_credentials(_opts), do: {:error, :invalid_options}

  @spec release_credentials(credential_ref()) :: :ok | :error
  def release_credentials(credential_ref) do
    case CredentialProvider.release(credential_ref) do
      :ok -> :ok
      _error -> :error
    end
  end

  @spec claim_credentials(credential_ref()) :: :ok | :error
  def claim_credentials(credential_ref) do
    case CredentialProvider.claim(credential_ref) do
      :ok -> :ok
      _error -> :error
    end
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, config, name} <- validate_options(opts) do
      start_validated(config, name)
    end
  end

  def start_link(_opts), do: {:error, :invalid_options}

  defp start_validated(config, name) do
    case start_client(config, name) do
      :ignore -> {:error, :invalid_options}
      result -> result
    end
  end

  defp start_client(config, nil), do: GenServer.start_link(__MODULE__, config)
  defp start_client(config, name), do: GenServer.start_link(__MODULE__, config, name: name)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    case validate_child_spec_options(opts) do
      {:ok, _config, name} ->
        %{
          id: child_id(name),
          start: {__MODULE__, :start_link, [opts]},
          type: :worker
        }

      {:error, :invalid_options} ->
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_invalid, []},
          type: :worker
        }
    end
  end

  @doc false
  def start_invalid, do: {:error, :invalid_options}

  @spec connected?(GenServer.server()) :: boolean()
  def connected?(server \\ __MODULE__) do
    GenServer.call(server, :connected?)
  catch
    :exit, _reason -> false
  end

  @spec connection_state(GenServer.server()) :: connection_state() | :unavailable
  def connection_state(server \\ __MODULE__) do
    GenServer.call(server, :connection_state)
  catch
    :exit, _reason -> :unavailable
  end

  @doc "Updates Management-visible runtime identity without replacing the control channel."
  @spec refresh_identity(map(), GenServer.server()) ::
          :ok | {:error, :invalid_identity | :unavailable}
  def refresh_identity(updates, server \\ __MODULE__) do
    with {:ok, updates} <- identity_updates(updates),
         pid when is_pid(pid) <- GenServer.whereis(server) do
      GenServer.cast(pid, {:refresh_identity, updates})
      :ok
    else
      nil -> {:error, :unavailable}
      _invalid -> {:error, :invalid_identity}
    end
  rescue
    _exception -> {:error, :unavailable}
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(%{enabled: false}) do
    {:ok, %{enabled: false, status: :disabled}}
  end

  def init(config) do
    Process.flag(:trap_exit, true)

    with :ok <-
           CredentialProvider.bind(
             config.credential_ref,
             self(),
             config.identity.id,
             config.credential_owner
           ) do
      {:ok,
       %{
         enabled: true,
         config: config,
         status: :connecting,
         socket: nil,
         socket_ref: nil,
         channel: nil,
         channel_ref: nil,
         generation: 0,
         connection_id: 0,
         connect_started_at: nil,
         attempt: 0,
         timers: empty_timers()
       }, {:continue, :connect}}
    else
      _error -> :ignore
    end
  end

  @impl true
  def handle_continue(:connect, state), do: start_socket(state)

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, Map.get(state, :status) == :active, state}
  end

  def handle_call(:connection_state, _from, state) do
    {:reply, Map.fetch!(state, :status), state}
  end

  @impl true
  def handle_cast({:refresh_identity, updates}, %{enabled: true} = state) do
    identity = struct!(state.config.identity, updates)

    case identity(identity) do
      {:ok, identity} ->
        state = put_in(state, [:config, :identity], identity)

        state =
          if state.status == :active do
            case push_message(status_message(state), nil, state) do
              :ok -> state
              :error -> schedule_rejoin(state)
            end
          else
            state
          end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_cast({:refresh_identity, _updates}, state), do: {:noreply, state}

  @impl true
  def handle_info({:check_socket, connection_id}, %{connection_id: connection_id} = state) do
    state = clear_timer(state, :check)

    cond do
      state.status != :connecting ->
        {:noreply, state}

      socket_connected?(state) ->
        {:noreply, join_and_activate(state)}

      connect_timed_out?(state) ->
        {:noreply, schedule_rejoin(state)}

      true ->
        {:noreply, schedule_check(state)}
    end
  end

  def handle_info({:check_socket, _old_connection}, state), do: {:noreply, state}

  def handle_info({:rejoin, attempt}, %{status: :backoff, attempt: attempt} = state) do
    state = clear_timer(state, :rejoin)
    {:noreply, elem(start_socket_reply(state), 1)}
  end

  def handle_info({:rejoin, _old_attempt}, state), do: {:noreply, state}

  def handle_info({:heartbeat, generation}, %{status: :active, generation: generation} = state) do
    state = clear_timer(state, :heartbeat)
    message = heartbeat_message(state)
    {:noreply, publish_periodic(message, :heartbeat, state)}
  end

  def handle_info({:heartbeat, _old_generation}, state), do: {:noreply, state}

  def handle_info({:status, generation}, %{status: :active, generation: generation} = state) do
    state = clear_timer(state, :status)

    state =
      case push_message(status_message(state), nil, state) do
        :ok ->
          state
          |> schedule_periodic(:status)
          |> flush_config_publications()

        :error ->
          schedule_rejoin(state)
      end

    {:noreply, state}
  end

  def handle_info({:status, _old_generation}, state), do: {:noreply, state}

  def handle_info(
        {:flush_config, generation},
        %{status: :active, generation: generation} = state
      ) do
    state =
      state
      |> clear_timer(:config)
      |> flush_config_publications()

    {:noreply, state}
  end

  def handle_info({:flush_config, _old_generation}, state), do: {:noreply, state}

  def handle_info(
        {:yellow_dog_socket_message, channel, @event, payload},
        %{status: :active, channel: channel} = state
      ) do
    {:noreply, handle_inbound(payload, state)}
  end

  def handle_info({:yellow_dog_socket_message, _channel, _event, _payload}, state),
    do: {:noreply, state}

  def handle_info(
        %Phoenix.SocketClient.Message{
          channel_pid: channel,
          event: @event,
          payload: payload
        },
        %{status: :active, channel: channel} = state
      ) do
    {:noreply, handle_inbound(payload, state)}
  end

  def handle_info(%Phoenix.SocketClient.Message{}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{socket_ref: ref} = state
      ) do
    {:noreply, schedule_rejoin(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{channel_ref: ref, channel: pid} = state
      ) do
    {:noreply, schedule_rejoin(state)}
  end

  def handle_info({:EXIT, pid, _reason}, %{socket: pid} = state) do
    {:noreply, schedule_rejoin(state)}
  end

  def handle_info({:EXIT, pid, _reason}, %{channel: pid} = state) do
    {:noreply, schedule_rejoin(state)}
  end

  def handle_info(
        {:credential_socket_down, credential_ref},
        %{config: %{credential_ref: credential_ref}} = state
      ) do
    {:noreply, schedule_rejoin(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{enabled: true} = state) do
    _state = cleanup_connection(state)

    CredentialProvider.unbind(
      state.config.credential_ref,
      self(),
      state.config.credential_owner
    )

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_socket(state) do
    {:noreply, next_state} = start_socket_reply(state)
    {:noreply, next_state}
  end

  defp start_socket_reply(state) do
    state = cleanup_connection(state)
    credential_ref = state.config.credential_ref
    socket_opts = [credential_ref: credential_ref]

    case safe_apply(state.config.socket, :start_link, [socket_opts]) do
      {:ok, ^credential_ref} ->
        connection_id = state.connection_id + 1

        state = %{
          state
          | status: :connecting,
            socket: credential_ref,
            socket_ref: CredentialProvider.monitor(credential_ref),
            connection_id: connection_id,
            connect_started_at: monotonic_now(state)
        }

        if socket_connected?(state) do
          {:noreply, join_and_activate(state)}
        else
          {:noreply, schedule_check(state)}
        end

      _error ->
        {:noreply, schedule_rejoin(state)}
    end
  end

  defp join_and_activate(state) do
    generation = state.generation + 1
    state = %{state | status: :handshaking, generation: generation}

    case socket_join(state) do
      {:ok, channel} ->
        state = %{
          state
          | channel: channel,
            channel_ref: Process.monitor(channel)
        }

        case handshake(state) do
          :ok -> activate(state)
          :error -> schedule_rejoin(state)
        end

      :error ->
        schedule_rejoin(state)
    end
  end

  defp socket_join(state) do
    topic = "server:control:" <> state.config.identity.id

    case safe_apply(state.config.socket, :join, [
           state.socket,
           topic,
           %{},
           state.config.join_timeout
         ]) do
      {:ok, _reply, channel} when is_pid(channel) -> {:ok, channel}
      _error -> :error
    end
  end

  defp handshake(state) do
    with :ok <- push_message(%Hello{identity: state.config.identity}, nil, state),
         :ok <- push_message(status_message(state), nil, state) do
      :ok
    else
      _error -> :error
    end
  end

  defp activate(state) do
    state = %{state | status: :active, attempt: 0}

    state
    |> schedule_periodic(:heartbeat)
    |> schedule_periodic(:status)
    |> upload_journal()
    |> flush_config_publications()
  end

  defp upload_journal(%{status: :active} = state) do
    case local_call(fn -> CommandJournal.wire_projection(state.config.command_journal) end) do
      {:ok, journal} ->
        case push_message(journal, nil, state) do
          :ok -> state
          :error -> schedule_rejoin(state)
        end

      _error ->
        schedule_rejoin(state)
    end
  end

  defp upload_journal(state), do: state

  defp handle_inbound(payload, state) do
    with {:ok, message} <- decode_inbound(payload),
         :ok <- inbound_identity(message, state.config.identity.id) do
      route_inbound(message, state)
    else
      _invalid -> state
    end
  end

  defp decode_inbound(%{"message" => encoded, "publication_sequence" => nil} = payload)
       when map_size(payload) == 2 and is_binary(encoded) do
    with {:ok, message} <- Message.decode(encoded),
         {:ok, ^encoded} <- Message.encode(message) do
      {:ok, message}
    else
      _invalid -> :error
    end
  end

  defp decode_inbound(_payload), do: :error

  defp inbound_identity(%Command{envelope: envelope}, server_id),
    do: envelope_identity(envelope, server_id)

  defp inbound_identity(%Query{envelope: envelope}, server_id),
    do: envelope_identity(envelope, server_id)

  defp inbound_identity(%ConfigDelivery{envelope: envelope}, server_id),
    do: envelope_identity(envelope, server_id)

  defp inbound_identity(_unsupported, _server_id), do: :error

  defp envelope_identity(%{target_type: :server, target_id: server_id}, server_id), do: :ok
  defp envelope_identity(_envelope, _server_id), do: :error

  defp route_inbound(%Command{envelope: envelope}, state),
    do: dispatch_inbound(envelope, state)

  defp route_inbound(%Query{envelope: envelope}, state),
    do: dispatch_query_inbound(envelope, state)

  defp route_inbound(%ConfigDelivery{envelope: envelope}, state) do
    _result = local_call(fn -> ConfigApplier.apply(envelope, state.config.config_applier) end)
    flush_config_publications(state)
  end

  defp dispatch_inbound(envelope, state) do
    result =
      local_call(fn ->
        state.config.dispatcher.dispatch(envelope, dispatcher_options(state))
      end)

    message = result_message(envelope, result)

    case push_message(message, nil, state) do
      :ok -> state
      :error -> schedule_rejoin(state)
    end
  end

  defp dispatcher_options(state) do
    [
      server_id: state.config.identity.id,
      capabilities: state.config.identity.capabilities,
      command_journal: state.config.command_journal,
      runtime_adapter: state.config.dispatcher_runtime_adapter
    ]
  end

  defp dispatch_query_inbound(envelope, state) do
    result =
      local_call(fn ->
        state.config.query_dispatcher.dispatch(envelope, query_dispatcher_options(state))
      end)

    message = result_message(envelope, result)

    case push_message(message, nil, state) do
      :ok -> state
      :error -> schedule_rejoin(state)
    end
  end

  defp query_dispatcher_options(state) do
    [
      server_id: state.config.identity.id,
      capabilities: state.config.identity.capabilities,
      runtime_adapter: state.config.query_runtime_adapter
    ]
  end

  defp result_message(envelope, {:ok, value}) when is_map(value) do
    %Result{
      request_id: envelope.request_id,
      target_type: :server,
      operation: envelope.operation,
      value: value,
      error: nil
    }
  end

  defp result_message(envelope, {:error, %Error{} = error}) do
    %Result{
      request_id: envelope.request_id,
      target_type: :server,
      operation: envelope.operation,
      value: nil,
      error: error
    }
  end

  defp result_message(envelope, _unknown_or_malformed) do
    result_message(envelope, {:error, Error.new(:internal, "internal error", %{})})
  end

  defp flush_config_publications(%{status: :active} = state) do
    case local_call(fn ->
           ConfigApplyStore.pending_publications(state.config.config_apply_store)
         end) do
      {:ok, publications} when is_list(publications) ->
        flush_publications(publications, state)

      _error ->
        schedule_config_retry(state)
    end
  end

  defp flush_config_publications(state), do: state

  defp flush_publications([], state), do: state

  defp flush_publications([publication | rest], state) do
    with {:ok, publication} <- validate_publication(publication, state),
         {:ok, receipt} <- push_publication(publication, state),
         :ok <- validate_receipt(receipt, publication, state.config.identity.id),
         {:ok, _snapshot} <-
           local_call(fn ->
             ConfigApplyStore.acknowledge_publication(
               publication.sequence,
               state.config.config_apply_store
             )
           end) do
      flush_publications(rest, state)
    else
      {:error, :transport} -> schedule_rejoin(state)
      _local_or_receipt_error -> schedule_config_retry(state)
    end
  end

  defp validate_publication(
         %{sequence: sequence, encoded_message: encoded, message: %ConfigState{} = message} =
           publication,
         state
       )
       when is_integer(sequence) and sequence > 0 and is_binary(encoded) do
    with :ok <- config_state_identity(message, state.config.identity.id),
         {:ok, ^message} <- Message.decode(encoded),
         {:ok, ^encoded} <- Message.encode(message) do
      {:ok, publication}
    else
      _invalid -> :error
    end
  end

  defp validate_publication(_publication, _state), do: :error

  defp config_state_identity(%ConfigState{target_type: :server, target_id: server_id}, server_id),
    do: :ok

  defp config_state_identity(_message, _server_id), do: :error

  defp push_publication(publication, state) do
    payload = %{
      "message" => publication.encoded_message,
      "publication_sequence" => publication.sequence
    }

    case socket_push(payload, state) do
      {:ok, receipt} when is_map(receipt) -> {:ok, receipt}
      {:ok, _malformed_receipt} -> {:error, :receipt}
      _transport_error -> {:error, :transport}
    end
  end

  defp validate_receipt(receipt, publication, server_id) do
    expected = %{
      "target_type" => "server",
      "target_id" => server_id,
      "publication_sequence" => publication.sequence,
      "state_revision" => state_revision(publication.message)
    }

    if Map.keys(receipt) |> Enum.sort() == @receipt_keys and receipt == expected,
      do: :ok,
      else: :error
  end

  defp state_revision(%ConfigState{state: :delivered}), do: 1
  defp state_revision(%ConfigState{state: :applying}), do: 2
  defp state_revision(%ConfigState{state: :applied}), do: 3

  defp state_revision(%ConfigState{state: :failed, failure: %{"phase" => "delivery"}}), do: 1

  defp state_revision(%ConfigState{state: :failed, failure: %{"phase" => "validation"}}), do: 2

  defp state_revision(%ConfigState{
         state: :failed,
         failure: %{"phase" => phase}
       })
       when phase in ["apply", "rollback"],
       do: 3

  defp state_revision(_message), do: nil

  defp push_message(message, publication_sequence, state) do
    with {:ok, encoded} <- Message.encode(message),
         {:ok, ^message} <- Message.decode(encoded),
         {:ok, %{"accepted" => true} = reply} <-
           socket_push(
             %{
               "message" => encoded,
               "publication_sequence" => publication_sequence
             },
             state
           ),
         true <- map_size(reply) == 1 do
      :ok
    else
      _error -> :error
    end
  end

  defp socket_push(payload, state) do
    CredentialProvider.push(
      state.socket,
      state.channel,
      @event,
      payload,
      state.config.push_timeout
    )
  end

  defp publish_periodic(message, timer_key, state) do
    case push_message(message, nil, state) do
      :ok -> schedule_periodic(state, timer_key)
      :error -> schedule_rejoin(state)
    end
  end

  defp heartbeat_message(state) do
    %Heartbeat{
      target_type: :server,
      target_id: state.config.identity.id,
      observed_at: wall_now(state)
    }
  end

  defp status_message(state) do
    identity = state.config.identity

    %Status{
      target_type: :server,
      target_id: identity.id,
      state: :online,
      details: %{
        "capabilities" => identity.capabilities,
        "config_revision" => identity.config_revision,
        "profile" => identity.profile,
        "version" => identity.version
      },
      observed_at: wall_now(state)
    }
  end

  defp schedule_check(state) do
    schedule_timer(
      state,
      :check,
      {:check_socket, state.connection_id},
      state.config.connection_poll_interval
    )
  end

  defp schedule_periodic(state, :heartbeat) do
    schedule_timer(
      state,
      :heartbeat,
      {:heartbeat, state.generation},
      state.config.heartbeat_interval
    )
  end

  defp schedule_periodic(state, :status) do
    schedule_timer(
      state,
      :status,
      {:status, state.generation},
      state.config.status_interval
    )
  end

  defp schedule_config_retry(%{status: :active} = state) do
    if state.timers.config do
      state
    else
      schedule_timer(
        state,
        :config,
        {:flush_config, state.generation},
        state.config.initial_backoff
      )
    end
  end

  defp schedule_config_retry(state), do: state

  defp schedule_rejoin(%{enabled: true} = state) do
    delay = backoff_delay(state.config, state.attempt)
    attempt = state.attempt + 1

    state
    |> cleanup_connection()
    |> Map.put(:status, :backoff)
    |> Map.put(:attempt, attempt)
    |> schedule_timer(:rejoin, {:rejoin, attempt}, delay)
  end

  defp backoff_delay(config, attempt) do
    multiplier = Integer.pow(2, min(attempt, 62))
    min(config.initial_backoff * multiplier, config.max_backoff)
  end

  defp schedule_timer(state, key, message, delay) do
    state = cancel_timer(state, key)
    ref = safe_apply(state.config.timer, :send_after, [self(), message, delay])
    put_in(state, [:timers, key], ref)
  end

  defp clear_timer(state, key), do: put_in(state, [:timers, key], nil)

  defp cancel_timer(state, key) do
    case state.timers[key] do
      nil ->
        state

      ref ->
        _result = safe_apply(state.config.timer, :cancel, [ref])
        clear_timer(state, key)
    end
  end

  defp cleanup_connection(state) do
    state = Enum.reduce(@timer_keys, state, &cancel_timer(&2, &1))
    demonitor(state.channel_ref)
    demonitor(state.socket_ref)
    stop_channel(state.channel)
    stop_socket(state)

    %{
      state
      | socket: nil,
        socket_ref: nil,
        channel: nil,
        channel_ref: nil,
        connect_started_at: nil,
        timers: empty_timers()
    }
  end

  defp stop_channel(nil), do: :ok

  defp stop_channel(channel) do
    if Process.alive?(channel) do
      Process.unlink(channel)
      Process.exit(channel, :shutdown)
    end

    :ok
  rescue
    _exception -> :ok
  end

  defp stop_socket(%{socket: nil}), do: :ok

  defp stop_socket(state) do
    _result = safe_apply(state.config.socket, :stop, [state.socket])
    :ok
  end

  defp demonitor(nil), do: :ok
  defp demonitor(ref), do: Process.demonitor(ref, [:flush])

  defp socket_connected?(%{socket: nil}), do: false

  defp socket_connected?(state) do
    safe_apply(state.config.socket, :connected?, [state.socket]) == true
  end

  defp connect_timed_out?(state) do
    monotonic_now(state) - state.connect_started_at >= state.config.connect_timeout
  end

  defp monotonic_now(state) do
    case safe_apply(state.config.monotonic_clock, :now, []) do
      value when is_integer(value) -> value
      _invalid -> 0
    end
  end

  defp wall_now(state) do
    case safe_apply(state.config.wall_clock, :now, []) do
      %DateTime{utc_offset: 0, std_offset: 0} = value -> value
      _invalid -> DateTime.from_unix!(0)
    end
  end

  defp local_call(callback) do
    callback.()
  rescue
    _exception -> {:error, Error.new(:internal, "internal error", %{})}
  catch
    _kind, _reason -> {:error, Error.new(:internal, "internal error", %{})}
  end

  defp safe_apply(module, function, arguments) do
    apply(module, function, arguments)
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp validate_options(opts), do: validate_options(opts, &server_ref/1)

  defp validate_child_spec_options(opts),
    do: validate_options(opts, &server_spec_ref/1)

  defp validate_options(opts, server_ref_validator) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- length(keys) == length(Enum.uniq(keys)),
         {:ok, enabled} <- enabled(Keyword.get(opts, :enabled)),
         {:ok, name} <- process_name(Keyword.get(opts, :name, __MODULE__)) do
      validate_mode(enabled, keys, opts, name, server_ref_validator)
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp validate_mode(false, keys, _opts, name, _server_ref_validator) do
    if Enum.all?(keys, &(&1 in @disabled_options)),
      do: {:ok, %{enabled: false}, name},
      else: {:error, :invalid_options}
  end

  defp validate_mode(true, keys, opts, name, server_ref_validator) do
    with true <- Enum.all?(keys, &(&1 in @enabled_options)),
         true <- Enum.all?(@required_enabled_options, &Keyword.has_key?(opts, &1)),
         {:ok, credential_ref} <- credential_ref(Keyword.get(opts, :credential_ref)),
         {:ok, credential_owner} <- pid(Keyword.get(opts, :credential_owner)),
         {:ok, identity} <- identity(Keyword.get(opts, :identity)),
         {:ok, dispatcher} <-
           callback_module(Keyword.get(opts, :dispatcher), dispatch: 2),
         {:ok, dispatcher_runtime_adapter} <-
           module(Keyword.get(opts, :dispatcher_runtime_adapter)),
         {:ok, query_dispatcher} <-
           callback_module(Keyword.get(opts, :query_dispatcher), dispatch: 2),
         {:ok, query_runtime_adapter} <-
           module(Keyword.get(opts, :query_runtime_adapter)),
         {:ok, command_journal} <-
           server_ref_validator.(Keyword.get(opts, :command_journal)),
         {:ok, config_applier} <-
           server_ref_validator.(Keyword.get(opts, :config_applier)),
         {:ok, config_apply_store} <-
           server_ref_validator.(Keyword.get(opts, :config_apply_store)),
         {:ok, timer} <- callback_module(Keyword.get(opts, :timer), @timer_callbacks),
         {:ok, monotonic_clock} <-
           callback_module(Keyword.get(opts, :monotonic_clock), @clock_callbacks),
         {:ok, wall_clock} <-
           callback_module(Keyword.get(opts, :wall_clock), @clock_callbacks),
         {:ok, timings} <- timings(opts) do
      config =
        Map.merge(timings, %{
          enabled: true,
          credential_ref: credential_ref,
          credential_owner: credential_owner,
          identity: identity,
          dispatcher: dispatcher,
          dispatcher_runtime_adapter: dispatcher_runtime_adapter,
          query_dispatcher: query_dispatcher,
          query_runtime_adapter: query_runtime_adapter,
          command_journal: command_journal,
          config_applier: config_applier,
          config_apply_store: config_apply_store,
          socket: CredentialProvider,
          timer: timer,
          monotonic_clock: monotonic_clock,
          wall_clock: wall_clock
        })

      {:ok, config, name}
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp enabled(value) when is_boolean(value), do: {:ok, value}
  defp enabled(_value), do: :error

  defp process_name(nil), do: {:ok, nil}
  defp process_name(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  defp process_name({:global, _term} = value), do: {:ok, value}

  defp process_name({:via, module, _term} = value)
       when is_atom(module) and not is_nil(module),
       do: {:ok, value}

  defp process_name(_value), do: :error

  defp management_url(value) when is_binary(value) do
    with {:ok,
          %URI{
            scheme: "https",
            host: host,
            port: port,
            userinfo: nil,
            query: nil,
            fragment: nil
          }} <- URI.new(value),
         true <- valid_management_host?(host),
         true <- valid_management_authority?(value, host),
         true <- is_integer(port) and port in 1..65_535 do
      {:ok,
       URI.to_string(%URI{
         scheme: "wss",
         host: normalize_management_host(host),
         port: port,
         path: "/server/ws/websocket"
       })}
    else
      _invalid -> :error
    end
  end

  defp management_url(_value), do: :error

  defp valid_management_host?(host) when is_binary(host) and host != "" do
    valid_ip_address?(host) or valid_dns_host?(host)
  end

  defp valid_management_host?(_host), do: false

  defp valid_management_authority?(value, host) do
    case :uri_string.parse(value) do
      %{scheme: scheme, host: ^host} = parts when is_binary(scheme) ->
        String.downcase(scheme, :ascii) == "https" and Map.get(parts, :port) != :undefined

      _invalid ->
        false
    end
  end

  defp valid_ip_address?(host) do
    match?({:ok, _address}, :inet.parse_address(String.to_charlist(host)))
  end

  defp valid_dns_host?(host) when byte_size(host) <= 253 do
    host
    |> String.split(".", trim: false)
    |> Enum.all?(&valid_dns_label?/1)
  end

  defp valid_dns_host?(_host), do: false

  defp valid_dns_label?(label) when byte_size(label) in 1..63 do
    Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\z/, label)
  end

  defp valid_dns_label?(_label), do: false

  defp normalize_management_host(host) do
    if valid_ip_address?(host), do: host, else: String.downcase(host, :ascii)
  end

  defp token(value) do
    with {:ok, value} <- Bounds.message(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> :error
    end
  end

  defp server_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> :error
    end
  end

  defp credential_ref({provider, capability} = credential_ref)
       when is_pid(provider) and is_reference(capability) do
    if Process.alive?(provider), do: {:ok, credential_ref}, else: :error
  end

  defp credential_ref(_value), do: :error

  defp pid(value) when is_pid(value), do: {:ok, value}
  defp pid(_value), do: :error

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

  defp identity(_value), do: :error

  defp identity_updates(%{
         profile: profile,
         capabilities: capabilities,
         config_revision: config_revision
       } = updates)
       when map_size(updates) == 3 do
    candidate = %Server{
      id: "validation",
      name: "validation",
      version: "validation",
      profile: profile,
      capabilities: capabilities,
      config_revision: config_revision
    }

    case identity(candidate) do
      {:ok, _candidate} ->
        {:ok,
         %{
           profile: profile,
           capabilities: capabilities,
           config_revision: config_revision
         }}

      :error ->
        :error
    end
  end

  defp identity_updates(_updates), do: :error

  defp module(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  defp module(_value), do: :error

  defp callback_module(value, callbacks) do
    with {:ok, value} <- module(value),
         true <- Code.ensure_loaded?(value),
         true <-
           Enum.all?(callbacks, fn {function, arity} ->
             function_exported?(value, function, arity)
           end) do
      {:ok, value}
    else
      _invalid -> :error
    end
  end

  defp server_ref(value) do
    case GenServer.whereis(value) do
      pid when is_pid(pid) -> {:ok, value}
      _missing -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp server_spec_ref(value) when is_pid(value) do
    if Process.alive?(value), do: {:ok, value}, else: :error
  end

  defp server_spec_ref(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  defp server_spec_ref({:global, _term} = value), do: {:ok, value}

  defp server_spec_ref({:via, module, _term} = value)
       when is_atom(module) and not is_nil(module),
       do: {:ok, value}

  defp server_spec_ref({name, node} = value)
       when is_atom(name) and not is_nil(name) and is_atom(node) and not is_nil(node),
       do: {:ok, value}

  defp server_spec_ref(_value), do: :error

  defp timings(opts) do
    keys = [
      :connection_poll_interval,
      :connect_timeout,
      :join_timeout,
      :push_timeout,
      :heartbeat_interval,
      :status_interval,
      :initial_backoff,
      :max_backoff
    ]

    with {:ok, values} <- positive_values(opts, keys),
         true <- values.connection_poll_interval <= values.connect_timeout,
         true <- values.initial_backoff <= values.max_backoff do
      {:ok, values}
    else
      _invalid -> :error
    end
  end

  defp positive_values(opts, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, values} ->
      case Keyword.get(opts, key) do
        value when is_integer(value) and value > 0 ->
          {:cont, {:ok, Map.put(values, key, value)}}

        _invalid ->
          {:halt, :error}
      end
    end)
  end

  defp child_id(nil), do: __MODULE__
  defp child_id(name), do: name

  defp empty_timers, do: %{check: nil, rejoin: nil, heartbeat: nil, status: nil, config: nil}

  defmodule CredentialProvider do
    @moduledoc false

    @call_timeout 5_000
    @bind_timeout 1_000
    @claim_timeout 5_000

    def start_owner(token, server_id, endpoint, socket) do
      creator = self()
      capability = make_ref()
      bootstrap_ref = make_ref()

      owner =
        spawn(__MODULE__, :bootstrap, [
          creator,
          bootstrap_ref,
          capability,
          token,
          server_id,
          endpoint,
          socket
        ])

      receive do
        {__MODULE__, ^bootstrap_ref, ^owner} -> {:ok, {owner, capability}}
      after
        @call_timeout ->
          Process.exit(owner, :kill)
          :error
      end
    end

    def bootstrap(creator, bootstrap_ref, capability, token, server_id, endpoint, socket) do
      Process.flag(:trap_exit, true)
      Process.flag(:sensitive, true)
      creator_ref = Process.monitor(creator)
      send(creator, {__MODULE__, bootstrap_ref, self()})

      loop(%{
        capability: capability,
        token: token,
        server_id: server_id,
        endpoint: endpoint,
        socket_adapter: socket,
        creator: creator,
        creator_ref: creator_ref,
        claim_timer:
          Process.send_after(self(), {:credential_claim_timeout, capability}, @claim_timeout),
        owner: nil,
        owner_ref: nil,
        client: nil,
        client_ref: nil,
        socket: nil,
        socket_ref: nil,
        channel: nil,
        channel_ref: nil
      })
    end

    def claim(credential_ref),
      do: call(credential_ref, :claim, @bind_timeout)

    def bind(credential_ref, client, server_id, owner) when is_pid(client) and is_pid(owner) do
      deadline = System.monotonic_time(:millisecond) + @bind_timeout
      bind_until(credential_ref, client, server_id, owner, deadline)
    end

    def bind(_credential_ref, _client, _server_id, _owner), do: :error

    def unbind(credential_ref, client, owner) when is_pid(client) and is_pid(owner),
      do: call(credential_ref, {:unbind, client, owner}, @bind_timeout)

    def unbind(_credential_ref, _client, _owner), do: :error

    def release(credential_ref),
      do: call(credential_ref, :release, @call_timeout)

    def start_link(opts) when is_list(opts) do
      with true <- Keyword.keyword?(opts),
           [:credential_ref] <- Keyword.keys(opts),
           {:ok, credential_ref} <- Keyword.fetch(opts, :credential_ref),
           {:ok, ^credential_ref} <- call(credential_ref, :start_socket, @call_timeout) do
        {:ok, credential_ref}
      else
        _error -> :error
      end
    end

    def start_link(_opts), do: :error

    def connected?(credential_ref),
      do: call(credential_ref, :connected?, @call_timeout) == true

    def join(credential_ref, topic, params, timeout) do
      call(credential_ref, {:join, topic, params, timeout}, timeout + 100)
    end

    def push(credential_ref, channel, event, payload, timeout) do
      call(credential_ref, {:push, channel, event, payload, timeout}, timeout + 100)
    end

    def stop(credential_ref),
      do: call(credential_ref, :stop_socket, @call_timeout)

    def monitor({owner, capability}) when is_pid(owner) and is_reference(capability),
      do: Process.monitor(owner)

    defp call({owner, capability}, request, timeout)
         when is_pid(owner) and is_reference(capability) do
      if Process.alive?(owner) do
        ref = make_ref()
        send(owner, {__MODULE__, self(), capability, ref, request})

        receive do
          {__MODULE__, ^capability, ^ref, reply} -> reply
        after
          timeout -> :error
        end
      else
        :error
      end
    end

    defp call(_credential_ref, _request, _timeout), do: :error

    defp loop(state) do
      receive do
        {__MODULE__, caller, capability, ref, :claim}
        when capability == state.capability ->
          case claim_owner(state, caller) do
            {:ok, state} ->
              reply(caller, capability, ref, :ok)
              loop(state)

            :error ->
              reply(caller, capability, ref, :error)
              loop(state)
          end

        {__MODULE__, caller, capability, ref, {:bind, client, server_id, owner}}
        when capability == state.capability and caller == client ->
          state = clear_dead_client(state)

          case bind_client(state, client, server_id, owner) do
            {:ok, state} ->
              reply(caller, capability, ref, :ok)
              loop(state)

            :busy ->
              reply(caller, capability, ref, :busy)
              loop(state)

            :error ->
              reply(caller, capability, ref, :error)
              loop(state)
          end

        {__MODULE__, caller, capability, ref, {:unbind, client, owner}}
        when capability == state.capability and caller == client ->
          case unbind_client(state, client, owner) do
            {:ok, state} ->
              reply(caller, capability, ref, :ok)
              loop(state)

            :error ->
              reply(caller, capability, ref, :error)
              loop(state)
          end

        {__MODULE__, caller, capability, ref, :start_socket}
        when capability == state.capability and caller == state.client ->
          {reply_value, state} = start_socket(state)
          reply(caller, capability, ref, reply_value)
          loop(state)

        {__MODULE__, caller, capability, ref, :connected?}
        when capability == state.capability and caller == state.client ->
          reply(caller, capability, ref, socket_connected?(state))
          loop(state)

        {__MODULE__, caller, capability, ref, {:join, topic, params, timeout}}
        when capability == state.capability and caller == state.client ->
          {reply_value, state} = socket_join(state, topic, params, timeout)
          reply(caller, capability, ref, reply_value)
          loop(state)

        {__MODULE__, caller, capability, ref, {:push, channel, event, payload, timeout}}
        when capability == state.capability and caller == state.client ->
          reply(
            caller,
            capability,
            ref,
            socket_push(state, channel, event, payload, timeout)
          )

          loop(state)

        {__MODULE__, caller, capability, ref, :stop_socket}
        when capability == state.capability and caller == state.client ->
          state = stop_socket(state)
          reply(caller, capability, ref, :ok)
          loop(state)

        {__MODULE__, caller, capability, ref, :release}
        when capability == state.capability and
               ((state.owner == nil and caller == state.creator) or caller == state.owner) ->
          _state = stop_socket(state)
          reply(caller, capability, ref, :ok)
          :ok

        {__MODULE__, caller, capability, ref, _invalid_request}
        when capability == state.capability ->
          reply(caller, capability, ref, :error)
          loop(state)

        {__MODULE__, _caller, _invalid_capability, _ref, _unauthorized_request} ->
          loop(state)

        {:credential_claim_timeout, capability}
        when capability == state.capability and state.owner == nil ->
          _state = stop_socket(state)
          :ok

        {:DOWN, ref, :process, _pid, _reason}
        when ref == state.creator_ref and state.owner == nil ->
          _state = stop_socket(state)
          :ok

        {:DOWN, ref, :process, _pid, _reason} when ref == state.owner_ref ->
          _state = stop_socket(state)
          :ok

        {:DOWN, ref, :process, _pid, _reason} when ref == state.client_ref ->
          state
          |> clear_client()
          |> loop()

        {:DOWN, ref, :process, _pid, _reason} when ref == state.socket_ref ->
          if is_pid(state.client) do
            send(state.client, {:credential_socket_down, credential_ref(state)})
          end

          state
          |> clear_transport_state()
          |> loop()

        {:DOWN, ref, :process, _pid, _reason} when ref == state.channel_ref ->
          loop(%{state | channel: nil, channel_ref: nil})

        {:EXIT, _pid, _reason} ->
          loop(state)

        {:yellow_dog_socket_message, channel, _event, _payload} = message
        when is_pid(channel) and channel == state.channel ->
          forward_socket_message(message, state)
          loop(state)

        %Phoenix.SocketClient.Message{} = message ->
          forward_socket_message(message, state)
          loop(state)

        _message ->
          loop(state)
      end
    end

    defp claim_owner(%{owner: owner} = state, owner), do: {:ok, state}

    defp claim_owner(%{owner: nil} = state, owner) when is_pid(owner) do
      owner_ref = Process.monitor(owner)

      if Process.alive?(state.creator) and
           Process.demonitor(state.creator_ref, [:flush, :info]) do
        cancel_claim_timer(state.claim_timer)

        {:ok,
         %{
           state
           | creator: nil,
             creator_ref: nil,
             claim_timer: nil,
             owner: owner,
             owner_ref: owner_ref
         }}
      else
        Process.demonitor(owner_ref, [:flush])
        :error
      end
    end

    defp claim_owner(_state, _owner), do: :error

    defp bind_client(
           %{owner: owner, client: nil} = state,
           client,
           server_id,
           owner
         )
         when server_id == state.server_id do
      if Process.alive?(owner) and Process.alive?(client) do
        {:ok, %{state | client: client, client_ref: Process.monitor(client)}}
      else
        :error
      end
    end

    defp bind_client(
           %{owner: owner, client: client} = state,
           _new_client,
           server_id,
           owner
         )
         when is_pid(client) and server_id == state.server_id,
         do: :busy

    defp bind_client(_state, _client, _server_id, _owner), do: :error

    defp bind_until(credential_ref, client, server_id, owner, deadline) do
      case call(credential_ref, {:bind, client, server_id, owner}, @bind_timeout) do
        :busy ->
          if System.monotonic_time(:millisecond) < deadline do
            Process.sleep(10)
            bind_until(credential_ref, client, server_id, owner, deadline)
          else
            :error
          end

        result ->
          result
      end
    end

    defp unbind_client(%{owner: owner, client: client} = state, client, owner),
      do: {:ok, clear_client(state)}

    defp unbind_client(_state, _client, _owner), do: :error

    defp clear_dead_client(%{client: client} = state) when is_pid(client) do
      if Process.alive?(client), do: state, else: clear_client(state)
    end

    defp clear_dead_client(state), do: state

    defp clear_client(state) do
      demonitor(state.client_ref)

      state
      |> stop_socket()
      |> Map.merge(%{client: nil, client_ref: nil})
    end

    defp start_socket(state) do
      state = stop_socket(state)

      opts = [
        url: state.endpoint,
        params: %{"token" => state.token, "server_id" => state.server_id}
      ]

      case invoke(state.socket_adapter, :start_link, [opts]) do
        {:ok, socket} when is_pid(socket) ->
          Process.unlink(socket)
          socket_ref = Process.monitor(socket)
          {{:ok, credential_ref(state)}, %{state | socket: socket, socket_ref: socket_ref}}

        _error ->
          {:error, state}
      end
    end

    defp socket_connected?(%{socket: socket, socket_adapter: adapter}) when is_pid(socket) do
      invoke(adapter, :connected?, [socket]) == true
    end

    defp socket_connected?(_state), do: false

    defp socket_join(
           %{socket: socket, socket_adapter: adapter} = state,
           topic,
           params,
           timeout
         )
         when is_pid(socket) do
      case invoke(adapter, :join, [socket, topic, params, timeout]) do
        {:ok, _reply, channel} when is_pid(channel) ->
          Process.unlink(channel)
          channel_ref = Process.monitor(channel)
          {{:ok, %{}, channel}, %{state | channel: channel, channel_ref: channel_ref}}

        _error ->
          {{:error, :transport}, state}
      end
    end

    defp socket_join(state, _topic, _params, _timeout), do: {{:error, :transport}, state}

    defp socket_push(
           %{socket_adapter: adapter, channel: channel},
           channel,
           event,
           payload,
           timeout
         )
         when is_pid(channel) do
      case invoke(adapter, :push, [channel, event, payload, timeout]) do
        {:ok, reply} -> {:ok, reply}
        _error -> {:error, :transport}
      end
    end

    defp socket_push(_state, _channel, _event, _payload, _timeout),
      do: {:error, :transport}

    defp stop_socket(%{socket: nil} = state) do
      demonitor(state.channel_ref)
      %{state | channel: nil, channel_ref: nil}
    end

    defp stop_socket(state) do
      demonitor(state.socket_ref)
      demonitor(state.channel_ref)
      _result = invoke(state.socket_adapter, :stop, [state.socket])
      clear_transport_state(state)
    end

    defp clear_transport_state(state) do
      demonitor(state.channel_ref)
      %{state | socket: nil, socket_ref: nil, channel: nil, channel_ref: nil}
    end

    defp demonitor(nil), do: :ok

    defp demonitor(ref) do
      Process.demonitor(ref, [:flush])
      :ok
    end

    defp cancel_claim_timer(nil), do: :ok

    defp cancel_claim_timer(timer) do
      _result = Process.cancel_timer(timer)
      :ok
    end

    defp forward_socket_message(
           %Phoenix.SocketClient.Message{} = message,
           %{client: client, channel: channel}
         )
         when is_pid(client) and is_pid(channel) do
      send(client, %{message | channel_pid: channel})
    end

    defp forward_socket_message(
           {:yellow_dog_socket_message, channel, _event, _payload} = message,
           %{client: client, channel: channel}
         )
         when is_pid(client) and is_pid(channel) do
      send(client, message)
    end

    defp forward_socket_message(_message, _state), do: :ok

    defp invoke(module, function, arguments) do
      apply(module, function, arguments)
    rescue
      _exception -> :error
    catch
      _kind, _reason -> :error
    end

    defp credential_ref(state), do: {self(), state.capability}

    defp reply(caller, capability, ref, value),
      do: send(caller, {__MODULE__, capability, ref, value})
  end

  defmodule SocketChannel do
    @moduledoc false

    use Phoenix.SocketClient.Channel

    @impl true
    def handle_message(event, payload, state) do
      send(state.caller, {:yellow_dog_socket_message, self(), event, payload})
      {:noreply, state}
    end
  end

  defmodule Socket do
    @moduledoc false

    def start_link(opts) do
      # TODO(upstream): gsmlg-dev/phoenix_socket_client#103
      Phoenix.SocketClient.start_link(
        url: Keyword.fetch!(opts, :url),
        params: Keyword.fetch!(opts, :params),
        default_channel_module: YellowDog.ServerAgent.Client.SocketChannel,
        reconnect?: false,
        auto_connect: true
      )
    end

    def connected?(socket), do: Phoenix.SocketClient.connected?(socket)

    def join(socket, topic, params, timeout),
      do: Phoenix.SocketClient.Channel.join(socket, topic, params, timeout)

    def push(channel, event, payload, timeout),
      do: Phoenix.SocketClient.Channel.push(channel, event, payload, timeout)

    def stop(socket) do
      if Process.alive?(socket), do: Supervisor.stop(socket, :normal, 1_000)
      :ok
    catch
      :exit, _reason -> :ok
    end
  end

  defmodule Timer do
    @moduledoc false

    def send_after(destination, message, delay),
      do: Process.send_after(destination, message, delay)

    def cancel(ref), do: Process.cancel_timer(ref)
  end

  defmodule MonotonicClock do
    @moduledoc false

    def now, do: System.monotonic_time(:millisecond)
  end

  defmodule WallClock do
    @moduledoc false

    def now, do: DateTime.utc_now(:second)
  end
end
