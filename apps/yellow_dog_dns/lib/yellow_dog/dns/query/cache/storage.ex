defmodule YellowDog.Dns.Query.Cache.Storage do
  @moduledoc """
  ETS-based storage for DNS query cache.

  Provides thread-safe storage and retrieval of cache entries using
  Erlang Term Storage (ETS). The table is designed for concurrent
  read access with write locks for modifications.

  ## Table Structure
  The ETS table is a `:set` type with the following structure:
  - Key: `{query_name, query_type, query_class}`
  - Value: `Cache.Entry.t()`

  ## Examples

      iex> Storage.init()
      :ok

      iex> entry = Entry.new("www.example.com.", :A, records, [], 300)
      iex> Storage.insert(entry)
      :ok

      iex> Storage.lookup("www.example.com.", :A)
      {:ok, entry}
  """

  alias YellowDog.Dns.Query.Cache.Entry

  @table_name :dns_query_cache

  @doc """
  Initializes the ETS table for cache storage.

  Creates a new named ETS table with the following properties:
  - Type: `:set` (unique keys)
  - Access: `:public` (readable/writable by all processes)
  - Named table: `:dns_query_cache`
  - Options: `read_concurrency: true` for optimized concurrent reads

  ## Returns
  - `:ok` if table created successfully
  - `{:error, :already_exists}` if table already exists

  ## Examples

      iex> Storage.init()
      :ok
  """
  @spec init() :: :ok | {:error, :already_exists}
  def init do
    case :ets.whereis(@table_name) do
      :undefined ->
        :ets.new(@table_name, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _tid ->
        {:error, :already_exists}
    end
  end

  @doc """
  Inserts or updates a cache entry.

  ## Parameters
  - `entry` - The cache entry to insert

  ## Returns
  `:ok`

  ## Examples

      iex> entry = Entry.new("www.example.com.", :A, records, [], 300)
      iex> Storage.insert(entry)
      :ok
  """
  @spec insert(Entry.t()) :: :ok
  def insert(%Entry{} = entry) do
    key = Entry.cache_key(entry.query_name, entry.query_type, entry.query_class)
    :ets.insert(@table_name, {key, entry})
    :ok
  end

  @doc """
  Looks up a cache entry by query parameters.

  ## Parameters
  - `query_name` - The query name
  - `query_type` - The query type
  - `query_class` - The query class (default: :IN)

  ## Returns
  - `{:ok, entry}` if found
  - `{:error, :not_found}` if not found

  ## Examples

      iex> Storage.lookup("www.example.com.", :A)
      {:ok, %Entry{...}}

      iex> Storage.lookup("nonexistent.com.", :A)
      {:error, :not_found}
  """
  @spec lookup(String.t(), atom(), atom()) :: {:ok, Entry.t()} | {:error, :not_found}
  def lookup(query_name, query_type, query_class \\ :IN) do
    key = Entry.cache_key(query_name, query_type, query_class)

    case :ets.lookup(@table_name, key) do
      [{^key, entry}] -> {:ok, entry}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Deletes a cache entry by query parameters.

  ## Parameters
  - `query_name` - The query name
  - `query_type` - The query type
  - `query_class` - The query class (default: :IN)

  ## Returns
  `:ok`

  ## Examples

      iex> Storage.delete("www.example.com.", :A)
      :ok
  """
  @spec delete(String.t(), atom(), atom()) :: :ok
  def delete(query_name, query_type, query_class \\ :IN) do
    key = Entry.cache_key(query_name, query_type, query_class)
    :ets.delete(@table_name, key)
    :ok
  end

  @doc """
  Clears all entries from the cache.

  ## Returns
  `:ok`

  ## Examples

      iex> Storage.flush()
      :ok
  """
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  @doc """
  Gets all cache entries.

  Returns all entries in the cache as a list. Useful for
  statistics collection and debugging.

  ## Returns
  List of all cache entries

  ## Examples

      iex> Storage.all_entries()
      [%Entry{...}, %Entry{...}]
  """
  @spec all_entries() :: [Entry.t()]
  def all_entries do
    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_key, entry} -> entry end)
  end

  @doc """
  Counts the total number of entries in the cache.

  ## Returns
  Non-negative integer count

  ## Examples

      iex> Storage.count()
      42
  """
  @spec count() :: non_neg_integer()
  def count do
    :ets.info(@table_name, :size)
  end

  @doc """
  Removes all expired entries from the cache.

  Iterates through all entries and deletes those that have expired.

  ## Returns
  Number of entries removed

  ## Examples

      iex> Storage.remove_expired()
      5
  """
  @spec remove_expired() :: non_neg_integer()
  def remove_expired do
    now = System.monotonic_time(:second)

    match_spec = [
      {
        # Match pattern: {key, entry}
        {{:"$1", :"$2", :"$3"}, %Entry{expires_at: :"$4"}},
        # Guard: expires_at < now
        [{:<, :"$4", now}],
        # Return: the key tuple
        [{{:"$1", :"$2", :"$3"}}]
      }
    ]

    expired_keys = :ets.select(@table_name, match_spec)

    Enum.each(expired_keys, fn key ->
      :ets.delete(@table_name, key)
    end)

    length(expired_keys)
  end

  @doc """
  Gets memory usage information for the cache.

  ## Returns
  Map with memory statistics:
  - `:bytes` - Total memory in bytes
  - `:words` - Total memory in words
  - `:mb` - Total memory in megabytes (float)

  ## Examples

      iex> Storage.memory_info()
      %{bytes: 12345, words: 1543, mb: 0.012}
  """
  @spec memory_info() :: %{bytes: non_neg_integer(), words: non_neg_integer(), mb: float()}
  def memory_info do
    words = :ets.info(@table_name, :memory)
    word_size = :erlang.system_info(:wordsize)
    bytes = words * word_size
    mb = bytes / 1_024 / 1_024

    %{
      bytes: bytes,
      words: words,
      mb: Float.round(mb, 2)
    }
  end

  @doc """
  Evicts the least recently used entries.

  Removes entries with the oldest insertion times until the target
  count is reached.

  ## Parameters
  - `target_count` - Target number of entries to keep

  ## Returns
  Number of entries evicted

  ## Examples

      iex> Storage.evict_lru(1000)
      50
  """
  @spec evict_lru(non_neg_integer()) :: non_neg_integer()
  def evict_lru(target_count) when target_count >= 0 do
    current_count = count()

    if current_count > target_count do
      evict_count = current_count - target_count

      # Get all entries sorted by insertion time (oldest first)
      entries_to_evict =
        all_entries()
        |> Enum.sort_by(& &1.inserted_at)
        |> Enum.take(evict_count)

      # Delete the oldest entries
      Enum.each(entries_to_evict, fn entry ->
        delete(entry.query_name, entry.query_type, entry.query_class)
      end)

      evict_count
    else
      0
    end
  end

  @doc """
  Checks if the ETS table exists.

  ## Returns
  `true` if table exists, `false` otherwise

  ## Examples

      iex> Storage.exists?()
      true
  """
  @spec exists?() :: boolean()
  def exists? do
    case :ets.whereis(@table_name) do
      :undefined -> false
      _tid -> true
    end
  end

  @doc """
  Gets detailed table information.

  ## Returns
  Map with table statistics

  ## Examples

      iex> Storage.table_info()
      %{size: 100, memory: 5000, name: :dns_query_cache}
  """
  @spec table_info() :: map()
  def table_info do
    if exists?() do
      %{
        name: @table_name,
        size: :ets.info(@table_name, :size),
        memory_words: :ets.info(@table_name, :memory),
        type: :ets.info(@table_name, :type),
        protection: :ets.info(@table_name, :protection)
      }
    else
      %{error: :not_initialized}
    end
  end
end
