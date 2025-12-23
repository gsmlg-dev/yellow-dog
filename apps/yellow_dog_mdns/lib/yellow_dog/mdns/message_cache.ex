defmodule YellowDog.Mdns.MessageCache do
  @moduledoc """
  Caches mDNS broadcast messages for later retrieval.

  Stores incoming mDNS messages with their source information in ETS,
  allowing queries for .local domains and service discovery.
  """

  use GenServer

  @table_name :mdns_message_cache
  @ets_options [:named_table, :public, :bag, read_concurrency: true, write_concurrency: true]
  # Cleanup every 5 minutes
  @cleanup_interval 300_000
  # Default TTL for cached records (2 minutes)
  @default_ttl 120

  @type message_entry :: %{
          domain: String.t(),
          record_type: atom(),
          message: DNS.Message.t(),
          source_ip: tuple(),
          source_port: integer(),
          received_at: integer(),
          ttl: integer()
        }

  # Client API

  @doc """
  Starts the MessageCache GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Stores an mDNS message in the cache.

  ## Parameters
  - `message` - DNS message to cache
  - `source_ip` - Source IP address
  - `source_port` - Source port

  ## Returns
  - `:ok`
  """
  @spec cache_message(DNS.Message.t(), tuple(), integer()) :: :ok
  def cache_message(message, source_ip, source_port) do
    GenServer.cast(__MODULE__, {:cache_message, message, source_ip, source_port})
  end

  @doc """
  Queries the cache for records matching a domain.

  ## Parameters
  - `domain` - Domain name to search for (e.g., "myservice.local")
  - `record_type` - Optional record type filter (e.g., :A, :AAAA, :PTR, :SRV, :TXT)

  ## Returns
  - List of matching cache entries
  """
  @spec query(String.t(), atom() | nil) :: [message_entry()]
  def query(domain, record_type \\ nil) do
    domain_key = normalize_domain(domain)

    entries =
      case :ets.lookup(@table_name, domain_key) do
        [] -> []
        results -> Enum.map(results, fn {_key, entry} -> entry end)
      end

    # Filter by record type if specified
    entries =
      if record_type do
        Enum.filter(entries, fn entry -> entry.record_type == record_type end)
      else
        entries
      end

    # Filter out expired entries
    now = System.system_time(:second)

    Enum.filter(entries, fn entry ->
      entry.received_at + entry.ttl > now
    end)
  end

  @doc """
  Gets all cached messages.

  ## Returns
  - List of all cache entries
  """
  @spec list_all() :: [message_entry()]
  def list_all do
    now = System.system_time(:second)

    @table_name
    |> :ets.tab2list()
    |> Enum.map(fn {_key, entry} -> entry end)
    |> Enum.filter(fn entry ->
      entry.received_at + entry.ttl > now
    end)
  end

  @doc """
  Gets statistics about the cache.

  ## Returns
  - Map with cache statistics
  """
  @spec stats() :: map()
  def stats do
    total = :ets.info(@table_name, :size)
    now = System.system_time(:second)

    all_entries = :ets.tab2list(@table_name)

    expired =
      Enum.count(all_entries, fn {_key, entry} ->
        entry.received_at + entry.ttl <= now
      end)

    %{
      total_entries: total,
      active_entries: total - expired,
      expired_entries: expired
    }
  end

  @doc """
  Clears all entries from the cache.
  """
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Initialize ETS table
    init_table()

    # Schedule periodic cleanup
    schedule_cleanup()

    :telemetry.execute(
      [:yellow_dog, :mdns, :message_cache, :started],
      %{count: 1},
      %{}
    )

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:cache_message, message, source_ip, source_port}, state) do
    store_message(message, source_ip, source_port)
    {:noreply, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table_name)

    :telemetry.execute(
      [:yellow_dog, :mdns, :message_cache, :cleared],
      %{count: 1},
      %{}
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup_expired, state) do
    cleanup_expired_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  # Private helper functions

  defp init_table do
    if :ets.whereis(@table_name) == :undefined do
      :ets.new(@table_name, @ets_options)
    end

    :ok
  end

  defp store_message(message, source_ip, source_port) do
    now = System.system_time(:second)

    # Extract and cache answers
    Enum.each(message.anlist, fn record ->
      cache_record(record, message, source_ip, source_port, now, :answer)
    end)

    # Extract and cache authority records
    Enum.each(message.nslist, fn record ->
      cache_record(record, message, source_ip, source_port, now, :authority)
    end)

    # Extract and cache additional records
    Enum.each(message.arlist, fn record ->
      cache_record(record, message, source_ip, source_port, now, :additional)
    end)

    # Also cache the questions for service discovery
    Enum.each(message.qdlist, fn question ->
      cache_question(question, message, source_ip, source_port, now)
    end)

    :ok
  end

  defp cache_record(record, message, source_ip, source_port, received_at, section) do
    domain_key = normalize_domain(to_string(record.name))

    entry = %{
      domain: to_string(record.name),
      record_type: record.type,
      record: record,
      message: message,
      source_ip: source_ip,
      source_port: source_port,
      received_at: received_at,
      ttl: max(record.ttl, @default_ttl),
      section: section
    }

    :ets.insert(@table_name, {domain_key, entry})

    :telemetry.execute(
      [:yellow_dog, :mdns, :message_cache, :record_cached],
      %{count: 1},
      %{domain: entry.domain, record_type: entry.record_type, section: section}
    )
  end

  defp cache_question(question, message, source_ip, source_port, received_at) do
    domain_key = normalize_domain(to_string(question.name))

    entry = %{
      domain: to_string(question.name),
      record_type: question.type,
      question: question,
      message: message,
      source_ip: source_ip,
      source_port: source_port,
      received_at: received_at,
      ttl: @default_ttl,
      section: :question
    }

    :ets.insert(@table_name, {domain_key, entry})

    :telemetry.execute(
      [:yellow_dog, :mdns, :message_cache, :query_cached],
      %{count: 1},
      %{domain: entry.domain, record_type: entry.record_type}
    )
  end

  defp cleanup_expired_entries do
    now = System.system_time(:second)

    all_entries = :ets.tab2list(@table_name)

    expired_entries =
      Enum.filter(all_entries, fn {_key, entry} ->
        entry.received_at + entry.ttl <= now
      end)

    Enum.each(expired_entries, fn {key, entry} ->
      :ets.delete_object(@table_name, {key, entry})
    end)

    expired_count = length(expired_entries)

    if expired_count > 0 do
      :telemetry.execute(
        [:yellow_dog, :mdns, :message_cache, :cleanup],
        %{expired_count: expired_count},
        %{}
      )
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup_expired, @cleanup_interval)
  end

  defp normalize_domain(domain) when is_binary(domain) do
    domain
    |> String.downcase()
    |> String.trim_trailing(".")
  end
end
