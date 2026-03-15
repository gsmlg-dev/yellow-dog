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

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @spec increment(:intercepted | :forwarded | :cached | :error | :rate_limited) :: :ok
  def increment(counter)
      when counter in [:intercepted, :forwarded, :cached, :error, :rate_limited] do
    :ets.update_counter(@table, counter, 1)
    :ok
  end

  @spec get() :: %{
          intercepted: non_neg_integer(),
          cached: non_neg_integer(),
          forwarded: non_neg_integer(),
          error: non_neg_integer(),
          rate_limited: non_neg_integer(),
          total: non_neg_integer()
        }
  def get do
    [{_, intercepted}] = :ets.lookup(@table, :intercepted)
    [{_, cached}] = :ets.lookup(@table, :cached)
    [{_, forwarded}] = :ets.lookup(@table, :forwarded)
    [{_, error}] = :ets.lookup(@table, :error)
    [{_, rate_limited}] = :ets.lookup(@table, :rate_limited)

    %{
      intercepted: intercepted,
      cached: cached,
      forwarded: forwarded,
      error: error,
      rate_limited: rate_limited,
      total: intercepted + cached + forwarded + error + rate_limited
    }
  end

  @spec reset() :: :ok
  def reset do
    :ets.insert(@table, [
      {:intercepted, 0},
      {:cached, 0},
      {:forwarded, 0},
      {:error, 0},
      {:rate_limited, 0}
    ])

    :ok
  end

  @doc """
  Returns the monotonic second at which this Counters GenServer started.
  Used to compute resolver uptime independently of the BEAM VM's wall-clock age.
  """
  @spec started_at() :: integer()
  def started_at do
    :persistent_term.get({__MODULE__, :started_at}, System.monotonic_time(:second))
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    :persistent_term.put({__MODULE__, :started_at}, System.monotonic_time(:second))
    try do: :ets.delete(@table), catch: (_, _ -> :ok)
    table = :ets.new(@table, [:named_table, :set, :public, write_concurrency: true])

    :ets.insert(table, [
      {:intercepted, 0},
      {:cached, 0},
      {:forwarded, 0},
      {:error, 0},
      {:rate_limited, 0}
    ])

    {:ok, %{table: table}}
  end
end
