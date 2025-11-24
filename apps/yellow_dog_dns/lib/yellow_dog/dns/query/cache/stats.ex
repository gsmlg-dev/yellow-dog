defmodule YellowDog.Dns.Query.Cache.Stats do
  @moduledoc """
  Cache statistics collection and reporting.

  Collects and reports various metrics about cache performance including
  hit/miss rates, memory usage, and entry counts.

  ## Examples

      iex> stats = Stats.collect()
      iex> Stats.hit_rate(stats)
      0.85
  """

  alias YellowDog.Dns.Query.Cache.Storage

  defstruct [
    :total_entries,
    :hit_count,
    :miss_count,
    :insert_count,
    :eviction_count,
    :expired_count,
    :memory_bytes,
    :collected_at
  ]

  @type t :: %__MODULE__{
          total_entries: non_neg_integer(),
          hit_count: non_neg_integer(),
          miss_count: non_neg_integer(),
          insert_count: non_neg_integer(),
          eviction_count: non_neg_integer(),
          expired_count: non_neg_integer(),
          memory_bytes: non_neg_integer(),
          collected_at: integer()
        }

  @doc """
  Collects current cache statistics.

  Gathers statistics from the ETS storage and any tracked counters.

  ## Parameters
  - `counters` - Map of counter values (optional)

  ## Returns
  A `Stats` struct with current statistics

  ## Examples

      iex> stats = Stats.collect()
      %Stats{total_entries: 100, hit_count: 850, ...}
  """
  @spec collect(map()) :: t()
  def collect(counters \\ %{}) do
    memory = Storage.memory_info()

    %__MODULE__{
      total_entries: Storage.count(),
      hit_count: Map.get(counters, :hit_count, 0),
      miss_count: Map.get(counters, :miss_count, 0),
      insert_count: Map.get(counters, :insert_count, 0),
      eviction_count: Map.get(counters, :eviction_count, 0),
      expired_count: Map.get(counters, :expired_count, 0),
      memory_bytes: memory.bytes,
      collected_at: System.monotonic_time(:second)
    }
  end

  @doc """
  Calculates the cache hit rate.

  ## Parameters
  - `stats` - The statistics struct

  ## Returns
  Hit rate as a float between 0.0 and 1.0, or 0.0 if no queries

  ## Examples

      iex> stats = %Stats{hit_count: 85, miss_count: 15}
      iex> Stats.hit_rate(stats)
      0.85
  """
  @spec hit_rate(t()) :: float()
  def hit_rate(%__MODULE__{hit_count: hits, miss_count: misses}) do
    total = hits + misses

    if total > 0 do
      Float.round(hits / total, 4)
    else
      0.0
    end
  end

  @doc """
  Converts memory bytes to megabytes.

  ## Parameters
  - `stats` - The statistics struct

  ## Returns
  Memory usage in megabytes as a float

  ## Examples

      iex> stats = %Stats{memory_bytes: 1_048_576}
      iex> Stats.memory_mb(stats)
      1.0
  """
  @spec memory_mb(t()) :: float()
  def memory_mb(%__MODULE__{memory_bytes: bytes}) do
    Float.round(bytes / 1_024 / 1_024, 2)
  end

  @doc """
  Calculates the cache miss rate.

  ## Parameters
  - `stats` - The statistics struct

  ## Returns
  Miss rate as a float between 0.0 and 1.0

  ## Examples

      iex> stats = %Stats{hit_count: 85, miss_count: 15}
      iex> Stats.miss_rate(stats)
      0.15
  """
  @spec miss_rate(t()) :: float()
  def miss_rate(%__MODULE__{} = stats) do
    Float.round(1.0 - hit_rate(stats), 4)
  end

  @doc """
  Calculates total number of queries (hits + misses).

  ## Parameters
  - `stats` - The statistics struct

  ## Returns
  Total query count

  ## Examples

      iex> stats = %Stats{hit_count: 85, miss_count: 15}
      iex> Stats.total_queries(stats)
      100
  """
  @spec total_queries(t()) :: non_neg_integer()
  def total_queries(%__MODULE__{hit_count: hits, miss_count: misses}) do
    hits + misses
  end

  @doc """
  Converts statistics to a map.

  Useful for serialization and reporting.

  ## Parameters
  - `stats` - The statistics struct

  ## Returns
  Map representation of statistics

  ## Examples

      iex> stats = Stats.collect()
      iex> Stats.to_map(stats)
      %{
        total_entries: 100,
        hit_count: 850,
        hit_rate: 0.85,
        ...
      }
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = stats) do
    %{
      total_entries: stats.total_entries,
      hit_count: stats.hit_count,
      miss_count: stats.miss_count,
      total_queries: total_queries(stats),
      hit_rate: hit_rate(stats),
      miss_rate: miss_rate(stats),
      insert_count: stats.insert_count,
      eviction_count: stats.eviction_count,
      expired_count: stats.expired_count,
      memory_bytes: stats.memory_bytes,
      memory_mb: memory_mb(stats),
      collected_at: stats.collected_at
    }
  end

  @doc """
  Creates a human-readable summary of statistics.

  ## Parameters
  - `stats` - The statistics struct

  ## Returns
  String summary of statistics

  ## Examples

      iex> stats = Stats.collect()
      iex> Stats.summary(stats)
      "Cache: 100 entries, 850/1000 hits (85.0%), 1.5 MB"
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{} = stats) do
    total = total_queries(stats)
    hit_pct = Float.round(hit_rate(stats) * 100, 1)
    mb = memory_mb(stats)

    "Cache: #{stats.total_entries} entries, #{stats.hit_count}/#{total} hits (#{hit_pct}%), #{mb} MB"
  end

  @doc """
  Calculates the cache effectiveness score.

  A composite metric that considers both hit rate and memory efficiency.
  Higher is better.

  ## Parameters
  - `stats` - The statistics struct

  ## Returns
  Effectiveness score (0.0 to 100.0)

  ## Examples

      iex> stats = %Stats{hit_count: 85, miss_count: 15, total_entries: 100}
      iex> Stats.effectiveness(stats)
      85.0
  """
  @spec effectiveness(t()) :: float()
  def effectiveness(%__MODULE__{} = stats) do
    # Simple effectiveness: hit rate * 100
    # Could be enhanced with memory efficiency factor
    Float.round(hit_rate(stats) * 100, 2)
  end

  @doc """
  Compares two statistics snapshots.

  ## Parameters
  - `current` - Current statistics
  - `previous` - Previous statistics

  ## Returns
  Map of deltas between snapshots

  ## Examples

      iex> Stats.compare(current, previous)
      %{
        entries_delta: 10,
        hits_delta: 50,
        ...
      }
  """
  @spec compare(t(), t()) :: map()
  def compare(%__MODULE__{} = current, %__MODULE__{} = previous) do
    %{
      entries_delta: current.total_entries - previous.total_entries,
      hits_delta: current.hit_count - previous.hit_count,
      misses_delta: current.miss_count - previous.miss_count,
      inserts_delta: current.insert_count - previous.insert_count,
      evictions_delta: current.eviction_count - previous.eviction_count,
      expired_delta: current.expired_count - previous.expired_count,
      memory_delta_bytes: current.memory_bytes - previous.memory_bytes,
      hit_rate_delta: hit_rate(current) - hit_rate(previous),
      time_delta_seconds: current.collected_at - previous.collected_at
    }
  end

  @doc """
  Checks if cache statistics indicate healthy operation.

  ## Parameters
  - `stats` - The statistics struct
  - `opts` - Options:
    - `:min_hit_rate` - Minimum acceptable hit rate (default: 0.5)
    - `:max_memory_mb` - Maximum memory usage in MB (default: 100)

  ## Returns
  `{:ok, stats}` if healthy, `{:warning, reason, stats}` if issues detected

  ## Examples

      iex> stats = %Stats{hit_count: 85, miss_count: 15}
      iex> Stats.health_check(stats)
      {:ok, stats}
  """
  @spec health_check(t(), keyword()) :: {:ok, t()} | {:warning, String.t(), t()}
  def health_check(%__MODULE__{} = stats, opts \\ []) do
    min_hit_rate = Keyword.get(opts, :min_hit_rate, 0.5)
    max_memory_mb = Keyword.get(opts, :max_memory_mb, 100)

    cond do
      hit_rate(stats) < min_hit_rate and total_queries(stats) > 100 ->
        {:warning, "Low hit rate: #{Float.round(hit_rate(stats) * 100, 1)}%", stats}

      memory_mb(stats) > max_memory_mb ->
        {:warning, "High memory usage: #{memory_mb(stats)} MB", stats}

      true ->
        {:ok, stats}
    end
  end
end
