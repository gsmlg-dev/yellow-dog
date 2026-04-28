# YellowDog.Store Backend Architecture — Write-Through PRD

## Overview

The Store backend currently treats ETS and Concord as mutually exclusive modes — `ModeDetector` picks one at startup and all operations route to that single backend. This is architecturally wrong. The correct layering is:

- **Concord** is the source of truth for all persistent data (single-node or cluster)
- **ETS** is the always-present local read cache

Every write persists to Concord first, then populates ETS. Every read hits ETS only. This PRD defines that architecture.

**Module:** `YellowDog.Store.Backend` (rework of existing)  
**Product:** yellow-dog server (one of two Mix releases from the umbrella; netman does not depend on Store)  
**Depends on:** Concord ~> 0.1.0, existing Store facade modules  
**Supersedes:** Current `Backend.active()` dispatch pattern

---

## Problem Statement

The current `Backend` module defines a behaviour with two implementations — `Backend.Ets` (single-node) and `Backend.Cluster` (multi-node). `ModeDetector` detects the topology at startup and stores the chosen module in `:persistent_term`. Every facade operation dispatches through `Backend.active()`.

This creates two failure modes:

1. **Single-node mode loses data on restart.** ETS is the sole store. No persistence.
2. **Cluster mode pays Raft overhead on every read.** Even reads that tolerate staleness go through leader/follower query paths instead of local memory.

Both modes also prevent the other layer's benefits — single-node has no durability, cluster has no local-read performance.

---

## Design Principles

- **Concord always persists.** Whether running single-node (Raft bypassed, direct local writes) or cluster (full Raft consensus), Concord handles durability. Single-node mode is "Concord without Raft overhead," not "ETS without Concord."
- **ETS always serves reads.** The hot path never touches Concord. ETS is populated on writes (write-through) and on startup (warming).
- **Write-through, not write-behind.** A write returns success only after Concord has accepted it AND ETS has been updated. This guarantees ETS never contains data that Concord doesn't.
- **Failed writes don't corrupt cache.** If Concord rejects a write (CAS failure, timeout, etc.), ETS is not updated. The error propagates to the caller.
- **Cache is special.** DNS resolver cache (`Store.Cache`) is the one namespace where ETS writes happen without going through Concord first. Cache is ephemeral by nature — losing it on restart is acceptable. It warms from Concord best-effort.

---

## Architecture

### Data Flow

```
Write path:
  Caller → Store facade → Concord.put (persist) → on :ok → ETS.insert (cache) → :ok to caller
  Caller → Store facade → Concord.put (persist) → on error → error to caller (ETS untouched)

Read path:
  Caller → Store facade → ETS.lookup → {:ok, value} | {:error, :not_found}

Delete path:
  Caller → Store facade → Concord.delete → on :ok → ETS.delete → :ok to caller

Prefix scan path:
  Caller → Store facade → Concord.Query.keys (source of truth) → results to caller

Startup:
  Concord ready → create ETS tables → warm from Concord snapshot → supervision continues
```

### Layers

```
┌─────────────────────────────────────────────────────────┐
│                  Store Facade Modules                    │
│  (Lease, Device, Zone, DynDns, Rpz, Host, Config)       │
├─────────────────────────────────────────────────────────┤
│                  Backend Orchestrator                    │
│  write-through: Concord first, ETS second               │
│  read-local: ETS only                                   │
│  scan: Concord only                                     │
├──────────────────────┬──────────────────────────────────┤
│   ETS Read Cache     │   Concord Persistence            │
│   (always present)   │   (always present)               │
│   per-namespace      │   single-node: no Raft           │
│   tables             │   cluster: full Raft             │
│   read_concurrency   │   TTL, CAS, indexes,            │
│                      │   event streaming                │
└──────────────────────┴──────────────────────────────────┘
```

### Where ModeDetector Fits

`ModeDetector` no longer selects a backend. It detects the node topology (single-node vs cluster) and configures Concord's internal mode accordingly. Both layers — ETS and Concord — are always active regardless of mode. The only difference is whether Concord uses Raft consensus (cluster) or direct local writes (single-node).

---

## Backend Orchestrator

The `Backend` module transforms from a behaviour with dynamic dispatch to a fixed orchestration module. It is no longer a behaviour — it is the single entry point that coordinates ETS and Concord.

### Operations

| Operation | Concord | ETS | Notes |
|-----------|---------|-----|-------|
| `put` | Write first | Update on success | Write-through |
| `put_if` (CAS) | Write first | Update on success | Re-read Concord for canonical value before caching |
| `get` | Never | Read only | Hot path — local memory only |
| `delete` | Delete first | Remove on success | Both layers |
| `prefix_scan` | Query | Never | Scans are not hot-path; Concord is source of truth |
| `put_many` | Batch write first | Batch update on success | Atomic at Concord layer |

### CAS Re-read

`put_if` is special. After a successful CAS write to Concord, the Backend re-reads the key from Concord (`:leader` consistency) before caching in ETS. This handles cases where a condition function transforms the value — the cached value must match what Concord actually stored, not what the caller originally passed.

### Error Propagation

All Concord errors propagate directly to the caller. ETS is a transparent cache layer — its operations do not produce errors that reach callers (ETS inserts/deletes are infallible for our use case).

---

## ETS Table Design

One ETS table per namespace. All tables created at startup before any data flows.

| Namespace | Table Name | Key Example |
|-----------|------------|-------------|
| DHCP leases | `:yd_store_leases` | `dhcp:lease:v4:aa:bb:cc:dd:ee:ff` |
| DHCP pools | `:yd_store_pools` | `dhcp:pool:192.168.1.0/24` |
| Devices | `:yd_store_devices` | `device:aa:bb:cc:dd:ee:ff` |
| DNS zones | `:yd_store_zones` | `dns:zone:home.local.` |
| DNS zone RRsets | `:yd_store_zone_rrs` | `dns:zone:home.local.:rr:www:a` |
| Dynamic DNS | `:yd_store_dyn_dns` | `dns:dyn:host1.home.local.` |
| RPZ rules | `:yd_store_rpz` | `rpz:blocklist:ads.example.com` |
| Host identity | `:yd_store_hosts` | `host:myserver` |
| Runtime config | `:yd_store_config` | `config:dns:upstream_servers` |
| DNS cache | `:yd_store_cache` | `dns:cache:google.com.:a` |

All tables: `:set`, `:public`, `read_concurrency: true`. Key routing is by prefix match — the Backend maps a key's prefix to the correct table name.

---

## Startup Warming

A dedicated `Warmer` process runs at startup. It reads all Concord keys per namespace prefix and populates the corresponding ETS tables. Warming completes before the rest of the supervision tree starts accepting traffic.

### Warming Order

1. ETS tables created (empty)
2. ModeDetector runs (configures Concord mode)
3. Warmer scans each namespace prefix from Concord, inserts into ETS
4. Warmer completes
5. EventBridge, DynDnsUpdater, ConfigWatcher start
6. Server apps begin accepting requests

### Excluded from Warming

DNS cache (`dns:cache:*`) is excluded from the Warmer. `Store.Cache` has its own warming via `CacheSyncer` which applies TTL filtering, LRU budget enforcement, and adaptive batching. The Warmer only handles persistent namespaces.

### TTL-Expired Keys

Keys that have expired in Concord (TTL elapsed) are not returned by Concord queries, so they naturally won't be warmed into ETS. No special filtering needed.

---

## DNS Cache Special Case

`Store.Cache` retains its existing two-tier design from the Concord Integration PRD. It does NOT follow the standard write-through pattern:

| Operation | Standard namespaces | DNS Cache |
|-----------|-------------------|-----------|
| Write | Concord first → ETS | ETS first (immediate) → Concord later (async batch) |
| Read | ETS only | Dedicated cache ETS only |
| Startup | Warmer populates ETS | CacheSyncer warms from Concord with TTL/LRU filtering |
| Eviction | None (persistent) | LRU when memory budget exceeded |
| Loss on crash | None (Concord has it) | Acceptable (warms from Concord best-effort) |

Rationale: DNS cache writes must never block the query path. A cache miss just means the resolver goes upstream — it's better to serve slightly stale or miss than to add Raft latency to every DNS resolution.

---

## Supervision Tree

```
yellow_dog_store (Application)
└── YellowDog.Store.Supervisor
    ├── ETS Table Initializer              # Creates all :yd_store_* tables
    ├── ModeDetector                       # Detects topology, configures Concord mode
    ├── Warmer                             # Scans Concord → populates ETS (blocks until done)
    ├── EventBridge                        # GenStage event dispatcher
    ├── DynDnsUpdater                      # GenStage consumer: lease events → DNS records
    └── ConfigWatcher                      # GenStage consumer: config events → service reload
```

The first three children run sequentially (each must complete before the next starts). The remaining children can start concurrently after warming is done.

---

## Facade Module Changes

All existing facade modules (`Store.Lease`, `Store.Zone`, `Store.Device`, etc.) currently call `Backend.active().operation(...)`. This changes to `Backend.operation(...)` — direct calls to the orchestrator, no dynamic dispatch.

This is a mechanical replacement with no behavioral change at the facade level. All facade-level validation, key encoding, telemetry, and CAS logic remain unchanged.

---

## Event Bridge Interaction

`EventBridge` subscribes to Concord's GenStage CDC stream — this is unchanged. Events fire based on Concord writes, not ETS updates. Since every write goes through Concord first, the event ordering guarantee is preserved.

On other nodes in a cluster, Raft replication causes Concord to update, which triggers CDC events, which EventBridge dispatches to consumers. Those consumers may then read from local ETS (which was also updated by the replication). The ETS update on follower nodes comes from Concord's internal ETS (which Ra manages), not from the Store Backend's ETS cache. The Store Backend's ETS on follower nodes is warmed at startup and then updated by local EventBridge consumers that re-read and re-cache on relevant events.

### Follower Node ETS Consistency

When a write happens on the leader:
1. Leader: Concord.put → Backend ETS updated → CDC event fires
2. Follower: Raft replicates → Concord state updated → CDC event fires
3. Follower EventBridge consumer receives event → reads from Concord → updates local Backend ETS

This means follower Backend ETS may lag behind the leader by the Raft replication delay plus event processing time. This is acceptable — the same staleness tolerance already exists in the Concord Integration PRD's consistency model.

---

## Telemetry

Existing Store telemetry events remain unchanged:

```
[:yellow_dog, :store, :operation, :start | :stop | :exception]
```

New measurements added to `:stop` metadata:

| Field | Description |
|-------|-------------|
| `concord_duration` | Time spent in Concord operation (write path only) |
| `ets_hit` | Boolean — whether ETS lookup succeeded (read path only) |

This allows monitoring the write-through overhead and cache effectiveness per namespace.

---

## Testing Requirements

### Unit Tests

- Write-through: Backend.put succeeds → value exists in both Concord and ETS
- Write-through: Backend.put fails at Concord → ETS unchanged
- Read-local: Backend.get returns from ETS only, Concord not called
- CAS write-through: Backend.put_if succeeds → ETS has canonical value from Concord
- CAS failure: Backend.put_if fails → ETS unchanged
- Delete: Backend.delete removes from both layers
- Prefix scan: Backend.prefix_scan queries Concord, not ETS

### Warming Tests

- Insert data into Concord, run Warmer, verify all namespace ETS tables populated
- Expired TTL keys in Concord not present in ETS after warming
- DNS cache prefix excluded from Warmer

### Integration Tests

- Full lifecycle: put → get → update → delete across both layers
- Concurrent CAS: multiple callers race on same key, ETS always matches Concord
- Restart simulation: populate data, clear ETS, run Warmer, verify consistency

### Property-Based Tests

- For any sequence of put/put_if/delete operations, ETS state always matches Concord state (excluding DNS cache namespace)

---

## Acceptance Criteria

- [ ] `Backend.put` persists to Concord first, then updates ETS
- [ ] `Backend.get` reads from ETS only — never touches Concord on the read path
- [ ] `Backend.put_if` persists CAS to Concord first, re-reads canonical value, caches in ETS
- [ ] `Backend.delete` removes from Concord first, then ETS
- [ ] `Backend.prefix_scan` queries Concord (source of truth)
- [ ] Failed Concord writes do not update ETS
- [ ] Per-namespace ETS tables with `read_concurrency: true`
- [ ] Warmer populates all persistent namespace ETS tables from Concord before app accepts traffic
- [ ] DNS cache retains async ETS-first write pattern (not write-through)
- [ ] ModeDetector configures Concord mode only — does not select backend
- [ ] No facade module uses `Backend.active()` — all call Backend directly
- [ ] Follower nodes update Backend ETS via EventBridge consumers on Raft replication
- [ ] Store telemetry includes `concord_duration` and `ets_hit` measurements
- [ ] All existing facade-level tests pass without modification
- [ ] Property: ETS state matches Concord state after any operation sequence

---

## Design Decisions

1. **Write-through over write-behind.** Write-behind (async ETS→Concord) risks data loss on crash and creates consistency windows. Write-through is simpler, correct, and the Concord write latency (microseconds for single-node, low milliseconds for Raft) is acceptable for all Store operations. DNS cache is the sole exception.

2. **Per-namespace ETS tables over a single table.** Namespace isolation prevents one high-volume namespace (e.g., DNS cache eviction) from impacting another (e.g., DHCP lease lookups). Also enables per-namespace monitoring and future per-namespace tuning (e.g., different `read_concurrency`/`write_concurrency` settings).

3. **Prefix-based key routing to tables.** Simple prefix match maps keys to tables. No secondary dispatch needed. The Key module already enforces structured prefixes, so routing is deterministic.

4. **CAS re-read before caching.** When `put_if` uses a condition function, the stored value may differ from what the caller passed (the condition evaluates server-side in Concord). Re-reading ensures ETS has the actual stored value. The extra Concord read is `:leader` consistency and only happens on CAS success — acceptable overhead for correctness.

5. **Warmer as blocking Task.** Warming must complete before traffic arrives. A transient Task in the supervision tree blocks startup naturally. If warming fails, the app crashes and restarts — correct behavior since serving without cache would mean every read misses.

6. **Follower ETS via EventBridge, not Raft hooks.** Rather than hooking into Ra's internal replication to update ETS, follower nodes use the existing EventBridge/GenStage infrastructure. This reuses existing code, respects backpressure, and keeps the Raft layer clean. The trade-off is slightly more lag on followers, which is already tolerated by the consistency model.

---

*Version: 1.0.0*  
*Depends on: Concord ~> 0.1.0, YellowDog.Store Concord Integration PRD v2.0.0*