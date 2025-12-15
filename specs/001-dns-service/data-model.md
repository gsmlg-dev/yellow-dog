# Data Model: DNS Service Implementation Fix and Dashboard Service Controls

**Branch**: `001-dns-service` | **Date**: 2025-12-10

## Entities

### 1. Service Status

**Description**: Represents the runtime state of a YellowDog service.

**Source**: `YellowDog.ServiceManager.get_service_status/1`

| Field | Type | Description | Validation |
|-------|------|-------------|------------|
| `key` | `atom` | Service identifier | One of: `:dns`, `:mdns`, `:dhcpv4`, `:dhcpv6` |
| `name` | `string` | Display name | Non-empty string |
| `enabled` | `boolean` | Configuration enabled | true/false |
| `running` | `boolean` | Process running | true/false |
| `uptime` | `string \| nil` | Formatted uptime | e.g., "1h 23m 45s" or nil if stopped |
| `config` | `map` | Service configuration | Contains `listen`, `port`, etc. |
| `stats` | `map \| nil` | Service-specific statistics | Varies by service type |
| `error` | `string \| nil` | Last error message | nil if no error |

**State Transitions**:
```
┌─────────────┐     start_service()      ┌─────────────┐
│   Stopped   │ ────────────────────────►│   Running   │
│  enabled=?  │                          │  enabled=T  │
│  running=F  │ ◄────────────────────────│  running=T  │
└─────────────┘     stop_service()       └─────────────┘
       │                                        │
       │ (error during start)                   │ (crash)
       ▼                                        ▼
┌─────────────┐                          ┌─────────────┐
│   Error     │                          │   Error     │
│  enabled=T  │                          │  enabled=T  │
│  running=F  │                          │  running=F  │
│  error=msg  │                          │  error=msg  │
└─────────────┘                          └─────────────┘
```

---

### 2. DNS Supervisor Children

**Description**: Child processes managed by DNS supervisor.

| Child | Module | ID | Purpose | Restart Strategy |
|-------|--------|-----|---------|------------------|
| Zone Manager | `YellowDog.Dns.Zone.Manager` | `:zone_manager` | Zone file management | `:permanent` |
| Cache Manager | `YellowDog.Dns.Query.Cache.Manager` | `:cache_manager` | Query cache | `:permanent` |
| Cache Cleaner | `YellowDog.Dns.Query.Cache.Cleaner` | `:cache_cleaner` | Cache expiration | `:permanent` |
| Root Zone Manager | `YellowDog.Dns.RootZone.Manager` | `:root_zone_manager` | Root hints | `:permanent` |
| View Manager | `YellowDog.Dns.View.Manager` | `:view_manager` | DNS views (NEW) | `:permanent` |
| Config Watcher | `YellowDog.Dns.View.ConfigWatcher` | `:config_watcher` | Config reload (NEW) | `:transient` |
| Server | `YellowDog.Dns.Server` | `:server` | UDP server | `:permanent` |

**Dependency Order**:
1. Zone Manager (no dependencies)
2. Cache Manager (no dependencies)
3. Cache Cleaner (depends on Cache Manager)
4. Root Zone Manager (no dependencies)
5. View Manager (depends on Zone Manager) ← NEW
6. Config Watcher (depends on View Manager) ← NEW
7. Server (depends on all above)

---

### 3. Dashboard Socket Assigns

**Description**: LiveView socket assigns for dashboard state.

| Assign | Type | Description | Initial Value |
|--------|------|-------------|---------------|
| `services` | `list(map)` | List of service status maps | `get_service_status()` result |
| `current_user` | `map \| nil` | Current user (if auth enabled) | nil |
| `flash` | `map` | Flash messages | `%{}` |

---

### 4. DNS Handler State

**Description**: State maintained by DNS UDP handler.

**Current (Broken)**:
| Field | Type | Description |
|-------|------|-------------|
| `view_manager_pid` | `pid` | ViewManager PID (inline created) |
| `config_watcher_pid` | `pid \| nil` | ConfigWatcher PID (inline created) |

**Proposed (Fixed)**:
| Field | Type | Description |
|-------|------|-------------|
| `view_manager` | `atom` | ViewManager process name |
| (removed) | - | ConfigWatcher managed by supervisor |

---

## Relationships

```
┌─────────────────────────────────────────────────────────────┐
│                    YellowDog.Application                     │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Enabled Services Filter                 │   │
│  │  [DNS, mDNS, DHCPv4, DHCPv6] → filter by config     │   │
│  └─────────────────────────────────────────────────────┘   │
│                            │                                │
│            ┌───────────────┼───────────────┐               │
│            ▼               ▼               ▼               │
│     ┌─────────────┐ ┌─────────────┐ ┌─────────────┐       │
│     │ DNS         │ │ mDNS        │ │ DHCPv4      │       │
│     │ Supervisor  │ │ Supervisor  │ │ Supervisor  │       │
│     └─────────────┘ └─────────────┘ └─────────────┘       │
│            │                                                │
│            ▼                                                │
│     ┌─────────────────────────────────────────┐           │
│     │         DNS Supervisor Children          │           │
│     │                                          │           │
│     │  ┌──────────────┐  ┌──────────────┐    │           │
│     │  │ Zone.Manager │  │ Cache.Manager│    │           │
│     │  └──────────────┘  └──────────────┘    │           │
│     │  ┌──────────────┐  ┌──────────────┐    │           │
│     │  │Cache.Cleaner │  │RootZone.Mgr  │    │           │
│     │  └──────────────┘  └──────────────┘    │           │
│     │  ┌──────────────┐  ┌──────────────┐    │           │
│     │  │ View.Manager │  │ConfigWatcher │    │  ← NEW    │
│     │  └──────────────┘  └──────────────┘    │           │
│     │  ┌──────────────┐                      │           │
│     │  │    Server    │                      │           │
│     │  └──────────────┘                      │           │
│     └─────────────────────────────────────────┘           │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                       Web Console                            │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                  DashboardLive                       │   │
│  │                                                      │   │
│  │  assigns:                                            │   │
│  │    services: [                                       │   │
│  │      %{key: :dns, running: true, ...},              │   │
│  │      %{key: :mdns, running: true, ...},             │   │
│  │      ...                                             │   │
│  │    ]                                                 │   │
│  │                                                      │   │
│  │  Events:                                             │   │
│  │    "start_service" → YellowDog.start_service/1      │   │
│  │    "stop_service"  → YellowDog.stop_service/1       │   │
│  └─────────────────────────────────────────────────────┘   │
│                            │                                │
│                            ▼                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              YellowDog.ServiceManager                │   │
│  │                                                      │   │
│  │  start_service(service)                             │   │
│  │    1. Config.set_service_enabled(service, true)     │   │
│  │    2. Application.start_service_supervisor()        │   │
│  │                                                      │   │
│  │  stop_service(service)                              │   │
│  │    1. Config.set_service_enabled(service, false)    │   │
│  │    2. Application.stop_service_supervisor()         │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## Validation Rules

### Service Control Validation

| Rule | Validation | Error Response |
|------|------------|----------------|
| Valid service atom | Must be in `[:dns, :mdns, :dhcpv4, :dhcpv6]` | `{:error, :invalid_service}` |
| Service not already running | Check before start | `{:error, {:already_started, pid}}` |
| Service is running | Check before stop | `{:error, :not_running}` |
| Port available | System check on start | `{:error, :port_in_use}` |
| Privileges | For port 53 | `{:error, :permission_denied}` |

### DNS Supervisor Child Validation

| Rule | Validation | Error Response |
|------|------------|----------------|
| Child spec valid | Pattern match | `{:error, :invalid_child_spec}` |
| Unique child IDs | No duplicates | `{:error, :duplicate_child_id}` |
| Dependencies available | Process registered | Wait/retry or error |

---

## State Persistence

| Entity | Storage | Persistence |
|--------|---------|-------------|
| Service Status | Memory (ETS/Agent) | Runtime only |
| Service Config | Agent + TOML file | Persisted on change |
| DNS Zones | ETS + Zone files | File-backed |
| DNS Cache | ETS | Runtime only (expires) |
| View Manager | ETS | Runtime only |
