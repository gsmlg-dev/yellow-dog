defmodule YellowDog.Resolved.Counters do
  @moduledoc """
  Query-level counters for the DNS stub resolver.

  Tracks routing outcomes (intercepted, cached, forwarded) separately from
  cache-internal statistics (hits/misses/evictions). This separation keeps
  the Cache module focused on cache concerns only.
  """
  use GenServer

  @table :resolved_query_counters

  # Client API

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec increment(:intercepted | :forwarded | :cached | :error) :: :ok
  def increment(counter) when counter in [:intercepted, :forwarded, :cached, :error] do
    :ets.update_counter(@table, counter, 1)
    :ok
  end

  @spec get() :: %{
          intercepted: non_neg_integer(),
          cached: non_neg_integer(),
          forwarded: non_neg_integer(),
          error: non_neg_integer(),
          total: non_neg_integer()
        }
  def get do
    [{_, intercepted}] = :ets.lookup(@table, :intercepted)
    [{_, cached}] = :ets.lookup(@table, :cached)
    [{_, forwarded}] = :ets.lookup(@table, :forwarded)
    [{_, error}] = :ets.lookup(@table, :error)

    %{
      intercepted: intercepted,
      cached: cached,
      forwarded: forwarded,
      error: error,
      total: intercepted + cached + forwarded + error
    }
  end

  @spec reset() :: :ok
  def reset do
    :ets.insert(@table, [
      {:intercepted, 0},
      {:cached, 0},
      {:forwarded, 0},
      {:error, 0}
    ])

    :ok
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])

    :ets.insert(table, [
      {:intercepted, 0},
      {:cached, 0},
      {:forwarded, 0},
      {:error, 0}
    ])

    {:ok, %{table: table}}
  end
end
