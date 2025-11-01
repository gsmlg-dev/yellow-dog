defmodule YellowDog.Dns.Query.Cache.Manager do
  @moduledoc """
  Manages DNS query cache lifecycle and configuration.

  The Cache Manager is a GenServer that coordinates cache operations,
  maintains statistics counters, and enforces cache policies like
  TTL limits and maximum entry counts.

  ## Configuration

  The manager accepts the following options:
  - `:enabled` - Enable/disable caching (default: true)
  - `:max_entries` - Maximum number of entries (default: 10000)
  - `:max_memory_mb` - Maximum memory usage in MB (default: 100)
  - `:min_ttl` - Minimum TTL in seconds (default: 0)
  - `:max_ttl` - Maximum TTL in seconds (default: 86400)
  - `:negative_ttl` - TTL for negative responses (default: 300)

  ## Examples

      iex> {:ok, _pid} = Manager.start_link(enabled: true, max_entries: 5000)
      iex> Manager.put("www.example.com.", :A, records, [], 300)
      :ok
      iex> Manager.get("www.example.com.", :A)
      {:ok, records, authority}
  """

  use GenServer
  require Logger

  alias YellowDog.Dns.Query.Cache.{Entry, Storage, Stats}
  alias YellowDog.Dns.Zone

  @default_config %{
    enabled: true,
    max_entries: 10_000,
    max_memory_mb: 100,
    min_ttl: 0,
    max_ttl: 86_400,
    negative_ttl: 300
  }

  defmodule State do
    @moduledoc false
    defstruct [
      :config,
      :counters,
      :started_at
    ]

    @type t :: %__MODULE__{
            config: map(),
            counters: map(),
            started_at: integer()
          }
  end

  # Client API

  @doc """
  Starts the cache manager.

  ## Parameters
  - `opts` - Configuration options (see module documentation)

  ## Returns
  `{:ok, pid}` or `{:error, reason}`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets a cached entry.

  Returns the cached records if found and not expired. Automatically
  updates TTLs in the returned records to reflect remaining time.

  ## Parameters
  - `query_name` - The query name
  - `query_type` - The query type
  - `query_class` - The query class (default: :IN)

  ## Returns
  - `{:ok, records, authority}` if found and not expired
  - `{:error, :not_found}` if not in cache or expired
  - `{:error, :disabled}` if caching is disabled

  ## Examples

      iex> Manager.get("www.example.com.", :A)
      {:ok, [%Record{...}], []}
  """
  @spec get(String.t(), atom(), atom()) ::
          {:ok, [Zone.Record.t()], [any()]} | {:error, :not_found | :disabled}
  def get(query_name, query_type, query_class \\ :IN) do
    GenServer.call(__MODULE__, {:get, query_name, query_type, query_class})
  end

  @doc """
  Stores an entry in the cache.

  Applies TTL clamping based on configuration and stores the entry.
  Enforces maximum entry limits using LRU eviction if necessary.

  ## Parameters
  - `query_name` - The query name
  - `query_type` - The query type
  - `records` - List of answer records
  - `authority` - List of authority records
  - `ttl` - Time to live in seconds
  - `opts` - Options:
    - `:query_class` - Query class (default: :IN)
    - `:response_type` - Response type (default: :answer)

  ## Returns
  - `:ok` if stored successfully
  - `{:error, :disabled}` if caching is disabled

  ## Examples

      iex> Manager.put("www.example.com.", :A, records, [], 300)
      :ok
  """
  @spec put(String.t(), atom(), [Zone.Record.t()], [any()], non_neg_integer(), keyword()) ::
          :ok | {:error, :disabled}
  def put(query_name, query_type, records, authority, ttl, opts \\ []) do
    GenServer.call(
      __MODULE__,
      {:put, query_name, query_type, records, authority, ttl, opts}
    )
  end

  @doc """
  Invalidates a cache entry.

  Removes the entry from the cache if it exists.

  ## Parameters
  - `query_name` - The query name
  - `query_type` - The query type
  - `query_class` - The query class (default: :IN)

  ## Returns
  `:ok`

  ## Examples

      iex> Manager.invalidate("www.example.com.", :A)
      :ok
  """
  @spec invalidate(String.t(), atom(), atom()) :: :ok
  def invalidate(query_name, query_type, query_class \\ :IN) do
    GenServer.call(__MODULE__, {:invalidate, query_name, query_type, query_class})
  end

  @doc """
  Flushes all cache entries.

  Removes all entries from the cache and resets statistics.

  ## Returns
  `:ok`

  ## Examples

      iex> Manager.flush()
      :ok
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @doc """
  Gets cache statistics.

  ## Returns
  `Stats.t()` struct with current statistics

  ## Examples

      iex> stats = Manager.stats()
      %Stats{total_entries: 100, hit_count: 850, ...}
  """
  @spec stats() :: Stats.t()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Checks if caching is enabled.

  ## Returns
  `true` if enabled, `false` otherwise

  ## Examples

      iex> Manager.enabled?()
      true
  """
  @spec enabled?() :: boolean()
  def enabled? do
    GenServer.call(__MODULE__, :enabled?)
  end

  @doc """
  Gets the current configuration.

  ## Returns
  Configuration map

  ## Examples

      iex> Manager.get_config()
      %{enabled: true, max_entries: 10000, ...}
  """
  @spec get_config() :: map()
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  @doc """
  Updates the configuration.

  ## Parameters
  - `config` - Map of configuration options to update

  ## Returns
  `:ok`

  ## Examples

      iex> Manager.update_config(%{max_entries: 5000})
      :ok
  """
  @spec update_config(map()) :: :ok
  def update_config(config) do
    GenServer.call(__MODULE__, {:update_config, config})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    # Initialize storage
    Storage.init()

    # Build configuration
    config =
      @default_config
      |> Map.merge(Map.new(opts))

    # Initialize counters
    counters = %{
      hit_count: 0,
      miss_count: 0,
      insert_count: 0,
      eviction_count: 0,
      expired_count: 0
    }

    state = %State{
      config: config,
      counters: counters,
      started_at: System.monotonic_time(:second)
    }

    Logger.info("DNS Query Cache Manager started",
      enabled: config.enabled,
      max_entries: config.max_entries
    )

    {:ok, state}
  end

  @impl true
  def handle_call({:get, query_name, query_type, query_class}, _from, state) do
    if state.config.enabled do
      case Storage.lookup(query_name, query_type, query_class) do
        {:ok, entry} ->
          if Entry.expired?(entry) do
            # Entry expired, remove it
            Storage.delete(query_name, query_type, query_class)
            counters = update_counter(state.counters, :miss_count)
            counters = update_counter(counters, :expired_count)
            {:reply, {:error, :not_found}, %{state | counters: counters}}
          else
            # Entry valid, update TTLs and record hit
            updated_entry = entry |> Entry.record_hit() |> Entry.update_ttls()
            Storage.insert(updated_entry)

            counters = update_counter(state.counters, :hit_count)

            # Emit telemetry
            :telemetry.execute(
              [:yellow_dog, :dns, :cache, :hit],
              %{count: 1},
              %{query_name: query_name, query_type: query_type}
            )

            {:reply, {:ok, updated_entry.records, updated_entry.authority},
             %{state | counters: counters}}
          end

        {:error, :not_found} ->
          counters = update_counter(state.counters, :miss_count)

          # Emit telemetry
          :telemetry.execute(
            [:yellow_dog, :dns, :cache, :miss],
            %{count: 1},
            %{query_name: query_name, query_type: query_type}
          )

          {:reply, {:error, :not_found}, %{state | counters: counters}}
      end
    else
      {:reply, {:error, :disabled}, state}
    end
  end

  @impl true
  def handle_call(
        {:put, query_name, query_type, records, authority, ttl, opts},
        _from,
        state
      ) do
    if state.config.enabled do
      # Clamp TTL
      clamped_ttl = clamp_ttl(ttl, records, state.config, opts)

      # Create entry
      entry_opts = Keyword.merge(opts, query_class: Keyword.get(opts, :query_class, :IN))
      entry = Entry.new(query_name, query_type, records, authority, clamped_ttl, entry_opts)

      # Store entry
      Storage.insert(entry)

      # Update counters
      counters = update_counter(state.counters, :insert_count)

      # Enforce limits
      {counters, evicted} = enforce_limits(state.config, counters)

      # Emit telemetry
      :telemetry.execute(
        [:yellow_dog, :dns, :cache, :insert],
        %{count: 1, ttl: clamped_ttl},
        %{query_name: query_name, query_type: query_type, response_type: entry.response_type}
      )

      if evicted > 0 do
        :telemetry.execute(
          [:yellow_dog, :dns, :cache, :eviction],
          %{count: evicted},
          %{}
        )
      end

      {:reply, :ok, %{state | counters: counters}}
    else
      {:reply, {:error, :disabled}, state}
    end
  end

  @impl true
  def handle_call({:invalidate, query_name, query_type, query_class}, _from, state) do
    Storage.delete(query_name, query_type, query_class)

    :telemetry.execute(
      [:yellow_dog, :dns, :cache, :invalidation],
      %{count: 1},
      %{query_name: query_name, query_type: query_type}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    Storage.flush()

    # Reset counters
    counters = %{
      hit_count: 0,
      miss_count: 0,
      insert_count: 0,
      eviction_count: 0,
      expired_count: 0
    }

    :telemetry.execute(
      [:yellow_dog, :dns, :cache, :flush],
      %{count: 1},
      %{}
    )

    {:reply, :ok, %{state | counters: counters}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = Stats.collect(state.counters)
    {:reply, stats, state}
  end

  @impl true
  def handle_call(:enabled?, _from, state) do
    {:reply, state.config.enabled, state}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  @impl true
  def handle_call({:update_config, new_config}, _from, state) do
    updated_config = Map.merge(state.config, new_config)
    {:reply, :ok, %{state | config: updated_config}}
  end

  # Private Functions

  defp update_counter(counters, key) do
    Map.update(counters, key, 1, &(&1 + 1))
  end

  defp clamp_ttl(ttl, records, config, opts) do
    # Use negative TTL for NXDOMAIN/NODATA responses
    ttl =
      case Keyword.get(opts, :response_type) do
        :nxdomain -> config.negative_ttl
        :nodata -> config.negative_ttl
        _ -> extract_min_ttl(records, ttl)
      end

    # Apply min/max TTL limits
    ttl
    |> max(config.min_ttl)
    |> min(config.max_ttl)
  end

  defp extract_min_ttl([], default_ttl), do: default_ttl

  defp extract_min_ttl(records, default_ttl) do
    records
    |> Enum.map(fn
      %Zone.Record{ttl: ttl} -> ttl
      _ -> default_ttl
    end)
    |> Enum.min(fn -> default_ttl end)
  end

  defp enforce_limits(config, counters) do
    current_count = Storage.count()

    if current_count > config.max_entries do
      evicted = Storage.evict_lru(config.max_entries)
      counters = Map.update(counters, :eviction_count, evicted, &(&1 + evicted))
      {counters, evicted}
    else
      {counters, 0}
    end
  end
end
