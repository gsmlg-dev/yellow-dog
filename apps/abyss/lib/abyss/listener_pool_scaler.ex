defmodule Abyss.ListenerPoolScaler do
  @moduledoc """
  Dynamic listener pool scaling functionality for Abyss servers.

  This module provides utilities to automatically scale the number of listener
  processes based on current load and processing characteristics.
  """

  use GenServer
  require Logger

  @typedoc "Scaler state"
  @type t :: %__MODULE__{
          server_supervisor: pid(),
          listener_pool_supervisor: pid(),
          connection_supervisor: pid(),
          server_config: Abyss.ServerConfig.t(),
          scale_check_interval: timeout(),
          current_connections: non_neg_integer(),
          avg_processing_time: float(),
          last_scale_time: integer()
        }

  defstruct [
    :server_supervisor,
    :listener_pool_supervisor,
    :connection_supervisor,
    :server_config,
    :scale_check_interval,
    :current_connections,
    :avg_processing_time,
    :last_scale_time
  ]

  @doc """
  Start the listener pool scaler
  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if scaling is needed and perform it if necessary
  """
  @spec check_and_scale(pid()) :: :ok
  def check_and_scale(scaler \\ __MODULE__) do
    GenServer.call(scaler, :check_and_scale)
  end

  @impl GenServer
  def init(opts) do
    server_supervisor = Keyword.fetch!(opts, :server_supervisor)
    server_config = Keyword.fetch!(opts, :server_config)
    # 30 seconds
    scale_check_interval = Keyword.get(opts, :scale_check_interval, 30_000)

    # Get supervisor pids
    listener_pool_supervisor = Abyss.Server.listener_pool_pid(server_supervisor)
    connection_supervisor = Abyss.Server.connection_sup_pid(server_supervisor)

    state = %__MODULE__{
      server_supervisor: server_supervisor,
      listener_pool_supervisor: listener_pool_supervisor,
      connection_supervisor: connection_supervisor,
      server_config: server_config,
      scale_check_interval: scale_check_interval,
      current_connections: 0,
      # Default 100ms
      avg_processing_time: 100.0,
      last_scale_time: System.monotonic_time(:millisecond)
    }

    # Start periodic scaling checks
    schedule_scale_check(scale_check_interval)

    {:ok, state}
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

  # Private functions

  defp perform_scale_check(state) do
    if state.server_config.dynamic_listeners do
      {current_connections, avg_processing_time} = gather_metrics(state)

      optimal =
        Abyss.ServerConfig.calculate_optimal_listeners(
          current_connections,
          avg_processing_time
        )

      current_count = get_current_listener_count(state.listener_pool_supervisor)

      new_state = %{
        state
        | current_connections: current_connections,
          avg_processing_time: avg_processing_time
      }

      should_scale?(current_count, optimal, state.server_config)
      |> maybe_scale(current_count, optimal, new_state)
    else
      state
    end
  end

  defp gather_metrics(state) do
    # Get current connection count
    current_connections =
      case DynamicSupervisor.which_children(state.connection_supervisor) do
        children when is_list(children) ->
          length(children)

        _ ->
          0
      end

    # Calculate average processing time from telemetry events
    # This is a simplified approach - in practice you'd want to aggregate
    # telemetry data over a time window
    avg_processing_time = state.avg_processing_time

    {current_connections, avg_processing_time}
  end

  defp get_current_listener_count(listener_pool_supervisor) do
    case DynamicSupervisor.which_children(listener_pool_supervisor) do
      children when is_list(children) ->
        length(children)

      _ ->
        0
    end
  end

  defp should_scale?(current_count, optimal, config) do
    cond do
      optimal > current_count * 1.2 and optimal < config.max_listeners ->
        :scale_up

      optimal < current_count * 0.8 and optimal > config.min_listeners ->
        :scale_down

      true ->
        :no_scale
    end
  end

  defp maybe_scale(:scale_up, current_count, optimal, state) do
    # Scale up by max 5 at a time
    scale_by = min(optimal - current_count, 5)

    {:ok, _count} = start_listeners(state.listener_pool_supervisor, state.server_config, scale_by)

    :telemetry.execute(
      [:abyss, :listener_pool, :scale_up],
      %{listeners_added: scale_by, new_total: current_count + scale_by},
      %{optimal: optimal, previous_count: current_count}
    )

    %{state | last_scale_time: System.monotonic_time(:millisecond)}
  end

  defp maybe_scale(:scale_down, current_count, optimal, state) do
    # Scale down by max 3 at a time
    scale_by = min(current_count - optimal, 3)

    {:ok, _count} = stop_listeners(state.listener_pool_supervisor, scale_by)

    :telemetry.execute(
      [:abyss, :listener_pool, :scale_down],
      %{listeners_removed: scale_by, new_total: current_count - scale_by},
      %{optimal: optimal, previous_count: current_count}
    )

    %{state | last_scale_time: System.monotonic_time(:millisecond)}
  end

  defp maybe_scale(:no_scale, _current_count, _optimal, state), do: state

  defp start_listeners(supervisor, config, count) do
    results =
      Enum.map(1..count, fn _ ->
        listener_id = generate_listener_id()
        child_spec = {Abyss.Listener, {listener_id, supervisor, config}}
        DynamicSupervisor.start_child(supervisor, child_spec)
      end)

    success = Enum.filter(results, &match?({:ok, _}, &1))
    {:ok, length(success)}
  end

  defp stop_listeners(supervisor, count) do
    children = DynamicSupervisor.which_children(supervisor)
    to_stop = Enum.take(children, count)

    results =
      Enum.map(to_stop, fn {_id, pid, _type, _modules} ->
        DynamicSupervisor.terminate_child(supervisor, pid)
      end)

    success = Enum.filter(results, &match?(:ok, &1))
    {:ok, length(success)}
  end

  defp generate_listener_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp schedule_scale_check(interval) do
    Process.send_after(self(), :scale_check, interval)
  end
end
