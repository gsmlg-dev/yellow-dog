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
        node: atom()
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

  alias YellowDog.Store.Key

  @event_log_retention_seconds 86_400

  defstruct subscriptions: %{}, counter: 0

  # ── Public API ──────────────────────────────────────────────────

  @doc "Start the EventBridge process."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Subscribe to events matching a key pattern.

  Pattern uses `*` as wildcard suffix, e.g. `"dhcp:lease:*"`.
  The handler function receives event maps.

  Returns `{:ok, subscription_ref}`.
  """
  @spec subscribe(String.t(), (map() -> any())) :: {:ok, reference()}
  def subscribe(pattern, handler_fn) when is_binary(pattern) and is_function(handler_fn, 1) do
    GenServer.call(__MODULE__, {:subscribe, pattern, handler_fn})
  end

  @doc """
  Subscribe to events matching a key pattern (GenStage consumer mode).

  Returns `{:ok, pid}` of a consumer process that forwards events
  to the calling process as `{:store_event, event}` messages.
  """
  @spec subscribe(String.t()) :: {:ok, pid()}
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

    case Concord.prefix_scan(prefix, consistency: :eventual) do
      {:ok, entries} ->
        events =
          entries
          |> Enum.map(fn {_key, value} -> value end)
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

    :telemetry.execute(
      [:yellow_dog, :store, :event, :dispatched],
      %{count: 1},
      %{key: key, type: type}
    )

    :ok
  end

  # ── GenServer Callbacks ─────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:subscribe, pattern, handler_fn}, _from, state) do
    ref = make_ref()

    subscription = %{
      pattern: pattern,
      handler: {:fn, handler_fn},
      ref: ref
    }

    new_state = %{state | subscriptions: Map.put(state.subscriptions, ref, subscription)}
    {:reply, {:ok, ref}, new_state}
  end

  def handle_call({:subscribe_pid, pattern, pid}, _from, state) do
    ref = make_ref()

    subscription = %{
      pattern: pattern,
      handler: {:pid, pid},
      ref: ref
    }

    new_state = %{state | subscriptions: Map.put(state.subscriptions, ref, subscription)}
    {:reply, {:ok, ref}, new_state}
  end

  @impl true
  def handle_cast({:unsubscribe, ref}, state) do
    {:noreply, %{state | subscriptions: Map.delete(state.subscriptions, ref)}}
  end

  def handle_cast({:dispatch, event}, state) do
    Enum.each(state.subscriptions, fn {_ref, sub} ->
      if matches_pattern?(event.key, sub.pattern) do
        dispatch_to_handler(sub.handler, event)
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────

  defp dispatch_to_handler({:fn, fun}, event) do
    Task.start(fn ->
      try do
        fun.(event)
      rescue
        e -> Logger.warning("EventBridge handler error: #{inspect(e)}")
      end
    end)
  end

  defp dispatch_to_handler({:pid, pid}, event) do
    send(pid, {:store_event, event})
  end

  defp matches_pattern?(key, pattern) do
    case String.split(pattern, "*", parts: 2) do
      [prefix, ""] -> String.starts_with?(key, prefix)
      [exact] -> key == exact
      _ -> false
    end
  end

  defp persist_event(event) do
    Task.start(fn ->
      key = Key.event_log(event.timestamp, event.key)

      Concord.put(key, event, ttl: @event_log_retention_seconds)
    end)
  end
end
