defmodule YellowDog.Store.EventBridge do
  @moduledoc """
  Event stream dispatcher for Store state changes.

  Bridges Concord's GenStage event stream to YellowDog consumers.
  Provides pattern-based subscriptions and durable event replay
  from Concord's event log.

  ## Event Format

      %{
        type: :put | :delete,
        key: String.t(),
        value: term() | nil,
        timestamp: integer(),
        node: atom(),
        operation_id: String.t() | nil,
        cursor: non_neg_integer() | nil
      }

  ## Usage

      # Subscribe with callback
      {:ok, ref} = EventBridge.subscribe("dhcp:lease:*", fn event ->
        handle_lease_event(event)
      end)

      # Subscribe for GenStage (returns consumer spec)
      {:ok, consumer} = EventBridge.subscribe("rpz:*")

      # Replay missed events
      {:ok, events} = EventBridge.replay("dhcp:lease:*", since_timestamp)
  """

  use GenServer
  require Logger

  alias YellowDog.Store.{Backend, Key}

  @event_log_retention_seconds 86_400
  @durable_event_version 1
  @durable_retry_ms 1_000

  defstruct subscriptions: %{},
            monitors: %{},
            counter: 0,
            pending_durable: %{},
            retry_scheduled: false

  # ── Public API ──────────────────────────────────────────────────

  @doc "Start the EventBridge process."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe to events matching a key pattern.

  Pattern uses `*` as a **trailing** wildcard only, e.g. `"dhcp:lease:*"`.
  Patterns like `"dhcp:*:v4"` (wildcard in the middle) are NOT supported.
  The handler function receives event maps.

  Returns `{:ok, subscription_ref}`.
  """
  @spec subscribe(String.t(), (map() -> any())) :: {:ok, reference()}
  def subscribe(pattern, handler_fn) when is_binary(pattern) and is_function(handler_fn, 1) do
    GenServer.call(__MODULE__, {:subscribe, pattern, handler_fn})
  end

  @doc """
  Subscribe to events matching a key pattern (pid-forwarding mode).

  Returns `{:ok, reference()}`. Events matching the pattern are sent
  to the calling process as `{:store_event, event}` messages.
  """
  @spec subscribe(String.t()) :: {:ok, reference()}
  def subscribe(pattern) when is_binary(pattern) do
    subscriber = self()
    GenServer.call(__MODULE__, {:subscribe_pid, pattern, subscriber})
  end

  @doc """
  Unsubscribe from events.
  """
  @spec unsubscribe(reference()) :: :ok
  def unsubscribe(ref) do
    GenServer.cast(__MODULE__, {:unsubscribe, ref})
  end

  @doc """
  Replay durable events from Concord's event log since the given timestamp.

  Returns events matching the pattern that occurred after `since_timestamp`.
  """
  @spec replay(String.t(), integer()) :: {:ok, [map()]}
  def replay(pattern, since_timestamp) when is_binary(pattern) and is_integer(since_timestamp) do
    prefix = Key.event_log_prefix()

    case Backend.active().prefix_scan(prefix, consistency: :eventual) do
      {:ok, entries} ->
        events =
          entries
          |> Enum.flat_map(fn {_key, value} -> event_from_log_value(value) end)
          |> Enum.filter(fn event ->
            event.timestamp >= since_timestamp and matches_pattern?(event.key, pattern)
          end)
          |> Enum.sort_by(& &1.timestamp)

        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Publish a state change event. Called by Store facade modules after mutations.

  Persists the event to the durable log and dispatches to subscribers.
  """
  @spec notify(atom(), String.t(), term()) :: :ok
  def notify(type, key, value) when type in [:put, :delete] do
    event = %{
      type: type,
      key: key,
      value: value,
      timestamp: System.system_time(:microsecond),
      node: node()
    }

    # Persist to durable event log (fire-and-forget)
    persist_event(event)

    # Dispatch to subscribers
    GenServer.cast(__MODULE__, {:dispatch, event})

    :ok
  end

  @doc false
  @spec notify_durable(
          module(),
          String.t(),
          non_neg_integer(),
          :put | :delete,
          String.t(),
          term()
        ) :: :ok | {:error, term()}
  def notify_durable(backend, operation_id, cursor, type, key, value)
      when is_atom(backend) and is_binary(operation_id) and is_integer(cursor) and cursor >= 0 and
             type in [:put, :delete] and is_binary(key) do
    notify_durable(backend, operation_id, cursor, type, key, value, [])
  end

  @doc false
  @spec notify_durable(
          module(),
          String.t(),
          non_neg_integer(),
          :put | :delete,
          String.t(),
          term(),
          keyword()
        ) :: :ok | {:error, term()}
  def notify_durable(backend, operation_id, cursor, type, key, value, opts)
      when is_atom(backend) and is_binary(operation_id) and is_integer(cursor) and cursor >= 0 and
             type in [:put, :delete] and is_binary(key) and is_list(opts) do
    event_key = Key.zone_replacement_event(operation_id, cursor)
    delivery = Keyword.get(opts, :delivery, :subscriber)

    event = %{
      type: type,
      key: key,
      value: value,
      timestamp: System.system_time(:microsecond),
      node: node(),
      operation_id: operation_id,
      cursor: cursor
    }

    if delivery in [:subscriber, :audit] do
      record = %{
        version: @durable_event_version,
        event: event,
        delivery: delivery,
        dispatch_state: :pending
      }

      persist_durable_event(backend, event_key, record)
    else
      {:error, :invalid_delivery}
    end
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}, {:continue, :load_durable_events}}
  end

  @impl true
  def handle_continue(:load_durable_events, state) do
    {:noreply, load_durable_events(state)}
  end

  @impl true
  def handle_call({:subscribe, pattern, handler_fn}, _from, state) do
    ref = make_ref()

    subscription = %{
      pattern: pattern,
      handler: {:fn, handler_fn},
      ref: ref
    }

    new_state =
      state
      |> Map.put(:subscriptions, Map.put(state.subscriptions, ref, subscription))
      |> request_pending_dispatch()

    {:reply, {:ok, ref}, new_state}
  end

  @impl true
  def handle_call({:subscribe_pid, pattern, pid}, _from, state) do
    ref = make_ref()
    mon_ref = Process.monitor(pid)

    subscription = %{
      pattern: pattern,
      handler: {:pid, pid},
      ref: ref
    }

    new_state = %{
      state
      | subscriptions: Map.put(state.subscriptions, ref, subscription),
        monitors: Map.put(state.monitors, mon_ref, {ref, pid})
    }

    {:reply, {:ok, ref}, request_pending_dispatch(new_state)}
  end

  @impl true
  def handle_cast({:unsubscribe, ref}, state) do
    # Clean up any associated monitor
    {mon_ref, monitors} =
      Enum.reduce(state.monitors, {nil, state.monitors}, fn {m_ref, {s_ref, _pid}},
                                                            {found, acc} ->
        if s_ref == ref, do: {m_ref, Map.delete(acc, m_ref)}, else: {found, acc}
      end)

    if mon_ref, do: Process.demonitor(mon_ref, [:flush])

    {:noreply, %{state | subscriptions: Map.delete(state.subscriptions, ref), monitors: monitors}}
  end

  def handle_cast({:dispatch, event}, state) do
    dispatch_event(state, event)
    {:noreply, state}
  end

  def handle_cast({:dispatch_durable, entry}, state) do
    state = put_pending_entry(state, entry)
    {:noreply, dispatch_pending_key(state, entry.event_key)}
  end

  @impl true
  def handle_info(:dispatch_pending, state) do
    {:noreply, dispatch_pending(state)}
  end

  def handle_info(:retry_durable_events, state) do
    {:noreply, state |> Map.put(:retry_scheduled, false) |> dispatch_pending()}
  end

  def handle_info(:reload_durable_events, state) do
    {:noreply, load_durable_events(state)}
  end

  def handle_info({:DOWN, mon_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, mon_ref) do
      {{sub_ref, _pid}, monitors} ->
        {:noreply,
         %{state | subscriptions: Map.delete(state.subscriptions, sub_ref), monitors: monitors}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────

  defp handler_id({:fn, _fun}), do: :anonymous
  defp handler_id({:pid, pid}), do: pid

  defp dispatch_to_handler({:fn, fun}, event) do
    Task.Supervisor.start_child(YellowDog.Store.TaskSupervisor, fn ->
      try do
        fun.(event)
      rescue
        e -> Logger.warning("EventBridge handler error: #{inspect(e)}")
      end
    end)
  end

  defp dispatch_to_handler({:pid, pid}, event) do
    send(pid, {:store_event, event})
    :ok
  end

  defp matches_pattern?(key, pattern) do
    case String.split(pattern, "*", parts: 2) do
      [prefix, ""] -> String.starts_with?(key, prefix)
      [exact] -> key == exact
      _ -> false
    end
  end

  defp persist_durable_event(backend, event_key, record) do
    case backend.put_if(event_key, record, expected: nil) do
      :ok ->
        queue_durable_event(backend, event_key, record, record)

      {:error, reason} ->
        resolve_durable_event(backend, event_key, record, reason)

      _invalid_result ->
        resolve_durable_event(backend, event_key, record, :invalid_result)
    end
  end

  defp resolve_durable_event(backend, event_key, expected, write_reason) do
    case backend.get(event_key, consistency: :strong) do
      {:ok, stored} ->
        with {:ok, persisted} <- normalize_durable_record(stored),
             true <- same_durable_event?(persisted, expected) do
          if persisted.dispatch_state == :dispatched,
            do: :ok,
            else: queue_durable_event(backend, event_key, stored, persisted)
        else
          _mismatch -> {:error, :event_conflict}
        end

      {:error, :not_found} ->
        {:error, {:event_persist_failed, write_reason}}

      {:error, reason} ->
        {:error, {:event_read_failed, reason}}

      _invalid_result ->
        {:error, {:event_read_failed, :invalid_result}}
    end
  end

  defp same_durable_event?(persisted, expected) do
    fields = [:type, :key, :value, :operation_id, :cursor]

    Map.take(persisted.event, fields) == Map.take(expected.event, fields) and
      persisted.delivery == expected.delivery
  end

  defp queue_durable_event(backend, event_key, stored, record) do
    entry = %{backend: backend, event_key: event_key, stored: stored, record: record}
    GenServer.cast(__MODULE__, {:dispatch_durable, entry})
    :ok
  end

  defp load_durable_events(state) do
    backend = Backend.active()

    case scan_durable_events(backend) do
      {:ok, entries} ->
        state =
          Enum.reduce(entries, %{state | pending_durable: %{}}, fn {event_key, stored}, acc ->
            case normalize_durable_record(stored) do
              {:ok, %{dispatch_state: :pending} = record} ->
                put_pending_entry(acc, %{
                  backend: backend,
                  event_key: event_key,
                  stored: stored,
                  record: record
                })

              {:ok, %{dispatch_state: :dispatched}} ->
                %{acc | pending_durable: Map.delete(acc.pending_durable, event_key)}

              {:error, reason} ->
                Logger.warning(
                  "EventBridge durable event #{inspect(event_key)} is invalid: #{inspect(reason)}"
                )

                acc
            end
          end)

        request_pending_dispatch(state)

      {:error, reason} ->
        Logger.warning("EventBridge durable replay scan failed: #{inspect(reason)}")
        Process.send_after(self(), :reload_durable_events, @durable_retry_ms)
        state
    end
  end

  defp scan_durable_events(backend) do
    backend.prefix_scan(Key.zone_replacement_event_prefix(), consistency: :strong)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp normalize_durable_record(
         %{
           version: @durable_event_version,
           event: event,
           delivery: delivery,
           dispatch_state: dispatch_state
         } = record
       )
       when delivery in [:subscriber, :audit] and dispatch_state in [:pending, :dispatched] do
    if valid_durable_event?(event), do: {:ok, record}, else: {:error, :invalid_event}
  end

  defp normalize_durable_record(event) when is_map(event) do
    if valid_durable_event?(event) do
      {:ok,
       %{
         version: @durable_event_version,
         event: event,
         delivery: delivery_for_event(event),
         dispatch_state: :pending
       }}
    else
      {:error, :invalid_event}
    end
  end

  defp normalize_durable_record(_stored), do: {:error, :invalid_record}

  defp valid_durable_event?(event) do
    is_map(event) and event[:type] in [:put, :delete] and is_binary(event[:key]) and
      is_integer(event[:timestamp]) and is_atom(event[:node]) and
      is_binary(event[:operation_id]) and is_integer(event[:cursor]) and event[:cursor] >= 0
  end

  defp delivery_for_event(%{cursor: 0, key: key}) do
    if String.starts_with?(key, Key.zone_replacement_header_prefix()),
      do: :audit,
      else: :subscriber
  end

  defp delivery_for_event(_event), do: :subscriber

  defp event_from_log_value(%{version: @durable_event_version} = stored) do
    case normalize_durable_record(stored) do
      {:ok, %{event: event}} -> [event]
      {:error, _reason} -> []
    end
  end

  defp event_from_log_value(%{type: type, key: key, timestamp: timestamp} = event)
       when type in [:put, :delete] and is_binary(key) and is_integer(timestamp),
       do: [event]

  defp event_from_log_value(_value), do: []

  defp request_pending_dispatch(state) do
    send(self(), :dispatch_pending)
    state
  end

  defp put_pending_entry(state, entry) do
    %{state | pending_durable: Map.put(state.pending_durable, entry.event_key, entry)}
  end

  defp dispatch_pending(state) do
    Enum.reduce(Map.keys(state.pending_durable), state, &dispatch_pending_key(&2, &1))
  end

  defp dispatch_pending_key(state, event_key) do
    case Map.get(state.pending_durable, event_key) do
      nil ->
        state

      %{record: %{delivery: :audit}} = entry ->
        acknowledge_pending(state, entry)

      %{record: %{event: event}} = entry ->
        matching =
          Enum.filter(state.subscriptions, fn {_ref, subscription} ->
            matches_pattern?(event.key, subscription.pattern)
          end)

        case dispatch_subscriptions(matching, event) do
          :no_subscribers -> state
          :ok -> acknowledge_pending(state, entry)
          {:error, _reason} -> schedule_durable_retry(state)
        end
    end
  end

  defp dispatch_subscriptions([], _event), do: :no_subscribers

  defp dispatch_subscriptions(subscriptions, event) do
    Enum.reduce_while(subscriptions, :ok, fn {_ref, subscription}, :ok ->
      case dispatch_subscription(subscription, event) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp dispatch_event(state, event) do
    Enum.each(state.subscriptions, fn {_ref, subscription} ->
      if matches_pattern?(event.key, subscription.pattern),
        do: dispatch_subscription(subscription, event)
    end)
  end

  defp dispatch_subscription(subscription, event) do
    case dispatch_to_handler(subscription.handler, event) do
      :ok ->
        emit_dispatch_telemetry(subscription, event)
        :ok

      {:ok, _pid} ->
        emit_dispatch_telemetry(subscription, event)
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  defp emit_dispatch_telemetry(subscription, event) do
    :telemetry.execute(
      [:yellow_dog, :store, :event, :dispatched],
      %{count: 1},
      %{
        key: event.key,
        pattern: subscription.pattern,
        consumer: handler_id(subscription.handler)
      }
    )
  end

  defp acknowledge_pending(state, entry) do
    dispatched =
      entry.record
      |> Map.put(:dispatch_state, :dispatched)
      |> Map.put(:dispatched_at, System.system_time(:microsecond))

    spec = %{
      compare: [{:value, entry.event_key, :==, entry.stored}],
      success: [
        {:put, entry.event_key, dispatched, %{ttl: @event_log_retention_seconds}}
      ],
      failure: []
    }

    result = entry.backend.txn(spec, [])

    if acknowledgement_committed?(entry, result) do
      %{state | pending_durable: Map.delete(state.pending_durable, entry.event_key)}
    else
      schedule_durable_retry(state)
    end
  end

  defp acknowledgement_committed?(_entry, {:ok, %{succeeded: true}}), do: true

  defp acknowledgement_committed?(entry, _unknown) do
    case entry.backend.get(entry.event_key, consistency: :strong) do
      {:ok, stored} ->
        case normalize_durable_record(stored) do
          {:ok, %{dispatch_state: :dispatched} = record} ->
            same_durable_event?(record, entry.record)

          _pending_or_invalid ->
            false
        end

      _read_failure ->
        false
    end
  end

  defp schedule_durable_retry(%{retry_scheduled: true} = state), do: state

  defp schedule_durable_retry(state) do
    Process.send_after(self(), :retry_durable_events, @durable_retry_ms)
    %{state | retry_scheduled: true}
  end

  defp persist_event(event) do
    Task.Supervisor.start_child(YellowDog.Store.TaskSupervisor, fn ->
      key = Key.event_log(event.timestamp, event.key)

      try do
        Backend.active().put(key, event, ttl: @event_log_retention_seconds)
      rescue
        ArgumentError -> :ok
      end
    end)
  end
end
