defmodule YellowDog.Resolved.Metrics do
  @moduledoc """
  Query metrics accumulator for the resolved DNS stub resolver.

  Attaches to telemetry events emitted by the Router and counts queries
  by source (intercept, cache, forward). Exposes counters for the
  management ping response.

  Uses an ETS table with write_concurrency for lock-free counter updates
  from the telemetry handler (which runs in the caller's process).
  """

  use GenServer

  @table :resolved_metrics

  # Client API

  @doc "Start the metrics accumulator."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get all query counters as a map."
  @spec get_query_counts() :: %{
          total: non_neg_integer(),
          intercepted: non_neg_integer(),
          cached: non_neg_integer(),
          forwarded: non_neg_integer()
        }
  def get_query_counts do
    %{
      total: get_counter(:queries_total),
      intercepted: get_counter(:queries_intercepted),
      cached: get_counter(:queries_cached),
      forwarded: get_counter(:queries_forwarded)
    }
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])

    :ets.insert(@table, [
      {:queries_total, 0},
      {:queries_intercepted, 0},
      {:queries_cached, 0},
      {:queries_forwarded, 0}
    ])

    attach_telemetry()
    {:ok, %{}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp attach_telemetry do
    :telemetry.attach(
      "resolved-metrics-query-stop",
      [:yellow_dog, :resolved, :query, :stop],
      &handle_query_stop/4,
      nil
    )
  end

  defp handle_query_stop(_event, _measurements, metadata, _config) do
    bump(:queries_total)

    case metadata[:source] do
      :intercept -> bump(:queries_intercepted)
      :cache -> bump(:queries_cached)
      :forward -> bump(:queries_forwarded)
      _ -> :ok
    end
  end

  defp bump(key) do
    :ets.update_counter(@table, key, 1)
  catch
    :error, :badarg -> :ok
  end

  defp get_counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  catch
    :error, :badarg -> 0
  end
end
