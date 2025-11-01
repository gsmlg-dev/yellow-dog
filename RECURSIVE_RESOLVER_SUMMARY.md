# YellowDog DNS Recursive Resolver - Executive Summary

**Full Design Document**: See `RECURSIVE_RESOLVER_DESIGN.md`

---

## Overview

This document summarizes the design for implementing a full recursive DNS resolver in YellowDog DNS. The recursive resolver will enable the server to resolve any domain name by starting from root servers and following referrals through the DNS hierarchy.

---

## Key Components

### 1. Root Zone Management (3 Strategies)

| Strategy | Description | Use Case |
|----------|-------------|----------|
| **Hints** (default) | Embedded 13 root servers | Standard deployments, no external dependencies |
| **Fetch** | Download from IANA periodically | Enterprise/ISP, always up-to-date |
| **Auth** | Load from local zone file | Air-gapped environments, testing, custom TLDs |

### 2. New Modules

```
apps/yellow_dog_dns/lib/yellow_dog/dns/
├── query/
│   ├── recursive.ex         # Main recursive resolver
│   └── iterator.ex          # Single iteration logic
├── root_zone/
│   ├── manager.ex           # GenServer managing root zone
│   ├── hints.ex            # Embedded root servers
│   ├── fetcher.ex          # IANA zone fetcher
│   └── strategy.ex         # Behavior for strategies
└── cache/
    ├── resolver_cache.ex   # Recursive resolver cache
    └── entry.ex            # Cache entry structure
```

### 3. Resolution Algorithm

```
1. Get root nameservers from RootZone.Manager
2. Start with query_name and root servers
3. LOOP (max 16 iterations):
   a. Query nameservers in parallel
   b. If ANSWER received:
      - Cache and return
   c. If REFERRAL received:
      - Extract NS records and glue
      - Check for loops
      - Update current servers
      - Continue loop
   d. If NXDOMAIN:
      - Return NXDOMAIN
4. Return answer or error
```

### 4. Key Features

**Glue Record Handling:**
- Extract glue from additional section
- Handle missing glue with sidequery resolution
- Validate out-of-bailiwick glue

**Loop Detection:**
- Track visited zones
- Check referral chain for duplicates
- Enforce max depth limit (16)

**Caching:**
- Cache final answers with TTL
- Cache NS records and glue
- Negative caching for NXDOMAIN
- Min/max TTL clamping

**Performance:**
- Parallel nameserver queries
- Connection pooling (planned)
- First-successful-wins strategy
- ETS-based cache with read_concurrency

**Security:**
- Query ID randomization
- Source port randomization
- Response validation
- Referral validation
- Rate limiting

---

## Configuration Example

```toml
[dns]
recursion_enabled = true
recursion_timeout_ms = 10000
max_recursion_depth = 16

[dns.root_zone]
strategy = "hints"  # or "fetch" or "auth"
fetch_interval_hours = 24
fallback_to_hints = true

[dns.cache]
recursive_cache_enabled = true
max_cache_size = 10000
min_cache_ttl = 60
max_cache_ttl = 86400
```

---

## Integration Points

### Handler.UDP
```elixir
# When zone not found locally and view allows recursion:
case YellowDog.Dns.Query.Recursive.resolve(query_name, query_type) do
  {:ok, records} -> return answer
  {:nxdomain, _} -> return NXDOMAIN
  {:error, _} -> return SERVFAIL
end
```

### Query.Resolver
```elixir
# Add recursive fallback when zone not found:
if YellowDog.Config.recursion_enabled?() do
  YellowDog.Dns.Query.Recursive.resolve(owner, qtype)
else
  {:servfail, [], []}
end
```

### View
```elixir
# Per-view recursion control:
defstruct [:name, :match_clients, :zones, :recursion_enabled]

def recursion_allowed?(view) do
  view.recursion_enabled
end
```

---

## Implementation Phases

| Phase | Duration | Focus |
|-------|----------|-------|
| 1. Foundation | Week 1-2 | Root zone hints, cache infrastructure |
| 2. Iterator | Week 3-4 | Single iteration query logic |
| 3. Recursive Resolver | Week 5-6 | Full iterative resolution |
| 4. Advanced Features | Week 7-8 | Fetch/auth strategies, optimizations |
| 5. Handler Integration | Week 9 | System integration |
| 6. Security & Polish | Week 10 | Security hardening, docs |

**Total Duration:** 10 weeks

---

## Example Resolution Trace

```
Query: www.example.com A

Step 1: Query Root Servers (a.root-servers.net)
└─ Referral to .com nameservers [a.gtld-servers.net, ...]

Step 2: Query .com Nameservers (a.gtld-servers.net)
└─ Referral to example.com nameservers [ns1.example.com, ...]

Step 3: Query example.com Nameservers (ns1.example.com)
└─ Answer: www.example.com A 192.0.2.100

Result: 192.0.2.100 (3 iterations, 156ms)
```

---

## Security Features

1. **Query ID Randomization**: Cryptographically strong random IDs
2. **Source Port Randomization**: Ephemeral ports prevent spoofing
3. **Response Validation**: Verify query ID and question match
4. **Referral Validation**: Check bailiwick and progression
5. **Rate Limiting**: Per-client query rate limits
6. **Loop Detection**: Track and prevent referral loops

---

## Performance Targets

- **Latency**: < 100ms for cached queries
- **Throughput**: 1000+ concurrent queries
- **Cache Hit Rate**: > 50% in typical usage
- **Memory**: < 100MB for 10,000 cache entries

---

## Testing Strategy

### Unit Tests
- Root zone management
- Cache operations
- Iterator logic
- Recursive resolver state machine
- Error handling

### Integration Tests
- End-to-end resolution
- Handler.UDP integration
- View-based recursion control
- Strategy switching

### Load Tests
- 1000+ concurrent queries
- Cache performance under load
- Memory usage monitoring

### Mock Infrastructure
- Mock nameserver framework
- Recorded real-world responses
- Synthetic test scenarios

---

## Key Challenges

| Challenge | Mitigation |
|-----------|------------|
| Root server availability | Caching, fallback to hints, retry logic |
| Cache poisoning | ID randomization, validation, DNSSEC (future) |
| Referral loops | Loop detection, max depth, visited zone tracking |
| Missing glue | Sidequery resolution, depth budget |
| Memory exhaustion | Max cache size, periodic cleanup, LRU eviction |
| Slow nameservers | Parallel queries, timeouts, retry with others |
| DDoS amplification | Rate limiting, ACLs, response rate limiting |

---

## Dependencies

### Existing (Already Available)
- `DNS.Zone.RootHint` - Root hints data in ex_dns
- `DNS.Zone.Recursive` - Basic recursive stub (will be replaced)
- `YellowDog.Dns.Zone.Storage` - ETS-based zone storage
- `YellowDog.Dns.Query.Resolver` - Authoritative resolver
- `Abyss` - UDP server framework

### New (To Be Implemented)
- `YellowDog.Dns.Query.Recursive` - Main recursive resolver
- `YellowDog.Dns.Query.Iterator` - Iteration logic
- `YellowDog.Dns.RootZone.Manager` - Root zone management
- `YellowDog.Dns.Cache.ResolverCache` - Cache system

---

## Next Steps

1. **Review Design Document**: Read full `RECURSIVE_RESOLVER_DESIGN.md`
2. **Phase 1 Implementation**: Start with root zone hints and cache
3. **Create Test Infrastructure**: Build mock nameserver framework
4. **Parallel Development**: Root zone management and iterator can be developed concurrently

---

## Resources

- **Full Design**: `RECURSIVE_RESOLVER_DESIGN.md` (comprehensive 15-section document)
- **RFCs**: 1034, 1035, 2181, 4592, 5452
- **Reference Implementations**: BIND9, Unbound, PowerDNS Recursor

---

**Status**: Design Complete - Ready for Implementation

**Estimated Effort**: 10 weeks (1 developer)

**Risk Level**: Medium (well-understood problem domain, clear specifications)
