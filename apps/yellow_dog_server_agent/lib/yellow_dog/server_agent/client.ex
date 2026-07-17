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
  alias YellowDog.ServerAgent.ConfigApplier
  alias YellowDog.ServerAgent.ConfigApplyStore
  alias YellowDog.ServerAgent.Dispatcher
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
  @enabled_options [
    :enabled,
    :name,
    :management_url,
    :token,
    :identity,
    :dispatcher,
    :dispatcher_runtime_adapter,
    :command_journal,
    :config_applier,
    :config_apply_store,
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
  @socket_callbacks [start_link: 1, connected?: 1, join: 4, push: 4, stop: 1]
  @timer_callbacks [send_after: 3, cancel: 1]
  @clock_callbacks [now: 0]
  @receipt_keys ~w(publication_sequence state_revision target_id target_type)
  @timer_keys [:check, :rejoin, :heartbeat, :status, :config]

  @type connection_state :: :disabled | :connecting | :handshaking | :active | :backoff

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, config, name} <- validate_options(opts) do
      case name do
        nil -> GenServer.start_link(__MODULE__, config)
        name -> GenServer.start_link(__MODULE__, config, name: name)
      end
    end
  end

  def start_link(_opts), do: {:error, :invalid_options}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: child_id(opts),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

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
        {:DOWN, ref, :process, pid, _reason},
        %{socket_ref: ref, socket: pid} = state
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

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{enabled: true} = state) do
    _state = cleanup_connection(state)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp start_socket(state) do
    {:noreply, next_state} = start_socket_reply(state)
    {:noreply, next_state}
  end

  defp start_socket_reply(state) do
    state = cleanup_connection(state)
    socket_opts = [url: state.config.url, params: state.config.socket_params.()]

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
    do: dispatch_inbound(envelope, state)

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
      _error -> schedule_config_retry(state)
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
      _error -> :error
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
    safe_apply(state.config.socket, :push, [
      state.channel,
      @event,
      payload,
      state.config.push_timeout
    ])
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
    Process.unlink(state.socket)
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

  defp validate_options(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- length(keys) == length(Enum.uniq(keys)),
         {:ok, enabled} <- enabled(Keyword.get(opts, :enabled)),
         {:ok, name} <- process_name(Keyword.get(opts, :name, __MODULE__)) do
      validate_mode(enabled, keys, opts, name)
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp validate_mode(false, keys, _opts, name) do
    if Enum.all?(keys, &(&1 in @disabled_options)),
      do: {:ok, %{enabled: false}, name},
      else: {:error, :invalid_options}
  end

  defp validate_mode(true, keys, opts, name) do
    with true <- Enum.all?(keys, &(&1 in @enabled_options)),
         {:ok, url} <- management_url(Keyword.get(opts, :management_url)),
         {:ok, token} <- token(Keyword.get(opts, :token)),
         {:ok, identity} <- identity(Keyword.get(opts, :identity)),
         {:ok, dispatcher} <-
           callback_module(Keyword.get(opts, :dispatcher, Dispatcher), dispatch: 2),
         {:ok, dispatcher_runtime_adapter} <-
           module(Keyword.get(opts, :dispatcher_runtime_adapter)),
         {:ok, command_journal} <- server_ref(Keyword.get(opts, :command_journal)),
         {:ok, config_applier} <- server_ref(Keyword.get(opts, :config_applier)),
         {:ok, config_apply_store} <- server_ref(Keyword.get(opts, :config_apply_store)),
         {:ok, socket} <- callback_module(Keyword.get(opts, :socket, Socket), @socket_callbacks),
         {:ok, timer} <- callback_module(Keyword.get(opts, :timer, Timer), @timer_callbacks),
         {:ok, monotonic_clock} <-
           callback_module(Keyword.get(opts, :monotonic_clock, MonotonicClock), @clock_callbacks),
         {:ok, wall_clock} <-
           callback_module(Keyword.get(opts, :wall_clock, WallClock), @clock_callbacks),
         {:ok, timings} <- timings(opts) do
      config =
        Map.merge(timings, %{
          enabled: true,
          url: url,
          socket_params: socket_params_provider(token, identity.id),
          identity: identity,
          dispatcher: dispatcher,
          dispatcher_runtime_adapter: dispatcher_runtime_adapter,
          command_journal: command_journal,
          config_applier: config_applier,
          config_apply_store: config_apply_store,
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
    with %URI{
           scheme: "https",
           host: host,
           userinfo: nil,
           query: nil,
           fragment: nil
         } = uri <- URI.parse(value),
         true <- is_binary(host) and host != "" do
      {:ok,
       URI.to_string(%{
         uri
         | scheme: "wss",
           path: "/server/ws/websocket",
           query: nil,
           fragment: nil
       })}
    else
      _invalid -> :error
    end
  end

  defp management_url(_value), do: :error

  defp token(value) do
    with {:ok, value} <- Bounds.message(value),
         true <- value != "" do
      {:ok, value}
    else
      _invalid -> :error
    end
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

  defp identity(_value), do: :error

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

  defp child_id(opts) when is_list(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> __MODULE__
      name -> name
    end
  rescue
    _exception -> __MODULE__
  end

  defp child_id(_opts), do: __MODULE__

  defp socket_params_provider(token, server_id) do
    fn -> %{"token" => token, "server_id" => server_id} end
  end

  defp empty_timers, do: %{check: nil, rejoin: nil, heartbeat: nil, status: nil, config: nil}

  defmodule Socket do
    @moduledoc false

    def start_link(opts) do
      Phoenix.SocketClient.start_link(
        url: Keyword.fetch!(opts, :url),
        params: Keyword.fetch!(opts, :params),
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
