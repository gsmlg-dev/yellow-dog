# Phase 2: Recursive Resolver - Design Document

**Objective**: Transform YellowDog DNS from an authoritative-only server into a full recursive DNS resolver with forward zones, iterative resolution, and root zone management.

**Timeline**: 5 weeks (Weeks 4-8)
**Deliverables**: Forward zones, recursive resolver, root zone manager, integration tests

---

## Architecture Overview

### Data Flow: Recursive Resolution

```
Client Query
    ↓
[Handler.UDP] - Parse query
    ↓
[Query.Resolver.resolve_recursive/3]
    ├─→ Check cache
    ├─→ Check authoritative zones
    ├─→ Check forward zones
    └─→ Perform iterative resolution
        ├─→ Query root zone/root servers
        ├─→ Follow NS records (referrals)
        ├─→ Handle glue records
        ├─→ Cache intermediate results
        └─→ Return final answer
    ↓
[Cache.Manager] - Cache response with TTL
    ↓
Response to Client
```

### Module Architecture

```
YellowDog.Dns.Recursive (new)
├── YellowDog.Dns.Query.Resolver.Recursive (new)
│   ├── Query engine (iterative algorithm)
│   ├── NS record following
│   └── Retry/timeout logic
├── YellowDog.Dns.Zone.Forward (new)
│   ├── Forward zone type
│   ├── Upstream server config
│   └── Forwarding logic
├── YellowDog.Dns.RootZone (new)
│   ├── RootZone.Hints (Strategy 1)
│   ├── RootZone.Fetcher (Strategy 2)
│   └── RootZone.Authoritative (Strategy 3)
└── YellowDog.Dns.Recursive.Upstream (new)
    ├── UDP/TCP client
    ├── Timeout/retry logic
    └── Response caching per upstream
```

### Integration Points

The recursive resolver integrates with existing components:

**Query.Resolver** (`lib/yellow_dog/dns/query/resolver.ex`):
- `resolve/3` - Enhanced to handle recursive queries
- `resolve_authoritative/3` - Existing authoritative lookup (unchanged)
- `resolve_recursive/3` - NEW: Recursive resolution
- `resolve_with_forwarding/3` - NEW: Check forward zones first

**Handler.UDP** (`lib/yellow_dog/dns/handler/udp.ex`):
- Query processing order:
  1. Check RD (Recursion Desired) flag
  2. RPZ check (if enabled)
  3. Cache lookup
  4. Authoritative zone lookup
  5. Forward zone lookup (NEW)
  6. Recursive resolution (NEW)

**Cache.Manager** (`lib/yellow_dog/dns/query/cache/manager.ex`):
- Extends existing cache for recursive responses
- Handles NXDOMAIN caching (negative caching)

---

## Week 4: Forward Zones

### Goals

1. Define forward zone data structure
2. Implement upstream server configuration
3. Create forwarding logic with UDP/TCP fallback
4. Add forward zone caching
5. Write comprehensive tests

### Implementation Details

#### 1. Zone.Forward Module (NEW)

**File**: `lib/yellow_dog/dns/zone/forward.ex`

```elixir
defmodule YellowDog.Dns.Zone.Forward do
  @moduledoc """
  Forward zone type for delegating queries to upstream servers.

  A forward zone forwards queries for a domain to one or more upstream
  DNS servers instead of performing authoritative lookup or recursion.

  Examples:
    # Simple forward to single server
    forward zone "example.com" { forwarders { 8.8.8.8; }; };

    # Multiple forwarders with failover
    forward zone "example.com" {
      forwarders { 8.8.8.8; 1.1.1.1; };
      forward first;
    };
  """

  defstruct [
    :name,           # Zone name (e.g., "example.com")
    :forwarders,     # List of {ip, port} tuples
    :forward_only,   # Boolean: true = only forward, false = fallback to recursion
    :timeout,        # Timeout in ms (default 5000)
    :attempts,       # Number of retries (default 3)
    :dnssec,         # DNSSEC validation (default false)
    :ssl_cert        # Path to SSL cert for DoT (future)
  ]

  @type t :: %__MODULE__{
    name: String.t(),
    forwarders: [{tuple(), 1..65535}],
    forward_only: boolean(),
    timeout: pos_integer(),
    attempts: pos_integer(),
    dnssec: boolean(),
    ssl_cert: String.t() | nil
  }

  @doc """
  Create a new forward zone.
  """
  def new(name, forwarders, opts \\ []) do
    %__MODULE__{
      name: normalize_name(name),
      forwarders: Enum.map(forwarders, fn
        {ip, port} -> {ip, port}
        ip -> {ip, 53}
      end),
      forward_only: Keyword.get(opts, :forward_only, false),
      timeout: Keyword.get(opts, :timeout, 5000),
      attempts: Keyword.get(opts, :attempts, 3),
      dnssec: Keyword.get(opts, :dnssec, false),
      ssl_cert: Keyword.get(opts, :ssl_cert, nil)
    }
  end

  @doc """
  Check if query matches forward zone.
  """
  def matches?(zone, query_name) do
    normalize_name(query_name)
    |> String.ends_with?(normalize_name(zone.name))
  end

  @doc """
  Get next forwarder to try (round-robin).
  """
  def next_forwarder(zone, attempt \\ 0) do
    index = rem(attempt, length(zone.forwarders))
    Enum.at(zone.forwarders, index)
  end

  defp normalize_name(name) do
    name
    |> String.trim_trailing(".")
    |> String.downcase()
  end
end
```

#### 2. Recursive.Upstream Module (NEW)

**File**: `lib/yellow_dog/dns/recursive/upstream.ex`

```elixir
defmodule YellowDog.Dns.Recursive.Upstream do
  @moduledoc """
  Upstream DNS server client for forwarding queries.

  Handles:
  - UDP and TCP queries to upstream servers
  - Timeout and retry logic
  - Response parsing and validation
  - Per-upstream statistics
  """

  @doc """
  Forward a query to an upstream server.

  Returns:
    {:ok, response}
    {:error, :timeout}
    {:error, :server_failure}
  """
  def forward_query(forwarder, query_binary, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5000)
    attempts = Keyword.get(opts, :attempts, 3)

    forward_with_retry(forwarder, query_binary, attempts, timeout)
  end

  defp forward_with_retry(_forwarder, _query, 0, _timeout) do
    {:error, :max_retries_exceeded}
  end

  defp forward_with_retry(forwarder, query, attempts, timeout) do
    case try_forward(forwarder, query, timeout) do
      {:ok, response} -> {:ok, response}
      {:error, :timeout} ->
        forward_with_retry(forwarder, query, attempts - 1, timeout)
      {:error, _} = error -> error
    end
  end

  defp try_forward({ip, port}, query_binary, timeout) do
    with {:ok, socket} <- :gen_udp.open(0, [:binary, active: false]),
         :ok <- :gen_udp.send(socket, ip, port, query_binary),
         {:ok, {_ip, _port, response}} <- :gen_udp.recv(socket, 512, timeout) do
      :gen_udp.close(socket)
      {:ok, response}
    else
      {:error, :timeout} ->
        :gen_udp.close(socket)
        {:error, :timeout}
      error ->
        error
    end
  catch
    :error, _ -> {:error, :socket_error}
  end
end
```

#### 3. Query.Resolver Enhancement

**File**: `lib/yellow_dog/dns/query/resolver.ex` (modified)

Add functions:

```elixir
@doc """
Resolve with forward zones checked first.
"""
def resolve_with_forwarding(zone_name, query_name, query_type, opts \\ []) do
  forward_zones = Keyword.get(opts, :forward_zones, [])

  # Check forward zones first
  case find_forward_zone(forward_zones, query_name) do
    {:ok, forward_zone} ->
      forward_query(forward_zone, query_name, query_type, opts)
    :not_found ->
      # Fall back to normal resolution
      resolve(zone_name, query_name, query_type)
  end
end

defp find_forward_zone(zones, query_name) do
  zones
  |> Enum.find(&Zone.Forward.matches?(&1, query_name))
  |> case do
    nil -> :not_found
    zone -> {:ok, zone}
  end
end

defp forward_query(forward_zone, query_name, query_type, opts) do
  attempt = Keyword.get(opts, :attempt, 0)
  {forwarder_ip, forwarder_port} = Zone.Forward.next_forwarder(forward_zone, attempt)

  # Build query message
  query = build_query(query_name, query_type)
  query_binary = DNS.to_iodata(query) |> IO.iodata_to_binary()

  # Forward to upstream server
  case Upstream.forward_query({forwarder_ip, forwarder_port}, query_binary,
         timeout: forward_zone.timeout, attempts: forward_zone.attempts) do
    {:ok, response_binary} ->
      response = DNS.Message.from_iodata(response_binary)
      convert_message_to_resolver_result(response)
    {:error, _} ->
      # Try next forwarder or fallback
      if forward_zone.forward_only do
        {:error, :server_failure}
      else
        resolve(nil, query_name, query_type)
      end
  end
end

defp convert_message_to_resolver_result(message) do
  case message.header.rcode do
    0 -> # NOERROR
      {:ok, message.anlist, message.nslist}
    3 -> # NXDOMAIN
      {:nxdomain, [], message.nslist}
    2 -> # SERVFAIL
      {:error, :server_failure}
    _ ->
      {:error, :query_failed}
  end
end
```

#### 4. Tests for Forward Zones

**File**: `test/yellow_dog/dns/zone/forward_test.exs`

```elixir
defmodule YellowDog.Dns.Zone.ForwardTest do
  use ExUnit.Case

  alias YellowDog.Dns.Zone.Forward

  describe "Forward zone creation" do
    test "creates forward zone with single forwarder" do
      zone = Forward.new("example.com", [{8, 8, 8, 8}])

      assert zone.name == "example.com"
      assert zone.forwarders == [{8, 8, 8, 8}]
      assert zone.forward_only == false
      assert zone.timeout == 5000
    end

    test "creates forward zone with multiple forwarders" do
      zone = Forward.new("example.com",
        [{8, 8, 8, 8}, {1, 1, 1, 1}],
        forward_only: true
      )

      assert length(zone.forwarders) == 2
      assert zone.forward_only == true
    end

    test "normalizes zone name" do
      zone = Forward.new("EXAMPLE.COM.", [{8, 8, 8, 8}])
      assert zone.name == "example.com"
    end
  end

  describe "Zone matching" do
    test "matches exact domain" do
      zone = Forward.new("example.com", [{8, 8, 8, 8}])

      assert Forward.matches?(zone, "example.com")
      assert Forward.matches?(zone, "www.example.com")
      refute Forward.matches?(zone, "notexample.com")
    end

    test "matches subdomain" do
      zone = Forward.new("example.com", [{8, 8, 8, 8}])

      assert Forward.matches?(zone, "a.b.c.example.com")
      assert Forward.matches?(zone, "sub.example.com")
    end
  end

  describe "Forwarder selection" do
    test "returns forwarders in round-robin order" do
      zone = Forward.new("example.com",
        [{8, 8, 8, 8}, {1, 1, 1, 1}, {208, 67, 222, 222}]
      )

      f1 = Forward.next_forwarder(zone, 0)
      f2 = Forward.next_forwarder(zone, 1)
      f3 = Forward.next_forwarder(zone, 2)
      f1_again = Forward.next_forwarder(zone, 3)

      assert f1 == {8, 8, 8, 8}
      assert f2 == {1, 1, 1, 1}
      assert f3 == {208, 67, 222, 222}
      assert f1_again == f1
    end
  end
end
```

### Summary

**Files Created**:
- `lib/yellow_dog/dns/zone/forward.ex` - Forward zone type
- `lib/yellow_dog/dns/recursive/upstream.ex` - Upstream client
- `test/yellow_dog/dns/zone/forward_test.exs` - Forward zone tests

**Files Modified**:
- `lib/yellow_dog/dns/query/resolver.ex` - Add forwarding functions
- `lib/yellow_dog/dns/handler/udp.ex` - Integrate forward zone lookup

**Tests**: 10+ tests for forward zones and forwarding logic

---

## Week 5: Recursive Resolver Foundation

### Goals

1. Implement recursive query engine
2. Build iterative resolution algorithm
3. Handle NS record following
4. Manage glue records
5. Implement timeout and retry logic

### Key Components (outline)

- `Query.Resolver.Recursive` - Main recursive engine
- Iterative algorithm with root server queries
- NS record chasing
- Glue record handling
- Timeout/retry with exponential backoff

---

## Week 6: Root Zone Management

### Goals

1. Implement Root hints (Strategy 1)
2. Implement Root fetcher (Strategy 2)
3. Implement Authoritative root (Strategy 3)
4. Configuration for root zone selection

### Key Components (outline)

- `RootZone.Hints` - Embedded root servers
- `RootZone.Fetcher` - IANA root zone fetcher
- `RootZone.Authoritative` - Manual root zone loading
- `RootZone.Manager` - Selectable strategy

---

## Week 8: Integration Testing

### Goals

1. End-to-end recursive resolution tests
2. Performance benchmarking
3. Documentation updates
4. Integration with existing cache and delegation

### Test Categories

- Basic recursive query resolution
- Root server fallback
- Forward zone forwarding
- Error handling and timeouts
- Performance benchmarks (QPS, latency)

---

## Dependencies

**New dependencies needed**:
- `httpoison` - For root zone fetching (optional, lazy load)
- No additional major dependencies required

---

## Performance Targets

- **Recursive query latency**: < 100ms on average
- **QPS for recursive queries**: > 10,000 QPS
- **Cache hit rate**: > 95% for repeated queries
- **Memory per cached entry**: < 1KB average

---

## Notes

- Backward compatibility maintained with existing code
- Cache integration seamless
- Handler logic updated minimally
- Configuration examples provided for all features
- All new code follows existing patterns and conventions

