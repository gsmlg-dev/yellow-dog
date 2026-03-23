# DNS Zone Support — Store-Backed Implementation Plan

## Context

Yellow Dog already has working Auth, Forward, and Stub zone GenServer processes (`apps/yellow_dog_dns/lib/yellow_dog/dns/zone/{auth,forward,stub}.ex`). However, zone configuration is currently loaded from TOML files (`data/dns/zones.toml` via `ZoneStore`) and auth zone records live in per-process ETS tables. Forward/stub zone configs are passed as opts at start time.

The goal is to make **all zone data and configuration persist in YellowDog.Store** (Concord-backed KV store), eliminating TOML config as the source of truth for zone data. This enables:
- Runtime zone management via API/UI without config file edits
- Cluster-wide zone data replication via Concord's Raft consensus
- EventBridge-driven zone reload on changes

`Store.Zone` (`apps/yellow_dog_store/lib/yellow_dog/store/zone.ex`) already handles auth zone metadata + RRset CRUD. We need to extend it for forward and stub zone types, then wire the zone GenServers to load/save via Store.

---

## Phase 1: Extend Store.Zone for All Zone Types

### 1.1 View-scoped key pattern

Zones are scoped to views (split-horizon DNS). The Store key hierarchy must reflect this:

**Key patterns**:
- Zone metadata (all types): `dns:view:{view_name}:zone:{zone_name}`
- Resource records (auth only): `dns:view:{view_name}:zone:{zone_name}:rr:{owner}:{type}`

This matches the `{view_name, zone_type, zone_name}` tuple used in `ZoneRegistry` and `ZoneController`. The same zone name in different views produces different Store keys.

**Important**: Only auth zones have zone data (RRsets). Forward and stub zones store only their configuration metadata — they have no zone data. Forward zones proxy queries upstream. Stub zones cache NS/glue at runtime from querying primaries but don't persist that cache.

### 1.2 Zone metadata schemas per type

Add a `:zone_type` field to discriminate zone types in metadata.

**Auth zone metadata** (existing, add `:zone_type`):
```elixir
%{
  zone_type: :auth,
  origin: name,
  soa: %{mname, rname, serial, refresh, retry, expire, minimum},
  default_ttl: 3600,
  authoritative: true,
  allow_dynamic_update: false,
  serial_strategy: :date_serial,
  created_at: now,
  updated_at: now
}
```
Auth zones also store RRsets under `dns:view:{view}:zone:{name}:rr:{owner}:{type}`.

**Forward zone metadata** (new — config only, no zone data):
```elixir
%{
  zone_type: :forward,
  origin: name,
  forwarders: [%{ip: "8.8.8.8", port: 53}, ...],
  forward_mode: :only | :first,   # BIND9: forward only; vs forward first;
  timeout_ms: 5000,
  max_retries: 2,
  created_at: now,
  updated_at: now
}
```

**Stub zone metadata** (new — config only, NS/glue cached at runtime, not persisted):
```elixir
%{
  zone_type: :stub,
  origin: name,
  primaries: [%{ip: "10.0.0.1", port: 53}, ...],  # servers to query for NS refresh
  refresh_interval: 3600,                           # how often to re-query primaries
  created_at: now,
  updated_at: now
}
```
Note: `ns_records` and `glue_records` are runtime cache — obtained by querying primaries. They live in GenServer state only, not in Store.

### 1.3 New Store.Zone functions

**File**: `apps/yellow_dog_store/lib/yellow_dog/store/zone.ex`

All functions now take `view_name` as first argument:

```elixir
# Auth zone — metadata + RRsets (update existing signatures to accept view_name)
create_zone(view_name, zone_name, soa, opts)
get_zone(view_name, zone_name)
delete_zone(view_name, zone_name)          # also deletes all RRsets for auth zones
put_rrset(view_name, zone_name, owner, type, rrset)
get_rrset(view_name, zone_name, owner, type)
delete_rrset(view_name, zone_name, owner, type)
list_records(view_name, zone_name)
list_records(view_name, zone_name, owner)
import_zone(view_name, zone_name, records)
export_zone(view_name, zone_name)
increment_serial(view_name, zone_name)

# Forward zone — config only, no zone data
create_forward_zone(view_name, name, forwarders, opts)  # opts: forward_mode, timeout_ms, max_retries
update_forward_zone(view_name, name, attrs)             # CAS update

# Stub zone — config only (NS/glue are runtime cache, not persisted)
create_stub_zone(view_name, name, primaries, opts)      # opts: refresh_interval
update_stub_zone(view_name, name, attrs)                # CAS update

# Listing (all zone types)
list_zones()                          # All zones across all views
list_zones_for_view(view_name)        # All zones in a view
list_zones_by_type(zone_type)         # Filter by type across all views

# Generic metadata update
update_zone(view_name, zone_name, attrs)  # CAS update on any zone type
```

### 1.4 Update Store.Key for view-scoped keys

**File**: `apps/yellow_dog_store/lib/yellow_dog/store/key.ex`

Replace existing zone key functions with view-scoped versions:

```elixir
# Zone metadata key (view-scoped)
def zone(view_name, zone_name), do: "dns:view:#{view_name}:zone:#{zone_name}"

# Zone resource record key (view-scoped)
def zone_rr(view_name, zone_name, owner, type),
  do: "dns:view:#{view_name}:zone:#{zone_name}:rr:#{owner}:#{type}"

# Prefix scans
def view_prefix(view_name), do: "dns:view:#{view_name}:"
def zone_prefix(view_name), do: "dns:view:#{view_name}:zone:"
def zone_rr_prefix(view_name, zone_name), do: "dns:view:#{view_name}:zone:#{zone_name}:rr:"
def all_views_prefix, do: "dns:view:"
```

Deprecate old `zone(name)` and `zone_rr(zone_name, owner, type)` — add `@deprecated` attribute and delegate to new functions with `view_name: "default"`.

### 1.5 Update Store facade delegates

**File**: `apps/yellow_dog_store/lib/yellow_dog/store.ex`

Add delegates for the new `Store.Zone` functions.

---

## Phase 2: Wire Zone GenServers to Store

### 2.1 Auth Zone — Store-backed record persistence

**File**: `apps/yellow_dog_dns/lib/yellow_dog/dns/zone/auth.ex`

Currently: Records stored in per-process ETS table. `save/1` writes to zone file.

**Runtime model**: ETS is the single source of truth while the server is running. Store is persistence only — used to survive restarts. No reads from Store during normal operation.

Change:
- On `init/1`: Load records from `Store.Zone.list_records(view_name, zone_name)` into ETS
- On `add_record/2` / `remove_record/3`: Write to ETS only (runtime truth). Then async-sync changed RRset to Store for persistence.
- On `import_zone_file/2`: Import into ETS, then batch-sync all records to Store.
- On `terminate/2`: Flush all dirty records to Store before shutdown.
- All query resolution reads ETS only — zero Store reads in hot path.
- Sync to Store is fire-and-forget (async Task) on mutation, plus a guaranteed flush on graceful stop.

### 2.2 Forward Zone — Store-backed config

**File**: `apps/yellow_dog_dns/lib/yellow_dog/dns/zone/forward.ex`

Currently: Config passed as opts at start time. No persistence.

**Runtime model**: GenServer state (upstreams, forward_mode, etc.) is the runtime truth. Store is persistence only.

Change:
- On `init/1`: Load config from `Store.Zone.get_zone(view_name, name)` into GenServer state
- On `update_config/2` (new API): Update GenServer state, then async-sync to Store
- On `reload/2`: Update GenServer state from new config, then async-sync to Store
- On `terminate/2`: Flush current config to Store

### 2.3 Stub Zone — Store-backed config

**File**: `apps/yellow_dog_dns/lib/yellow_dog/dns/zone/stub.ex`

**Runtime model**: GenServer state is runtime truth. Store persists config (primaries, refresh_interval) only. NS records and glue are runtime cache obtained by querying primaries — not persisted.

- On `init/1`: Load config (primaries, refresh_interval) from `Store.Zone.get_zone(view_name, name)`. Then query primaries for NS/glue to populate runtime cache.
- On `update_config/2` (new API): Update primaries/refresh config in state, async-sync to Store. Re-query primaries for fresh NS/glue.
- On `reload/2`: Same as update_config
- On `terminate/2`: Flush config (primaries, refresh_interval) to Store. NS/glue cache is discarded — will be re-fetched on next start.

### 2.4 ZoneController — Create zone in Store before starting process

**File**: `apps/yellow_dog_dns/lib/yellow_dog/dns/zone_controller.ex`

Update `start_zone/4` to:
1. Persist zone metadata to Store (if not already exists)
2. Start the GenServer process

Update startup flow to:
1. On DNS supervisor start, scan `Store.Zone.list_zones()` (returns all view-scoped zones)
2. For each zone in Store, start the corresponding GenServer via ZoneController with its view_name

### 2.5 ZoneReloader — Handle all zone types

**File**: `apps/yellow_dog_dns/lib/yellow_dog/dns/zone_reloader.ex`

Update subscription pattern from `dns:zone:*` to `dns:view:*` to match new key hierarchy. Needs to handle:
- Forward zone metadata changes → reload forwarders
- Stub zone metadata changes → reload NS/glue records
- Auth zone RR changes → reload records into ETS (already partially done)

---

## Phase 3: Deprecate TOML-based ZoneStore

### 3.1 Migration path

**File**: `apps/yellow_dog_dns/lib/yellow_dog/dns/zone_store.ex`

- Add `migrate_to_store/0` function that reads TOML zones and writes them to YellowDog.Store
- Keep `ZoneStore` module for backward compat but mark as deprecated
- On startup: if Store has zones, use Store; if Store is empty and TOML has zones, auto-migrate

### 3.2 Remove zone config from TOML config

Zone definitions should no longer be in `yellowdogdns_default_config.toml`. The TOML config retains only server-level settings (listen address, port, recursion settings, etc.).

---

## Phase 4: Unit Tests

### 4.1 Store.Zone unit tests

**File**: `apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs`

Test each Store.Zone function in isolation:

**Auth zone tests:**
- `create_zone/3` — creates metadata, CAS prevents duplicate
- `delete_zone/1` — removes metadata + all RRsets
- `get_zone/1` — retrieves metadata
- `list_zones/0` — lists all zone names
- `put_rrset/4` — creates/updates RRset, auto-increments serial
- `get_rrset/3` — retrieves specific RRset
- `delete_rrset/3` — removes RRset, auto-increments serial
- `list_records/1` — lists all RRsets in zone
- `list_records/2` — filters by owner
- `import/2` — bulk import records
- `export/1` — export all records
- `increment_serial/1` — serial strategies (date_serial, increment)

**Forward zone tests:**
- `create_forward_zone/3` — creates with forwarders + mode
- `create_forward_zone/3` duplicate — returns `{:error, :already_exists}`
- `update_forward_zone/2` — updates forwarders list
- `update_forward_zone/2` — updates forward_mode (:only ↔ :first)
- `get_zone/1` — returns forward zone metadata with correct zone_type
- `list_zones_by_type(:forward)` — filters correctly

**Stub zone tests:**
- `create_stub_zone/3` — creates with primaries + refresh_interval
- `create_stub_zone/3` duplicate — returns `{:error, :already_exists}`
- `update_stub_zone/2` — updates primaries
- `update_stub_zone/2` — updates refresh_interval
- `get_zone/1` — returns stub zone metadata with correct zone_type (no NS/glue — those are runtime cache)
- `list_zones_by_type(:stub)` — filters correctly

**Cross-type tests:**
- `list_zones/0` — returns all zone types
- `list_zones_by_type/1` — filters by each type
- `delete_zone/1` — works for all zone types

### 4.2 Zone GenServer unit tests (Store integration)

**Auth zone**: `apps/yellow_dog_dns/test/yellow_dog/dns/zone/auth_test.exs`
- Add tests for Store-backed persistence: add record → restart process → records still available
- Test that `add_record` writes to both ETS and Store

**Forward zone**: `apps/yellow_dog_dns/test/yellow_dog/dns/zone/forward_test.exs`
- Test loading config from Store on init
- Test `update_config/2` persists to Store
- Test reload reads from Store

**Stub zone**: `apps/yellow_dog_dns/test/yellow_dog/dns/zone/stub_test.exs`
- Test loading config from Store on init
- Test `update_config/2` persists to Store
- Test reload reads from Store

---

## Phase 5: E2E Tests

E2E tests live in `e2e_test/` at umbrella root and run via `mix test.e2e.dns`.

### 5.1 Auth zone E2E — `e2e_test/dns_zone_auth_e2e_test.exs`

Update existing test to verify Store persistence:
- Create auth zone via ZoneController → verify zone metadata in Store
- Add records → query via DNS → verify answers
- Add records → verify RRsets in Store
- Restart zone process → verify records survive (loaded from Store)
- Delete zone → verify Store cleanup

### 5.2 Forward zone E2E — `e2e_test/dns_zone_forward_e2e_test.exs`

Update existing test to verify Store persistence:
- Create forward zone → verify metadata persisted in Store
- Query domain → verify forwarding to upstream works
- Update forwarders via Store → verify zone reloads
- Test forward-only mode: upstream fails → SERVFAIL
- Test forward-first mode: upstream fails → fallback (if recursion enabled)

### 5.3 Stub zone E2E — `e2e_test/dns_zone_stub_e2e_test.exs`

Update existing test to verify Store persistence:
- Create stub zone → verify metadata persisted in Store
- Verify NS records maintained
- Verify delegation queries route correctly
- Update NS records via Store → verify zone reloads

### 5.4 Add mix aliases for zone-specific E2E

**File**: `mix.exs`

```elixir
"test.e2e.zone.auth": &run_e2e_zone_auth/1,
"test.e2e.zone.forward": &run_e2e_zone_forward/1,
"test.e2e.zone.stub": &run_e2e_zone_stub/1,
```

---

## Critical Files

| File | Action |
|------|--------|
| `apps/yellow_dog_store/lib/yellow_dog/store/zone.ex` | Extend for forward/stub zone types |
| `apps/yellow_dog_store/lib/yellow_dog/store.ex` | Add delegates for new functions |
| `apps/yellow_dog_dns/lib/yellow_dog/dns/zone/auth.ex` | Wire to Store for record persistence |
| `apps/yellow_dog_dns/lib/yellow_dog/dns/zone/forward.ex` | Wire to Store for config persistence |
| `apps/yellow_dog_dns/lib/yellow_dog/dns/zone/stub.ex` | Wire to Store for config persistence |
| `apps/yellow_dog_dns/lib/yellow_dog/dns/zone_controller.ex` | Store-first zone lifecycle |
| `apps/yellow_dog_dns/lib/yellow_dog/dns/zone_reloader.ex` | Handle all zone type events |
| `apps/yellow_dog_dns/lib/yellow_dog/dns/zone_store.ex` | Deprecate, add migration |
| `apps/yellow_dog_store/test/yellow_dog/store/zone_test.exs` | Unit tests for Store.Zone |
| `apps/yellow_dog_dns/test/yellow_dog/dns/zone/auth_test.exs` | Store integration tests |
| `apps/yellow_dog_dns/test/yellow_dog/dns/zone/forward_test.exs` | Store integration tests |
| `apps/yellow_dog_dns/test/yellow_dog/dns/zone/stub_test.exs` | Store integration tests |
| `e2e_test/dns_zone_auth_e2e_test.exs` | Store persistence E2E |
| `e2e_test/dns_zone_forward_e2e_test.exs` | Store persistence E2E |
| `e2e_test/dns_zone_stub_e2e_test.exs` | Store persistence E2E |
| `mix.exs` | Add zone-specific E2E aliases |

## Verification

1. **Unit tests**: `cd apps/yellow_dog_store && mix test test/yellow_dog/store/zone_test.exs`
2. **DNS unit tests**: `cd apps/yellow_dog_dns && mix test`
3. **E2E auth**: `mix test.e2e.zone.auth`
4. **E2E forward**: `mix test.e2e.zone.forward`
5. **E2E stub**: `mix test.e2e.zone.stub`
6. **Full CI check**: `mix compile --warnings-as-errors && mix format --check-formatted && mix credo --strict`
7. **Manual**: Start dev server, create zones via console UI, restart, verify zones survive

## Implementation Order

1. Phase 1 (Store.Zone extension) — no breaking changes, additive only
2. Phase 4.1 (Store.Zone unit tests) — validate the new Store functions
3. Phase 2 (Wire GenServers) — integrate Store with zone processes
4. Phase 4.2 (GenServer unit tests) — validate the integration
5. Phase 3 (Deprecate TOML ZoneStore) — migration path
6. Phase 5 (E2E tests) — full-stack validation
