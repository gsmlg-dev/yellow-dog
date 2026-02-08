defmodule YellowDog.Dns.MetricsCollector do
  @moduledoc """
  DNS metrics collector using telemetry events.

  Subscribes to DNS telemetry events and aggregates metrics into
  ETS-based counters and gauges for efficient concurrent reads.

  ## Metrics Tracked

  **Counters:**
  - `queries_total` - Total queries received
  - `queries_by_protocol` - Queries by UDP/TCP
  - `queries_by_view` - Queries per view
  - `queries_by_type` - Queries by record type (A, AAAA, etc.)
  - `responses_by_code` - Responses by RCODE
  - `cache_hits` - Cache hit count
  - `cache_misses` - Cache miss count
  - `rate_limit_rejected` - Rate-limited queries

  **Gauges:**
  - `active_zones` - Current active zone count
  - `active_views` - Current active view count

  **Histograms:**
  - `response_time_us` - Response latency in microseconds

  ## Telemetry Events Handled

  - `[:yellow_dog, :dns, :query, :received]`
  - `[:yellow_dog, :dns, :response, :sent]`
  - `[:yellow_dog, :dns, :cache, :lookup]`
  - `[:yellow_dog, :dns, :query, :logged]`
  - `[:yellow_dog, :dns, :view, :fallback]`
  """

  use GenServer

  alias YellowDog.Dns.IpFormat
  alias YellowDog.Telemetry

  @table_name :dns_metrics
  @handler_prefix "dns_metrics_collector"

  # Histogram bucket boundaries (microseconds)
  @response_time_buckets [100, 500, 1_000, 5_000, 10_000, 50_000, 100_000, 500_000, 1_000_000]

  defstruct [:table, :handler_ids, started_at: nil]

  # Client API

  @doc """
  Starts the MetricsCollector.

  ## Options

  - `:name` - GenServer registration name (default: __MODULE__)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns all current metrics as a map.
  """
  @spec get_metrics() :: map()
  def get_metrics, do: get_metrics(__MODULE__)

  @spec get_metrics(GenServer.server()) :: map()
  def get_metrics(server) do
    GenServer.call(server, :get_metrics)
  end

  @doc """
  Returns a specific counter value.
  """
  @spec get_counter(atom()) :: non_neg_integer()
  def get_counter(metric), do: get_counter(__MODULE__, metric)

  @spec get_counter(GenServer.server(), atom()) :: non_neg_integer()
  def get_counter(server, metric) do
    GenServer.call(server, {:get_counter, metric})
  end

  @doc """
  Returns a keyed counter (e.g., queries by type).
  """
  @spec get_counter(GenServer.server(), atom(), term()) :: non_neg_integer()
  def get_counter(server, metric, key) do
    GenServer.call(server, {:get_counter, metric, key})
  end

  @doc """
  Returns response time histogram data.
  """
  @spec get_response_times() :: map()
  def get_response_times, do: get_response_times(__MODULE__)

  @spec get_response_times(GenServer.server()) :: map()
  def get_response_times(server) do
    GenServer.call(server, :get_response_times)
  end

  @doc """
  Returns top queried domains.

  ## Options

  - `:limit` - Maximum entries to return (default: 10)
  """
  @spec get_top_domains(keyword()) :: [{String.t(), non_neg_integer()}]
  def get_top_domains(opts \\ []), do: get_top_domains(__MODULE__, opts)

  @spec get_top_domains(GenServer.server(), keyword()) :: [{String.t(), non_neg_integer()}]
  def get_top_domains(server, opts) do
    GenServer.call(server, {:get_top_domains, opts})
  end

  @doc """
  Returns top clients by query count.

  ## Options

  - `:limit` - Maximum entries to return (default: 10)
  """
  @spec get_top_clients(keyword()) :: [{String.t(), non_neg_integer()}]
  def get_top_clients(opts \\ []), do: get_top_clients(__MODULE__, opts)

  @spec get_top_clients(GenServer.server(), keyword()) :: [{String.t(), non_neg_integer()}]
  def get_top_clients(server, opts) do
    GenServer.call(server, {:get_top_clients, opts})
  end

  @doc """
  Resets all metrics counters.
  """
  @spec reset() :: :ok
  def reset, do: reset(__MODULE__)

  @spec reset(GenServer.server()) :: :ok
  def reset(server) do
    GenServer.call(server, :reset)
  end

  @doc """
  Returns a summary of key metrics for dashboard display.
  """
  @spec summary() :: map()
  def summary, do: summary(__MODULE__)

  @spec summary(GenServer.server()) :: map()
  def summary(server) do
    GenServer.call(server, :summary)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, @table_name)

    table =
      :ets.new(table_name, [
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    # Initialize counters
    init_counters(table)

    # Attach telemetry handlers (pass ETS table ref as handler config)
    handler_ids = attach_handlers(table)

    state = %__MODULE__{
      table: table,
      handler_ids: handler_ids,
      started_at: DateTime.utc_now()
    }

    Telemetry.info("MetricsCollector started", %{handlers: length(handler_ids)})

    {:ok, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    metrics = collect_all_metrics(state.table, state.started_at)
    {:reply, metrics, state}
  end

  @impl true
  def handle_call({:get_counter, metric}, _from, state) do
    value = read_counter(state.table, {:counter, metric})
    {:reply, value, state}
  end

  @impl true
  def handle_call({:get_counter, metric, key}, _from, state) do
    value = read_counter(state.table, {:counter, metric, key})
    {:reply, value, state}
  end

  @impl true
  def handle_call(:get_response_times, _from, state) do
    histogram = read_histogram(state.table)
    {:reply, histogram, state}
  end

  @impl true
  def handle_call({:get_top_domains, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    domains = read_top_keyed(state.table, :domain, limit)
    {:reply, domains, state}
  end

  @impl true
  def handle_call({:get_top_clients, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 10)
    clients = read_top_keyed(state.table, :client, limit)
    {:reply, clients, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state.table)
    init_counters(state.table)
    {:reply, :ok, %{state | started_at: DateTime.utc_now()}}
  end

  @impl true
  def handle_call(:summary, _from, state) do
    total = read_counter(state.table, {:counter, :queries_total})
    cache_hits = read_counter(state.table, {:counter, :cache_hits})
    cache_misses = read_counter(state.table, {:counter, :cache_misses})
    cache_lookups = cache_hits + cache_misses

    hit_rate =
      if cache_lookups > 0 do
        Float.round(cache_hits / cache_lookups * 100, 1)
      else
        0.0
      end

    histogram = read_histogram(state.table)

    avg_response_time =
      if histogram.count > 0 do
        Float.round(histogram.sum / histogram.count, 0)
      else
        0.0
      end

    summary = %{
      queries_total: total,
      cache_hit_rate: hit_rate,
      avg_response_time_us: avg_response_time,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), state.started_at, :second),
      started_at: state.started_at
    }

    {:reply, summary, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Detach telemetry handlers
    Enum.each(state.handler_ids, fn id ->
      :telemetry.detach(id)
    end)

    :ets.delete(state.table)
    :ok
  end

  # Telemetry Handlers

  @doc false
  def handle_event([:yellow_dog, :dns, :query, :received], _measurements, metadata, table) do
    increment(table, {:counter, :queries_total})

    if protocol = metadata[:protocol] do
      increment(table, {:counter, :queries_by_protocol, protocol})
    end

    if qtype = metadata[:qtype] do
      increment(table, {:counter, :queries_by_type, qtype})
    end

    if client_ip = metadata[:client_ip] do
      ip_str = IpFormat.format(client_ip)
      increment(table, {:counter, :client, ip_str})
    end

    if qname = metadata[:qname] do
      name_str = to_string(qname)
      increment(table, {:counter, :domain, name_str})
    end
  end

  @doc false
  def handle_event([:yellow_dog, :dns, :response, :sent], measurements, metadata, table) do
    if rcode = metadata[:rcode] do
      increment(table, {:counter, :responses_by_code, rcode})
    end

    if duration = measurements[:duration] do
      record_histogram(table, duration)
    end

    if metadata[:cache_hit] do
      increment(table, {:counter, :cache_hits})
    end
  end

  @doc false
  def handle_event([:yellow_dog, :dns, :cache, :lookup], _measurements, metadata, table) do
    if metadata[:hit] do
      increment(table, {:counter, :cache_hits})
    else
      increment(table, {:counter, :cache_misses})
    end

    if view = metadata[:view] do
      increment(table, {:counter, :queries_by_view, view})
    end
  end

  @doc false
  def handle_event([:yellow_dog, :dns, :query, :logged], _measurements, metadata, table) do
    # Track from QueryLogger events as fallback for query counting
    if qtype = metadata[:qtype] do
      increment(table, {:counter, :queries_by_type, qtype})
    end

    if client_ip = metadata[:client_ip] do
      ip_str = IpFormat.format(client_ip)
      increment(table, {:counter, :client, ip_str})
    end

    if qname = metadata[:qname] do
      name_str = to_string(qname)
      increment(table, {:counter, :domain, name_str})
    end

    if response_time = metadata[:response_time_us] do
      record_histogram(table, response_time)
    end
  end

  @doc false
  def handle_event([:yellow_dog, :dns, :view, :fallback], _measurements, metadata, table) do
    increment(table, {:counter, :fallbacks_total})

    if view = metadata[:view] do
      increment(table, {:counter, :fallbacks_by_view, view})
    end
  end

  # Private Functions

  defp attach_handlers(table) do
    events = [
      {[:yellow_dog, :dns, :query, :received], "received"},
      {[:yellow_dog, :dns, :response, :sent], "response"},
      {[:yellow_dog, :dns, :cache, :lookup], "cache"},
      {[:yellow_dog, :dns, :query, :logged], "logged"},
      {[:yellow_dog, :dns, :view, :fallback], "fallback"}
    ]

    Enum.map(events, fn {event, suffix} ->
      handler_id = "#{@handler_prefix}_#{suffix}"

      :telemetry.attach(
        handler_id,
        event,
        &__MODULE__.handle_event/4,
        table
      )

      handler_id
    end)
  end

  defp init_counters(table) do
    counters = [
      :queries_total,
      :cache_hits,
      :cache_misses,
      :rate_limit_rejected,
      :fallbacks_total
    ]

    Enum.each(counters, fn name ->
      :ets.insert(table, {{:counter, name}, 0})
    end)

    # Initialize histogram
    :ets.insert(table, {{:histogram, :response_time, :count}, 0})
    :ets.insert(table, {{:histogram, :response_time, :sum}, 0})
    :ets.insert(table, {{:histogram, :response_time, :min}, nil})
    :ets.insert(table, {{:histogram, :response_time, :max}, nil})

    Enum.each(@response_time_buckets, fn bucket ->
      :ets.insert(table, {{:histogram, :response_time, :bucket, bucket}, 0})
    end)

    :ets.insert(table, {{:histogram, :response_time, :bucket, :inf}, 0})
  end

  defp increment(table, key) do
    try do
      :ets.update_counter(table, key, {2, 1})
    rescue
      ArgumentError ->
        :ets.insert_new(table, {key, 0})
        :ets.update_counter(table, key, {2, 1})
    end
  end

  defp read_counter(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  end

  defp record_histogram(table, value) when is_number(value) do
    try do
      :ets.update_counter(table, {:histogram, :response_time, :count}, {2, 1})
      :ets.update_counter(table, {:histogram, :response_time, :sum}, {2, round(value)})
    rescue
      ArgumentError -> :ok
    end

    # Update min/max
    update_min_max(table, value)

    # Update bucket
    bucket = find_bucket(value)

    try do
      :ets.update_counter(table, {:histogram, :response_time, :bucket, bucket}, {2, 1})
    rescue
      ArgumentError -> :ok
    end
  end

  defp update_min_max(table, value) do
    case :ets.lookup(table, {:histogram, :response_time, :min}) do
      [{_, nil}] ->
        :ets.insert(table, {{:histogram, :response_time, :min}, value})

      [{_, current}] when value < current ->
        :ets.insert(table, {{:histogram, :response_time, :min}, value})

      _ ->
        :ok
    end

    case :ets.lookup(table, {:histogram, :response_time, :max}) do
      [{_, nil}] ->
        :ets.insert(table, {{:histogram, :response_time, :max}, value})

      [{_, current}] when value > current ->
        :ets.insert(table, {{:histogram, :response_time, :max}, value})

      _ ->
        :ok
    end
  end

  defp find_bucket(value) do
    Enum.find(@response_time_buckets, :inf, fn bucket -> value <= bucket end)
  end

  defp read_histogram(table) do
    count = read_counter(table, {:histogram, :response_time, :count})
    sum = read_counter(table, {:histogram, :response_time, :sum})

    min_val =
      case :ets.lookup(table, {:histogram, :response_time, :min}) do
        [{_, v}] -> v
        [] -> nil
      end

    max_val =
      case :ets.lookup(table, {:histogram, :response_time, :max}) do
        [{_, v}] -> v
        [] -> nil
      end

    buckets =
      Enum.map(@response_time_buckets ++ [:inf], fn bucket ->
        val = read_counter(table, {:histogram, :response_time, :bucket, bucket})
        {bucket, val}
      end)

    %{
      count: count,
      sum: sum,
      min: min_val,
      max: max_val,
      buckets: buckets
    }
  end

  defp read_top_keyed(table, prefix, limit) do
    # Scan ETS for all entries with the given prefix
    :ets.tab2list(table)
    |> Enum.filter(fn
      {{:counter, ^prefix, _key}, _count} -> true
      _ -> false
    end)
    |> Enum.map(fn {{:counter, ^prefix, key}, count} -> {key, count} end)
    |> Enum.sort_by(fn {_key, count} -> count end, :desc)
    |> Enum.take(limit)
  end

  defp collect_all_metrics(table, started_at) do
    %{
      counters: %{
        queries_total: read_counter(table, {:counter, :queries_total}),
        cache_hits: read_counter(table, {:counter, :cache_hits}),
        cache_misses: read_counter(table, {:counter, :cache_misses}),
        rate_limit_rejected: read_counter(table, {:counter, :rate_limit_rejected}),
        fallbacks_total: read_counter(table, {:counter, :fallbacks_total})
      },
      response_times: read_histogram(table),
      top_domains: read_top_keyed(table, :domain, 10),
      top_clients: read_top_keyed(table, :client, 10),
      queries_by_type: read_top_keyed(table, :queries_by_type, 20),
      queries_by_view: read_top_keyed(table, :queries_by_view, 20),
      queries_by_protocol: read_top_keyed(table, :queries_by_protocol, 5),
      responses_by_code: read_top_keyed(table, :responses_by_code, 20),
      started_at: started_at,
      uptime_seconds: DateTime.diff(DateTime.utc_now(), started_at, :second)
    }
  end

end
