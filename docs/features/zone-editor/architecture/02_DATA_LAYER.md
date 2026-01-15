# Data Layer: DNS Zone Editor

## Storage Strategy

The zone editor uses the existing ETS-based storage in `YellowDog.Dns.Zone.Auth` with enhancements for optimistic locking and change tracking.

### Why ETS (Not PostgreSQL)

| Factor | ETS | PostgreSQL |
|--------|-----|------------|
| Latency | <1ms | 5-50ms |
| DNS query path | No network hop | Network hop |
| Complexity | Simple | Requires migrations |
| Clustering | Single-node | Multi-node capable |
| Persistence | File-based | Built-in |

**Decision**: Keep ETS for its performance in the DNS query path. Zone files provide persistence. See [ADR-001](../decisions/ADR-001-storage-strategy.md).

## Enhanced Record Structure

```elixir
# Current record in ETS
{{"www.example.com", :a}, %DNS.Message.Record{
  name: "www.example.com",
  type: :a,
  class: :in,
  ttl: 3600,
  rdata: {192, 0, 2, 1}
}}

# Enhanced record with metadata
{{"www.example.com", :a}, %{
  record: %DNS.Message.Record{
    name: "www.example.com",
    type: :a,
    class: :in,
    ttl: 3600,
    rdata: {192, 0, 2, 1}
  },
  metadata: %{
    version: 3,                     # Optimistic locking
    created_at: ~U[2026-01-10 10:00:00Z],
    updated_at: ~U[2026-01-13 14:30:00Z]
  }
}}
```

## Optimistic Locking Implementation

### Adding Version to Auth Zone State

```elixir
# In YellowDog.Dns.Zone.Auth
defstruct [
  :name,
  :table,
  :soa,
  :ns_records,
  :zone_file,
  :zone_data_path,
  :ttl,
  :created_at,
  query_count: 0,
  hit_count: 0,
  miss_count: 0,
  dirty: false,
  zone_version: 0        # NEW: Zone-level version for bulk operations
]
```

### Record-Level Versioning

```elixir
defmodule YellowDog.Dns.Zone.Auth do
  # Enhanced add_record with version initialization
  def handle_call({:add_record, record}, _from, state) do
    key = {normalize_name(record.name), normalize_type(record.type)}

    entry = %{
      record: record,
      metadata: %{
        version: 1,
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }
    }

    :ets.insert(state.table, {key, entry})
    new_state = %{state | dirty: true, zone_version: state.zone_version + 1}
    {:reply, :ok, new_state}
  end

  # Enhanced update with version check
  def handle_call({:update_record, name, type, new_record, expected_version}, _from, state) do
    key = {normalize_name(name), normalize_type(type)}

    case :ets.lookup(state.table, key) do
      [] ->
        {:reply, {:error, :not_found}, state}

      [{^key, %{metadata: %{version: current_version}}}] when current_version != expected_version ->
        {:reply, {:error, :version_conflict}, state}

      [{^key, %{metadata: metadata}}] ->
        entry = %{
          record: new_record,
          metadata: %{metadata |
            version: metadata.version + 1,
            updated_at: DateTime.utc_now()
          }
        }
        :ets.insert(state.table, {key, entry})
        new_state = %{state | dirty: true, zone_version: state.zone_version + 1}
        {:reply, {:ok, entry}, new_state}
    end
  end
end
```

## Change History Storage

### In-Memory Ring Buffer

```elixir
defmodule YellowDog.Dns.Zone.History do
  @moduledoc """
  In-memory change history for a zone.
  Uses a fixed-size ring buffer to limit memory usage.
  """

  defstruct [
    zone_name: nil,
    max_entries: 1000,
    entries: [],           # List acts as ring buffer
    entry_count: 0
  ]

  @doc """
  Add a change entry to history.
  Oldest entries are dropped when max_entries is reached.
  """
  def add_entry(history, entry) do
    entries =
      if length(history.entries) >= history.max_entries do
        [entry | Enum.take(history.entries, history.max_entries - 1)]
      else
        [entry | history.entries]
      end

    %{history |
      entries: entries,
      entry_count: history.entry_count + 1
    }
  end

  @doc """
  Get recent entries, newest first.
  """
  def get_recent(history, count \\ 50) do
    Enum.take(history.entries, count)
  end

  @doc """
  Find entry by ID for rollback.
  """
  def find_entry(history, entry_id) do
    Enum.find(history.entries, &(&1.id == entry_id))
  end
end
```

### History Entry Structure

```elixir
defmodule YellowDog.Dns.Zone.History.Entry do
  defstruct [
    :id,                    # ULID
    :zone_name,
    :action,                # :create | :update | :delete | :import
    :record_type,
    :record_name,
    :before,                # nil for create, record for update/delete
    :after,                 # nil for delete, record for create/update
    :timestamp,
    :metadata               # Additional context (user, IP, etc.)
  ]

  def new(action, zone_name, opts \\ []) do
    %__MODULE__{
      id: generate_ulid(),
      zone_name: zone_name,
      action: action,
      record_type: opts[:record_type],
      record_name: opts[:record_name],
      before: opts[:before],
      after: opts[:after],
      timestamp: DateTime.utc_now(),
      metadata: opts[:metadata] || %{}
    }
  end

  defp generate_ulid do
    # Use ex_ulid or similar
    "chg_" <> Base.encode32(:crypto.strong_rand_bytes(16), case: :lower, padding: false)
  end
end
```

## Zone File Persistence

### Saving Enhanced Records

The existing `Zone.Loader.save_zone_to_file/2` handles basic records. Metadata is not persisted to zone files (reconstructed on load).

```elixir
# In YellowDog.Dns.Zone.Auth
defp do_save(state) do
  records =
    :ets.tab2list(state.table)
    |> Enum.map(fn
      {_key, %{record: record}} -> record  # Extract record from enhanced format
      {_key, record} -> record              # Legacy format
    end)

  zone = %DNS.Zone{
    name: %DNS.Zone.Name{value: state.name},
    type: :authoritative,
    origin: state.name,
    ttl: state.ttl || 3600,
    soa: extract_soa_map(state.soa),
    records: records_to_rrsets(records),
    options: [source_file: state.zone_file],
    comments: []
  }

  DNS.Zone.Loader.save_zone_to_file(zone, state.zone_file)
end
```

### Loading and Initializing Metadata

```elixir
defp load_zone_data(state, zone_data) when is_list(zone_data) do
  now = DateTime.utc_now()

  # Categorize and store records
  {soa, ns_records, _other_records} =
    Enum.reduce(zone_data, {nil, [], []}, fn record, {soa, ns, others} ->
      case normalize_type(record.type) do
        :soa -> {record, ns, others}
        :ns -> {soa, [record | ns], others}
        _ -> {soa, ns, [record | others]}
      end
    end)

  # Insert all records with metadata
  Enum.each(zone_data, fn record ->
    key = {normalize_name(record.name), normalize_type(record.type)}
    entry = %{
      record: record,
      metadata: %{
        version: 1,
        created_at: now,
        updated_at: now
      }
    }
    :ets.insert(state.table, {key, entry})
  end)

  %{state |
    soa: soa,
    ns_records: Enum.reverse(ns_records),
    zone_version: 1
  }
end
```

## Query Patterns

### Get Records (Updated for Enhanced Format)

```elixir
def handle_call({:get_records, name, type}, _from, state) do
  records = lookup_records(state.table, name, type)
  {:reply, records, state}
end

defp lookup_records(table, name, type) do
  normalized = normalize_name(name)

  matches = case type do
    :any ->
      :ets.match_object(table, {{normalized, :_}, :_})
    specific_type ->
      :ets.lookup(table, {normalized, specific_type})
  end

  # Extract records from enhanced format
  Enum.map(matches, fn
    {_key, %{record: record}} -> record
    {_key, record} -> record  # Legacy support
  end)
end
```

### Get Records with Metadata

```elixir
def handle_call({:get_records_with_metadata, name, type}, _from, state) do
  entries = lookup_entries(state.table, name, type)
  {:reply, entries, state}
end

defp lookup_entries(table, name, type) do
  normalized = normalize_name(name)

  matches = case type do
    :any ->
      :ets.match_object(table, {{normalized, :_}, :_})
    specific_type ->
      :ets.lookup(table, {normalized, specific_type})
  end

  Enum.map(matches, fn {_key, entry} ->
    case entry do
      %{record: _, metadata: _} -> entry
      record -> %{record: record, metadata: %{version: 0}}  # Legacy
    end
  end)
end
```

## Migration Path

### Phase 1: Non-Breaking Enhancement

1. Update `add_record` to store enhanced format
2. Update `lookup_records` to handle both formats
3. Existing zones continue to work (legacy format)

### Phase 2: Background Migration

```elixir
def migrate_to_enhanced_format(state) do
  now = DateTime.utc_now()

  :ets.tab2list(state.table)
  |> Enum.each(fn
    {key, %{record: _}} ->
      # Already enhanced
      :ok

    {key, record} when is_map(record) ->
      # Migrate legacy record
      entry = %{
        record: record,
        metadata: %{version: 1, created_at: now, updated_at: now}
      }
      :ets.insert(state.table, {key, entry})
  end)
end
```

## Performance Considerations

### ETS Table Configuration

```elixir
# Current configuration (optimized for reads)
:ets.new(:zone_table, [
  :bag,                    # Multiple records per key (same name+type)
  :protected,              # Only owner can write
  read_concurrency: true   # Optimized for concurrent reads
])

# Consider for high-write scenarios
:ets.new(:zone_table, [
  :bag,
  :protected,
  read_concurrency: true,
  write_concurrency: true  # Add if many concurrent writes expected
])
```

### Memory Estimation

```elixir
# Approximate memory per record entry
record_size = 200           # Average record struct bytes
metadata_size = 100         # Metadata struct bytes
key_overhead = 50           # ETS key overhead
entry_total = 350           # ~350 bytes per entry

# For a zone with 10,000 records
zone_memory = 10_000 * 350  # ~3.5 MB

# History buffer (1000 entries × ~500 bytes each)
history_memory = 1_000 * 500  # ~500 KB

# Total per zone
total_per_zone = 4_000_000  # ~4 MB
```

## Backup and Recovery

### Zone File Backup

```elixir
defmodule YellowDog.Dns.Zone.Backup do
  @doc """
  Create a timestamped backup of the zone file.
  """
  def create_backup(zone_file) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    backup_path = "#{zone_file}.#{timestamp}.bak"

    case File.copy(zone_file, backup_path) do
      {:ok, _} -> {:ok, backup_path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  List available backups for a zone.
  """
  def list_backups(zone_file) do
    dir = Path.dirname(zone_file)
    base = Path.basename(zone_file)

    Path.wildcard(Path.join(dir, "#{base}.*.bak"))
    |> Enum.sort(:desc)  # Newest first
  end

  @doc """
  Restore zone from backup.
  """
  def restore_backup(zone_pid, backup_path) do
    YellowDog.Dns.Zone.Auth.reload(zone_pid, zone_file: backup_path)
  end
end
```

## Concurrency Safety

### Read Operations

- ETS reads are lock-free with `read_concurrency: true`
- Multiple LiveView processes can read simultaneously
- No coordination needed

### Write Operations

- All writes go through GenServer (serialized)
- Optimistic locking prevents lost updates
- Version mismatch returns clear error

### PubSub for UI Updates

```elixir
# After successful write, publish event
defp publish_change(zone_name, event) do
  Phoenix.PubSub.broadcast(
    YellowDog.Console.PubSub,
    "zone:#{zone_name}",
    event
  )
end

# In LiveView
def mount(params, _session, socket) do
  zone_name = params["zone_name"]

  if connected?(socket) do
    Phoenix.PubSub.subscribe(YellowDog.Console.PubSub, "zone:#{zone_name}")
  end

  {:ok, assign(socket, zone_name: zone_name)}
end

def handle_info({:record_added, record}, socket) do
  # Refresh record list
  {:noreply, stream_insert(socket, :records, record)}
end
```
