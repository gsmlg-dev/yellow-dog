defmodule YellowDog.NetmanAgent.Client do
  @moduledoc """
  Typed outbound management connection for one concrete Netman agent.

  The client owns transport generations and reconnect timing. Local command
  durability remains owned by `CommandJournal`; configuration application and
  publication replay remain owned by `ConfigApplier` and `ConfigApplyStore`.
  """

  use GenServer

  alias YellowDog.NetmanAgent.CommandJournal
  alias YellowDog.NetmanAgent.ConfigApplier
  alias YellowDog.NetmanAgent.ConfigApplyStore
  alias YellowDog.NetmanAgent.RollbackTimer
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Identity.Netman
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.Command
  alias YellowDog.Sync.Message.ConfigDelivery
  alias YellowDog.Sync.Message.ConfigState
  alias YellowDog.Sync.Message.Heartbeat
  alias YellowDog.Sync.Message.Hello
  alias YellowDog.Sync.Message.Journal
  alias YellowDog.Sync.Message.Query
  alias YellowDog.Sync.Message.Result
  alias YellowDog.Sync.Message.Status

  @event "sync"
  @disabled_options [:enabled, :name]
  @enabled_options [
    :enabled,
    :name,
    :management_url,
    :token,
    :identity,
    :dispatcher,
    :dispatcher_runtime_adapter,
    :query_dispatcher,
    :query_runtime_adapter,
    :command_journal,
    :config_store,
    :config_applier,
    :config_apply_store,
    :rollback_timer,
    :socket,
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
  @max_timer_ms 4_294_967_295
  @token_key {__MODULE__, :management_token}

  @type connection_state :: :disabled | :connecting | :handshaking | :active | :backoff

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, config, name} <- validate_options(opts, &live_server_ref/1) do
      start_client(config, name)
    end
  end

  def start_link(_opts), do: {:error, :invalid_options}

  defp start_client(config, nil), do: GenServer.start_link(__MODULE__, config)
  defp start_client(config, name), do: GenServer.start_link(__MODULE__, config, name: name)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    case validate_options(opts, &child_server_ref/1) do
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

  @impl true
  def init(%{enabled: false}) do
    {:ok, %{enabled: false, status: :disabled}}
  end

  def init(config) do
    Process.flag(:trap_exit, true)
    Process.flag(:sensitive, true)
    Process.put(@token_key, config.token)
    config = Map.delete(config, :token)

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
       config_apply: nil,
       queued_config: nil,
       timers: empty_timers()
     }, {:continue, :connect}}
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
    {_reply, next_state} = start_socket_reply(state)
    {:noreply, next_state}
  end

  def handle_info({:rejoin, _old_attempt}, state), do: {:noreply, state}

  def handle_info({:heartbeat, generation}, %{status: :active, generation: generation} = state) do
    state = clear_timer(state, :heartbeat)
    {:noreply, publish_periodic(heartbeat_message(state), :heartbeat, state)}
  end

  def handle_info({:heartbeat, _old_generation}, state), do: {:noreply, state}

  def handle_info({:status, generation}, %{status: :active, generation: generation} = state) do
    state = clear_timer(state, :status)

    state =
      case push_message(status_message(state), state) do
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
        {:config_apply_result, ref, worker, result},
        %{config_apply: %{ref: ref, worker: worker, monitor: monitor}} = state
      ) do
    Process.demonitor(monitor, [:flush])

    state =
      state
      |> Map.put(:config_apply, nil)
      |> complete_config_apply(result)
      |> start_queued_config()

    {:noreply, state}
  end

  def handle_info({:config_apply_result, _ref, _worker, _result}, state),
    do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %{config_apply: %{monitor: monitor, worker: worker}} = state
      ) do
    state =
      state
      |> Map.put(:config_apply, nil)
      |> flush_config_publications()
      |> start_queued_config()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{socket_ref: ref} = state) do
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

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{enabled: true} = state) do
    _state = cleanup_connection(state)
    Process.delete(@token_key)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_socket(state) do
    {_reply, next_state} = start_socket_reply(state)
    {:noreply, next_state}
  end

  defp start_socket_reply(state) do
    state = cleanup_connection(state)

    socket_opts = [
      url: state.config.endpoint,
      params: %{
        "token" => management_token(),
        "netman_id" => state.config.identity.id
      }
    ]

    case safe_apply(state.config.socket, :start_link, [socket_opts]) do
      {:ok, socket} when is_pid(socket) ->
        connection_id = state.connection_id + 1

        state = %{
          state
          | status: :connecting,
            socket: socket,
            socket_ref: Process.monitor(socket),
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
        state = %{state | channel: channel, channel_ref: Process.monitor(channel)}

        case handshake(state) do
          :ok -> activate(state)
          :error -> schedule_rejoin(state)
        end

      :error ->
        schedule_rejoin(state)
    end
  end

  defp socket_join(state) do
    topic = "netman:control:" <> state.config.identity.id

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
    with :ok <- push_message(%Hello{identity: state.config.identity}, state),
         :ok <- push_message(status_message(state), state) do
      :ok
    else
      _error -> :error
    end
  end

  defp activate(state) do
    state =
      state
      |> Map.merge(%{status: :active, attempt: 0})
      |> schedule_periodic(:heartbeat)
      |> schedule_periodic(:status)
      |> upload_journal()

    activate_after_journal(state)
  end

  defp activate_after_journal(%{status: :active} = state) do
    case confirm_provisional(state) do
      {:ok, publications} ->
        publications
        |> flush_publications(state)
        |> flush_config_publications()

      :error ->
        schedule_rejoin(state)
    end
  end

  defp activate_after_journal(state), do: state

  defp confirm_provisional(state) do
    case local_call(fn -> RollbackTimer.confirm(state.config.rollback_timer) end) do
      {:ok, :idle} -> {:ok, []}
      {:ok, %{publications: publications}} when is_list(publications) -> {:ok, publications}
      _error_or_malformed -> :error
    end
  end

  defp upload_journal(%{status: :active} = state) do
    case local_call(fn -> CommandJournal.wire_projection(state.config.command_journal) end) do
      {:ok,
       %Journal{
         target_type: :netman,
         target_id: target_id
       } = journal}
      when target_id == state.config.identity.id ->
        case push_message(journal, state) do
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

  defp inbound_identity(%Command{envelope: envelope}, netman_id),
    do: envelope_identity(envelope, netman_id)

  defp inbound_identity(%Query{envelope: envelope}, netman_id),
    do: envelope_identity(envelope, netman_id)

  defp inbound_identity(%ConfigDelivery{envelope: envelope}, netman_id),
    do: envelope_identity(envelope, netman_id)

  defp inbound_identity(_unsupported, _netman_id), do: :error

  defp envelope_identity(%{target_type: :netman, target_id: netman_id}, netman_id), do: :ok
  defp envelope_identity(_envelope, _netman_id), do: :error

  defp route_inbound(%Command{envelope: envelope}, state),
    do: dispatch_command(envelope, state)

  defp route_inbound(%Query{envelope: envelope}, state),
    do: dispatch_query(envelope, state)

  defp route_inbound(%ConfigDelivery{envelope: envelope}, state),
    do: enqueue_config_apply(envelope, state)

  defp enqueue_config_apply(envelope, %{config_apply: nil} = state),
    do: start_config_apply(envelope, state)

  defp enqueue_config_apply(envelope, state) do
    current_version = state.config_apply.version
    queued_version = if state.queued_config, do: state.queued_config.config_version, else: 0

    if envelope.config_version > max(current_version, queued_version) do
      %{state | queued_config: envelope}
    else
      state
    end
  end

  defp start_config_apply(envelope, state) do
    owner = self()
    ref = make_ref()
    config_applier = state.config.config_applier

    {worker, monitor} =
      spawn_monitor(fn ->
        result = local_call(fn -> ConfigApplier.apply(envelope, config_applier) end)
        send(owner, {:config_apply_result, ref, self(), result})
      end)

    %{
      state
      | config_apply: %{
          ref: ref,
          worker: worker,
          monitor: monitor,
          version: envelope.config_version
        },
        queued_config: nil
    }
  end

  defp start_queued_config(%{config_apply: nil, queued_config: nil} = state), do: state

  defp start_queued_config(%{config_apply: nil, queued_config: envelope} = state),
    do: start_config_apply(envelope, state)

  defp start_queued_config(state), do: state

  defp complete_config_apply(%{status: :active} = state, result) do
    case result do
      {:ok, %{status: status, publications: publications}}
      when status in [:applied, :failed, :provisional, :replay] and is_list(publications) ->
        state = flush_publications(publications, state)

        if status == :provisional and state.status == :active,
          do: schedule_rejoin(state),
          else: state

      _error_or_malformed ->
        flush_config_publications(state)
    end
  end

  defp complete_config_apply(state, _result), do: state

  defp dispatch_command(envelope, state) do
    result =
      local_call(fn ->
        state.config.dispatcher.dispatch(envelope, dispatcher_options(state))
      end)

    publish_result(envelope, result, state)
  end

  defp dispatcher_options(state) do
    [
      netman_id: state.config.identity.id,
      capabilities: state.config.identity.capabilities,
      command_journal: state.config.command_journal,
      runtime_adapter: state.config.dispatcher_runtime_adapter
    ]
  end

  defp dispatch_query(envelope, state) do
    result =
      local_call(fn ->
        state.config.query_dispatcher.dispatch(envelope, query_dispatcher_options(state))
      end)

    publish_result(envelope, result, state)
  end

  defp query_dispatcher_options(state) do
    [
      netman_id: state.config.identity.id,
      capabilities: state.config.identity.capabilities,
      runtime_adapter: state.config.query_runtime_adapter
    ]
  end

  defp publish_result(envelope, result, state) do
    message = result_message(envelope, result)

    case push_message(message, state) do
      :ok -> state
      :error -> schedule_rejoin(state)
    end
  end

  defp result_message(envelope, {:ok, value}) when is_map(value) do
    %Result{
      request_id: envelope.request_id,
      target_type: :netman,
      operation: envelope.operation,
      value: value,
      error: nil
    }
  end

  defp result_message(envelope, {:error, %Error{} = error}) do
    %Result{
      request_id: envelope.request_id,
      target_type: :netman,
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

  defp config_state_identity(%ConfigState{target_type: :netman, target_id: netman_id}, netman_id),
    do: :ok

  defp config_state_identity(_message, _netman_id), do: :error

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

  defp validate_receipt(receipt, publication, netman_id) do
    expected = %{
      "target_type" => "netman",
      "target_id" => netman_id,
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

  defp state_revision(%ConfigState{state: :failed, failure: %{"phase" => phase}})
       when phase in ["apply", "rollback"],
       do: 3

  defp state_revision(_message), do: nil

  defp push_message(message, state) do
    with {:ok, encoded} <- Message.encode(message),
         {:ok, ^message} <- Message.decode(encoded),
         {:ok, %{"accepted" => true} = reply} <-
           socket_push(%{"message" => encoded, "publication_sequence" => nil}, state),
         true <- map_size(reply) == 1 do
      :ok
    else
      _error -> :error
    end
  end

  defp socket_push(payload, state) do
    safe_apply(state.config.socket, :push, [
      state.channel,
      @event,
      payload,
      state.config.push_timeout
    ])
  end

  defp publish_periodic(message, timer_key, state) do
    case push_message(message, state) do
      :ok -> schedule_periodic(state, timer_key)
      :error -> schedule_rejoin(state)
    end
  end

  defp heartbeat_message(state) do
    %Heartbeat{
      target_type: :netman,
      target_id: state.config.identity.id,
      observed_at: wall_now(state)
    }
  end

  defp status_message(state) do
    identity = state.config.identity
    config_runtime = config_runtime(state)

    %Status{
      target_type: :netman,
      target_id: identity.id,
      state: status_state(config_runtime.runtime_status),
      details: %{
        "capabilities" => identity.capabilities,
        "config_revision" => config_runtime.revision,
        "config_runtime_status" => Atom.to_string(config_runtime.runtime_status),
        "profile" => identity.profile,
        "version" => identity.version
      },
      observed_at: wall_now(state)
    }
  end

  defp config_runtime(state) do
    fallback = %{
      runtime_status: :unavailable,
      revision: state.config.identity.config_revision
    }

    case local_call(fn -> ConfigApplyStore.snapshot(state.config.config_apply_store) end) do
      {:ok, %{runtime_status: runtime_status, known_good: known_good}}
      when runtime_status in [:unconfigured, :known, :unknown] ->
        %{
          runtime_status: runtime_status,
          revision: known_good_revision(known_good, fallback.revision)
        }

      _unavailable ->
        fallback
    end
  end

  defp known_good_revision(%{revision: revision}, _fallback) when is_binary(revision),
    do: revision

  defp known_good_revision(_known_good, fallback), do: fallback

  defp status_state(:unknown), do: :degraded
  defp status_state(_runtime_status), do: :online

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
         {:ok, endpoint} <- management_url(Keyword.get(opts, :management_url)),
         {:ok, token} <- token(Keyword.get(opts, :token)),
         {:ok, identity} <- identity(Keyword.get(opts, :identity)),
         {:ok, dispatcher} <- callback_module(Keyword.get(opts, :dispatcher), dispatch: 2),
         {:ok, dispatcher_runtime_adapter} <-
           module(Keyword.get(opts, :dispatcher_runtime_adapter)),
         {:ok, query_dispatcher} <-
           callback_module(Keyword.get(opts, :query_dispatcher), dispatch: 2),
         {:ok, query_runtime_adapter} <-
           module(Keyword.get(opts, :query_runtime_adapter)),
         {:ok, command_journal} <-
           server_ref_validator.(Keyword.get(opts, :command_journal)),
         {:ok, config_store} <- server_ref_validator.(Keyword.get(opts, :config_store)),
         {:ok, config_applier} <- server_ref_validator.(Keyword.get(opts, :config_applier)),
         {:ok, config_apply_store} <-
           server_ref_validator.(Keyword.get(opts, :config_apply_store)),
         {:ok, rollback_timer} <-
           server_ref_validator.(Keyword.get(opts, :rollback_timer)),
         {:ok, socket} <- callback_module(Keyword.get(opts, :socket), @socket_callbacks),
         {:ok, timer} <- callback_module(Keyword.get(opts, :timer), @timer_callbacks),
         {:ok, monotonic_clock} <-
           callback_module(Keyword.get(opts, :monotonic_clock), @clock_callbacks),
         {:ok, wall_clock} <-
           callback_module(Keyword.get(opts, :wall_clock), @clock_callbacks),
         {:ok, timings} <- timings(opts) do
      config =
        Map.merge(timings, %{
          enabled: true,
          endpoint: endpoint,
          token: token,
          identity: identity,
          dispatcher: dispatcher,
          dispatcher_runtime_adapter: dispatcher_runtime_adapter,
          query_dispatcher: query_dispatcher,
          query_runtime_adapter: query_runtime_adapter,
          command_journal: command_journal,
          config_store: config_store,
          config_applier: config_applier,
          config_apply_store: config_apply_store,
          rollback_timer: rollback_timer,
          socket: socket,
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
         path: "/netman/ws/websocket"
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

  defp management_token, do: Process.get(@token_key)

  defp identity(%Netman{} = identity) do
    message = %Hello{identity: identity}
    identity_id = identity.id

    with {:ok, ^identity_id} <- netman_id(identity_id),
         true <- identity.capabilities == Enum.uniq(identity.capabilities),
         {:ok, encoded} <- Message.encode(message),
         {:ok, ^message} <- Message.decode(encoded) do
      {:ok, identity}
    else
      _invalid -> :error
    end
  end

  defp identity(_value), do: :error

  defp netman_id(value) do
    with {:ok, value} <- Bounds.id(value),
         true <- value != "",
         true <- value not in [".", ".."],
         false <- String.contains?(value, ["/", "\\"]),
         false <- Regex.match?(~r/\A[A-Za-z]:/, value),
         normalized when is_binary(normalized) <- :unicode.characters_to_nfkc_binary(value),
         true <- normalized == value,
         false <- Regex.match?(~r/\p{C}/u, value) do
      {:ok, value}
    else
      _invalid -> :error
    end
  rescue
    _exception -> :error
  end

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

  defp live_server_ref(value) do
    case GenServer.whereis(value) do
      pid when is_pid(pid) -> {:ok, value}
      _missing -> :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp child_server_ref(value) when is_pid(value) do
    if Process.alive?(value), do: {:ok, value}, else: :error
  end

  defp child_server_ref(value) when is_atom(value) and not is_nil(value), do: {:ok, value}
  defp child_server_ref({:global, _term} = value), do: {:ok, value}

  defp child_server_ref({:via, module, _term} = value)
       when is_atom(module) and not is_nil(module),
       do: {:ok, value}

  defp child_server_ref({name, node} = value)
       when is_atom(name) and not is_nil(name) and is_atom(node) and not is_nil(node),
       do: {:ok, value}

  defp child_server_ref(_value), do: :error

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
        value when is_integer(value) and value > 0 and value <= @max_timer_ms ->
          {:cont, {:ok, Map.put(values, key, value)}}

        _invalid ->
          {:halt, :error}
      end
    end)
  end

  defp child_id(nil), do: __MODULE__
  defp child_id(name), do: name

  defp empty_timers, do: %{check: nil, rejoin: nil, heartbeat: nil, status: nil, config: nil}

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
        default_channel_module: YellowDog.NetmanAgent.Client.SocketChannel,
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
