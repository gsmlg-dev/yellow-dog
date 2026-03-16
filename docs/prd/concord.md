# YellowDog.Store — Concord Integration PRD

## Overview

Concord serves as YellowDog's unified service data backend — an embedded, strongly-consistent key-value store using Raft consensus. It provides a single substrate for all service state: consistency guarantees, TTL-based expiration, compare-and-swap semantics, event streaming, and multi-node replication.

**Module:** `YellowDog.Store`  
**Dependency:** `{:concord, "~> 0.1.0"}` in `apps/yellow_dog/mix.exs`  
**Concord starts embedded** within the `yellow_dog` core application.

---

## Design Principles

- **Facade over Concord** — Child apps never call `Concord.*` directly. `YellowDog.Store` provides domain-typed functions with validation, telemetry, and schema enforcement. Insulates the umbrella from Concord internals and allows backend substitution.
- **Event-driven cross-app integration** — DHCP writes leases; DNS subscribes to lease events for dynamic record creation. No direct cross-app function calls for state propagation.
- **Consistency per operation** — Each function declares its consistency requirement. Writes use `:strong`. Frequent reads use `:eventual` or `:leader` depending on staleness tolerance.
- **TOML for defaults, Concord for runtime** — TOML configuration files provide boot-time defaults. Runtime overrides live in Concord and take precedence. Config changes propagate via event stream.

---

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                    yellow_dog (core app)                       │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │              Concord.Application (embedded)             │  │
│  │              Raft · ETS reads · Snapshotting             │  │
│  └─────────────────────────────────────────────────────────┘  │
│                            ▲                                  │
│  ┌─────────────────────────┴───────────────────────────────┐  │
│  │                   YellowDog.Store                        │  │
│  │                   (facade module)                        │  │
│  │                                                         │  │
│  │  .Lease      — DHCP lease lifecycle                     │  │
│  │  .Device     — device fingerprint registry              │  │
│  │  .Zone       — authoritative DNS zone data              │  │
│  │  .Cache      — DNS resolver cache (ETS + Concord)       │  │
│  │  .DynDns     — dynamic DNS records                      │  │
│  │  .Rpz        — response policy zones                    │  │
│  │  .Host       — host identity registry                   │  │
│  │  .Config     — runtime configuration                    │  │
│  │  .Backup     — backup and restore                       │  │
│  │  .EventBridge — event stream dispatcher                 │  │
│  └─────────────────────────────────────────────────────────┘  │
└────────────────────────────┬──────────────────────────────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
  yellow_dog_dhcp    yellow_dog_dns    yellow_dog_console
  (writes leases,    (reads zones,     (reads/writes all,
   devices)           dyn DNS, cache;   subscribes to
                      subscribes to     all events)
                      lease + rpz +
                      zone events)
```

### Event Stream Topology

```
Producer                    Event Key Pattern        Consumers
─────────────────────────────────────────────────────────────────
yellow_dog_dhcp       →     dhcp:lease:*        →   DynDnsUpdater (core app)
                                                     Console dashboard

yellow_dog_console    →     rpz:*               →   RpzReloader (DNS app)
                            config:*            →   ConfigWatcher (all apps)
                            dns:zone:*          →   ZoneReloader (DNS app)

yellow_dog_dns        →     dns:dyn:*           →   CacheInvalidator (DNS app)
                                                     Console dashboard
```

---

## Key Schema

All keys are UTF-8 strings. Hierarchical with `:` separator. Values are Elixir terms (maps).

**Key encoding convention:** Keys use structured tuples serialized to a canonical string form. The facade modules handle serialization — callers pass typed arguments (atoms, tuples, strings), the facade produces the string key. This provides type safety at the facade boundary while keeping Concord keys as plain strings for HTTP API compatibility.

### `dhcp:lease:v4:{mac_normalized}` / `dhcp:lease:v6:{duid}`

DHCP lease state. Separate key prefixes for DHCPv4 (keyed by MAC) and DHCPv6 (keyed by DUID). This avoids conflating two different identifier spaces and allows protocol-specific queries.

DHCPv4 example: `dhcp:lease:v4:aa:bb:cc:dd:ee:ff`
DHCPv6 example: `dhcp:lease:v6:00:01:00:01:2a:3b:...`

| Field | Type | Description |
|-------|------|-------------|
| `ip` | ip tuple | Assigned IP address |
| `hostname` | string \| nil | Client-provided hostname |
| `state` | atom | `:offered \| :bound \| :renewing \| :rebinding \| :released \| :declined` |
| `xid` | integer | Transaction ID from DHCP exchange |
| `lease_start` | integer | Unix timestamp |
| `lease_duration` | integer | Seconds |
| `server_id` | ip tuple | DHCP server IP |
| `subnet` | string | CIDR notation, e.g. `"192.168.1.0/24"` |
| `options` | map | DHCP options sent to client |
| `interface` | string | Server network interface |
| `renewed_at` | integer \| nil | Last renewal timestamp |
| `version` | integer | CAS version counter |

- **TTL:** `lease_duration` — auto-expires when lease elapses.
- **CAS:** State transitions require `put_if` with expected previous state.
- **Index:** `ip` field — enables reverse lookup (IP → lease).
- **Consistency:** `:strong` for writes, `:leader` for reads.

### `dhcp:pool:{subnet}`

DHCP address pool configuration.

| Field | Type | Description |
|-------|------|-------------|
| `range_start` | ip tuple | First assignable IP |
| `range_end` | ip tuple | Last assignable IP |
| `gateway` | ip tuple | Default gateway |
| `dns_servers` | list of ip tuples | DNS servers to advertise |
| `domain` | string | Search domain |
| `default_lease` | integer | Default lease duration (seconds) |
| `max_lease` | integer | Maximum lease duration (seconds) |
| `reservations` | map | MAC → IP static reservations |
| `interface` | string | Bound network interface |

- **TTL:** None (persistent).
- **Consistency:** `:strong`.

### `device:{mac_normalized}`

Unified cross-protocol device fingerprint. Updated from DHCPv4, DHCPv6, and mDNS handlers.

| Field | Type | Description |
|-------|------|-------------|
| `vendor_class` | string \| nil | DHCP option 60 value |
| `hostname` | string \| nil | Client hostname |
| `dhcpv4_fingerprint` | string \| nil | Ordered DHCP option list |
| `dhcpv6_fingerprint` | binary \| nil | DHCPv6 fingerprint |
| `dhcpv4_options` | map | Raw DHCP options observed |
| `mdns_services` | list of strings | Advertised mDNS service types |
| `vendor_id` | string \| nil | Resolved vendor identifier |
| `os_guess` | string \| nil | OS identification guess |
| `first_seen` | integer | Unix timestamp |
| `last_seen` | integer | Unix timestamp |
| `interfaces_seen` | list of strings | Network interfaces observed on |

- **TTL:** None (persistent).
- **CAS:** On `last_seen` to prevent stale overwrites from out-of-order updates.
- **Index:** `vendor_class` — query all devices from a vendor.
- **Consistency:** `:leader` for writes, `:eventual` for reads.

### `dns:dyn:{fqdn}`

Dynamic DNS entries created by DHCP lease events or API calls. Separate from static zone data (which stays in zone files).

| Field | Type | Description |
|-------|------|-------------|
| `type` | atom | `:a \| :aaaa \| :ptr \| :cname` |
| `rdata` | ip tuple \| string | Record data (parsed, not wire format) |
| `dns_ttl` | integer | DNS TTL in seconds |
| `source` | atom | `:dhcp \| :api \| :mdns` |
| `source_ref` | string | Key of originating record (e.g. lease key) |
| `created_at` | integer | Unix timestamp |
| `updated_at` | integer | Unix timestamp |

- **TTL:** Tied to DHCP lease duration when source is `:dhcp`. None when source is `:api`.
- **Consistency:** `:strong` for writes, `:eventual` for reads.
- **Event:** Changes trigger cache invalidation in DNS workers.

### `dns:dyn:ptr:{reverse_arpa}`

Reverse DNS entries, created alongside forward entries by DynDnsUpdater. Same schema as `dns:dyn:*` but keyed by reverse ARPA name (e.g. `100.1.168.192.in-addr.arpa`). TTL mirrors the forward entry.

### `dns:zone:{zone_name}`

Zone metadata. One key per authoritative zone. Concord is the source of truth — zone files are an import/export format only, not the primary storage.

| Field | Type | Description |
|-------|------|-------------|
| `origin` | string | Zone origin (e.g. `"home.local."`) |
| `soa` | map | SOA record fields: `mname`, `rname`, `serial`, `refresh`, `retry`, `expire`, `minimum` |
| `default_ttl` | integer | Default TTL for records in this zone |
| `authoritative` | boolean | Whether this node serves authoritative answers |
| `allow_dynamic_update` | boolean | Accept RFC 2136 dynamic updates |
| `created_at` | integer | Unix timestamp |
| `updated_at` | integer | Unix timestamp |
| `serial_strategy` | atom | `:date_serial \| :increment` — how SOA serial advances |

- **TTL:** None (persistent).
- **Consistency:** `:strong` — zone metadata must be uniform across all nodes.
- **Replication:** Raft-only. All authoritative nodes must be members of the Raft cluster. No AXFR/IXFR support for external secondaries.
- **Event:** Changes trigger zone reload in DNS workers.

### `dns:zone:{zone_name}:rr:{owner}:{type}`

Individual resource records within a zone. One key per (owner, type) tuple, holding an RRset (list of records of that type for that name).

| Field | Type | Description |
|-------|------|-------------|
| `rrset` | list of maps | List of records, each with `rdata`, `ttl` (optional override) |
| `owner` | string | Owner name relative to zone origin (e.g. `"www"`, `"@"` for apex) |
| `type` | atom | `:a \| :aaaa \| :ns \| :mx \| :cname \| :txt \| :srv \| :ptr \| :soa` |
| `zone` | string | Parent zone name (denormalized for query convenience) |
| `class` | atom | `:in` (always IN for practical purposes) |
| `source` | atom | `:import \| :api \| :console \| :dynamic_update` |
| `updated_at` | integer | Unix timestamp |

- **TTL:** None (persistent — records live until explicitly deleted or zone is removed).
- **CAS:** Prevents concurrent edits to same RRset (Console edit vs dynamic update race).
- **Consistency:** `:strong` for writes, `:eventual` for reads (DNS workers maintain a local ETS snapshot).
- **Index:** `zone` field — list all records in a zone. `type` field — find all records of a type.
- **Event:** Changes trigger incremental zone reload and SOA serial increment.

**Key design note:** The key encodes `{owner}:{type}` rather than individual records. This means an A record with three addresses is a single Concord key holding an RRset of three entries. This matches DNS semantics (RRsets are the unit of operation) and avoids key explosion.

**Zone file relationship:** Zone files are import/export only — `Store.Zone.import/2` parses a zone file and writes individual RR keys to Concord. `Store.Zone.export/1` reads all RR keys for a zone and renders a zone file. No zone files are read at runtime.

### `dns:cache:{qname}:{qtype}`

DNS resolver cache. **Two-tier architecture:**

- **Tier 1 (hot path):** Per-node local ETS table. All cache reads and writes hit ETS first. No Raft overhead. This is where the DNS resolver looks during query processing.
- **Tier 2 (warm backing):** Concord store. Populated asynchronously from ETS. Provides cache warming on node startup and optional cache sharing across nodes.

| Field | Type | Description |
|-------|------|-------------|
| `rrset` | list of maps | Cached response records |
| `qname` | string | Query name |
| `qtype` | atom | Query type |
| `rcode` | atom | Response code (`:noerror \| :nxdomain \| :servfail`) |
| `upstream` | string | Upstream resolver that provided the answer |
| `fetched_at` | integer | Unix timestamp when originally resolved |
| `original_ttl` | integer | TTL from the upstream response |
| `negative` | boolean | Whether this is a negative cache entry (NXDOMAIN/NODATA) |

- **TTL:** Set to the DNS record's TTL. Auto-expires in both ETS and Concord.
- **Consistency:** `:eventual` — cache is best-effort, staleness is acceptable.
- **Writes to Concord:** Asynchronous, fire-and-forget. Cache writes must never block the DNS query path.
- **Reads from Concord:** Only on node startup (cache warming) or explicit cache share request. Never on the hot query path.
- **Eviction:** Max memory budget with LRU eviction. Configurable memory cap (e.g. 64MB default). When ETS table exceeds budget, evict least-recently-used entries until under threshold. TTL expiration still applies independently.

**ETS → Concord sync strategy:**

- **Write-behind:** ETS is written immediately on upstream response. A periodic process flushes recent ETS entries to Concord.
- **Adaptive batching:** Flush batch size adjusts based on observed Raft latency. Starts with a baseline batch size, increases when Raft is responsive, decreases (smaller batches, longer intervals) when latency rises. This prevents cache sync from degrading Raft performance under load.
- **Startup warming:** On DNS worker startup, read all `dns:cache:*` from Concord (`:eventual` consistency) and populate local ETS. Stale entries are harmless — they'll be refreshed on next query or expire via TTL.
- **No read-through:** A cache miss in ETS does not trigger a Concord read. The resolver goes to upstream instead. This keeps the hot path ETS-only.

### `rpz:{zone_name}:{domain_trigger}`

Response Policy Zone rules.

| Field | Type | Description |
|-------|------|-------------|
| `action` | atom | `:nxdomain \| :nodata \| :passthru \| :redirect \| :local_data` |
| `redirect_to` | ip tuple \| nil | Redirect target |
| `local_data` | binary \| nil | Synthesized response data |
| `reason` | string | Human-readable reason |
| `created_by` | string | Creator identity |
| `created_at` | integer | Unix timestamp |
| `enabled` | boolean | Active/inactive toggle |

- **TTL:** None (persistent).
- **Consistency:** `:strong` — policy must be uniform across nodes.
- **Event:** Changes trigger hot-reload in DNS workers.

### `host:{hostname}`

Host identity registry for SSH key management with pluggable trust.

| Field | Type | Description |
|-------|------|-------------|
| `ssh_pubkeys` | list of strings | Authorized public keys |
| `trust_method` | atom | `:dhcp_correlation \| :cloud_attestation \| :provisioning_token` |
| `trust_metadata` | map | Method-specific attestation data |
| `attested_at` | integer | Unix timestamp |
| `mac` | string \| nil | If trust via DHCP correlation |
| `ip` | ip tuple \| nil | Last known IP |
| `roles` | list of atoms | Assigned roles |
| `registered_at` | integer | Unix timestamp |

- **TTL:** Attestation validity window for token-based trust. None for DHCP-correlated.
- **CAS:** Prevent hostname squatting races.
- **Consistency:** `:strong` for registration, `:eventual` for lookups.

### `config:{service}:{key}`

Runtime configuration overrides. Supplements TOML boot defaults.

- **Value:** Any Elixir term.
- **TTL:** None.
- **Consistency:** `:leader` for reads, `:strong` for writes.
- **Event:** Changes notify affected services via ConfigWatcher.

### `event_log:{timestamp}:{key}`

Durable event log. Every state change in Concord is appended here for consumer replay on restart.

| Field | Type | Description |
|-------|------|-------------|
| `type` | atom | `:put \| :delete` |
| `key` | string | The Concord key that changed |
| `value` | term \| nil | New value (nil for deletes) |
| `timestamp` | integer | Microsecond timestamp |
| `node` | atom | Node that originated the write |

- **TTL:** Configurable retention window (default 24h). Old entries auto-expire.
- **Consistency:** `:eventual` — log is append-only, ordering within a node is guaranteed by timestamp.
- **Not queried on hot path.** Only read during consumer startup replay via `EventBridge.replay/2`.

---

## Facade API Surface

`YellowDog.Store` is the top-level module delegating to sub-modules. Each sub-module owns its key namespace.

### Store.Lease

All functions take a `protocol` parameter (`:v4` or `:v6`) and the appropriate client identifier (MAC for v4, DUID for v6). The facade routes to the correct key prefix.

| Function | Description | Notes |
|----------|-------------|-------|
| `offer(protocol, client_id, ip, opts)` | Create lease in `:offered` state | CAS `put_if expected: nil`; re-offer over stale offers allowed |
| `bind(protocol, client_id, xid)` | Transition `:offered → :bound` | CAS on state + xid match; retry on race |
| `renew(protocol, client_id, duration)` | Transition `:bound \| :renewing → :renewing` | Updates TTL |
| `release(protocol, client_id)` | Mark `:released`, short TTL for cleanup | Does not delete immediately |
| `decline(protocol, client_id)` | Mark `:declined` | IP flagged for avoidance |
| `get(protocol, client_id)` | Lookup by client identifier | `:leader` consistency |
| `by_ip(ip)` | Reverse lookup across both v4 and v6 | Uses Concord secondary index on `ip`, falls back to local ETS index |
| `list_by_subnet(subnet)` | All leases in a subnet | Prefix scan + filter |
| `list_by_protocol(protocol)` | All leases for v4 or v6 | Prefix scan on `dhcp:lease:v4:*` or `dhcp:lease:v6:*` |

MAC addresses (v4) normalized to lowercase colon-separated. DUIDs (v6) normalized to lowercase colon-separated hex.

**Query strategy:** `by_ip/1` and `list_by_subnet/1` first attempt Concord secondary indexes. If Concord's Query module does not support the needed index type, the facade maintains a local ETS index as fallback. This dual strategy applies to all cross-key lookups throughout the Store.

### Store.Device

| Function | Description |
|----------|-------------|
| `upsert(mac, attrs)` | Merge fingerprint data; CAS on `last_seen` |
| `get(mac)` | Lookup by MAC |
| `by_vendor(vendor_class)` | Query via secondary index |
| `list_recent(since_timestamp)` | Devices seen since timestamp |

### Store.DynDns

| Function | Description |
|----------|-------------|
| `put(fqdn, record, opts)` | Create/update dynamic DNS record; optional TTL |
| `put_ptr(arpa, fqdn, opts)` | Create reverse PTR record |
| `get(fqdn)` | Lookup forward record |
| `get_ptr(arpa)` | Lookup reverse record |
| `delete(fqdn)` | Remove forward + associated reverse |
| `list_by_source(source)` | All records from `:dhcp`, `:api`, or `:mdns` |

### Store.Zone

| Function | Description |
|----------|-------------|
| `create_zone(name, soa, opts)` | Create zone metadata; fails if zone exists |
| `delete_zone(name)` | Remove zone and all its resource records |
| `get_zone(name)` | Get zone metadata |
| `list_zones()` | All zone names |
| `put_rrset(zone, owner, type, rrset)` | Create/update RRset; CAS prevents concurrent edit races; auto-increments SOA serial |
| `get_rrset(zone, owner, type)` | Lookup specific RRset |
| `delete_rrset(zone, owner, type)` | Remove RRset; auto-increments SOA serial |
| `list_records(zone)` | All RRsets in a zone (prefix scan) |
| `list_records(zone, owner)` | All RRsets for a specific owner name |
| `import(name, zone_file_content)` | Parse zone file text, write all records to Concord. Replaces existing zone data. |
| `export(name)` | Read all records, render as zone file text |
| `increment_serial(name)` | Manually bump SOA serial |

**Import/export notes:** `import/2` is the mechanism for loading zone files — it parses the text, creates the zone metadata key, and writes individual RR keys. `export/1` is the reverse. Neither reads zone files from disk at runtime. Import is idempotent — re-importing the same zone file results in the same Concord state.

### Store.Cache

| Function | Description |
|----------|-------------|
| `lookup(qname, qtype)` | Read from local ETS only (hot path, never Concord) |
| `store(qname, qtype, response)` | Write to local ETS; triggers LRU eviction if over memory budget; async flush to Concord |
| `invalidate(qname, qtype)` | Remove from local ETS and Concord |
| `invalidate_all()` | Flush entire local ETS cache; optionally clear Concord cache keys |
| `warm_from_store()` | Load all `dns:cache:*` from Concord into local ETS (startup) |
| `flush_to_store()` | Adaptive batch write recent ETS entries to Concord (periodic). Batch size adjusts based on observed Raft latency. |
| `stats()` | Cache hit/miss counts, size, memory usage, eviction stats, flush latency |
| `configure(opts)` | Update runtime cache settings: `:max_memory_bytes`, `:flush_interval_ms` |

**Critical constraint:** `lookup/2` and `store/3` never touch Concord on the query path. Only `warm_from_store/0` and `flush_to_store/0` interact with Concord, and both run outside the query processing flow.

### Store.Rpz

| Function | Description |
|----------|-------------|
| `put(zone, trigger, rule)` | Create/update RPZ rule |
| `get(zone, trigger)` | Lookup specific rule |
| `list(zone)` | All rules in a zone (prefix scan) |
| `delete(zone, trigger)` | Remove rule |
| `zones()` | List all zone names |

### Store.Host

| Function | Description |
|----------|-------------|
| `register(hostname, attrs)` | Register host identity; CAS prevents squatting |
| `update_keys(hostname, pubkeys)` | Update SSH keys for existing host |
| `get(hostname)` | Lookup host record |
| `by_mac(mac)` | Find host correlated to MAC |
| `attest(hostname)` | Refresh attestation timestamp; reset TTL |

### Store.Config

| Function | Description |
|----------|-------------|
| `get(service, key, default)` | Read config value; falls back to default |
| `put(service, key, value)` | Write config value; emits event |
| `list(service)` | All config keys for a service |
| `delete(service, key)` | Remove override; TOML default resumes |

### Store.Backup

| Function | Description |
|----------|-------------|
| `create(opts)` | Create compressed backup with integrity checksum. Returns `{:ok, path}`. Options: `:dir` (output directory), `:label` (human-readable label embedded in backup metadata). |
| `restore(path, opts)` | Restore from backup file. Options: `:verify_only` (validate without applying), `:confirm` (required `true` to proceed — safety latch). Returns `{:ok, stats}` or `{:error, reason}`. |
| `list(opts)` | List available backups in directory. Returns metadata: path, timestamp, size, label, checksum. Options: `:dir`. |
| `verify(path)` | Verify backup integrity without restoring. Returns `{:ok, stats}` or `{:error, reason}`. |
| `delete(path)` | Remove a backup file. |

**Backup contents:** Full Concord state snapshot — all namespaces (leases, zones, devices, RPZ rules, config, etc.). Compressed with integrity checksum for verification before restore.

**Restore behavior:** Restore overwrites all current Concord state. This is a destructive operation — the `:confirm` option is a required safety latch. On a multi-node cluster, restore should be performed on the leader node; Raft replicates the restored state to followers.

**CLI access:** Release CLI commands via `YellowDog.CLI` module. See CLI Commands section below.

**Console access:** Console UI provides backup/restore through a settings page. See Console Integration section below.

### Store.EventBridge

| Function | Description |
|----------|-------------|
| `subscribe(pattern, handler_fn)` | Register callback for key pattern |
| `subscribe(pattern)` | Return GenStage consumer spec for caller to manage |
| `replay(pattern, since_timestamp)` | Replay durable events from Concord event log since timestamp |

**Event durability:** Events are persisted to a durable log in Concord (`event_log:{timestamp}:{key}`). Consumers that crash or fall behind can replay missed events from the log on restart. The log is TTL-bounded (configurable retention, e.g. 24h) to prevent unbounded growth. GenStage backpressure still applies for real-time flow control, but durability ensures no events are permanently lost within the retention window.

---

## Cross-Domain Processes

### DynDnsUpdater

GenStage consumer subscribed to `dhcp:lease:*` events. Responsibilities:

- **Lease bound** → Create forward (A/AAAA) + reverse (PTR) DNS records. FQDN constructed from `hostname` + configured domain for the subnet. TTL tied to lease duration.
- **Lease renewed** → Update DNS record TTL to new lease duration.
- **Lease expired** → No action needed — DNS records auto-expire via their own Concord TTL.
- **Lease released** → Delete DNS records immediately (don't wait for TTL).

Lives in `yellow_dog` core app supervision tree (bridges two domains, belongs to neither).

### RpzReloader

GenStage consumer subscribed to `rpz:*` events. Lives in `yellow_dog_dns`. On any RPZ change, triggers reload of the RPZ ruleset in DNS worker processes.

### ZoneReloader

GenStage consumer subscribed to `dns:zone:*` events. Lives in `yellow_dog_dns`. On zone metadata or RR changes, triggers incremental reload of the affected zone in DNS worker processes. For RR changes, also ensures SOA serial is incremented and optionally sends DNS NOTIFY to configured targets.

### CacheSyncer

Periodic process in `yellow_dog_dns`. Responsibilities:

- **Startup:** Calls `Store.Cache.warm_from_store/0` to populate local ETS from Concord.
- **Periodic flush:** Calls `Store.Cache.flush_to_store/0` on a configurable interval. Batch size adapts to Raft latency — increases when Raft is responsive, decreases when latency rises. This prevents cache sync from degrading cluster performance under load.
- **LRU eviction:** Monitors ETS memory usage against configured budget. Evicts least-recently-used entries when threshold is exceeded.
- **Not on the query path.** Must never block DNS resolution.

### ConfigWatcher

GenStage consumer subscribed to `config:*` events. Each service app starts its own ConfigWatcher that filters for its namespace and applies changes.

---

## Supervision Tree

```
yellow_dog (Application)
└── YellowDog.Supervisor
    ├── Concord.Application           # Embedded Raft, ETS, snapshots
    ├── YellowDog.Store.EventBridge   # Event stream dispatcher
    └── YellowDog.Store.DynDnsUpdater # GenStage consumer: lease → DNS
```

---

## CLI Commands

Release-compatible CLI commands via `eval` or a dedicated CLI module invoked through the release boot script. Not Mix tasks — those are unavailable in releases.

### `yellow_dog backup create`

Create a backup of all Concord data.

| Flag | Description |
|------|-------------|
| `--dir PATH` | Output directory (default: `./backups`) |
| `--label TEXT` | Human-readable label embedded in backup metadata |

Outputs backup file path and summary (key count, size, checksum) to stdout.

### `yellow_dog backup restore`

Restore Concord data from a backup file.

| Flag | Description |
|------|-------------|
| `--file PATH` | Backup file to restore (required) |
| `--verify-only` | Validate backup integrity without applying |
| `--yes` | Skip confirmation prompt (for scripting) |

Without `--yes`, prompts for interactive confirmation before overwriting current state. Prints restore summary (keys restored, namespaces affected) on completion.

### `yellow_dog backup list`

List available backups.

| Flag | Description |
|------|-------------|
| `--dir PATH` | Backup directory to scan (default: `./backups`) |

Prints table: filename, timestamp, size, label, checksum status.

### Invocation

Commands are invoked through the release:

```
bin/yellow_dog eval "YellowDog.CLI.main([\"backup\", \"create\", \"--label\", \"nightly\"])"
```

Or via a release command wrapper script (`rel/overlays/bin/yellow_dog_cli`) that forwards arguments:

```
bin/yellow_dog_cli backup create --label nightly
bin/yellow_dog_cli backup restore --file ./backups/2026-03-13.backup --yes
bin/yellow_dog_cli backup list
```

`YellowDog.CLI` parses argv via `OptionParser`, dispatches to `Store.Backup` functions, and formats output for terminal.

---

## Console Integration (Backup/Restore)

The Console (Phoenix LiveView) provides a settings page for backup and restore operations.

### Backup Page

- **Create backup** — button triggers `Store.Backup.create/1`, shows progress and result (path, size, checksum).
- **Backup list** — table of available backups with timestamp, label, size. Sourced from `Store.Backup.list/1`.
- **Download** — each backup has a download link served from the backup directory.
- **Delete** — remove old backups with confirmation.

### Restore Page

- **Upload or select** — upload a backup file, or select from the backup list.
- **Verify** — runs `Store.Backup.verify/1`, shows integrity check result and contents summary (namespace counts) before committing.
- **Restore** — requires explicit confirmation step in the UI (equivalent to the `:confirm` safety latch). Shows progress and result.
- **Warning banner** — restore is destructive. UI must clearly communicate that current state will be overwritten.

### Telemetry Events

```
[:yellow_dog, :store, :backup, :created]
Measurements: %{duration: native_time, size_bytes: integer}
Metadata: %{path: path, label: label}

[:yellow_dog, :store, :backup, :restored]
Measurements: %{duration: native_time, keys_restored: integer}
Metadata: %{path: path, namespaces: list}

[:yellow_dog, :store, :backup, :verified]
Measurements: %{duration: native_time}
Metadata: %{path: path, valid: boolean}
```

---

## Consistency Level Guide

| Operation | Consistency | Rationale |
|-----------|------------|-----------|
| Lease offer/bind (write) | `:strong` | No dual IP assignment |
| Lease lookup | `:leader` | Slightly stale OK for DHCP processing |
| Device upsert | `:leader` | Fingerprint updates tolerate slight staleness |
| Device read | `:eventual` | Informational |
| Zone metadata write | `:strong` | Zone config must be uniform across nodes |
| Zone RR write | `:strong` | Authoritative data must converge |
| Zone RR read | `:eventual` | DNS workers maintain local ETS snapshot |
| Cache write to Concord | `:eventual` | Async backing store, best-effort |
| Cache read from Concord | `:eventual` | Startup warming only, staleness harmless |
| Cache hot path (ETS) | N/A | Local ETS, no Raft involved |
| Dynamic DNS write | `:strong` | DNS records must be authoritative |
| Dynamic DNS read | `:eventual` | DNS workers cache anyway |
| RPZ write | `:strong` | Policy must be uniform |
| RPZ read | `:eventual` | Hot-reloaded periodically |
| Host register (CAS) | `:strong` | Prevent hostname squatting |
| Host lookup | `:eventual` | Auth checks tolerate slight staleness |
| Config write | `:strong` | Config must converge |
| Config read | `:leader` | Want reasonably fresh config |

---

## Telemetry Events

### Store Operations

```
[:yellow_dog, :store, :operation, :start | :stop | :exception]

Measurements (stop): %{duration: native_time}
Metadata: %{
  namespace: :lease | :device | :zone | :cache | :dyn_dns | :rpz | :host | :config,
  operation: :get | :put | :put_if | :delete | :list,
  key: String.t(),
  consistency: :eventual | :leader | :strong
}
```

### Lease State Transitions

```
[:yellow_dog, :store, :lease, :transition]
Metadata: %{mac: mac, from: old_state, to: new_state, ip: ip}
```

### Zone Changes

```
[:yellow_dog, :store, :zone, :rr_changed]
Metadata: %{zone: zone, owner: owner, type: type, action: :put | :delete}

[:yellow_dog, :store, :zone, :imported]
Metadata: %{zone: zone, record_count: integer}

[:yellow_dog, :store, :zone, :serial_incremented]
Metadata: %{zone: zone, old_serial: integer, new_serial: integer}
```

### Cache Sync

```
[:yellow_dog, :store, :cache, :warm]
Measurements: %{duration: native_time, entries_loaded: integer}

[:yellow_dog, :store, :cache, :flush]
Measurements: %{duration: native_time, entries_flushed: integer}

[:yellow_dog, :store, :cache, :stats]
Measurements: %{hits: integer, misses: integer, size: integer, evictions: integer}
```

### Event Dispatch

```
[:yellow_dog, :store, :event, :dispatched]
Metadata: %{pattern: pattern, key: key, consumer: module}
```

---

## Multi-Tenancy / Network Segmentation

For deployments managing multiple VLANs or sites, Concord namespaces provide isolation. Same MAC can have different leases in `vlan100` vs `vlan200` namespaces. Default namespace suffices for single-site deployments.

---

## Single-Node Mode

When YellowDog detects a single-node deployment (no cluster peers), the Store facade bypasses Raft consensus and writes directly to ETS. This eliminates Raft overhead for standalone home/office deployments while keeping the same API surface. The facade detects node count at startup and can switch modes dynamically if peers join or leave. All consistency level parameters are accepted but ignored in single-node mode (all reads/writes are local ETS).

---

## File Structure

```
apps/yellow_dog/lib/yellow_dog/
├── store.ex                          # Top-level facade with delegations
├── store/
│   ├── lease.ex                      # DHCP lease state machine
│   ├── device.ex                     # Device fingerprint registry
│   ├── zone.ex                       # Authoritative DNS zone data
│   ├── cache.ex                      # DNS cache (ETS + Concord backing)
│   ├── dyn_dns.ex                    # Dynamic DNS records
│   ├── rpz.ex                        # Response policy zones
│   ├── host.ex                       # Host identity registry
│   ├── config.ex                     # Runtime configuration
│   ├── backup.ex                     # Backup and restore operations
│   ├── cli.ex                        # Release CLI command dispatcher
│   ├── event_bridge.ex               # Event stream dispatcher
│   └── dyn_dns_updater.ex            # GenStage: lease → DNS

apps/yellow_dog/test/yellow_dog/store/
├── lease_test.exs
├── device_test.exs
├── zone_test.exs
├── cache_test.exs
├── dyn_dns_test.exs
├── rpz_test.exs
├── host_test.exs
├── config_test.exs
├── backup_test.exs
├── event_bridge_test.exs
├── cli_test.exs
└── dyn_dns_updater_test.exs

rel/overlays/bin/
└── yellow_dog_cli                    # Shell wrapper for CLI commands
```

---

## Testing Requirements

### Unit Tests

- Lease state machine: `offer → bind → renew → release` full lifecycle
- CAS enforcement: concurrent offers on same MAC serialize correctly
- XID mismatch: bind with wrong transaction ID rejected
- MAC normalization: various formats (dashes, dots, uppercase) resolve to same key
- Device upsert: merge semantics preserve existing fields while updating new ones
- Zone import: parse zone file text, verify all RR keys created with correct values
- Zone export: read RR keys, verify rendered zone file matches expected output
- Zone RRset CAS: concurrent edits to same RRset serialize correctly
- Zone SOA serial: auto-increments on any RR change
- Cache lookup: ETS-only, never touches Concord
- Cache store: writes to ETS immediately, does not block on Concord
- Cache warm: loads entries from Concord into ETS, skips expired entries
- Cache LRU eviction: filling past memory budget evicts least-recently-used entries
- RPZ list: prefix scan returns all rules in a zone
- Config fallback: missing Concord key returns TOML default
- Backup create: produces valid compressed file with checksum
- Backup verify: detects corrupted backup files
- Backup list: enumerates backups with correct metadata
- Event log: state changes produce durable log entries
- Event replay: `EventBridge.replay/2` returns events after given timestamp
- Structured key encoding: facade produces correct string keys from typed arguments
- DHCPv6 lease: offer/bind/renew/release using DUID key path

### Integration Tests

- **Lease → DNS pipeline:** Bind a lease with hostname, verify DynDnsUpdater creates A + PTR records
- **DHCPv6 lease lifecycle:** Full offer/bind/renew/release cycle using DUID, verify records under `v6:` prefix
- **Cross-protocol `by_ip`:** Create v4 and v6 leases, verify `by_ip/1` finds both
- **RPZ → DNS reload:** Write RPZ rule via Console, verify DNS workers pick up the change
- **Zone → DNS reload:** Add RRset via Store.Zone, verify ZoneReloader triggers DNS worker update
- **Zone import/export round-trip:** Import a zone file, export it back, verify semantic equivalence
- **Zone Raft replication:** Write zone data on leader, verify follower nodes serve same authoritative answers
- **Cache warming:** Write cache entries to Concord, start a new DNS worker, verify it pre-populates ETS from Concord
- **Cache flush:** Store entries in ETS, trigger flush, verify entries appear in Concord
- **Cache LRU under pressure:** Fill cache past memory budget, verify eviction occurs and hot path unaffected
- **Adaptive flush:** Simulate elevated Raft latency, verify flush batch size decreases; restore normal latency, verify batch size recovers
- **Config propagation:** Update upstream DNS config, verify DNS app receives event and reconfigures
- **TTL expiration:** Create lease with short TTL, verify both lease and DNS records auto-expire
- **Event replay on crash:** Kill a consumer mid-stream, restart it, verify it replays missed events from durable log
- **Event log retention:** Create events, advance time past retention window, verify expired log entries are cleaned up
- **Single-node mode:** Start without cluster peers, verify all Store operations succeed without Raft
- **Single-node → cluster transition:** Start single-node, add a peer, verify state replicates and mode switches to Raft
- **Query fallback:** If Concord secondary index unavailable, verify ETS fallback index returns same results
- **Backup/restore round-trip:** Populate data across all namespaces, create backup, clear state, restore, verify all data recovered
- **Restore safety latch:** Restore without `:confirm` option returns error

### Property-Based Tests

- Lease state machine: random sequences of offer/bind/renew/release always reach valid states
- MAC normalization: any valid MAC format round-trips to canonical form
- DUID normalization: any valid DUID format round-trips to canonical form
- Structured key encoding: round-trip serialization/deserialization for all key types
- Cache LRU: memory usage never exceeds budget after any sequence of store/evict operations

---

## Acceptance Criteria

- [ ] `YellowDog.Store.Lease` manages full DHCP lease lifecycle with CAS state transitions
- [ ] DHCPv4 leases keyed under `dhcp:lease:v4:{mac}`, DHCPv6 under `dhcp:lease:v6:{duid}`
- [ ] `by_ip/1` searches across both v4 and v6 prefixes
- [ ] `YellowDog.Store.Zone` stores authoritative zone data in Concord, replicated via Raft
- [ ] `Store.Zone.import/2` parses zone file text into Concord keys; `export/1` renders back to zone file
- [ ] Zone RR changes auto-increment SOA serial
- [ ] Zone replication is Raft-only (no AXFR/IXFR)
- [ ] `ZoneReloader` triggers DNS worker zone reload on `dns:zone:*` events
- [ ] `YellowDog.Store.Cache` reads/writes ETS on the hot path; never blocks on Concord during queries
- [ ] Cache enforces max memory budget with LRU eviction
- [ ] `CacheSyncer` warms ETS from Concord on startup and flushes with adaptive batch sizing
- [ ] Flush batch size adjusts based on observed Raft latency
- [ ] `YellowDog.Store.DynDns` creates/reads/deletes dynamic DNS records with TTL
- [ ] `DynDnsUpdater` automatically creates A + PTR records on lease bind events
- [ ] `YellowDog.Store.Rpz` manages RPZ rules with prefix scanning per zone
- [ ] `YellowDog.Store.Device` merges fingerprint data from multiple protocol sources
- [ ] `YellowDog.Store.Host` enforces CAS for hostname registration
- [ ] `YellowDog.Store.Config` overrides TOML defaults at runtime with event propagation
- [ ] `YellowDog.Store.EventBridge` persists events to durable log with configurable retention
- [ ] `EventBridge.replay/2` replays missed events from durable log on consumer restart
- [ ] `YellowDog.Store.Backup` creates compressed backups with integrity checksums
- [ ] `Store.Backup.restore/2` requires explicit `:confirm` safety latch
- [ ] `Store.Backup.verify/1` validates backup integrity without restoring
- [ ] Release CLI commands `backup create`, `backup restore`, `backup list` wrap Store.Backup functions
- [ ] Console UI provides backup create/download/delete and restore with verification step
- [ ] Single-node mode bypasses Raft for direct ETS writes; detects peers dynamically
- [ ] Cross-key lookups use Concord secondary indexes with ETS fallback
- [ ] All Store operations emit telemetry events
- [ ] Lease state transitions emit dedicated telemetry events
- [ ] No child app calls `Concord.*` directly — all access through `YellowDog.Store`
- [ ] Unit and integration tests pass
- [ ] Event stream consumers handle backpressure via GenStage

---

## Design Decisions

1. **Query strategy** — Concord secondary indexes first, local ETS index as fallback. The facade maintains ETS indexes for cross-key lookups (`by_ip`, `by_vendor`, `list_by_subnet`) if Concord's Query module lacks the needed index type. Both paths return the same results; ETS is rebuilt from Concord state on startup.

2. **DHCPv4/v6 key separation** — Separate key prefixes: `dhcp:lease:v4:{mac}` and `dhcp:lease:v6:{duid}`. MAC and DUID are fundamentally different identifier spaces. Separate prefixes allow protocol-specific prefix scans and avoid ambiguity. Cross-protocol lookups (e.g. `by_ip`) search both prefixes.

3. **Durable event log** — Events persisted to Concord (`event_log:{timestamp}:{key}`) with configurable TTL retention. Consumers replay missed events on restart via `EventBridge.replay/2`. GenStage backpressure handles real-time flow; durability ensures no events lost within retention window.

4. **Single-node Raft bypass** — Facade detects single-node deployment and writes directly to ETS, bypassing Raft consensus. Same API surface, same data model, no overhead. Switches dynamically if peers join. Consistency parameters accepted but ignored in single-node mode.

5. **Structured key encoding** — Keys use a structured convention (typed arguments at the facade boundary, serialized to canonical strings internally). Callers pass atoms, tuples, and strings; the facade produces the Concord key string. Provides type safety while keeping keys HTTP API compatible.

6. **RRset-level zone keys** — One Concord key per `{owner}:{type}` tuple, holding the full RRset. Matches DNS semantics where RRsets are the unit of operation. Avoids key explosion for records with many addresses. CAS operates at RRset granularity.

7. **Raft-only zone replication** — No AXFR/IXFR support. All authoritative nodes must be Raft cluster members. Simplifies the architecture — Raft provides stronger consistency guarantees than zone transfer protocols. Zone files serve only as import/export format.

8. **Cache memory budget with LRU** — ETS cache bounded by configurable max memory (default 64MB). LRU eviction when budget exceeded. TTL expiration still applies independently. Prevents unbounded memory growth under high query volume.

9. **Adaptive cache flush batching** — Flush batch size adjusts based on observed Raft write latency. Increases batch size when Raft is responsive, decreases when latency rises. Prevents cache sync from degrading cluster performance under load.

---

*Version: 2.0.0 — All design decisions resolved*  
*Depends on: Concord ~> 0.1.0*