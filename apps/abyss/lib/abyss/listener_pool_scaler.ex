defmodule Abyss.ListenerPoolScaler do
  @moduledoc """
  Dynamically scales the number of listener processes based on load.

  Started by `Abyss.Server` when the server is configured with
  `dynamic_listeners: true` (unicast mode only — broadcast mode always uses a
  single listener). Every `scale_check_interval` (default 30s) the scaler:

  1. Reads the number of active handler processes from the connection
     supervisor
  2. Reads the average response time from `[:abyss, :metrics, :response_time]`
     telemetry events emitted by this server's handler module
  3. Computes the optimal listener count via
     `Abyss.ServerConfig.calculate_optimal_listeners/2`, clamped to
     `min_listeners`..`max_listeners`
  4. Starts or stops listeners when the optimal count falls outside the
     hysteresis band derived from `listener_scale_threshold`

  ## Hysteresis

  With `listener_scale_threshold: 0.8` (default), the pool scales down when
  the optimal count falls below 80% of the current count, and scales up when
  it exceeds 120% (`2 - threshold`) of it. Scale-up adds at most
  #{5} listeners per check; scale-down removes at most #{3}.

  ## Scaling mechanics

  Scaled-up listeners are added to the `Abyss.ListenerPool` supervisor with
  `"listener-dyn-*"` child ids. Scale-down prefers removing those dynamic
  listeners first, stops each one gracefully via `Abyss.Listener.stop/1`, and
  deletes its child spec so the pool size stays consistent with what the
  scaler decided. No scaling is performed while the pool has no running
  listeners (e.g. while suspended via `Abyss.suspend/1`).

  ## Telemetry

  - `[:abyss, :listener_pool, :scale_up]` — measurements:
    `listeners_added`, `new_total`; metadata: `optimal`, `previous_count`
  - `[:abyss, :listener_pool, :scale_down]` — measurements:
    `listeners_removed`, `new_total`; metadata: `optimal`, `previous_count`
  """

  use GenServer

  @default_scale_check_interval 30_000
  @max_scale_up_per_check 5
  @max_scale_down_per_check 3
  @dynamic_id_prefix "listener-dyn-"
  @response_time_event [:abyss, :metrics, :response_time]

  @typedoc "Scaler state"
  @type t :: %__MODULE__{
          server_supervisor: pid(),
          server_config: Abyss.ServerConfig.t(),
          scale_check_interval: timeout(),
          counters: :counters.counters_ref(),
          telemetry_id: String.t(),
          current_connections: non_neg_integer(),
          avg_processing_time: float(),
          last_scale_time: integer()
        }

  defstruct [
    :server_supervisor,
    :server_config,
    :scale_check_interval,
    :counters,
    :telemetry_id,
    :current_connections,
    :avg_processing_time,
    :last_scale_time
  ]

  @doc """
  Start the listener pool scaler.

  ## Options

  - `:server_supervisor` (required) - PID of the `Abyss.Server` supervisor
  - `:server_config` (required) - The server's `Abyss.ServerConfig`
  - `:scale_check_interval` - Interval between scale checks in ms (default: 30_000)
  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Synchronously run a scale check, scaling the pool if necessary.
  """
  @spec check_and_scale(GenServer.server()) :: :ok
  def check_and_scale(scaler) do
    GenServer.call(scaler, :check_and_scale)
  end

  @impl GenServer
  def init(opts) do
    # Trap exits so terminate/2 runs on shutdown and detaches the telemetry
    # handler.
    Process.flag(:trap_exit, true)

    server_supervisor = Keyword.fetch!(opts, :server_supervisor)
    server_config = Keyword.fetch!(opts, :server_config)

    scale_check_interval =
      Keyword.get(opts, :scale_check_interval, @default_scale_check_interval)

    # Slot 1 accumulates response time (ms), slot 2 counts responses. Written
    # by the telemetry handler below, read & reset on each scale check.
    counters = :counters.new(2, [:write_concurrency])
    telemetry_id = "abyss-listener-pool-scaler-#{inspect(self())}"

    :telemetry.attach(
      telemetry_id,
      @response_time_event,
      &__MODULE__.handle_response_time/4,
      %{handler_module: server_config.handler_module, counters: counters}
    )

    # Note: supervisor pids (listener pool, connection supervisor) are looked
    # up lazily on each check. Doing it here would deadlock: our parent
    # supervisor cannot answer which_children while it is still starting us.
    state = %__MODULE__{
      server_supervisor: server_supervisor,
      server_config: server_config,
      scale_check_interval: scale_check_interval,
      counters: counters,
      telemetry_id: telemetry_id,
      current_connections: 0,
      # Default 100ms until real response times arrive
      avg_processing_time: 100.0,
      last_scale_time: System.monotonic_time(:millisecond)
    }

    schedule_scale_check(scale_check_interval)

    {:ok, state}
  end

  @doc false
  # Telemetry handler for response_time events. Only accumulates events
  # emitted by this server's handler module so that multiple Abyss instances
  # in one node don't pollute each other's metrics.
  @spec handle_response_time(
          :telemetry.event_name(),
          :telemetry.event_measurements(),
          :telemetry.event_metadata(),
          map()
        ) :: :ok
  def handle_response_time(_event, measurements, metadata, config) do
    if metadata[:handler] == config.handler_module do
      :counters.add(config.counters, 1, round(measurements[:response_time] || 0))
      :counters.add(config.counters, 2, 1)
    end

    :ok
  end

  @impl GenServer
  def handle_call(:check_and_scale, _from, state) do
    new_state = perform_scale_check(state)
    {:reply, :ok, new_state}
  end

  @impl GenServer
  def handle_info(:scale_check, state) do
    new_state = perform_scale_check(state)
    schedule_scale_check(state.scale_check_interval)
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :telemetry.detach(state.telemetry_id)
    :ok
  end

  # Private functions

  defp perform_scale_check(state) do
    state = gather_metrics(state)
    pool = Abyss.Server.listener_pool_pid(state.server_supervisor)
    current = if is_pid(pool), do: active_listener_count(pool), else: 0

    # current == 0 means the pool is missing or suspended — don't scale.
    if current > 0 do
      config = state.server_config

      optimal =
        state.current_connections
        |> Abyss.ServerConfig.calculate_optimal_listeners(state.avg_processing_time)
        |> min(config.max_listeners)
        |> max(config.min_listeners)

      case scale_action(current, optimal, config) do
        :scale_up -> scale_up(pool, current, optimal, state)
        :scale_down -> scale_down(pool, current, optimal, state)
        :no_scale -> state
      end
    else
      state
    end
  end

  defp gather_metrics(state) do
    connections =
      case Abyss.Server.connection_sup_pid(state.server_supervisor) do
        nil ->
          0

        pid ->
          case DynamicSupervisor.count_children(pid) do
            %{active: active} -> active
            _ -> 0
          end
      end

    total_ms = :counters.get(state.counters, 1)
    count = :counters.get(state.counters, 2)
    :counters.put(state.counters, 1, 0)
    :counters.put(state.counters, 2, 0)

    # Keep the previous average when no responses were recorded this window
    avg = if count > 0, do: total_ms / count, else: state.avg_processing_time

    %{state | current_connections: connections, avg_processing_time: avg}
  end

  defp active_listener_count(pool) do
    case Supervisor.count_children(pool) do
      %{active: active} -> active
      _ -> 0
    end
  end

  defp scale_action(current, optimal, config) do
    scale_down_factor = config.listener_scale_threshold
    scale_up_factor = 2 - scale_down_factor

    cond do
      optimal > current * scale_up_factor -> :scale_up
      optimal < current * scale_down_factor -> :scale_down
      true -> :no_scale
    end
  end

  defp scale_up(pool, current, optimal, state) do
    to_add = min(optimal - current, @max_scale_up_per_check)

    added =
      Enum.count(1..to_add//1, fn _ ->
        id = @dynamic_id_prefix <> generate_listener_id()

        spec =
          Supervisor.child_spec(
            {Abyss.Listener, {id, state.server_supervisor, state.server_config}},
            id: id
          )

        match?({:ok, _}, Supervisor.start_child(pool, spec))
      end)

    :telemetry.execute(
      [:abyss, :listener_pool, :scale_up],
      %{listeners_added: added, new_total: current + added},
      %{optimal: optimal, previous_count: current}
    )

    %{state | last_scale_time: System.monotonic_time(:millisecond)}
  end

  defp scale_down(pool, current, optimal, state) do
    to_remove = min(current - optimal, @max_scale_down_per_check)

    removed =
      pool
      |> Supervisor.which_children()
      |> Enum.filter(fn {_id, pid, _type, _modules} -> is_pid(pid) end)
      # Remove dynamically added listeners before the configured baseline
      |> Enum.sort_by(fn {id, _pid, _type, _modules} -> !dynamic_id?(id) end)
      |> Enum.take(to_remove)
      |> Enum.count(&remove_listener(pool, &1))

    :telemetry.execute(
      [:abyss, :listener_pool, :scale_down],
      %{listeners_removed: removed, new_total: current - removed},
      %{optimal: optimal, previous_count: current}
    )

    %{state | last_scale_time: System.monotonic_time(:millisecond)}
  end

  defp dynamic_id?(id) when is_binary(id), do: String.starts_with?(id, @dynamic_id_prefix)
  defp dynamic_id?(_id), do: false

  defp remove_listener(pool, {id, pid, _type, _modules}) do
    # Stop gracefully first (closes the socket, runs the listener's
    # terminate/2), then sync the supervisor and drop the child spec so a
    # later resume doesn't resurrect it.
    Abyss.Listener.stop(pid)
    Supervisor.terminate_child(pool, id)
    Supervisor.delete_child(pool, id) == :ok
  end

  defp generate_listener_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp schedule_scale_check(interval) do
    Process.send_after(self(), :scale_check, interval)
  end
end
