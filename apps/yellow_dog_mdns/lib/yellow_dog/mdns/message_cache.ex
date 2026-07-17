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

  @type control_entry :: %{
          required(String.t()) => String.t() | [String.t()]
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
        results -> for {_key, entry} <- results, do: entry
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

    for {_key, entry} <- :ets.tab2list(@table_name),
        entry.received_at + entry.ttl > now,
        do: entry
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

  @doc false
  @spec control_snapshot() :: {:ok, [control_entry()]} | {:error, :cache_absent | term()}
  def control_snapshot, do: control_call(:control_snapshot)

  @doc false
  @spec control_clear() :: {:ok, non_neg_integer()} | {:error, :cache_absent | term()}
  def control_clear, do: control_call(:control_clear)

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
    clear_entries()

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:control_snapshot, _from, state) do
    {:reply, control_snapshot_entries(), state}
  end

  @impl true
  def handle_call(:control_clear, _from, state) do
    {:reply, control_clear_entries(), state}
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

  # Private helper functions

  defp init_table do
    try do: :ets.delete(@table_name), catch: (_, _ -> :ok)
    :ets.new(@table_name, @ets_options)
    :ok
  end

  defp control_call(message) do
    GenServer.call(__MODULE__, message)
  catch
    :exit, :noproc -> {:error, :cache_absent}
    :exit, {:noproc, _details} -> {:error, :cache_absent}
    :exit, reason -> {:error, reason}
  end

  defp control_snapshot_entries do
    if :ets.whereis(@table_name) == :undefined do
      {:error, :cache_absent}
    else
      now = System.system_time(:second)

      entries =
        @table_name
        |> :ets.tab2list()
        |> Enum.flat_map(fn {_key, entry} -> project_control_entry(entry, now) end)
        |> Enum.sort_by(fn %{"name" => name, "type" => type, "values" => values} ->
          {name, type, values}
        end)

      {:ok, entries}
    end
  end

  defp control_clear_entries do
    case :ets.info(@table_name, :size) do
      :undefined ->
        {:error, :cache_absent}

      count ->
        clear_entries()
        {:ok, count}
    end
  end

  defp project_control_entry(
         %{
           section: section,
           record: %DNS.Message.Record{} = record,
           received_at: received_at,
           ttl: ttl
         },
         now
       )
       when section in [:answer, :authority, :additional] and is_integer(received_at) and
              is_integer(ttl) and received_at + ttl > now do
    with {:ok, name} <- control_domain(record.name),
         {:ok, type, values} <- control_record_values(record.type, record.data) do
      [%{"name" => name, "type" => type, "values" => values}]
    else
      :error -> []
    end
  end

  defp project_control_entry(_entry, _now), do: []

  defp control_record_values(type, data) do
    case control_type(type) do
      {:ok, "A"} -> control_ipv4(data)
      {:ok, "AAAA"} -> control_ipv6(data)
      {:ok, "PTR"} -> control_ptr(data)
      {:ok, "SRV"} -> control_srv(data)
      {:ok, "TXT"} -> control_txt(data)
      :error -> :error
    end
  end

  defp control_type(:A), do: {:ok, "A"}
  defp control_type(:AAAA), do: {:ok, "AAAA"}
  defp control_type(:PTR), do: {:ok, "PTR"}
  defp control_type(:SRV), do: {:ok, "SRV"}
  defp control_type(:TXT), do: {:ok, "TXT"}
  defp control_type(%DNS.ResourceRecordType{value: <<1::16>>}), do: {:ok, "A"}
  defp control_type(%DNS.ResourceRecordType{value: <<28::16>>}), do: {:ok, "AAAA"}
  defp control_type(%DNS.ResourceRecordType{value: <<12::16>>}), do: {:ok, "PTR"}
  defp control_type(%DNS.ResourceRecordType{value: <<33::16>>}), do: {:ok, "SRV"}
  defp control_type(%DNS.ResourceRecordType{value: <<16::16>>}), do: {:ok, "TXT"}
  defp control_type(_type), do: :error

  defp control_ipv4(%DNS.Message.Record.Data.A{data: data}), do: control_ipv4(data)

  defp control_ipv4({a, b, c, d} = address)
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    {:ok, "A", [address |> :inet.ntoa() |> List.to_string()]}
  end

  defp control_ipv4(_data), do: :error

  defp control_ipv6(%DNS.Message.Record.Data.AAAA{data: data}), do: control_ipv6(data)

  defp control_ipv6({a, b, c, d, e, f, g, h} = address)
       when a in 0..65_535 and b in 0..65_535 and c in 0..65_535 and d in 0..65_535 and
              e in 0..65_535 and f in 0..65_535 and g in 0..65_535 and h in 0..65_535 do
    {:ok, "AAAA", [address |> :inet.ntoa() |> List.to_string()]}
  end

  defp control_ipv6(_data), do: :error

  defp control_ptr(%DNS.Message.Record.Data.PTR{data: %DNS.Message.Domain{value: target}}),
    do: control_ptr(target)

  defp control_ptr(target) when is_binary(target) do
    if valid_dns_name?(target), do: {:ok, "PTR", [target]}, else: :error
  end

  defp control_ptr(_data), do: :error

  defp control_srv(%DNS.Message.Record.Data.SRV{
         data: {priority, weight, port, %DNS.Message.Domain{value: target}}
       }) do
    control_srv_data(priority, weight, port, target)
  end

  defp control_srv(%{priority: priority, weight: weight, port: port, target: target} = data)
       when map_size(data) == 4 do
    control_srv_data(priority, weight, port, target)
  end

  defp control_srv(_data), do: :error

  defp control_srv_data(priority, weight, port, target)
       when priority in 0..65_535 and weight in 0..65_535 and port in 0..65_535 and
              is_binary(target) do
    if valid_srv_target?(target) do
      {:ok, "SRV", ["#{priority} #{weight} #{port} #{target}"]}
    else
      :error
    end
  end

  defp control_srv_data(_priority, _weight, _port, _target), do: :error

  defp valid_srv_target?("."), do: true
  defp valid_srv_target?(target), do: valid_dns_name?(target)

  defp control_txt(%DNS.Message.Record.Data.TXT{data: values}), do: control_txt(values)

  defp control_txt([_ | _] = values) do
    if Enum.all?(values, &valid_text?/1), do: {:ok, "TXT", values}, else: :error
  end

  defp control_txt(_data), do: :error

  defp control_domain(%DNS.Message.Domain{value: value}), do: control_domain(value)

  defp control_domain(value) when is_binary(value) do
    if valid_dns_name?(value), do: {:ok, value}, else: :error
  end

  defp control_domain(_value), do: :error

  defp valid_text?(value) when is_binary(value) and byte_size(value) in 1..1024,
    do: String.valid?(value)

  defp valid_text?(_value), do: false

  defp valid_dns_name?(value) when is_binary(value) and byte_size(value) in 1..254 do
    name =
      if String.ends_with?(value, ".") do
        binary_part(value, 0, byte_size(value) - 1)
      else
        value
      end

    case name do
      "" -> false
      name when byte_size(name) > 253 -> false
      name -> name |> String.split(".", trim: false) |> Enum.all?(&valid_dns_label?/1)
    end
  end

  defp valid_dns_name?(_value), do: false

  defp valid_dns_label?(label) when byte_size(label) in 1..63 do
    Regex.match?(~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\z/, label) or
      Regex.match?(~r/\A_[A-Za-z0-9](?:[A-Za-z0-9-]{0,60}[A-Za-z0-9])?\z/, label)
  end

  defp valid_dns_label?(_label), do: false

  defp clear_entries do
    :ets.delete_all_objects(@table_name)

    :telemetry.execute(
      [:yellow_dog, :mdns, :message_cache, :cleared],
      %{count: 1},
      %{}
    )
  end

  defp store_message(message, source_ip, source_port) do
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

    # Cache questions for service discovery
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
