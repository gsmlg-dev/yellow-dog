# DNS Provider — Auth Zone Data Provider System

**Date:** 2026-04-13
**Status:** Design approved

## Overview

A new umbrella app `yellow_dog_dns_provider` that provides a pluggable provider system for synchronizing DNS auth zone data between Yellow Dog and external sources. Supports bidirectional sync with configurable conflict resolution per provider.

### Providers

| Provider | Module | Source | Direction |
|----------|--------|--------|-----------|
| IANA Root Zone | `Provider.IanaRoot` | `https://www.internic.net/domain/root.zone` | Read-only (pull) |
| AWS Route 53 | `Provider.Aws` | Route 53 API | Bidirectional |
| Cloudflare | `Provider.Cloudflare` | Cloudflare DNS API v4 | Bidirectional |
| Google Cloud DNS | `Provider.Gcp` | Cloud DNS API | Bidirectional |
| Vultr | `Provider.Vultr` | Vultr DNS API | Bidirectional |

## Architecture

### App: `yellow_dog_dns_provider`

**Dependencies:** `yellow_dog_dns`, `yellow_dog_store`, `yellow_dog_telemetry`, `req` (HTTP client)

**Module namespace:** `YellowDog.DnsProvider.*`

### Provider Behaviour

Each cloud provider implements `YellowDog.DnsProvider.Provider`:

```elixir
@type zone_ref :: %{name: String.t(), id: String.t() | nil}
@type record_entry :: %{owner: String.t(), type: String.t(), ttl: non_neg_integer(), rdata: term()}
@type changeset :: %{additions: [record_entry()], deletions: [record_entry()]}
@type conflict_strategy :: :local_wins | :remote_wins | :manual

@callback init(config :: map()) :: {:ok, state :: term()} | {:error, term()}
@callback list_zones(state) :: {:ok, [zone_ref()], state} | {:error, term(), state}
@callback get_records(zone_ref(), state) :: {:ok, [record_entry()], state} | {:error, term(), state}
@callback apply_changeset(zone_ref(), changeset(), state) :: {:ok, state} | {:error, term(), state}
@callback zone_serial(zone_ref(), state) :: {:ok, non_neg_integer(), state} | {:error, term(), state}
```

Design decisions:
- `apply_changeset/3` instead of individual put/delete — handles Route 53's batch model and is more efficient for bulk syncs
- State threaded through all callbacks for auth tokens, pagination cursors, rate limit tracking
- `zone_serial/2` for SOA-based comparison when conflict strategy needs it
- Read-only providers (IANA Root) return `{:error, :read_only}` from `apply_changeset/3`

### Sync Engine

One `SyncEngine` GenServer per provider binding (a binding = one provider config instance).

**Sync cycle per zone:**

1. Pull remote records via `provider.get_records/2`
2. Read local records from `Store.Zone`
3. Compute diff (both directions) via `YellowDog.DnsProvider.Diff`
4. Apply conflict strategy
5. Push resolved changeset to remote via `provider.apply_changeset/3`
6. Write resolved changeset to local `Store.Zone`
7. Emit telemetry events

**Sync triggers:**
- Periodic: configurable `sync_interval` per provider via `Process.send_after/3`
- On-demand: `DnsProvider.sync_now/1` public API

### Diff Module

`YellowDog.DnsProvider.Diff` compares record sets:

- Compares by `{owner, type, rdata}` tuples
- Produces two changesets: `local_changes` (what remote is missing) and `remote_changes` (what local is missing)
- TTL differences treated as updates (deletion + addition)

### Conflict Resolution

Per-provider configurable strategy:

| Strategy | Behaviour |
|----------|-----------|
| `:local_wins` | Local changeset applied to remote. Remote-only non-conflicting changes merged into local. Conflicts resolved by keeping local version. |
| `:remote_wins` | Remote changeset applied to local. Local-only non-conflicting changes merged into remote. Conflicts resolved by keeping remote version. |
| `:manual` | Conflicts flagged as `SyncConflict` structs, stored in Concord, surfaced in console. Non-conflicting changes applied automatically. |

**IANA Root special case:** Always read-only. SyncEngine skips push phase. Pulls root zone on schedule (daily default).

## Configuration

### Store-based (Concord persistence, no TOML)

All provider config lives in Concord via the Store facade. Providers are created/updated/deleted through the console UI or public API.

**Store key schema** — new namespace `dns:provider:*`:

| Key pattern | Purpose |
|-------------|---------|
| `dns:provider:{name}:config` | Provider configuration |
| `dns:provider:{name}:status` | Runtime state (last_sync, next_sync, last_error) |
| `dns:provider:{name}:conflict:{id}` | Unresolved manual conflicts |

**Config struct** — `YellowDog.DnsProvider.Config`:

```elixir
%Config{
  name: "aws-prod",
  type: :aws,
  credentials: %{access_key_id: "...", secret_access_key: "..."},
  sync_interval: 300,
  zones: ["example.com."],
  conflict_strategy: :local_wins,
  enabled: true
}
```

**Store facade** — `YellowDog.Store.Provider` (new module in `yellow_dog_store`):

- `put_config(config)` / `get_config(name)` / `list_configs()` / `delete_config(name)`
- `put_status(name, status)` / `get_status(name)`
- `put_conflict(conflict)` / `list_conflicts(name)` / `delete_conflict(id)`
- Write-through: Concord persist then ETS cache; reads from ETS only

**Startup:** Warmer loads all provider configs from Concord. SyncSupervisor starts a SyncEngine per enabled provider.

**Config reload:** EventBridge CDC events on `dns:provider:*:config` changes trigger DynamicSupervisor to start/stop/restart SyncEngines (same pattern as ZoneReloader).

## Supervision Tree

```
YellowDog.DnsProvider.Supervisor (one_for_one)
├── Registry (named: YellowDog.DnsProvider.Registry)
├── ConflictStore (GenServer — ETS for :manual conflicts)
└── SyncSupervisor (DynamicSupervisor)
    ├── SyncEngine "iana-root"
    ├── SyncEngine "aws-prod"
    ├── SyncEngine "cf-main"
    └── ...
```

- DynamicSupervisor for runtime provider add/remove via config changes
- Registry for SyncEngine lookup by provider name (on-demand sync)
- ConflictStore holds unresolved `:manual` conflicts (ETS read cache backed by Concord via Store.Provider facade)

**Integration with existing DNS app:**
- `YellowDog.Application` starts `DnsProvider.Supervisor` conditionally, gated by provider config presence in Store
- SyncEngine writes to local zones via `Store.Zone` facade (same write path as zone editor)
- ZoneReloader picks up Store changes via EventBridge — no additional wiring needed

## Public API

`YellowDog.DnsProvider` facade module:

```elixir
# Provider management
add_provider(config) :: :ok | {:error, term()}
update_provider(name, changes) :: :ok | {:error, term()}
remove_provider(name) :: :ok | {:error, term()}
list_providers() :: [%{name: String.t(), type: atom(), status: :running | :stopped}]
start_provider(name) :: :ok | {:error, term()}
stop_provider(name) :: :ok | {:error, term()}

# Sync operations
sync_now(provider_name) :: :ok | {:error, term()}
sync_now(provider_name, zone_origin) :: :ok | {:error, term()}
sync_status(provider_name) :: %{last_sync: DateTime.t() | nil, next_sync: DateTime.t(), zone_statuses: map()}

# Conflict management (for :manual strategy)
list_conflicts() :: [SyncConflict.t()]
list_conflicts(provider_name) :: [SyncConflict.t()]
resolve_conflict(conflict_id, :keep_local | :keep_remote) :: :ok | {:error, term()}
resolve_all_conflicts(provider_name, :keep_local | :keep_remote) :: :ok
```

## Console Pages

New section under DNS in sidebar:

| Page | Route | Purpose |
|------|-------|---------|
| Providers | `/dns/providers` | List providers, status, last sync, sync button |
| Provider Detail | `/dns/providers/:name` | Zone bindings, sync history, config (secrets masked), per-zone sync |
| Conflicts | `/dns/providers/:name/conflicts` | Unresolved conflicts for `:manual` strategy, resolve buttons |

**PubSub integration:**
- Topic: `"dns_provider:#{provider_name}"`
- Events: `{:sync_complete, %{zone: origin, pulled: n, pushed: n, conflicts: n}}`, `{:sync_error, reason}`
- Console LiveViews subscribe for real-time status updates

## Telemetry

Events under `[:yellow_dog, :dns_provider, :sync, :start | :stop | :exception]`:

| Measurement | Description |
|-------------|-------------|
| `duration` | Sync cycle duration |
| `records_pulled` | Records fetched from remote |
| `records_pushed` | Records pushed to remote |
| `conflicts` | Conflict count |

Metadata: `provider`, `zone`, `strategy`, `direction`

## Testing Strategy

- **Unit tests:** Each provider adapter with mocked HTTP responses (Req test adapters)
- **Diff module:** Property-based tests with StreamData for record set comparison correctness
- **SyncEngine:** Integration tests with a `Provider.Test` stub implementation
- **Store.Provider facade:** Standard Store facade tests (put/get/list/delete through Concord+ETS)
- **Console:** ConnCase integration tests for provider pages

## Scope Boundaries

**In scope:**
- Provider behaviour and 5 provider implementations
- SyncEngine with periodic + on-demand sync
- Diff computation and conflict resolution (3 strategies)
- Store.Provider facade for config/status/conflict persistence
- Console pages for provider management
- Telemetry instrumentation

**Out of scope:**
- DNSSEC signing/validation of synced records
- Zone transfer (AXFR/IXFR) as a provider (existing `DNS.Zone.Transfer` handles this)
- Webhook-based event-driven sync (future enhancement)
- Provider-specific advanced features (Route 53 health checks, Cloudflare proxying, etc.)
