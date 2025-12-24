defmodule YellowDog.Dns.Query.Cache.Cleaner do
  @moduledoc """
  Periodically removes expired cache entries.

  The Cleaner runs on a configurable interval to remove expired entries,
  enforce memory limits, and collect cleanup statistics.

  ## Configuration

  - `:interval` - Cleanup interval in milliseconds (default: 60000)
  - `:max_memory_mb` - Maximum memory usage threshold (default: 100)
  - `:max_entries` - Maximum entry count (default: 10000)

  ## Examples

      iex> {:ok, _pid} = Cleaner.start_link(interval: 30_000)
  """

  use GenServer

  alias YellowDog.Dns.Query.Cache.Storage

  @default_interval 60_000

  defmodule State do
    @moduledoc false
    defstruct [
      :interval,
      :max_memory_mb,
      :max_entries,
      :last_cleanup,
      :cleanup_stats
    ]

    @type t :: %__MODULE__{
            interval: non_neg_integer(),
            max_memory_mb: non_neg_integer(),
            max_entries: non_neg_integer(),
            last_cleanup: integer() | nil,
            cleanup_stats: map()
          }
  end

  # Client API

  @doc """
  Starts the cache cleaner.

  ## Parameters
  - `opts` - Configuration options:
    - `:interval` - Cleanup interval in milliseconds
    - `:max_memory_mb` - Maximum memory threshold
    - `:max_entries` - Maximum entry count

  ## Returns
  `{:ok, pid}` or `{:error, reason}`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers an immediate cleanup.

  Forces a cleanup cycle regardless of the scheduled interval.

  ## Returns
  Map with cleanup statistics

  ## Examples

      iex> Cleaner.cleanup_now()
      %{expired_removed: 5, evicted: 0, duration_ms: 12}
  """
  @spec cleanup_now() :: map()
  def cleanup_now do
    GenServer.call(__MODULE__, :cleanup_now)
  end

  @doc """
  Gets the last cleanup statistics.

  ## Returns
  Map with last cleanup stats or `nil` if no cleanup has run

  ## Examples

      iex> Cleaner.last_stats()
      %{expired_removed: 5, evicted: 0, duration_ms: 12, timestamp: 123456}
  """
  @spec last_stats() :: map() | nil
  def last_stats do
    GenServer.call(__MODULE__, :last_stats)
  end

  @doc """
  Gets the current cleaner configuration.

  ## Returns
  Configuration map

  ## Examples

      iex> Cleaner.get_config()
      %{interval: 60000, max_memory_mb: 100, max_entries: 10000}
  """
  @spec get_config() :: map()
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    max_memory_mb = Keyword.get(opts, :max_memory_mb, 100)
    max_entries = Keyword.get(opts, :max_entries, 10_000)

    state = %State{
      interval: interval,
      max_memory_mb: max_memory_mb,
      max_entries: max_entries,
      last_cleanup: nil,
      cleanup_stats: %{}
    }

    # Schedule first cleanup
    schedule_cleanup(interval)

    :telemetry.execute(
      [:yellow_dog, :dns, :cache, :cleaner_start],
      %{count: 1},
      %{source: __MODULE__, interval_ms: interval, max_memory_mb: max_memory_mb, max_entries: max_entries, severity: :info}
    )

    {:ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    stats = perform_cleanup(state)

    # Schedule next cleanup
    schedule_cleanup(state.interval)

    new_state = %{
      state
      | last_cleanup: System.monotonic_time(:millisecond),
        cleanup_stats: stats
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:cleanup_now, _from, state) do
    stats = perform_cleanup(state)

    new_state = %{
      state
      | last_cleanup: System.monotonic_time(:millisecond),
        cleanup_stats: stats
    }

    {:reply, stats, new_state}
  end

  @impl true
  def handle_call(:last_stats, _from, state) do
    {:reply, state.cleanup_stats, state}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    config = %{
      interval: state.interval,
      max_memory_mb: state.max_memory_mb,
      max_entries: state.max_entries
    }

    {:reply, config, state}
  end

  # Private Functions

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup, interval)
  end

  defp perform_cleanup(state) do
    start_time = System.monotonic_time(:millisecond)

    # Remove expired entries
    expired_removed = cleanup_expired_entries()

    # Enforce memory limits
    memory_evicted = enforce_memory_limits(state.max_memory_mb)

    # Enforce entry count limits
    count_evicted = enforce_count_limits(state.max_entries)

    # Collect statistics
    memory_info = Storage.memory_info()
    entry_count = Storage.count()

    end_time = System.monotonic_time(:millisecond)
    duration_ms = end_time - start_time

    stats = %{
      expired_removed: expired_removed,
      memory_evicted: memory_evicted,
      count_evicted: count_evicted,
      total_evicted: memory_evicted + count_evicted,
      duration_ms: duration_ms,
      memory_mb: memory_info.mb,
      entry_count: entry_count,
      timestamp: System.monotonic_time(:second)
    }

    # Emit telemetry if significant cleanup occurred
    if expired_removed > 0 or memory_evicted > 0 or count_evicted > 0 do
      :telemetry.execute(
        [:yellow_dog, :dns, :cache, :cleanup_completed],
        %{count: 1, expired_removed: expired_removed, memory_evicted: memory_evicted, count_evicted: count_evicted, duration_ms: duration_ms},
        %{source: __MODULE__, memory_mb: memory_info.mb, entry_count: entry_count, severity: :debug}
      )
    end

    # Emit telemetry
    :telemetry.execute(
      [:yellow_dog, :dns, :cache, :cleanup],
      %{
        expired_removed: expired_removed,
        evicted: memory_evicted + count_evicted,
        duration_ms: duration_ms
      },
      %{memory_mb: memory_info.mb, entry_count: entry_count}
    )

    stats
  end

  defp cleanup_expired_entries do
    Storage.remove_expired()
  end

  defp enforce_memory_limits(max_memory_mb) do
    memory_info = Storage.memory_info()

    if memory_info.mb > max_memory_mb do
      # Calculate how many entries to remove (estimate)
      # Rough estimate: assume average entry size
      current_count = Storage.count()
      avg_entry_size_mb = if current_count > 0, do: memory_info.mb / current_count, else: 0

      if avg_entry_size_mb > 0 do
        # Calculate target count to reach max memory
        excess_mb = memory_info.mb - max_memory_mb
        entries_to_remove = ceil(excess_mb / avg_entry_size_mb)

        # Remove at least 10% to avoid frequent evictions
        entries_to_remove = max(entries_to_remove, div(current_count, 10))

        target_count = max(0, current_count - entries_to_remove)
        Storage.evict_lru(target_count)
      else
        0
      end
    else
      0
    end
  end

  defp enforce_count_limits(max_entries) do
    current_count = Storage.count()

    if current_count > max_entries do
      # Keep 90% of max to avoid frequent evictions
      target_count = div(max_entries * 90, 100)
      Storage.evict_lru(target_count)
    else
      0
    end
  end
end
