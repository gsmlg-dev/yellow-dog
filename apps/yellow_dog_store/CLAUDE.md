# CLAUDE.md — yellow_dog_store

This file provides guidance to Claude Code when working in `apps/yellow_dog_store/`.

## Product Context

YellowDog ships as **two applications** from the same umbrella, built as separate Mix releases:

- **yellow-dog server** — DNS, DHCP, mDNS, netboot, identity, fingerprinting, web console. This is where `yellow_dog_store` lives.
- **yellow-dog netman** — NetworkManager replacement (netman, dhcp_client, resolved). Does NOT depend on Store or Concord.

`yellow_dog_store` is **server-side only**. Netman apps never import it.

## Purpose

`yellow_dog_store` is the unified service data backend for all server-side apps. It wraps Concord (Raft-based embedded KV store) behind domain-typed facade modules. No server app may call `Concord.*` directly — all access goes through `YellowDog.Store.*`.

## Data Flow Architecture

**Concord is the source of truth for all persistent data. ETS is the runtime read cache.**

```
Write path:  Caller → Store.Facade → Concord.put/put_if → on success → ETS insert → :ok
Read path:   Caller → Store.Facade → ETS lookup → {:ok, value} | {:error, :not_found}
Startup:     Concord snapshot → warm all ETS tables per namespace → ready to serve
```

This applies to ALL namespaces (leases, zones, devices, RPZ, hosts, config). The DNS resolver cache (`Store.Cache`) adds LRU eviction and adaptive flush batching on top of this same pattern, but the underlying write-through/read-local model is universal.

### What this means concretely

- `Backend.Ets` is NOT an alternative to `Backend.Cluster` — it is the always-present local read layer
- `Backend.Cluster` is NOT an alternative to `Backend.Ets` — it is the always-present persistence layer
- The old `ModeDetector` choosing one-or-the-other is WRONG — both layers are always active
- `ModeDetector` still exists but only controls whether Concord uses Raft consensus (multi-node) or direct local writes (single-node). ETS read cache is present regardless.
- Single-node mode does NOT mean "ETS only" — it means "Concord without Raft overhead" + ETS cache

### Write-through guarantee

Every successful `Concord.put` MUST be followed by an ETS insert of the same key/value before returning to the caller. If Concord write fails, ETS is not updated and the error propagates. This ensures ETS never contains data that Concord doesn't have.

### Startup warming

On application start, each namespace warms its ETS table by scanning all Concord keys with its prefix. This happens BEFORE the app signals readiness. Order: Concord starts → ETS tables created → warming scans → supervision tree continues.

## Module Layout

```
lib/yellow_dog/store.ex                    # Top-level facade, delegates to sub-modules
lib/yellow_dog/store/
├── backend.ex                             # Behaviour + write-through orchestration
├── backend/
│   ├── ets.ex                             # ETS read/write operations (local cache)
│   └── cluster.ex                         # Concord operations (persistence)
├── mode_detector.ex                       # Detects single-node vs cluster; configures Concord mode
├── key.ex                                 # Structured key encoding/decoding
├── warmer.ex                              # Startup ETS warming from Concord
├── lease.ex                               # DHCP lease state machine (v4 + v6)
├── device.ex                              # Device fingerprint registry
├── zone.ex                                # Authoritative DNS zone data + RRsets
├── cache.ex                               # DNS resolver cache (ETS hot path + Concord backing)
├── dyn_dns.ex                             # Dynamic DNS records
├── rpz.ex                                 # Response policy zones
├── host.ex                                # Host identity registry
├── config.ex                              # Runtime configuration overrides
├── backup.ex                              # Backup/restore operations
├── cli.ex                                 # Release CLI dispatcher
├── event_bridge.ex                        # GenStage event stream dispatcher
├── dyn_dns_updater.ex                     # GenStage consumer: lease → DNS records
└── config_watcher.ex                      # GenStage consumer: config → service reload
```

## Key Concord API Surface

These are the Concord functions the Backend.Cluster module wraps:

```elixir
# Core CRUD
Concord.put(key, value, opts)              # opts: :ttl, :compress
Concord.get(key, opts)                     # opts: :consistency (:eventual | :leader | :strong)
Concord.delete(key, opts)
Concord.put_many([{key, value} | {key, value, ttl}], opts)
Concord.get_many([keys], opts)

# Conditional (CAS)
Concord.put_if(key, value, expected: current_value)
Concord.put_if(key, value, condition: fn current -> ... end)
Concord.delete_if(key, expected: current_value)

# TTL
Concord.put(key, value, ttl: seconds)
Concord.touch(key, additional_ttl, opts)
Concord.ttl(key, opts)

# Query
Concord.Query.keys(prefix: "dhcp:lease:v4:")
Concord.Query.keys(range: {"a", "z"})
Concord.Query.where(prefix: "device:", filter: fn {_k, v} -> ... end)
Concord.Query.count(prefix: "rpz:")

# Secondary Indexes — ALWAYS use declarative specs, NEVER anonymous functions
Concord.Index.create("leases_by_ip", {:map_get, :ip})
Concord.Index.lookup("leases_by_ip", {192, 168, 1, 100})

# Event Streaming (GenStage CDC)
# Used by EventBridge — see Concord observability docs
```

### Critical Concord constraints

- **No anonymous functions in index extractors** — they break across code versions/nodes. Use `{:map_get, key}`, `{:nested, path}`, `{:identity}`, `{:element, n}` only.
- **Batch max 500 items** for `put_many`/`get_many`.
- **`:consistency` option is for reads only** — writes always go through Raft (or direct ETS in single-node mode).
- **TTL uses leader-assigned timestamps** — be aware of clock drift in `Query` TTL filtering.

## Key Schema

All keys are UTF-8 strings with `:` separator. Facade modules handle encoding from typed args to string keys. See `Store.Key` for the canonical encoder.

| Prefix | Namespace | Example |
|--------|-----------|---------|
| `dhcp:lease:v4:` | DHCPv4 leases | `dhcp:lease:v4:aa:bb:cc:dd:ee:ff` |
| `dhcp:lease:v6:` | DHCPv6 leases | `dhcp:lease:v6:00:01:00:01:2a:3b:...` |
| `dhcp:pool:` | Address pools | `dhcp:pool:192.168.1.0/24` |
| `device:` | Device fingerprints | `device:aa:bb:cc:dd:ee:ff` |
| `dns:dyn:` | Dynamic DNS records | `dns:dyn:host1.home.local.` |
| `dns:dyn:ptr:` | Reverse DNS | `dns:dyn:ptr:100.1.168.192.in-addr.arpa` |
| `dns:zone:` | Zone metadata | `dns:zone:home.local.` |
| `dns:zone:*:rr:` | Zone RRsets | `dns:zone:home.local.:rr:www:a` |
| `dns:cache:` | Resolver cache | `dns:cache:google.com.:a` |
| `rpz:` | RPZ rules | `rpz:blocklist:ads.example.com` |
| `host:` | Host identity | `host:myserver` |
| `config:` | Runtime config | `config:dns:upstream_servers` |
| `event_log:` | Durable event log | `event_log:1711500000000:dhcp:lease:v4:...` |

## Dependencies

- `yellow_dog_config` — boot-time TOML defaults
- `yellow_dog_telemetry` — span/event emission
- `concord` — persistence backend
- `gen_stage` — event streaming
- `stream_data` — property tests (test only)

## Testing

```bash
# Run store tests
cd apps/yellow_dog_store && mix test

# Property tests (MAC normalization, key encoding, lease FSM)
mix test test/yellow_dog/store/property_test.exs
```

All tests use `Backend.Ets` + Concord in single-node mode. No external infra needed.

## Constitution Constraints

- **No server app calls `Concord.*` directly** — always through `YellowDog.Store.*`
- **Netman apps never depend on `yellow_dog_store`** — netman is a separate product with its own persistence (TOML lease files via `LeaseStore`)
- **ETS is read cache, Concord is source of truth** — never persist in ETS alone
- **Zone files are import/export format only** — Concord (via Store.Zone) is authoritative
- **No AXFR/IXFR** — zone replication is Raft-only
- **GenStage for all cross-domain events** — no direct function calls between namespaces
- **Telemetry on every Store operation** — `[:yellow_dog, :store, :operation, :start | :stop | :exception]`

## Common Gotchas

- `Concord.get` returns `{:error, :not_found}` for missing AND expired keys — don't distinguish
- `put_if` with `expected: nil` means "key must not exist" — use for create-if-absent semantics
- MAC normalization: lowercase colon-separated (`aa:bb:cc:dd:ee:ff`) — `Store.Key` handles this
- DUID normalization: lowercase colon-separated hex — same pattern
- ETS table names follow namespace: `:yellow_dog_store_leases`, `:yellow_dog_store_zones`, etc.
- Backup/restore is Concord-level (all namespaces). Restore requires `:confirm` safety latch.