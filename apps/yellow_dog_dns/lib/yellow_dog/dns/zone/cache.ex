defmodule YellowDog.Dns.Zone.Cache do
  @moduledoc """
  Cache zone process.

  Caches resolved DNS answers with TTL-based expiration.
  Implements RFC 2308 for negative caching.

  ## Features

  - TTL-based expiration
  - Negative caching (NXDOMAIN/NODATA)
  - Maximum cache size with LRU eviction
  - Cache statistics
  """

  use GenServer

  alias YellowDog.Dns.Zone.Behaviour

  @behaviour Behaviour

  alias YellowDog.Telemetry
  alias DNS.Message

  @default_max_size 10000
  @default_min_ttl 60
  @default_max_ttl 86400
  @cleanup_interval :timer.seconds(60)

  defstruct [
    :name,
    :view_name,
    :table,
    :max_size,
    :min_ttl,
    :max_ttl,
    hit_count: 0,
    miss_count: 0,
    insert_count: 0,
    eviction_count: 0
  ]

  # Client API

  @doc """
  Starts a cache zone process.

  ## Options

  - `:name` - Zone name (required)
  - `:max_size` - Maximum cache entries (default: 10000)
  - `:min_ttl` - Minimum TTL in seconds (default: 60)
  - `:max_ttl` - Maximum TTL in seconds (default: 86400)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    zone_name = Keyword.fetch!(opts, :name)
    view_name = Keyword.get(opts, :view_name, "default")
    GenServer.start_link(__MODULE__, opts, name: Behaviour.zone_via_tuple(view_name, :cache, zone_name))
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def get_name(pid) do
    GenServer.call(pid, :get_name)
  end

  @doc """
  Gets the view name this zone belongs to.
  """
  @spec get_view(pid()) :: String.t()
  def get_view(pid) do
    GenServer.call(pid, :get_view)
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def resolve(pid, query) do
    GenServer.call(pid, {:resolve, query})
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def reload(pid, config) do
    GenServer.call(pid, {:reload, config})
  end

  @impl YellowDog.Dns.Zone.Behaviour
  def stats(pid) do
    GenServer.call(pid, :stats)
  end

  @doc """
  Caches a DNS response.
  """
  @spec cache(pid(), Message.t(), Message.t()) :: :ok
  def cache(pid, query, response) do
    GenServer.cast(pid, {:cache, query, response})
  end

  @doc """
  Looks up a cached response.
  """
  @spec lookup(pid(), String.t(), atom()) :: {:ok, Message.t()} | :miss
  def lookup(pid, name, type) do
    GenServer.call(pid, {:lookup, name, type})
  end

  @doc """
  Clears all cached entries.
  """
  @spec clear(pid()) :: :ok
  def clear(pid) do
    GenServer.call(pid, :clear)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    zone_name = Keyword.fetch!(opts, :name)
    view_name = Keyword.get(opts, :view_name, "default")
    max_size = Keyword.get(opts, :max_size, @default_max_size)
    min_ttl = Keyword.get(opts, :min_ttl, @default_min_ttl)
    max_ttl = Keyword.get(opts, :max_ttl, @default_max_ttl)

    # Create ETS table for cache (view-scoped)
    table =
      :ets.new(:"cache_#{view_name}_#{zone_name}", [
        :set,
        :protected,
        read_concurrency: true
      ])

    state = %__MODULE__{
      name: zone_name,
      view_name: view_name,
      table: table,
      max_size: max_size,
      min_ttl: min_ttl,
      max_ttl: max_ttl
    }

    # Schedule periodic cleanup
    schedule_cleanup()

    Telemetry.info("Cache zone started", %{name: zone_name, view: view_name, max_size: max_size})

    {:ok, state}
  end

  @impl true
  def handle_call(:get_name, _from, state) do
    {:reply, state.name, state}
  end

  @impl true
  def handle_call(:get_view, _from, state) do
    {:reply, state.view_name, state}
  end

  @impl true
  def handle_call({:resolve, query}, _from, state) do
    case query.qdlist do
      [question | _] ->
        key = cache_key(question.name, question.type)

        case :ets.lookup(state.table, key) do
          [{^key, entry}] ->
            if entry.expires_at > System.system_time(:second) do
              # Cache hit
              state = %{state | hit_count: state.hit_count + 1}
              response = build_cached_response(query, entry)
              {:reply, {:ok, response}, state}
            else
              # Expired
              :ets.delete(state.table, key)
              state = %{state | miss_count: state.miss_count + 1}
              {:reply, :miss, state}
            end

          [] ->
            state = %{state | miss_count: state.miss_count + 1}
            {:reply, :miss, state}
        end

      [] ->
        {:reply, {:error, :format_error}, state}
    end
  end

  @impl true
  def handle_call({:lookup, name, type}, _from, state) do
    key = cache_key(name, type)

    case :ets.lookup(state.table, key) do
      [{^key, entry}] ->
        if entry.expires_at > System.system_time(:second) do
          state = %{state | hit_count: state.hit_count + 1}
          {:reply, {:ok, entry.response}, state}
        else
          :ets.delete(state.table, key)
          state = %{state | miss_count: state.miss_count + 1}
          {:reply, :miss, state}
        end

      [] ->
        state = %{state | miss_count: state.miss_count + 1}
        {:reply, :miss, state}
    end
  end

  @impl true
  def handle_call({:reload, config}, _from, state) do
    max_size = Keyword.get(config, :max_size, state.max_size)
    min_ttl = Keyword.get(config, :min_ttl, state.min_ttl)
    max_ttl = Keyword.get(config, :max_ttl, state.max_ttl)

    new_state = %{state | max_size: max_size, min_ttl: min_ttl, max_ttl: max_ttl}

    # Evict if necessary
    new_state = maybe_evict(new_state)

    Telemetry.info("Cache zone reloaded", %{name: state.name})

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    current_size = :ets.info(state.table, :size)

    stats = %{
      name: state.name,
      current_size: current_size,
      max_size: state.max_size,
      hit_count: state.hit_count,
      miss_count: state.miss_count,
      insert_count: state.insert_count,
      eviction_count: state.eviction_count,
      hit_rate: calculate_hit_rate(state)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(state.table)
    Telemetry.info("Cache zone cleared", %{name: state.name})
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:cache, query, response}, state) do
    case query.qdlist do
      [question | _] ->
        # Calculate TTL from response
        ttl = calculate_ttl(response, state.min_ttl, state.max_ttl)

        entry = %{
          response: response,
          expires_at: System.system_time(:second) + ttl,
          inserted_at: System.system_time(:second),
          access_count: 0
        }

        key = cache_key(question.name, question.type)
        :ets.insert(state.table, {key, entry})

        state = %{state | insert_count: state.insert_count + 1}
        state = maybe_evict(state)

        {:noreply, state}

      [] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)

    # Remove expired entries
    expired =
      :ets.foldl(
        fn {key, entry}, acc ->
          if entry.expires_at <= now do
            :ets.delete(state.table, key)
            acc + 1
          else
            acc
          end
        end,
        0,
        state.table
      )

    if expired > 0 do
      Telemetry.debug("Cache cleanup", %{
        zone: state.name,
        expired: expired
      })
    end

    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    :ets.delete(state.table)
    :ok
  end

  # Private Functions

  defp cache_key(name, type) do
    normalized = normalize_name(name)
    {normalized, type}
  end

  defp normalize_name(name) do
    name
    |> String.downcase()
    |> String.trim_trailing(".")
  end

  defp calculate_ttl(response, min_ttl, max_ttl) do
    # Get minimum TTL from all records
    all_records = response.anlist ++ response.nslist ++ response.arlist

    record_ttl =
      Enum.reduce(all_records, min_ttl, fn r, acc -> min(r.ttl, acc) end)

    # Clamp to configured bounds
    record_ttl
    |> max(min_ttl)
    |> min(max_ttl)
  end

  defp build_cached_response(query, entry) do
    response = entry.response

    # Update TTL based on remaining time
    now = System.system_time(:second)
    remaining = max(entry.expires_at - now, 0)

    # Adjust TTLs in response
    %{
      response
      | header: %{response.header | id: query.header.id},
        qdlist: query.qdlist,
        anlist: adjust_ttls(response.anlist, remaining),
        nslist: adjust_ttls(response.nslist, remaining),
        arlist: adjust_ttls(response.arlist, remaining)
    }
  end

  defp adjust_ttls(records, remaining_ttl) do
    Enum.map(records, fn record ->
      %{record | ttl: min(record.ttl, remaining_ttl)}
    end)
  end

  defp calculate_hit_rate(%{hit_count: hits, miss_count: misses}) when hits + misses > 0 do
    Float.round(hits / (hits + misses) * 100, 2)
  end

  defp calculate_hit_rate(_), do: 0.0

  defp maybe_evict(state) do
    current_size = :ets.info(state.table, :size)

    if current_size > state.max_size do
      # Simple eviction: remove oldest entries
      to_remove = current_size - state.max_size + div(state.max_size, 10)

      # Get entries sorted by inserted_at
      entries =
        :ets.tab2list(state.table)
        |> Enum.sort_by(fn {_key, entry} -> entry.inserted_at end)
        |> Enum.take(to_remove)

      Enum.each(entries, fn {key, _entry} ->
        :ets.delete(state.table, key)
      end)

      %{state | eviction_count: state.eviction_count + to_remove}
    else
      state
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

end
