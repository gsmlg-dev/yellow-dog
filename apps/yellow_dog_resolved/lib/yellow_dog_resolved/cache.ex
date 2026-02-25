defmodule YellowDog.Resolved.Cache do
  @moduledoc """
  ETS-based DNS response cache with TTL, negative caching, and LRU eviction.

  Cache keys are `{normalized_domain, query_type}`. Entries expire based on
  upstream TTL (clamped to configured min/max). Periodic sweep removes expired
  entries. LRU eviction kicks in when max_entries is exceeded.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @stats_table :"#{__MODULE__}.Stats"

  @type cache_entry :: {
          key :: {String.t(), atom()},
          response :: binary(),
          expires_at :: integer(),
          last_accessed :: integer(),
          negative :: boolean()
        }

  # Client API

  def start_link(cache_config) do
    GenServer.start_link(__MODULE__, cache_config, name: __MODULE__)
  end

  @doc "Look up a cached DNS response by domain and type."
  @spec lookup(String.t(), atom()) :: {:hit, binary()} | :miss
  def lookup(domain, type) do
    key = cache_key(domain, type)
    now = System.monotonic_time(:second)

    case :ets.lookup(@table, key) do
      [{^key, response, expires_at, _last_accessed, _negative}] when expires_at > now ->
        # Update last_accessed for LRU
        :ets.update_element(@table, key, {4, now})
        bump_stat(:hits)

        :telemetry.execute(
          [:yellow_dog, :resolved, :cache, :hit],
          %{},
          %{domain: domain, type: type}
        )

        {:hit, response}

      [{^key, _response, _expires_at, _last_accessed, _negative}] ->
        # Expired — lazy eviction
        :ets.delete(@table, key)
        bump_stat(:misses)
        bump_stat(:evictions)

        :telemetry.execute(
          [:yellow_dog, :resolved, :cache, :miss],
          %{},
          %{domain: domain, type: type}
        )

        :miss

      [] ->
        bump_stat(:misses)

        :telemetry.execute(
          [:yellow_dog, :resolved, :cache, :miss],
          %{},
          %{domain: domain, type: type}
        )

        :miss
    end
  end

  @doc "Store a DNS response in the cache with the given TTL."
  @spec store(String.t(), atom(), binary(), pos_integer()) :: :ok
  def store(domain, type, response, ttl) do
    GenServer.cast(__MODULE__, {:store, domain, type, response, ttl, false})
  end

  @doc "Store a negative (NXDOMAIN) response in the cache."
  @spec store_negative(String.t(), atom(), binary()) :: :ok
  def store_negative(domain, type, response) do
    GenServer.cast(__MODULE__, {:store, domain, type, response, :negative, true})
  end

  @doc "Flush the entire cache."
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc "Flush a specific domain from the cache."
  @spec flush(String.t()) :: :ok
  def flush(domain) do
    GenServer.call(__MODULE__, {:flush_domain, domain})
  end

  @doc "Flush entries matching a wildcard pattern. Returns count of flushed entries."
  @spec flush_pattern(String.t()) :: non_neg_integer()
  def flush_pattern(pattern) do
    GenServer.call(__MODULE__, {:flush_pattern, pattern})
  end

  @doc "Get cache statistics."
  @spec stats() :: map()
  def stats do
    entries = :ets.info(@table, :size)
    hits = get_stat(:hits)
    misses = get_stat(:misses)
    evictions = get_stat(:evictions)
    total = hits + misses
    hit_rate = if total > 0, do: Float.round(hits / total, 2), else: 0.0

    %{
      entries: entries,
      hits: hits,
      misses: misses,
      evictions: evictions,
      hit_rate: hit_rate
    }
  end

  # GenServer callbacks

  @impl true
  def init(cache_config) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@stats_table, [:named_table, :set, :public, write_concurrency: true])
    :ets.insert(@stats_table, [{:hits, 0}, {:misses, 0}, {:evictions, 0}])

    state = %{
      max_entries: Map.get(cache_config, :max_entries, 10_000),
      min_ttl_s: Map.get(cache_config, :min_ttl_s, 30),
      max_ttl_s: Map.get(cache_config, :max_ttl_s, 86_400),
      negative_ttl_s: Map.get(cache_config, :negative_ttl_s, 60),
      sweep_interval_s: Map.get(cache_config, :sweep_interval_s, 60)
    }

    schedule_sweep(state.sweep_interval_s)
    {:ok, state}
  end

  @impl true
  def handle_cast({:store, domain, type, response, ttl, negative}, state) do
    key = cache_key(domain, type)
    now = System.monotonic_time(:second)

    actual_ttl =
      if ttl == :negative do
        state.negative_ttl_s
      else
        ttl |> max(state.min_ttl_s) |> min(state.max_ttl_s)
      end

    expires_at = now + actual_ttl
    :ets.insert(@table, {key, response, expires_at, now, negative})

    :telemetry.execute(
      [:yellow_dog, :resolved, :cache, :store],
      %{},
      %{domain: domain, type: type, ttl: actual_ttl}
    )

    maybe_evict_lru(state)
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

  @impl true
  def handle_call({:flush_domain, domain}, _from, state) do
    normalized = String.downcase(domain) |> String.trim_trailing(".")
    # Delete all type variants for this domain
    count = flush_matching(fn {key_domain, _type} -> key_domain == normalized end)

    :telemetry.execute(
      [:yellow_dog, :resolved, :cache, :flush],
      %{},
      %{pattern: domain, count: count}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:flush_pattern, pattern}, _from, state) do
    count =
      case pattern do
        "*." <> suffix ->
          suffix = String.downcase(suffix)

          flush_matching(fn {key_domain, _type} ->
            key_domain == suffix or String.ends_with?(key_domain, "." <> suffix)
          end)

        exact ->
          exact = String.downcase(exact) |> String.trim_trailing(".")
          flush_matching(fn {key_domain, _type} -> key_domain == exact end)
      end

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
    expired_count = sweep_expired(now)

    if expired_count > 0 do
      bump_stat(:evictions, expired_count)
    end

    schedule_sweep(state.sweep_interval_s)
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp cache_key(domain, type) do
    {String.downcase(domain) |> String.trim_trailing("."), type}
  end

  defp schedule_sweep(interval_s) do
    Process.send_after(self(), :sweep, interval_s * 1000)
  end

  defp sweep_expired(now) do
    # Fold over all entries and delete expired ones
    :ets.foldl(
      fn {key, _response, expires_at, _last_accessed, _negative}, acc ->
        if expires_at <= now do
          :ets.delete(@table, key)
          acc + 1
        else
          acc
        end
      end,
      0,
      @table
    )
  end

  defp maybe_evict_lru(state) do
    size = :ets.info(@table, :size)

    if size > state.max_entries do
      evict_count = size - state.max_entries

      # Get all entries sorted by last_accessed (oldest first)
      entries =
        :ets.foldl(
          fn {key, _response, _expires, last_accessed, _negative}, acc ->
            [{key, last_accessed} | acc]
          end,
          [],
          @table
        )
        |> Enum.sort_by(&elem(&1, 1))
        |> Enum.take(evict_count)

      Enum.each(entries, fn {key, _} -> :ets.delete(@table, key) end)
      bump_stat(:evictions, evict_count)
    end
  end

  defp flush_matching(match_fn) do
    :ets.foldl(
      fn {key, _response, _expires, _last_accessed, _negative}, acc ->
        if match_fn.(key) do
          :ets.delete(@table, key)
          acc + 1
        else
          acc
        end
      end,
      0,
      @table
    )
  end

  defp bump_stat(key, amount \\ 1) do
    :ets.update_counter(@stats_table, key, amount)
  catch
    :error, :badarg -> :ok
  end

  defp get_stat(key) do
    case :ets.lookup(@stats_table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  catch
    :error, :badarg -> 0
  end
end
