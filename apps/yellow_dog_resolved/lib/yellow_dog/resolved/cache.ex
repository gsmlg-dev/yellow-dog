defmodule YellowDog.Resolved.Cache do
  @moduledoc """
  ETS-based DNS cache with TTL, negative caching, and LRU eviction.
  """
  use GenServer

  require Logger

  @table :resolved_dns_cache
  @stats_table :resolved_cache_stats

  # Client API

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @spec lookup(String.t(), atom()) :: {:hit, term()} | :miss
  def lookup(domain, type) do
    key = cache_key(domain, type)
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, response, expires_at, _inserted_at}] when expires_at > now ->
        :ets.update_counter(@stats_table, :hits, 1)
        # Update last access time for LRU
        :ets.update_element(@table, key, {4, now})

        :telemetry.execute(
          [:yellow_dog, :resolved, :cache, :hit],
          %{},
          %{domain: domain, type: type}
        )

        {:hit, response}

      [{^key, _response, _expires_at, _inserted_at}] ->
        # Expired - lazy eviction
        :ets.delete(@table, key)
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

  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @spec flush(String.t()) :: :ok
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

    oldest =
      case :ets.first(@table) do
        :"$end_of_table" ->
          0

        key ->
          now = System.monotonic_time(:second)
          [{_, _, _, inserted_at}] = :ets.lookup(@table, key)
          max(now - inserted_at, 0)
      end

    %{
      entries: entries,
      hits: hits,
      misses: misses,
      evictions: evictions,
      hit_rate: hit_rate,
      oldest_entry_age_s: oldest
    }
  end

  # Server callbacks

  @impl true
  def init(config) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    stats = :ets.new(@stats_table, [:named_table, :set, :public])

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
  def handle_cast({:store, domain, type, response, ttl}, state) do
    clamped_ttl = clamp_ttl(ttl, state.min_ttl_s, state.max_ttl_s)
    key = cache_key(domain, type)
    now = System.monotonic_time(:second)
    expires_at = now + clamped_ttl

    # Enforce max entries via LRU eviction
    if :ets.info(@table, :size) >= state.max_entries do
      evict_lru()
    end

    :ets.insert(@table, {key, response, expires_at, now})

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

    :telemetry.execute(
      [:yellow_dog, :resolved, :cache, :flush],
      %{},
      %{pattern: nil, count: count}
    )

    {:reply, :ok, state}
  end

  def handle_call({:flush, domain}, _from, state) do
    # Flush all types for this domain
    count = flush_domain_entries(domain)

    :telemetry.execute(
      [:yellow_dog, :resolved, :cache, :flush],
      %{},
      %{pattern: domain, count: count}
    )

    {:reply, :ok, state}
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

  defp cache_key(domain, type) do
    {String.downcase(String.trim_trailing(domain, ".")), type}
  end

  defp clamp_ttl(ttl, min_ttl, max_ttl) do
    ttl |> max(min_ttl) |> min(max_ttl)
  end

  defp evict_lru do
    # Find the entry with the oldest access time
    case :ets.match_object(@table, {:_, :_, :_, :_}) do
      [] ->
        :ok

      entries ->
        {oldest_key, _, _, _} = Enum.min_by(entries, fn {_, _, _, accessed_at} -> accessed_at end)
        :ets.delete(@table, oldest_key)
        :ets.update_counter(@stats_table, :evictions, 1)
    end
  end

  defp sweep_expired(now) do
    # Use match_spec to find and delete expired entries
    match_spec = [{{:_, :_, :"$1", :_}, [{:<, :"$1", now}], [true]}]
    :ets.select_delete(@table, match_spec)
  end

  defp flush_domain_entries(domain) do
    normalized = String.downcase(String.trim_trailing(domain, "."))
    match_spec = [{{{normalized, :_}, :_, :_, :_}, [], [true]}]
    :ets.select_delete(@table, match_spec)
  end

  defp do_flush_pattern("*." <> suffix) do
    normalized_suffix = String.downcase(suffix)

    :ets.foldl(
      fn {{domain, _type} = key, _, _, _}, count ->
        if domain == normalized_suffix or String.ends_with?(domain, "." <> normalized_suffix) do
          :ets.delete(@table, key)
          count + 1
        else
          count
        end
      end,
      0,
      @table
    )
  end

  defp do_flush_pattern(domain) do
    flush_domain_entries(domain)
  end

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end
end
