defmodule YellowDog.Mdns.NetworkMonitor do
  @moduledoc """
  Monitors all mDNS network traffic (queries + responses) for network visibility.

  Tracks both queries and responses, providing comprehensive network discovery
  and activity monitoring. This is an enhanced version of MessageCache that
  tracks not just responses but also queries seen on the network.
  """

  use GenServer

  @response_table :mdns_responses
  @query_table :mdns_queries
  @services_table :mdns_discovered_services
  @ets_options [:named_table, :public, :bag, read_concurrency: true, write_concurrency: true]

  # Cleanup every 5 minutes
  @cleanup_interval 300_000
  # Default TTL for cached records
  @default_ttl 120
  # Time thresholds for queries and cleanup
  @query_lookback_seconds 3600
  @stale_service_seconds 300
  @stale_cleanup_seconds 600

  @type message_entry :: %{
          domain: String.t(),
          record_type: atom(),
          message: DNS.Message.t(),
          source_ip: tuple(),
          source_port: integer(),
          received_at: integer(),
          ttl: integer()
        }

  @type query_entry :: %{
          domain: String.t(),
          record_type: atom(),
          source_ip: tuple(),
          source_port: integer(),
          timestamp: integer(),
          answered: boolean()
        }

  @type discovered_service :: %{
          service_id: String.t(),
          name: String.t(),
          type: String.t(),
          domain: String.t(),
          host: String.t() | nil,
          port: integer() | nil,
          txt_records: map(),
          addresses: [tuple()],
          first_seen: integer(),
          last_seen: integer(),
          response_count: integer(),
          source_ips: [tuple()]
        }

  # Client API

  @doc """
  Starts the NetworkMonitor GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Logs a query seen on the network.
  """
  @spec log_query(DNS.Message.t(), tuple(), integer()) :: :ok
  def log_query(message, source_ip, source_port) do
    GenServer.cast(__MODULE__, {:log_query, message, source_ip, source_port})
  end

  @doc """
  Caches a response message.
  """
  @spec cache_response(DNS.Message.t(), tuple(), integer()) :: :ok
  def cache_response(message, source_ip, source_port) do
    GenServer.cast(__MODULE__, {:cache_response, message, source_ip, source_port})
  end

  @doc """
  Queries the cache for records matching a domain.
  """
  @spec query(String.t(), atom() | nil) :: [message_entry()]
  def query(domain, record_type \\ nil) do
    domain_key = normalize_domain(domain)

    entries =
      case :ets.lookup(@response_table, domain_key) do
        [] -> []
        results -> for {_key, entry} <- results, do: entry
      end

    entries =
      if record_type do
        Enum.filter(entries, fn entry -> entry.record_type == record_type end)
      else
        entries
      end

    now = System.system_time(:second)

    Enum.filter(entries, fn entry ->
      entry.received_at + entry.ttl > now
    end)
  end

  @doc """
  Gets recent queries seen on the network.
  """
  @spec get_queries(keyword()) :: [query_entry()]
  def get_queries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    since = Keyword.get(opts, :since, System.system_time(:second) - @query_lookback_seconds)

    for(
      {_key, entry} <- :ets.tab2list(@query_table),
      entry.timestamp >= since,
      do: entry
    )
    |> Enum.sort_by(& &1.timestamp, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Gets queries that have not been answered.
  """
  @spec get_unanswered_queries() :: [query_entry()]
  def get_unanswered_queries do
    for(
      {_key, entry} <- :ets.tab2list(@query_table),
      not entry.answered,
      do: entry
    )
    |> Enum.sort_by(& &1.timestamp, :desc)
  end

  @doc """
  Lists all discovered services on the network.
  """
  @spec list_discovered_services() :: [discovered_service()]
  def list_discovered_services do
    now = System.system_time(:second)
    stale_threshold = now - @stale_service_seconds

    for(
      {_key, service} <- :ets.tab2list(@services_table),
      service.last_seen > stale_threshold,
      do: service
    )
    |> Enum.sort_by(& &1.name)
  end

  @doc """
  Gets details about a specific discovered service.
  """
  @spec get_discovered_service(String.t()) :: discovered_service() | nil
  def get_discovered_service(service_id) do
    case :ets.lookup(@services_table, service_id) do
      [{^service_id, service}] -> service
      [] -> nil
    end
  end

  @doc """
  Searches for services by type.
  """
  @spec search_services(keyword()) :: [discovered_service()]
  def search_services(opts \\ []) do
    type_filter = Keyword.get(opts, :type)

    services = list_discovered_services()

    if type_filter do
      normalized_type = String.downcase(type_filter)

      Enum.filter(services, fn service ->
        String.downcase(service.type) == normalized_type
      end)
    else
      services
    end
  end

  @doc """
  Gets network statistics.
  """
  @spec network_stats() :: map()
  def network_stats do
    responses = :ets.info(@response_table, :size)
    queries = :ets.info(@query_table, :size)
    services = length(list_discovered_services())

    # Get unique hosts
    unique_hosts =
      @response_table
      |> :ets.tab2list()
      |> Enum.uniq_by(fn {_key, entry} -> entry.source_ip end)
      |> length()

    # Calculate queries per minute (last hour)
    now = System.system_time(:second)
    one_hour_ago = now - @query_lookback_seconds

    recent_queries =
      get_queries(since: one_hour_ago)
      |> length()

    queries_per_minute = recent_queries / 60.0

    # Get most queried services
    most_queried =
      get_queries(since: one_hour_ago)
      |> Enum.group_by(& &1.domain)
      |> Enum.map(fn {domain, queries} -> {domain, length(queries)} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(10)
      |> Enum.map(fn {domain, count} -> %{domain: domain, count: count} end)

    %{
      total_responses: responses,
      total_queries: queries,
      active_services: services,
      unique_hosts: unique_hosts,
      queries_per_minute: Float.round(queries_per_minute, 2),
      most_queried_services: most_queried
    }
  end

  @doc """
  Gets all cached messages (legacy API compatibility).
  """
  @spec list_all() :: [message_entry()]
  def list_all do
    now = System.system_time(:second)

    for {_key, entry} <- :ets.tab2list(@response_table),
        entry.received_at + entry.ttl > now,
        do: entry
  end

  @doc """
  Gets cache statistics (legacy API compatibility).
  """
  @spec stats() :: map()
  def stats do
    total = :ets.info(@response_table, :size)
    now = System.system_time(:second)

    all_entries = :ets.tab2list(@response_table)

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
    init_tables()
    schedule_cleanup()

    :telemetry.execute(
      [:yellow_dog, :mdns, :network_monitor, :started],
      %{count: 1},
      %{}
    )

    {:ok, %{}}
  end

  @impl true
  def handle_cast({:log_query, message, source_ip, source_port}, state) do
    store_query(message, source_ip, source_port)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:cache_response, message, source_ip, source_port}, state) do
    store_response(message, source_ip, source_port)
    mark_queries_as_answered(message)
    update_discovered_services(message, source_ip)
    {:noreply, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@response_table)
    :ets.delete_all_objects(@query_table)
    :ets.delete_all_objects(@services_table)

    :telemetry.execute(
      [:yellow_dog, :mdns, :network_monitor, :cleared],
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

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  defp init_tables do
    for table <- [@response_table, @query_table, @services_table] do
      if :ets.whereis(table) == :undefined do
        :ets.new(table, @ets_options)
      end
    end

    :ok
  end

  defp store_query(message, source_ip, source_port) do
    now = System.system_time(:second)

    Enum.each(message.qdlist, fn question ->
      domain_key = normalize_domain(to_string(question.name))

      entry = %{
        domain: to_string(question.name),
        record_type: question.type,
        source_ip: source_ip,
        source_port: source_port,
        timestamp: now,
        answered: false
      }

      :ets.insert(@query_table, {domain_key, entry})
    end)

    :telemetry.execute(
      [:yellow_dog, :mdns, :query_logged],
      %{question_count: length(message.qdlist)},
      %{source_ip: source_ip}
    )
  end

  defp store_response(message, source_ip, source_port) do
    now = System.system_time(:second)

    # Cache records from each DNS message section
    for {section_list, section} <- [
          {message.anlist, :answer},
          {message.nslist, :authority},
          {message.arlist, :additional}
        ],
        record <- section_list do
      cache_record(record, message, source_ip, source_port, now, section)
    end
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

    :ets.insert(@response_table, {domain_key, entry})
  end

  defp mark_queries_as_answered(message) do
    # Match answers to queries
    Enum.each(message.anlist, fn record ->
      domain_key = normalize_domain(to_string(record.name))

      case :ets.lookup(@query_table, domain_key) do
        [] ->
          :ok

        queries ->
          Enum.each(queries, fn {key, query} ->
            if to_string(query.record_type) == to_string(record.type) or
                 to_string(query.record_type) == "ANY" do
              updated_query = %{query | answered: true}
              :ets.delete_object(@query_table, {key, query})
              :ets.insert(@query_table, {key, updated_query})
            end
          end)
      end
    end)
  end

  defp update_discovered_services(message, source_ip) do
    # Extract service information from PTR, SRV, TXT records
    # Group records by service instance

    services = extract_services_from_message(message, source_ip)

    Enum.each(services, &update_or_create_service/1)
  end

  defp extract_services_from_message(message, source_ip) do
    now = System.system_time(:second)

    # Find PTR records (service type enumeration)
    ptr_records =
      Enum.filter(message.anlist, fn record -> to_string(record.type) == "PTR" end)

    # For each PTR, try to find corresponding SRV, TXT, A/AAAA records
    Enum.flat_map(ptr_records, fn ptr ->
      service_instance = to_string(ptr.data)
      service_type = to_string(ptr.name)

      # Find SRV record
      srv_record =
        Enum.find(message.anlist ++ message.arlist, fn record ->
          to_string(record.type) == "SRV" and to_string(record.name) == service_instance
        end)

      # Find TXT record
      txt_record =
        Enum.find(message.anlist ++ message.arlist, fn record ->
          to_string(record.type) == "TXT" and to_string(record.name) == service_instance
        end)

      # Find A/AAAA records
      host = if srv_record, do: to_string(srv_record.data.target)

      addresses =
        if host do
          (message.anlist ++ message.arlist)
          |> Enum.filter(fn record ->
            to_string(record.type) in ["A", "AAAA"] and to_string(record.name) == host
          end)
          |> Enum.map(& &1.data)
        else
          []
        end

      if srv_record do
        [
          %{
            service_id: service_instance,
            name: extract_service_name(service_instance),
            type: service_type,
            domain: "local",
            host: host,
            port: srv_record.data.port,
            txt_records: parse_txt_records(txt_record),
            addresses: addresses,
            timestamp: now,
            source_ip: source_ip
          }
        ]
      else
        []
      end
    end)
  end

  defp extract_service_name(service_instance) do
    # service_instance is like "My Service._http._tcp.local"
    # Extract "My Service"
    service_instance
    |> String.split(".")
    |> hd()
  end

  defp parse_txt_records(nil), do: %{}

  defp parse_txt_records(txt_record) do
    case txt_record.data do
      list when is_list(list) ->
        Map.new(list, fn str ->
          case String.split(str, "=", parts: 2) do
            [key, value] -> {key, value}
            [key] -> {key, ""}
          end
        end)

      _ ->
        %{}
    end
  end

  defp update_or_create_service(service_info) do
    service_id = service_info.service_id

    case :ets.lookup(@services_table, service_id) do
      [{^service_id, existing}] ->
        # Update existing service
        updated = %{
          existing
          | last_seen: service_info.timestamp,
            response_count: existing.response_count + 1,
            source_ips: Enum.uniq([service_info.source_ip | existing.source_ips]),
            # Update fields that may have changed
            host: service_info.host || existing.host,
            port: service_info.port || existing.port,
            txt_records: Map.merge(existing.txt_records, service_info.txt_records),
            addresses: Enum.uniq(service_info.addresses ++ existing.addresses)
        }

        :ets.insert(@services_table, {service_id, updated})

      [] ->
        # Create new service
        new_service = %{
          service_id: service_id,
          name: service_info.name,
          type: service_info.type,
          domain: service_info.domain,
          host: service_info.host,
          port: service_info.port,
          txt_records: service_info.txt_records,
          addresses: service_info.addresses,
          first_seen: service_info.timestamp,
          last_seen: service_info.timestamp,
          response_count: 1,
          source_ips: [service_info.source_ip]
        }

        :ets.insert(@services_table, {service_id, new_service})

        :telemetry.execute(
          [:yellow_dog, :mdns, :service_discovered],
          %{count: 1},
          %{service_id: service_id, type: service_info.type}
        )
    end
  end

  defp cleanup_expired_entries do
    now = System.system_time(:second)

    # Clean up expired responses
    response_entries = :ets.tab2list(@response_table)

    expired_responses =
      Enum.filter(response_entries, fn {_key, entry} ->
        entry.received_at + entry.ttl <= now
      end)

    Enum.each(expired_responses, fn {key, entry} ->
      :ets.delete_object(@response_table, {key, entry})
    end)

    # Clean up old queries (older than 1 hour)
    one_hour_ago = now - @query_lookback_seconds
    query_entries = :ets.tab2list(@query_table)

    old_queries =
      Enum.filter(query_entries, fn {_key, entry} ->
        entry.timestamp < one_hour_ago
      end)

    Enum.each(old_queries, fn {key, entry} ->
      :ets.delete_object(@query_table, {key, entry})
    end)

    # Clean up stale services (not seen in 10 minutes)
    ten_minutes_ago = now - @stale_cleanup_seconds

    stale_services =
      @services_table
      |> :ets.tab2list()
      |> Enum.filter(fn {_key, service} -> service.last_seen < ten_minutes_ago end)

    Enum.each(stale_services, fn {key, _service} ->
      :ets.delete(@services_table, key)
    end)

    total_cleaned = length(expired_responses) + length(old_queries) + length(stale_services)

    if total_cleaned > 0 do
      :telemetry.execute(
        [:yellow_dog, :mdns, :network_monitor, :cleanup],
        %{expired_count: total_cleaned},
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
