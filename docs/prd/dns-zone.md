# Product: Store-Backed DNS Zone Management

## Overview

Persist all DNS zone configuration and data in YellowDog.Store (Concord-backed KV store), replacing TOML files as the source of truth for zone definitions. Covers three zone types: authoritative, forward, and stub. ETS remains the runtime data plane for query resolution — Store is persistence only.

**This delivers runtime zone management without config edits or restarts, with cluster-wide replication via Raft consensus.**

## Architecture Reference

The implementation plan is in `docs/plans/zone.md`. All Store key patterns, phase ordering, and file-level changes are defined there. This PRD defines the product requirements and data models.

## Context

Yellow Dog is an Elixir umbrella providing DNS, DHCP, mDNS, and network infrastructure services. The following sibling apps are involved:

- `yellow_dog_dns` — DNS server: views, zones, name resolution, ACLs
- `yellow_dog_store` — Unified Store facade over Concord (distributed KV)
- `yellow_dog` — Core config (TOML), orchestration, service manager
- `ex_dns` — DNS protocol library (messages, zones, records)

## Tech Stack

- **Language**: Elixir 1.18 / OTP 27-28
- **Storage**: YellowDog.Store (Concord Raft KV, ETS backend for single-node)
- **Runtime cache**: ETS (per-process, sub-microsecond reads)
- **Events**: Store.EventBridge (pattern-matched subscriptions)
- **Test**: ExUnit, E2E with auto-selected ports

## Problem Statement

DNS zone configuration is currently loaded from TOML files (`data/dns/zones.toml` via `ZoneStore`) and auth zone records live in per-process ETS tables with no durable persistence. Forward and stub zone configs are passed as start-time options with no runtime management.

- **No runtime zone management** — adding/removing zones requires editing TOML config files and restarting
- **No cluster replication** — zone config is local to each node
- **Data loss on restart** — auth zone records in ETS are lost when the process stops
- **No unified API** — different zone types have different configuration mechanisms

## Goals

1. All zone configuration and data persists in YellowDog.Store
2. Zones are manageable at runtime via API without config file edits or restarts
3. Zone data replicates across cluster nodes via Concord's Raft consensus
4. EventBridge-driven zone reload on changes (no polling, no restarts)
5. ETS remains the runtime data plane — zero Store reads in the DNS query hot path

## Non-Goals

- DNSSEC signing or key management
- Zone transfer protocol (AXFR/IXFR) serving to external secondaries
- Dynamic DNS update protocol (RFC 2136) from external clients
- Console UI changes (separate PRD)

## Features

### 1. View-Scoped Zone Storage

All zones are scoped to a DNS view (split-horizon DNS). The Store key hierarchy reflects this:

```
dns:view:{view_name}:zone:{zone_name}
dns:view:{view_name}:zone:{zone_name}:rr:{owner}:{type}   # auth only
```

- Same zone name in different views → different Store keys
- Matches existing `{view_name, zone_type, zone_name}` tuple in `ZoneRegistry`
- Prefix scan `dns:view:{view_name}:zone:` returns all zones in a view
- Prefix scan `dns:view:` returns all zones across all views

### 2. Authoritative Zone (Auth)

An auth zone holds the complete, definitive set of resource records for a domain. The server returns answers with the AA (Authoritative Answer) flag set.

**Persisted in Store:**
- Zone metadata (SOA, TTL, serial strategy, flags)
- All resource records (A, AAAA, CNAME, MX, NS, TXT, SRV, PTR, CAA, etc.)

**Runtime model:**
- ETS is the single source of truth while the server is running
- Store is persistence only — loaded on start, synced on mutation and stop
- Query resolution reads ETS only — zero Store reads in hot path
- Async sync to Store on each mutation; guaranteed flush on graceful shutdown

**Zone metadata:**

```elixir
%{
  zone_type: :auth,
  origin: "example.com",
  soa: %{mname: "ns1.example.com", rname: "admin.example.com",
         serial: 2026032401, refresh: 3600, retry: 900, expire: 604800, minimum: 300},
  default_ttl: 3600,
  authoritative: true,
  allow_dynamic_update: false,
  serial_strategy: :date_serial,
  created_at: ~U[2026-03-24 00:00:00Z],
  updated_at: ~U[2026-03-24 00:00:00Z]
}
```

**RRset value:**

```elixir
%{
  rrset: [%{address: {93, 184, 216, 34}}],
  owner: "www",
  type: :a,
  zone: "example.com",
  class: :in,
  source: :api,
  updated_at: ~U[2026-03-24 00:00:00Z]
}
```

**SOA serial management:**
- Auto-incremented on every RR change
- Strategies: `:date_serial` (YYYYMMDDNN, 100 changes/day) or `:increment` (simple +1)
- CAS with bounded retries (max 10) to prevent lost updates

### 3. Forward Zone

A forward zone holds no zone data. It redirects queries for a specific domain to designated upstream forwarders. This is conditional forwarding — different domains can use different upstream servers.

**Persisted in Store:**
- Configuration only (forwarders list, forward mode, timeout, retries)
- **No zone data, no RRsets**

**Runtime model:**
- GenServer state is runtime truth (upstream list, round-robin index, pending queries)
- Store persists config only — loaded on start, synced on config change and stop

**Zone metadata:**

```elixir
%{
  zone_type: :forward,
  origin: "internal.corp.com",
  forwarders: [%{ip: "10.1.1.53", port: 53}, %{ip: "10.1.2.53", port: 53}],
  forward_mode: :only,       # :only = SERVFAIL if all forwarders fail
                              # :first = fall back to recursion if forwarders fail
  timeout_ms: 5000,
  max_retries: 2,
  created_at: ~U[2026-03-24 00:00:00Z],
  updated_at: ~U[2026-03-24 00:00:00Z]
}
```

**Behavior:**
- `forward :only` — try forwarders in order; SERVFAIL if all fail (BIND9: `forward only`)
- `forward :first` — try forwarders first; fall back to normal recursion if all fail (BIND9: `forward first`)
- Longest-matching zone name wins (most specific forward zone)

**Use cases:**
- Split-horizon DNS (forward `corp.internal` to internal DNS)
- Conditional forwarding to partner/cloud DNS
- Active Directory integration (forward AD zones to domain controllers)

### 4. Stub Zone

A stub zone maintains only the NS records and glue (A/AAAA for those nameservers) for a zone. It does NOT hold full zone data. The purpose is delegation awareness — the resolver knows which nameservers are authoritative without holding all records.

**Persisted in Store:**
- Configuration only (list of primaries to query, refresh interval)

**NOT persisted (runtime cache only):**
- NS records and glue A/AAAA records — fetched by querying primaries at runtime

**Runtime model:**
- GenServer state holds config + cached NS/glue
- On start: load config from Store, then query primaries for NS/glue
- Periodic refresh: re-query primaries at `refresh_interval` for fresh NS/glue
- NS/glue cache discarded on stop — re-fetched on next start

**Zone metadata:**

```elixir
%{
  zone_type: :stub,
  origin: "subsidiary.example.com",
  primaries: [%{ip: "10.2.0.1", port: 53}, %{ip: "10.2.0.2", port: 53}],
  refresh_interval: 3600,
  created_at: ~U[2026-03-24 00:00:00Z],
  updated_at: ~U[2026-03-24 00:00:00Z]
}
```

**Refresh mechanism (NOT zone transfer — uses normal DNS queries):**
1. Query primary for current SOA → compare serial
2. If serial changed, query for NS records at zone apex
3. For each in-bailiwick NS, query for A/AAAA glue
4. Update runtime cache

**Use cases:**
- Internal delegation tracking (auto-track child zone NS changes)
- Multi-site networks (HQ knows branch DNS without replicating branch data)
- Reduces manual configuration vs maintaining forward zones

### 5. Store.Zone API

```elixir
# Auth zone — metadata + RRsets
create_zone(view_name, zone_name, soa, opts)
get_zone(view_name, zone_name)
delete_zone(view_name, zone_name)          # also deletes all RRsets
put_rrset(view_name, zone_name, owner, type, rrset)
get_rrset(view_name, zone_name, owner, type)
delete_rrset(view_name, zone_name, owner, type)
list_records(view_name, zone_name)
list_records(view_name, zone_name, owner)
import_zone(view_name, zone_name, records)
export_zone(view_name, zone_name)
increment_serial(view_name, zone_name)

# Forward zone — config only
create_forward_zone(view_name, name, forwarders, opts)
update_forward_zone(view_name, name, attrs)

# Stub zone — config only
create_stub_zone(view_name, name, primaries, opts)
update_stub_zone(view_name, name, attrs)

# Listing
list_zones()                          # all zones across all views
list_zones_for_view(view_name)        # all zones in a view
list_zones_by_type(zone_type)         # filter by type across all views

# Generic
update_zone(view_name, zone_name, attrs)
```

### 6. Zone GenServer APIs

Each zone type exposes the existing `Zone.Behaviour` interface plus new Store-backed operations:

- `resolve/2` — resolve a DNS query (reads ETS/state only, never Store)
- `reload/2` — reload config/data from new opts
- `update_config/2` — **(new)** update config at runtime, async-sync to Store
- `stats/1` — return zone statistics

### 7. Zone Lifecycle Management

**ZoneController** orchestrates zone creation and startup:
1. Persist zone metadata to Store (CAS, prevent duplicate)
2. Start the zone GenServer process
3. GenServer loads data from Store on `init/1`

**Startup flow:**
1. DNS supervisor starts → scan `Store.Zone.list_zones()`
2. For each zone in Store → start GenServer via ZoneController with its `view_name`
3. Each GenServer loads its data from Store into ETS/state

**ZoneReloader** subscribes to `dns:view:*` via EventBridge:
- Auth zone RR changes → reload records into ETS
- Forward zone metadata changes → reload forwarders in GenServer state
- Stub zone metadata changes → reload config and re-query primaries

### 8. TOML Migration

- On startup: if Store has zones, use Store; if Store is empty and TOML has zones, auto-migrate
- `migrate_to_store/0` reads TOML zones and writes to Store (one-time)
- Old `ZoneStore` module kept but marked `@deprecated`
- TOML config retains server-level settings only (listen address, port, recursion)

## Testing Requirements

### Unit Tests

**Store.Zone** (`apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs`):
- CRUD for each zone type (create, get, update, delete)
- CAS prevents duplicate zone creation
- Auth zone: RRset CRUD with auto serial increment
- Auth zone: import/export round-trip
- Cross-type: list_zones returns all types, list_zones_by_type filters correctly
- Delete auth zone cascades to all RRsets

**Zone GenServers** (existing test files):
- Auth: add record → restart process → records survive (loaded from Store)
- Forward: load config from Store on init; update_config persists to Store
- Stub: load config from Store on init; update_config persists to Store

### E2E Tests

Each zone type gets a separate E2E test file:

| Test | File | Mix Alias |
|------|------|-----------|
| Auth zone | `e2e_test/dns_zone_auth_e2e_test.exs` | `mix test.e2e.zone.auth` |
| Forward zone | `e2e_test/dns_zone_forward_e2e_test.exs` | `mix test.e2e.zone.forward` |
| Stub zone | `e2e_test/dns_zone_stub_e2e_test.exs` | `mix test.e2e.zone.stub` |

**Auth E2E:** Create zone → add records → query via DNS → verify answers → restart process → verify records survive → delete zone → verify cleanup

**Forward E2E:** Create forward zone → query domain → verify forwarding → update forwarders → verify reload → test forward-only SERVFAIL → test forward-first fallback

**Stub E2E:** Create stub zone → verify NS records cached → verify delegation routing → update primaries → verify reload

## RFC References

| RFC | Relevance |
|-----|-----------|
| RFC 1035 | Zone file format, record types, wire protocol |
| RFC 1982 | Serial number arithmetic (comparison with wraparound) |
| RFC 2181 | Authoritative data definition, TTL rules |
| RFC 2308 | Negative caching (SOA minimum = negative TTL) |

## Success Criteria

1. All zone types can be created, updated, and deleted at runtime without restart
2. Auth zone records survive process/node restart (loaded from Store)
3. Forward/stub zone configs survive restart (loaded from Store)
4. Zero Store reads in DNS query hot path (ETS/state only)
5. Zone changes propagate across cluster nodes via EventBridge
6. All unit tests pass; all E2E tests pass
7. `mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict` clean
