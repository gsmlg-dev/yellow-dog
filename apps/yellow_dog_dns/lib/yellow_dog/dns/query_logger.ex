defmodule YellowDog.Dns.QueryLogger do
  @moduledoc """
  DNS query and response logger.

  Maintains a circular buffer of recent DNS query logs in memory,
  with configurable buffer size. Logs are also emitted as telemetry
  events for external consumption.

  ## Features

  - In-memory circular buffer (configurable size, default 1000)
  - Filtering by client IP, view, qname, qtype, response code
  - Real-time PubSub broadcasting for LiveView streaming
  - Export to map format for serialization

  ## Telemetry Events

  - `[:yellow_dog, :dns, :query, :logged]` - Emitted for each logged query
  """

  use GenServer

  alias YellowDog.Telemetry

  @default_buffer_size 1000
  @pubsub_topic "dns:query_logs"

  defstruct [
    :buffer_size,
    buffer: :queue.new(),
    count: 0,
    total_logged: 0,
    enabled: true
  ]

  # Query log entry
  defmodule Entry do
    @moduledoc false
    defstruct [
      :id,
      :timestamp,
      :client_ip,
      :client_port,
      :view,
      :qname,
      :qtype,
      :qclass,
      :protocol,
      :response_code,
      :response_time_us,
      :answer_count,
      :authority_count,
      :additional_count,
      :cache_hit,
      :zone_used,
      :fallback_used,
      :error
    ]
  end

  # Client API

  @doc """
  Starts the QueryLogger.

  ## Options

  - `:buffer_size` - Maximum entries in the circular buffer (default: 1000)
  - `:enabled` - Whether logging is enabled (default: true)
  - `:name` - GenServer registration name (default: __MODULE__)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Logs a DNS query entry.

  This is a cast (fire-and-forget) to avoid blocking the caller.
  """
  @spec log_query(map()) :: :ok
  def log_query(attrs) do
    log_query(__MODULE__, attrs)
  end

  @spec log_query(GenServer.server(), map()) :: :ok
  def log_query(server, attrs) do
    GenServer.cast(server, {:log_query, attrs})
  end

  @doc """
  Gets the most recent log entries.

  ## Options

  - `:limit` - Maximum entries to return (default: 100)
  """
  @spec get_recent_logs(keyword()) :: [Entry.t()]
  def get_recent_logs(opts \\ []) do
    get_recent_logs(__MODULE__, opts)
  end

  @spec get_recent_logs(GenServer.server(), keyword()) :: [Entry.t()]
  def get_recent_logs(server, opts) do
    GenServer.call(server, {:get_recent_logs, opts})
  end

  @doc """
  Gets log entries filtered by client IP.
  """
  @spec get_logs_by_client(:inet.ip_address() | String.t(), keyword()) :: [Entry.t()]
  def get_logs_by_client(client_ip, opts \\ []) do
    get_logs_by_client(__MODULE__, client_ip, opts)
  end

  @spec get_logs_by_client(GenServer.server(), :inet.ip_address() | String.t(), keyword()) ::
          [Entry.t()]
  def get_logs_by_client(server, client_ip, opts) do
    GenServer.call(server, {:get_logs_by_client, client_ip, opts})
  end

  @doc """
  Gets log entries filtered by view name.
  """
  @spec get_logs_by_view(String.t(), keyword()) :: [Entry.t()]
  def get_logs_by_view(view, opts \\ []) do
    get_logs_by_view(__MODULE__, view, opts)
  end

  @spec get_logs_by_view(GenServer.server(), String.t(), keyword()) :: [Entry.t()]
  def get_logs_by_view(server, view, opts) do
    GenServer.call(server, {:get_logs_by_view, view, opts})
  end

  @doc """
  Gets log entries filtered by query name pattern.
  """
  @spec get_logs_by_qname(String.t(), keyword()) :: [Entry.t()]
  def get_logs_by_qname(pattern, opts \\ []) do
    get_logs_by_qname(__MODULE__, pattern, opts)
  end

  @spec get_logs_by_qname(GenServer.server(), String.t(), keyword()) :: [Entry.t()]
  def get_logs_by_qname(server, pattern, opts) do
    GenServer.call(server, {:get_logs_by_qname, pattern, opts})
  end

  @doc """
  Clears the log buffer.
  """
  @spec clear_buffer() :: :ok
  def clear_buffer do
    clear_buffer(__MODULE__)
  end

  @spec clear_buffer(GenServer.server()) :: :ok
  def clear_buffer(server) do
    GenServer.call(server, :clear_buffer)
  end

  @doc """
  Returns statistics about the query logger.
  """
  @spec stats() :: map()
  def stats do
    stats(__MODULE__)
  end

  @spec stats(GenServer.server()) :: map()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @doc """
  Enables or disables query logging.
  """
  @spec set_enabled(boolean()) :: :ok
  def set_enabled(enabled) do
    set_enabled(__MODULE__, enabled)
  end

  @spec set_enabled(GenServer.server(), boolean()) :: :ok
  def set_enabled(server, enabled) do
    GenServer.call(server, {:set_enabled, enabled})
  end

  @doc """
  Returns the PubSub topic for query log streaming.
  """
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  # Server Callbacks

  @impl true
  def init(opts) do
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)
    enabled = Keyword.get(opts, :enabled, true)

    state = %__MODULE__{
      buffer_size: buffer_size,
      enabled: enabled
    }

    Telemetry.info("QueryLogger started", %{buffer_size: buffer_size, enabled: enabled})
    {:ok, state}
  end

  @impl true
  def handle_cast({:log_query, attrs}, %{enabled: false} = state) do
    # Logging disabled, ignore
    _ = attrs
    {:noreply, state}
  end

  @impl true
  def handle_cast({:log_query, attrs}, state) do
    entry = build_entry(attrs)

    # Add to circular buffer
    buffer = :queue.in(entry, state.buffer)
    {buffer, count} = trim_buffer(buffer, state.count + 1, state.buffer_size)

    new_state = %{state | buffer: buffer, count: count, total_logged: state.total_logged + 1}

    # Broadcast via PubSub if available
    broadcast_log(entry)

    # Emit telemetry event
    :telemetry.execute(
      [:yellow_dog, :dns, :query, :logged],
      %{count: 1},
      %{
        client_ip: entry.client_ip,
        qname: entry.qname,
        qtype: entry.qtype,
        response_code: entry.response_code,
        response_time_us: entry.response_time_us
      }
    )

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:get_recent_logs, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    entries = state.buffer |> :queue.to_list() |> Enum.reverse() |> Enum.take(limit)
    {:reply, entries, state}
  end

  @impl true
  def handle_call({:get_logs_by_client, client_ip, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    normalized_ip = normalize_ip(client_ip)

    entries =
      state.buffer
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.filter(fn entry -> normalize_ip(entry.client_ip) == normalized_ip end)
      |> Enum.take(limit)

    {:reply, entries, state}
  end

  @impl true
  def handle_call({:get_logs_by_view, view, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)

    entries =
      state.buffer
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.filter(fn entry -> entry.view == view end)
      |> Enum.take(limit)

    {:reply, entries, state}
  end

  @impl true
  def handle_call({:get_logs_by_qname, pattern, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    pattern_lower = String.downcase(pattern)

    entries =
      state.buffer
      |> :queue.to_list()
      |> Enum.reverse()
      |> Enum.filter(fn entry ->
        entry.qname != nil and
          String.contains?(String.downcase(to_string(entry.qname)), pattern_lower)
      end)
      |> Enum.take(limit)

    {:reply, entries, state}
  end

  @impl true
  def handle_call(:clear_buffer, _from, state) do
    new_state = %{state | buffer: :queue.new(), count: 0}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    stats = %{
      buffer_size: state.buffer_size,
      current_entries: state.count,
      total_logged: state.total_logged,
      enabled: state.enabled
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:set_enabled, enabled}, _from, state) do
    {:reply, :ok, %{state | enabled: enabled}}
  end

  # Private Functions

  defp build_entry(attrs) do
    %Entry{
      id: generate_id(),
      timestamp: Map.get(attrs, :timestamp, DateTime.utc_now()),
      client_ip: Map.get(attrs, :client_ip),
      client_port: Map.get(attrs, :client_port),
      view: Map.get(attrs, :view),
      qname: Map.get(attrs, :qname),
      qtype: Map.get(attrs, :qtype),
      qclass: Map.get(attrs, :qclass, :in),
      protocol: Map.get(attrs, :protocol, :udp),
      response_code: Map.get(attrs, :response_code),
      response_time_us: Map.get(attrs, :response_time_us),
      answer_count: Map.get(attrs, :answer_count, 0),
      authority_count: Map.get(attrs, :authority_count, 0),
      additional_count: Map.get(attrs, :additional_count, 0),
      cache_hit: Map.get(attrs, :cache_hit, false),
      zone_used: Map.get(attrs, :zone_used),
      fallback_used: Map.get(attrs, :fallback_used, false),
      error: Map.get(attrs, :error)
    }
  end

  defp trim_buffer(buffer, count, max_size) when count > max_size do
    {{:value, _dropped}, buffer} = :queue.out(buffer)
    {buffer, count - 1}
  end

  defp trim_buffer(buffer, count, _max_size) do
    {buffer, count}
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp normalize_ip(ip) when is_tuple(ip), do: :inet.ntoa(ip) |> to_string()
  defp normalize_ip(ip) when is_binary(ip), do: ip
  defp normalize_ip(ip), do: inspect(ip)

  defp broadcast_log(entry) do
    # Use dynamic dispatch to avoid compile-time dependency on Phoenix.PubSub
    try do
      pubsub_mod = Module.concat([:Phoenix, :PubSub])

      if Code.ensure_loaded?(pubsub_mod) do
        apply(pubsub_mod, :broadcast, [
          YellowDog.Console.PubSub,
          @pubsub_topic,
          {:query_logged, entry}
        ])
      end
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
