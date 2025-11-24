# YellowDog DNS Recursive Resolver - Quick Reference

**For Developers**: Quick reference guide for implementing the recursive resolver.

---

## Key Files to Create

```
apps/yellow_dog_dns/lib/yellow_dog/dns/
├── query/
│   ├── recursive.ex         # 400 LOC - Main recursive resolver
│   └── iterator.ex          # 300 LOC - Single iteration logic
├── root_zone/
│   ├── manager.ex           # 200 LOC - GenServer managing root zone
│   ├── hints.ex            # 100 LOC - Embedded root servers
│   ├── fetcher.ex          # 250 LOC - IANA zone fetcher
│   └── strategy.ex         # 50 LOC  - Behavior definition
└── cache/
    ├── resolver_cache.ex   # 300 LOC - Cache GenServer
    └── entry.ex            # 100 LOC - Cache entry structure

Total: ~1700 LOC
```

---

## Core Types

```elixir
# Nameserver
@type nameserver :: %{
  name: String.t() | nil,
  address: :inet.ip_address()
}

# Resolution state
@type resolution_state :: %{
  query_name: String.t(),
  query_type: atom(),
  referral_chain: [[String.t()]],
  depth: non_neg_integer(),
  max_depth: non_neg_integer(),
  timeout_ms: non_neg_integer(),
  start_time: integer()
}

# Results
@type iteration_result ::
  {:answer, [DNS.Message.Record.t()]}
  | {:referral, [DNS.Message.Record.t()], [DNS.Message.Record.t()]}
  | {:nxdomain}
  | {:error, term()}

@type resolve_result ::
  {:ok, [Zone.Record.t()]}
  | {:nxdomain, []}
  | {:error, term()}
```

---

## Key Functions Signatures

### Query.Recursive

```elixir
defmodule YellowDog.Dns.Query.Recursive do
  @spec resolve(String.t(), atom(), keyword()) :: resolve_result()
  def resolve(query_name, query_type, opts \\ [])

  @spec resolve_iterative([nameserver()], resolution_state()) :: resolve_result()
  defp resolve_iterative(current_servers, state)

  @spec extract_nameserver_addresses([Record.t()], [Record.t()]) :: [nameserver()]
  defp extract_nameserver_addresses(ns_records, glue_records)

  @spec resolve_nameserver_addresses([Record.t()], resolution_state()) :: resolve_result()
  defp resolve_nameserver_addresses(ns_records, parent_state)
end
```

### Query.Iterator

```elixir
defmodule YellowDog.Dns.Query.Iterator do
  @spec query_nameservers([nameserver()], String.t(), atom(), keyword()) :: iteration_result()
  def query_nameservers(nameservers, query_name, query_type, opts \\ [])

  @spec query_parallel([nameserver()], iodata(), non_neg_integer()) :: {:ok, DNS.Message.t()} | {:error, term()}
  defp query_parallel(nameservers, query_data, timeout_ms)

  @spec parse_response(DNS.Message.t(), String.t()) :: iteration_result()
  defp parse_response(response, query_name)

  @spec extract_glue_records([Record.t()], [Record.t()]) :: [glue_record()]
  defp extract_glue_records(ns_records, ar_records)
end
```

### RootZone.Manager

```elixir
defmodule YellowDog.Dns.RootZone.Manager do
  @spec get_root_nameservers() :: {:ok, [nameserver()]} | {:error, term()}
  def get_root_nameservers()

  @spec reload_root_zone() :: :ok | {:error, term()}
  def reload_root_zone()

  @spec get_strategy() :: :hints | :fetch | :auth
  def get_strategy()
end
```

### Cache.ResolverCache

```elixir
defmodule YellowDog.Dns.Cache.ResolverCache do
  @spec lookup(String.t(), atom()) :: {:hit, [record()], non_neg_integer()} | :miss
  def lookup(query_name, query_type)

  @spec insert(String.t(), atom(), [record()], non_neg_integer()) :: :ok
  def insert(query_name, query_type, records, ttl)

  @spec stats() :: map()
  def stats()
end
```

---

## Algorithm Pseudocode

### Main Recursive Resolution

```elixir
def resolve(query_name, query_type, opts) do
  # 1. Initialize state
  state = %{
    query_name: query_name,
    query_type: query_type,
    depth: 0,
    max_depth: 16,
    referral_chain: [],
    start_time: now()
  }

  # 2. Get root servers
  {:ok, root_servers} = RootZone.Manager.get_root_nameservers()

  # 3. Start iteration
  resolve_iterative(root_servers, state)
end

defp resolve_iterative(current_servers, state) do
  # Check limits
  if state.depth >= state.max_depth, do: return {:error, :max_depth_exceeded}

  # Query nameservers
  case Iterator.query_nameservers(current_servers, state.query_name, state.query_type) do
    {:answer, records} ->
      # Got answer, cache and return
      {:ok, records}

    {:referral, ns_records, glue_records} ->
      # Check loop
      if loop_detected?(ns_records, state.referral_chain) do
        {:error, :referral_loop}
      else
        # Extract next servers from glue
        next_servers = extract_nameserver_addresses(ns_records, glue_records)

        if empty?(next_servers) do
          # No glue, resolve NS names (sidequery)
          resolve_nameserver_addresses(ns_records, state)
        else
          # Continue with glue addresses
          new_state = update_state(state, ns_records)
          resolve_iterative(next_servers, new_state)
        end
      end

    {:nxdomain} ->
      {:nxdomain, []}

    {:error, reason} ->
      {:error, reason}
  end
end
```

### Iterator Query

```elixir
def query_nameservers(nameservers, query_name, query_type, opts) do
  # 1. Create query message
  query_message = create_query_message(query_name, query_type)
  query_data = DNS.Parameter.to_iodata(query_message)

  # 2. Query in parallel
  case query_parallel(nameservers, query_data, timeout_ms) do
    {:ok, response} ->
      # 3. Parse response
      parse_response(response, query_name)

    {:error, reason} ->
      {:error, reason}
  end
end

defp query_parallel(nameservers, query_data, timeout_ms) do
  # Use Task.async_stream for parallel queries
  nameservers
  |> Task.async_stream(fn ns ->
    query_single_nameserver(ns.address, 53, query_data, timeout_ms)
  end, timeout: timeout_ms, on_timeout: :kill_task)
  |> Enum.find_value(fn
    {:ok, {:ok, response}} -> {:ok, response}
    _ -> nil
  end)
  |> case do
    nil -> {:error, :all_nameservers_failed}
    result -> result
  end
end
```

---

## Root Hints Data

```elixir
@root_servers [
  %{name: "a.root-servers.net",
    ipv4: [{198, 41, 0, 4}],
    ipv6: [{0x2001, 0x503, 0xba3e, 0, 0, 0, 0x2, 0x30}]},

  %{name: "b.root-servers.net",
    ipv4: [{170, 247, 170, 2}],
    ipv6: [{0x2801, 0x1b8, 0x10, 0, 0, 0, 0, 0xb}]},

  # ... (11 more servers)
]
```

---

## Configuration Defaults

```elixir
@default_config %{
  recursion_enabled: true,
  recursion_timeout_ms: 10_000,
  max_recursion_depth: 16,
  query_retries: 2,
  query_timeout_ms: 5_000,
  parallel_queries: true,
  max_concurrent_queries: 10,

  root_zone: %{
    strategy: :hints,
    fetch_interval_hours: 24,
    fallback_to_hints: true
  },

  cache: %{
    enabled: true,
    max_size: 10_000,
    min_ttl: 60,
    max_ttl: 86_400,
    cleanup_interval_seconds: 300
  }
}
```

---

## Telemetry Events

```elixir
# Start resolution
:telemetry.execute(
  [:yellow_dog, :dns, :recursive_start],
  %{timestamp: System.monotonic_time()},
  %{query_name: name, query_type: type}
)

# Iteration
:telemetry.execute(
  [:yellow_dog, :dns, :recursive_iteration],
  %{depth: depth},
  %{query_name: name, referral_zone: zone}
)

# Complete
:telemetry.execute(
  [:yellow_dog, :dns, :recursive_complete],
  %{duration: duration, iterations: depth},
  %{query_name: name, result: :ok}
)

# Error
:telemetry.execute(
  [:yellow_dog, :dns, :recursive_error],
  %{count: 1},
  %{error: error_type, query_name: name}
)

# Cache hit
:telemetry.execute(
  [:yellow_dog, :dns, :recursive_cache_hit],
  %{ttl: remaining_ttl},
  %{query_name: name, query_type: type}
)

# Cache miss
:telemetry.execute(
  [:yellow_dog, :dns, :recursive_cache_miss],
  %{count: 1},
  %{query_name: name, query_type: type}
)
```

---

## Testing Checklist

### Unit Tests
- [ ] RootZone.Hints.get_root_servers/0 returns 13 servers
- [ ] RootZone.Manager.get_root_nameservers/0 works with hints
- [ ] Cache.Entry.new/4 creates valid entry
- [ ] Cache.Entry.expired?/1 detects expiration
- [ ] ResolverCache.lookup/2 returns :miss for uncached
- [ ] ResolverCache.insert/4 stores entry
- [ ] ResolverCache.lookup/2 returns {:hit, ...} for cached
- [ ] Iterator.extract_glue_records/2 extracts A records
- [ ] Iterator.extract_glue_records/2 extracts AAAA records
- [ ] Iterator.parse_response/2 identifies answers
- [ ] Iterator.parse_response/2 identifies referrals
- [ ] Iterator.parse_response/2 handles NXDOMAIN
- [ ] Recursive.resolve/3 initializes state correctly
- [ ] Recursive.resolve_iterative/2 detects loops
- [ ] Recursive.resolve_iterative/2 enforces depth limit
- [ ] Recursive.resolve_iterative/2 handles timeouts

### Integration Tests
- [ ] End-to-end resolution from root (real query)
- [ ] Resolution with mock nameservers
- [ ] CNAME chain following in recursive context
- [ ] Handler.UDP integration
- [ ] View-based recursion control
- [ ] Cache integration

### Performance Tests
- [ ] 100 concurrent queries (success rate > 95%)
- [ ] 1000 concurrent queries (success rate > 90%)
- [ ] Cache hit rate measurement
- [ ] Memory usage under load
- [ ] Latency measurements (cached vs recursive)

---

## Common Pitfalls

### 1. Query ID Mismatch
```elixir
# WRONG: Don't reuse query ID from original query
response = %{response | header: %{response.header | id: query.header.id}}

# RIGHT: Validate response ID matches request
if response.header.id != query_message.header.id do
  {:error, :query_id_mismatch}
end
```

### 2. Referral Loop Detection
```elixir
# WRONG: Only check last referral
if ns_names == last_referral do
  {:error, :referral_loop}
end

# RIGHT: Check entire chain
if ns_names in state.referral_chain do
  {:error, :referral_loop}
end
```

### 3. Glue Record Handling
```elixir
# WRONG: Assume glue always present
next_servers = extract_nameserver_addresses(ns_records, glue_records)
resolve_iterative(next_servers, state)  # Fails if no glue!

# RIGHT: Handle missing glue
if Enum.empty?(next_servers) do
  resolve_nameserver_addresses(ns_records, state)  # Sidequery
else
  resolve_iterative(next_servers, state)
end
```

### 4. TTL Caching
```elixir
# WRONG: Use fixed TTL
insert_cache(query, records, 300)

# RIGHT: Use record TTL, clamp to min/max
ttl = get_minimum_ttl(records)
clamped_ttl = clamp_ttl(ttl, min_ttl, max_ttl)
insert_cache(query, records, clamped_ttl)
```

### 5. Timeout Handling
```elixir
# WRONG: Fixed timeout for all iterations
query_nameservers(servers, query, timeout: 5000)

# RIGHT: Subtract elapsed time
elapsed = now() - state.start_time
remaining = state.timeout_ms - elapsed
query_nameservers(servers, query, timeout: remaining)
```

---

## Debug Commands

```elixir
# Get root servers
YellowDog.Dns.RootZone.Manager.get_root_nameservers()

# Check cache
YellowDog.Dns.Cache.ResolverCache.lookup("example.com", :A)

# Get cache stats
YellowDog.Dns.Cache.ResolverCache.stats()

# Resolve with debug
YellowDog.Dns.Query.Recursive.resolve("example.com", :A, debug: true)

# Check strategy
YellowDog.Dns.RootZone.Manager.get_strategy()

# Force cache cleanup
send(YellowDog.Dns.Cache.ResolverCache, :cleanup)
```

---

## Performance Tuning

### ETS Table Options
```elixir
:ets.new(:dns_recursive_cache, [
  :set,                    # One entry per key
  :public,                 # Accessible from all processes
  :named_table,            # Named for easy access
  read_concurrency: true,  # Optimize for reads
  write_concurrency: true  # Optimize for writes
])
```

### Parallel Query Tuning
```elixir
Task.async_stream(nameservers, fn ns -> ... end,
  timeout: timeout_ms,           # Per-task timeout
  on_timeout: :kill_task,        # Kill on timeout
  max_concurrency: 10,           # Limit concurrent tasks
  ordered: false                 # Don't preserve order
)
```

### Cache Size Limits
```elixir
# Monitor cache size
cache_size = :ets.info(:dns_recursive_cache, :size)

# Implement LRU eviction when size > max_size
if cache_size > max_size do
  evict_oldest_entries(cache_size - max_size)
end
```

---

## References

- **Full Design**: `RECURSIVE_RESOLVER_DESIGN.md`
- **Summary**: `RECURSIVE_RESOLVER_SUMMARY.md`
- **Architecture Diagrams**: `RECURSIVE_RESOLVER_ARCHITECTURE.md`
- **RFC 1034**: DNS Concepts and Facilities
- **RFC 1035**: DNS Implementation and Specification

---

**Quick Start**: Begin with Phase 1 (Foundation) - implement root zone hints and cache infrastructure.
