defmodule YellowDog.Store.Cache do
  @moduledoc """
  DNS resolver cache with a two-tier architecture.

  - **Tier 1 (hot path):** Per-node local ETS table. All reads and writes
    hit ETS first. `lookup/2` and `store/3` never touch Concord.
  - **Tier 2 (warm backing):** Concord store. Populated asynchronously
    via `flush_to_store/0` and hydrated via `warm_from_store/0`.

  The ETS table (`:yellow_dog_dns_cache`) is initialized lazily on first access.
  Each entry is `{key, value, inserted_at, last_accessed}` where key is `{qname, qtype}`.
  """

  alias YellowDog.Store.{Backend, Key}

  @table :yellow_dog_dns_cache

  # Counter indices
  @hit_idx 1
  @miss_idx 2
  @eviction_idx 3

  # Defaults
  @default_max_memory 64 * 1024 * 1024
  @default_batch_size 100
  @min_batch_size 10
  @max_batch_size 500

  @type qname :: String.t()
  @type qtype :: atom()
  @type cache_entry :: %{
          rrset: list(),
          qname: String.t(),
          qtype: atom(),
          rcode: atom(),
          upstream: String.t(),
          fetched_at: integer(),
          original_ttl: integer(),
          negative: boolean()
        }

  # --- Public API ---

  @doc """
  Look up a cached DNS response by query name and type.

  Reads from local ETS only (hot path, never Concord). Updates the
  `last_accessed` timestamp on hit. Returns `{:error, :not_found}` and
  deletes the entry when the TTL has expired.
  """
  @spec lookup(qname(), qtype()) :: {:ok, cache_entry()} | {:error, :not_found}
  def lookup(qname, qtype) do
    ensure_table()
    key = {qname, qtype}
    now = System.system_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, entry, _inserted_at, _last_accessed}] ->
        if entry.fetched_at + entry.original_ttl < now do
          :ets.delete(@table, key)
          bump_counter(@miss_idx)
          {:error, :not_found}
        else
          :ets.update_element(@table, key, {4, now})
          bump_counter(@hit_idx)
          {:ok, entry}
        end

      [] ->
        bump_counter(@miss_idx)
        {:error, :not_found}
    end
  end

  @doc """
  Store a DNS response in the local ETS cache.

  Checks the memory budget and triggers LRU eviction if the table exceeds
  the configured maximum. Does NOT write to Concord synchronously.
  """
  @spec store(qname(), qtype(), cache_entry()) :: :ok
  def store(qname, qtype, response) do
    ensure_table()
    key = {qname, qtype}
    now = System.system_time(:second)

    :ets.insert(@table, {key, response, now, now})
    maybe_evict()
    :ok
  end

  @doc """
  Remove a cached entry from local ETS and asynchronously from Concord.
  """
  @spec invalidate(qname(), qtype()) :: :ok
  def invalidate(qname, qtype) do
    ensure_table()
    key = {qname, qtype}
    :ets.delete(@table, key)

    Task.start(fn ->
      try do
        Backend.active().delete(Key.cache(qname, qtype))
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  @doc """
  Flush the entire local ETS cache. Optionally clears Concord cache keys.
  """
  @spec invalidate_all() :: :ok
  def invalidate_all do
    ensure_table()
    :ets.delete_all_objects(@table)
    reset_counters()

    Task.start(fn ->
      try do
        case Backend.active().prefix_scan(Key.cache_prefix(), consistency: :eventual) do
          {:ok, entries} ->
            Enum.each(entries, fn {key, _value} -> Backend.active().delete(key) end)

          {:error, _} ->
            :ok
        end
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  @doc """
  Load all `dns:cache:*` entries from Concord into local ETS.

  Uses `:eventual` consistency for the prefix scan. Skips entries whose
  TTL has already expired.
  """
  @spec warm_from_store() :: :ok
  def warm_from_store do
    ensure_table()
    start_time = System.monotonic_time()
    now = System.system_time(:second)

    {count, _} =
      case Backend.active().prefix_scan(Key.cache_prefix(), consistency: :eventual) do
        {:ok, entries} ->
          loaded =
            entries
            |> Enum.filter(fn {_key, entry} ->
              entry.fetched_at + entry.original_ttl >= now
            end)
            |> Enum.map(fn {_key, entry} ->
              ets_key = {entry.qname, entry.qtype}
              :ets.insert(@table, {ets_key, entry, entry.fetched_at, now})
            end)

          {length(loaded), :ok}

        {:error, _} ->
          {0, :error}
      end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:yellow_dog, :store, :cache, :warm],
      %{duration: duration, entries_loaded: count},
      %{}
    )

    :ok
  end

  @doc """
  Batch write recent ETS entries to Concord.

  Adaptive batch size based on Raft latency: increases by 20% when
  latency is under 50ms, decreases by 30% when over 200ms.
  Uses `Concord.put_many/2`.
  """
  @spec flush_to_store() :: :ok
  def flush_to_store do
    ensure_table()
    start_time = System.monotonic_time()
    batch_size = get_batch_size()
    now = System.system_time(:second)

    entries =
      @table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_key, _entry, _inserted, last_accessed} -> last_accessed end, :desc)
      |> Enum.take(batch_size)

    operations =
      entries
      |> Enum.filter(fn {_key, entry, _inserted, _last_accessed} ->
        remaining_ttl = entry.fetched_at + entry.original_ttl - now
        remaining_ttl > 0
      end)
      |> Enum.map(fn {{qname, qtype}, entry, _inserted, _last_accessed} ->
        concord_key = Key.cache(qname, qtype)
        remaining_ttl = entry.fetched_at + entry.original_ttl - now
        {concord_key, entry, remaining_ttl}
      end)

    flushed_count = length(operations)

    if flushed_count > 0 do
      write_start = System.monotonic_time(:millisecond)
      Backend.active().put_many(operations)
      write_latency = System.monotonic_time(:millisecond) - write_start

      adapt_batch_size(batch_size, write_latency)
    end

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:yellow_dog, :store, :cache, :flush],
      %{duration: duration, entries_flushed: flushed_count},
      %{}
    )

    :ok
  end

  @doc """
  Return cache statistics: hit/miss counts, entry count, and memory usage.
  """
  @spec stats() :: map()
  def stats do
    ensure_table()

    info = :ets.info(@table)
    memory_bytes = Keyword.get(info, :memory, 0) * :erlang.system_info(:wordsize)
    entry_count = Keyword.get(info, :size, 0)

    {hits, misses, evictions} = read_counters()

    result = %{
      hits: hits,
      misses: misses,
      size: entry_count,
      evictions: evictions,
      memory_bytes: memory_bytes,
      max_memory_bytes: get_max_memory(),
      hit_rate: if(hits + misses > 0, do: hits / (hits + misses), else: 0.0)
    }

    :telemetry.execute(
      [:yellow_dog, :store, :cache, :stats],
      %{hits: hits, misses: misses, size: entry_count, evictions: evictions},
      %{}
    )

    result
  end

  @doc """
  Update runtime cache settings.

  Supported keys:
  - `:max_memory_bytes` — memory budget (default 64MB)
  - `:flush_interval_ms` — flush interval in milliseconds
  """
  @spec configure(keyword()) :: :ok
  def configure(opts) do
    if max_mem = Keyword.get(opts, :max_memory_bytes) do
      :persistent_term.put({__MODULE__, :max_memory_bytes}, max_mem)
    end

    if flush_ms = Keyword.get(opts, :flush_interval_ms) do
      :persistent_term.put({__MODULE__, :flush_interval_ms}, flush_ms)
    end

    :ok
  end

  # --- Internal Helpers ---

  @doc false
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        init_table()
        :ok

      _ref ->
        :ok
    end
  end

  defp init_table do
    :ets.new(@table, [
      :set,
      :public,
      :named_table,
      read_concurrency: true
    ])

    init_counters()
  rescue
    ArgumentError ->
      # Table already exists (race between concurrent callers)
      :ok
  end

  defp init_counters do
    ref = :counters.new(3, [:write_concurrency])
    :persistent_term.put({__MODULE__, :counters}, ref)
  end

  defp counters_ref do
    :persistent_term.get({__MODULE__, :counters}, nil)
  end

  defp bump_counter(idx), do: bump_counter(idx, 1)

  defp bump_counter(idx, amount) do
    case counters_ref() do
      nil ->
        :ok

      ref ->
        try do
          :counters.add(ref, idx, amount)
        rescue
          ArgumentError ->
            # Counter ref is stale (wrong size); reinitialize and retry
            init_counters()
            :counters.add(counters_ref(), idx, amount)
        end
    end
  end

  defp read_counters do
    case counters_ref() do
      nil ->
        {0, 0, 0}

      ref ->
        try do
          {:counters.get(ref, @hit_idx), :counters.get(ref, @miss_idx),
           :counters.get(ref, @eviction_idx)}
        rescue
          ArgumentError ->
            init_counters()
            {0, 0, 0}
        end
    end
  end

  defp reset_counters do
    case counters_ref() do
      nil ->
        :ok

      ref ->
        try do
          :counters.put(ref, @hit_idx, 0)
          :counters.put(ref, @miss_idx, 0)
          :counters.put(ref, @eviction_idx, 0)
        rescue
          ArgumentError ->
            init_counters()
        end
    end
  end

  defp get_max_memory do
    :persistent_term.get({__MODULE__, :max_memory_bytes}, @default_max_memory)
  end

  defp get_batch_size do
    :persistent_term.get({__MODULE__, :batch_size}, @default_batch_size)
  end

  defp adapt_batch_size(current, latency_ms) do
    new_size =
      cond do
        latency_ms < 50 ->
          trunc(current * 1.2)

        latency_ms > 200 ->
          trunc(current * 0.7)

        true ->
          current
      end

    clamped = new_size |> max(@min_batch_size) |> min(@max_batch_size)
    :persistent_term.put({__MODULE__, :batch_size}, clamped)
  end

  defp maybe_evict do
    info = :ets.info(@table)
    memory_bytes = Keyword.get(info, :memory, 0) * :erlang.system_info(:wordsize)
    max_memory = get_max_memory()

    if memory_bytes > max_memory do
      evict_lru()
    end
  end

  defp evict_lru do
    # Collect all entries with their last_accessed timestamps
    entries =
      :ets.foldl(
        fn {key, _entry, _inserted, last_accessed}, acc ->
          [{key, last_accessed} | acc]
        end,
        [],
        @table
      )

    # Sort by last_accessed ascending (oldest first) and delete the bottom 10%
    evict_count = max(div(length(entries), 10), 1)

    entries
    |> Enum.sort_by(fn {_key, last_accessed} -> last_accessed end, :asc)
    |> Enum.take(evict_count)
    |> Enum.each(fn {key, _} -> :ets.delete(@table, key) end)

    bump_counter(@eviction_idx, evict_count)
  end
end
