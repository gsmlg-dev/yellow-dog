defmodule YellowDog.Resolved.Cache do
  @moduledoc """
  ETS-based DNS cache with TTL, negative caching, and LRU eviction.
  """
  use GenServer

  require Logger

  @table :resolved_dns_cache
  @stats_table :resolved_cache_stats
  @lru_table :resolved_cache_lru

  # Client API

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec lookup(String.t(), atom()) :: {:hit, term(), non_neg_integer()} | :miss
  def lookup(domain, type) do
    key = cache_key(domain, type)
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, response, expires_at, last_access, _stored_at}] when expires_at > now ->
        :ets.update_counter(@stats_table, :hits, 1)
        # Update last access time for LRU
        :ets.delete(@lru_table, {last_access, key})
        :ets.insert(@lru_table, {{now, key}})
        :ets.update_element(@table, key, {4, now})

        remaining_ttl = expires_at - now

        :telemetry.execute(
          [:yellow_dog, :resolved, :cache, :hit],
          %{},
          %{domain: domain, type: type}
        )

        {:hit, response, remaining_ttl}

      [{^key, _response, _expires_at, last_access, _stored_at}] ->
        # Expired - lazy eviction
        :ets.delete(@table, key)
        :ets.delete(@lru_table, {last_access, key})
        :ets.update_counter(@stats_table, :misses, 1)

        :telemetry.execute(
          [:yellow_dog, :resolved, :cache, :miss],
          %{},
          %{domain: domain, type: type}
        )

        :miss

      [] ->
        :ets.update_counter(@stats_table, :misses, 1)

        :telemetry.execute(
          [:yellow_dog, :resolved, :cache, :miss],
          %{},
          %{domain: domain, type: type}
        )

        :miss
    end
  end

  @spec store(String.t(), atom(), term(), pos_integer()) :: :ok
  def store(domain, type, response, ttl) do
    GenServer.cast(__MODULE__, {:store, domain, type, response, ttl})
  end

  @spec flush() :: non_neg_integer()
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @spec flush(String.t()) :: non_neg_integer()
  def flush(domain) do
    GenServer.call(__MODULE__, {:flush, domain})
  end

  @spec flush_pattern(String.t()) :: non_neg_integer()
  def flush_pattern(pattern) do
    GenServer.call(__MODULE__, {:flush_pattern, pattern})
  end

  @spec stats() :: map()
  def stats do
    entries = :ets.info(@table, :size)
    [{_, hits}] = :ets.lookup(@stats_table, :hits)
    [{_, misses}] = :ets.lookup(@stats_table, :misses)
    [{_, evictions}] = :ets.lookup(@stats_table, :evictions)

    total = hits + misses
    hit_rate = if total > 0, do: Float.round(hits / total, 2), else: 0.0

    now = System.monotonic_time(:second)

    oldest =
      :ets.foldl(
        fn {_key, _response, _expires_at, _last_access, stored_at}, min_stored_at ->
          min(stored_at, min_stored_at)
        end,
        now,
        @table
      )
      |> then(fn min_stored_at ->
        if min_stored_at == now, do: 0, else: max(now - min_stored_at, 0)
      end)

    %{
      entries: entries,
      hits: hits,
      misses: misses,
      evictions: evictions,
      hit_rate: hit_rate,
      oldest_entry_age_s: oldest
    }
  end

  @doc "Returns unexpired A and AAAA cache entries without exposing cached protocol structs."
  @spec entries() :: [
          %{domain: String.t(), address: :inet.ip_address(), expires_at: DateTime.t()}
        ]
  def entries do
    monotonic_now = System.monotonic_time(:second)
    utc_now = DateTime.utc_now()

    @table
    |> :ets.tab2list()
    |> Enum.flat_map(&project_entry(&1, monotonic_now, utc_now))
    |> Enum.sort_by(&{&1.domain, :inet.ntoa(&1.address)})
  rescue
    ArgumentError -> []
  end

  @doc false
  @spec revision_material() :: [map()]
  def revision_material do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {{domain, type}, _response, expires_at, _last_access, stored_at} ->
      %{
        "domain" => domain,
        "type" => to_string(type),
        "expires_at" => expires_at,
        "stored_at" => stored_at
      }
    end)
    |> Enum.sort_by(&{&1["domain"], &1["type"], &1["expires_at"], &1["stored_at"]})
  rescue
    ArgumentError -> []
  end

  # Server callbacks

  @impl true
  def init(config) do
    for t <- [@table, @stats_table, @lru_table] do
      try do: :ets.delete(t), catch: (_, _ -> :ok)
    end

    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    stats = :ets.new(@stats_table, [:named_table, :set, :public])
    :ets.new(@lru_table, [:named_table, :ordered_set, :public])

    :ets.insert(stats, [
      {:hits, 0},
      {:misses, 0},
      {:evictions, 0}
    ])

    sweep_interval = Map.get(config, :sweep_interval_s, 60) * 1000
    schedule_sweep(sweep_interval)

    state = %{
      table: table,
      stats: stats,
      max_entries: Map.get(config, :max_entries, 10_000),
      min_ttl_s: Map.get(config, :min_ttl_s, 30),
      max_ttl_s: Map.get(config, :max_ttl_s, 86_400),
      negative_ttl_s: Map.get(config, :negative_ttl_s, 60),
      sweep_interval: sweep_interval
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:update_config, cache_config}, state) do
    Logger.info("[Resolved] Cache config updated")

    new_sweep = Map.get(cache_config, :sweep_interval_s, 60) * 1000

    {:noreply,
     %{
       state
       | max_entries: Map.get(cache_config, :max_entries, state.max_entries),
         min_ttl_s: Map.get(cache_config, :min_ttl_s, state.min_ttl_s),
         max_ttl_s: Map.get(cache_config, :max_ttl_s, state.max_ttl_s),
         negative_ttl_s: Map.get(cache_config, :negative_ttl_s, state.negative_ttl_s),
         sweep_interval: new_sweep
     }}
  end

  def handle_cast({:store, domain, type, response, ttl}, state) do
    clamped_ttl = clamp_ttl(ttl, state.min_ttl_s, state.max_ttl_s)
    key = cache_key(domain, type)
    now = System.monotonic_time(:second)
    expires_at = now + clamped_ttl

    # Remove old LRU entry if key already exists; track if this is a new key
    is_new_key =
      case :ets.lookup(@table, key) do
        [{^key, _, _, old_access, _stored_at}] ->
          :ets.delete(@lru_table, {old_access, key})
          false

        [] ->
          true
      end

    # Enforce max entries via LRU eviction (only when inserting a new key)
    if is_new_key and :ets.info(@table, :size) >= state.max_entries do
      evict_lru()
    end

    :ets.insert(@table, {key, response, expires_at, now, now})
    :ets.insert(@lru_table, {{now, key}})

    :telemetry.execute(
      [:yellow_dog, :resolved, :cache, :store],
      %{},
      %{domain: domain, type: type, ttl: clamped_ttl}
    )

    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    count = :ets.info(@table, :size)
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@lru_table)

    :telemetry.execute(
      [:yellow_dog, :resolved, :cache, :flush],
      %{},
      %{pattern: nil, count: count}
    )

    {:reply, count, state}
  end

  def handle_call({:flush, domain}, _from, state) do
    # Flush all types for this domain
    count = flush_domain_entries(domain)

    :telemetry.execute(
      [:yellow_dog, :resolved, :cache, :flush],
      %{},
      %{pattern: domain, count: count}
    )

    {:reply, count, state}
  end

  def handle_call({:flush_pattern, pattern}, _from, state) do
    count = do_flush_pattern(pattern)

    :telemetry.execute(
      [:yellow_dog, :resolved, :cache, :flush],
      %{},
      %{pattern: pattern, count: count}
    )

    {:reply, count, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:second)
    expired = sweep_expired(now)

    if expired > 0 do
      :ets.update_counter(@stats_table, :evictions, expired)
    end

    schedule_sweep(state.sweep_interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Private

  defp project_entry({{domain, _type}, response, expires_at, _last_access, _stored_at}, now, utc)
       when expires_at > now do
    response
    |> response_addresses()
    |> Enum.map(fn address ->
      %{
        domain: domain,
        address: address,
        expires_at: DateTime.add(utc, expires_at - now, :second)
      }
    end)
  end

  defp project_entry(_entry, _now, _utc), do: []

  defp response_addresses(%DNS.Message{anlist: answers}) do
    Enum.flat_map(answers, fn
      %DNS.Message.Record{data: %DNS.Message.Record.Data.A{data: address}} -> [address]
      %DNS.Message.Record{data: %DNS.Message.Record.Data.AAAA{data: address}} -> [address]
      _record -> []
    end)
  end

  defp response_addresses(_response), do: []

  defp cache_key(domain, type) do
    {String.downcase(String.trim_trailing(domain, ".")), type}
  end

  defp clamp_ttl(ttl, min_ttl, max_ttl) do
    ttl |> max(min_ttl) |> min(max_ttl)
  end

  defp evict_lru do
    # O(log n) eviction using ordered_set LRU index
    case :ets.first(@lru_table) do
      :"$end_of_table" ->
        :ok

      {_access_time, key} = lru_key ->
        :ets.delete(@lru_table, lru_key)
        :ets.delete(@table, key)
        :ets.update_counter(@stats_table, :evictions, 1)
    end
  end

  defp sweep_expired(now) do
    # Delete expired entries from main table
    delete_spec = [{{:_, :_, :"$1", :_, :_}, [{:<, :"$1", now}], [true]}]
    count = :ets.select_delete(@table, delete_spec)

    if count > 0, do: sweep_lru_orphans()

    count
  end

  # Scan the LRU index for entries whose main-table key no longer exists.
  # This handles the race where a concurrent lookup updates last_access between
  # a main-table delete and the corresponding LRU delete, leaving an orphan
  # at the new timestamp that the original delete could not know about.
  defp sweep_lru_orphans do
    :ets.foldl(
      fn {{_access_time, key} = lru_key}, _acc ->
        if :ets.lookup(@table, key) == [] do
          :ets.delete(@lru_table, lru_key)
        end

        :ok
      end,
      :ok,
      @lru_table
    )
  end

  defp flush_domain_entries(domain) do
    normalized = String.downcase(String.trim_trailing(domain, "."))

    entries = :ets.match_object(@table, {{normalized, :_}, :_, :_, :_, :_})

    # Delete from main table first (best-effort LRU cleanup using snapshot access_time).
    # A concurrent lookup may have already updated last_access, leaving an orphaned
    # LRU entry — sweep_lru_orphans/0 handles those after.
    Enum.each(entries, fn {key, _, _, access_time, _stored_at} ->
      :ets.delete(@lru_table, {access_time, key})
      :ets.delete(@table, key)
    end)

    if length(entries) > 0, do: sweep_lru_orphans()

    length(entries)
  end

  defp do_flush_pattern("*." <> suffix) do
    normalized_suffix = String.downcase(suffix)

    count =
      :ets.foldl(
        fn {{domain, _type} = key, _, _, access_time, _stored_at}, count ->
          if domain == normalized_suffix or String.ends_with?(domain, "." <> normalized_suffix) do
            :ets.delete(@lru_table, {access_time, key})
            :ets.delete(@table, key)
            count + 1
          else
            count
          end
        end,
        0,
        @table
      )

    if count > 0, do: sweep_lru_orphans()
    count
  end

  defp do_flush_pattern(domain) do
    flush_domain_entries(domain)
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end
end
