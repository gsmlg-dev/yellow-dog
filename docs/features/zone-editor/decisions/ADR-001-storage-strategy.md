# ADR-001: Storage Strategy for Zone Data

**Status:** Accepted
**Date:** 2026-01-13
**Deciders:** Architecture Team
**Context:** DNS zone editor data persistence

## Context

The DNS zone editor needs to store and retrieve zone records efficiently. We need to decide between:
1. Keeping the existing ETS-based storage in Auth zones
2. Migrating to PostgreSQL for full database capabilities
3. A hybrid approach

Key considerations:
- DNS query performance (sub-millisecond latency required)
- Zone editor operations (add/update/delete records)
- Change tracking and audit trail
- Multi-user concurrent editing
- Data persistence across restarts

## Decision

**Keep ETS as primary storage** with zone file persistence, enhanced with metadata for optimistic locking and in-memory change history.

## Rationale

### Performance Requirements

DNS query path must be extremely fast:
- ETS lookup: <1ms (memory-local)
- PostgreSQL query: 5-50ms (network + disk)

For a DNS server handling thousands of queries per second, ETS is the only viable option.

### Current Architecture Fit

The existing YellowDog DNS architecture uses:
- GenServer per zone (Auth, Forward, Stub)
- ETS table per zone for record storage
- Zone files for persistence

Adding PostgreSQL would require fundamental redesign.

### Complexity vs. Benefit

| Capability | ETS + Files | PostgreSQL |
|------------|-------------|------------|
| Query latency | <1ms | 5-50ms |
| ACID transactions | No | Yes |
| SQL queries | No | Yes |
| Clustering | Manual | Built-in |
| Maintenance | Low | High |
| Dependencies | None | External service |

For our use case (single-node DNS server, moderate zone sizes), ETS provides sufficient capabilities without PostgreSQL's complexity.

## Alternatives Considered

### Alternative 1: PostgreSQL as Primary Store

```elixir
# Zone record in PostgreSQL
schema "dns_records" do
  field :zone_id, :binary_id
  field :name, :string
  field :type, :string
  field :ttl, :integer
  field :rdata, :map
  field :version, :integer
  timestamps()
end
```

**Pros:**
- Full SQL query capabilities
- ACID transactions
- Built-in replication

**Cons:**
- 50x+ slower than ETS for DNS queries
- External dependency
- Migration complexity
- Overkill for most deployments

**Why Rejected:** Performance requirements for DNS query path cannot tolerate database latency.

### Alternative 2: ETS + PostgreSQL Hybrid

```elixir
# ETS for hot path (DNS queries)
# PostgreSQL for audit trail and complex queries

def add_record(zone_pid, record) do
  :ok = Auth.add_record(zone_pid, record)  # ETS
  {:ok, _} = AuditLog.log(record)           # PostgreSQL
end
```

**Pros:**
- Best of both worlds
- Full audit capabilities

**Cons:**
- Sync complexity between stores
- Two sources of truth
- Higher operational burden

**Why Rejected:** Complexity outweighs benefits for current requirements. Can revisit if audit requirements grow.

### Alternative 3: Redis as Cache + PostgreSQL

**Pros:**
- Proven pattern for web apps
- Scalable

**Cons:**
- Two external dependencies
- Even more complex sync
- Overkill for DNS use case

**Why Rejected:** DNS servers traditionally don't need this level of complexity.

## Consequences

### Positive

1. **Zero latency impact** - DNS query performance unchanged
2. **No new dependencies** - No PostgreSQL/Redis to maintain
3. **Simple deployment** - Self-contained application
4. **Existing code reuse** - Leverages proven Auth zone implementation
5. **Fast development** - No migration or schema work needed

### Negative

1. **No SQL queries** - Complex reporting requires custom code
2. **Single-node limitation** - No built-in clustering
3. **Memory-bound** - Large zones consume more RAM
4. **Manual sync** - Multi-server deployments need zone transfers

### Mitigations

| Limitation | Mitigation |
|------------|------------|
| No SQL | Export to JSON for analysis |
| Single-node | Zone transfers (AXFR) for replication |
| Memory-bound | Monitor memory, plan capacity |
| Manual sync | Implement NOTIFY/AXFR (future) |

## Implementation Guidelines

### DO: Use ETS for All Zone Operations

```elixir
# Record lookup - ETS
records = Auth.get_records(zone_pid, name, type)

# Record add - ETS via GenServer
:ok = Auth.add_record(zone_pid, record)

# Persistence - zone files
:ok = Auth.save(zone_pid)
```

### DON'T: Add Database Dependency for Zone Data

```elixir
# ❌ DON'T do this
def get_record(zone_id, name, type) do
  Repo.get_by(DnsRecord, zone_id: zone_id, name: name, type: type)
end
```

### DO: Add Metadata for Editing Features

```elixir
# Store metadata alongside records
{key, %{
  record: %DNS.Message.Record{...},
  metadata: %{
    version: 1,
    created_at: ~U[...],
    updated_at: ~U[...]
  }
}}
```

## Validation

This decision will be validated by:

1. **Performance metric**: DNS query latency remains <1ms p99
2. **Functionality**: All zone editor features work with ETS storage
3. **User feedback**: No complaints about zone management UX
4. **Memory usage**: Zones up to 10K records use <50MB

## References

- [ETS Documentation](https://www.erlang.org/doc/man/ets.html)
- [Why DNS Servers Use Memory](https://blog.cloudflare.com/how-we-made-our-dns-server-fast/)
- [BIND Zone File Format](https://bind9.readthedocs.io/en/latest/chapter3.html)

## Related ADRs

- ADR-002: Validation Approach
- ADR-003: Change Tracking Strategy

## Review Schedule

**Last Reviewed:** 2026-01-13
**Next Review:** 2026-07-13 (6 months)

Consider PostgreSQL if:
- Multi-node clustering becomes required
- Complex audit/compliance requirements emerge
- Zone sizes exceed 100K records consistently
