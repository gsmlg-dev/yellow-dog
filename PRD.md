# PRD: YellowDog DNS Server & Console Completion

## Executive Summary

This PRD outlines the complete implementation of the YellowDog DNS server and its web console management interface. The DNS server will support multiple zone types (authoritative, forward, stub, response policy), sophisticated view-based routing with ACL controls, configuration persistence to TOML files, hot-reload capabilities, comprehensive logging/metrics, and full E2E test coverage.

---

## 1. Goals & Success Criteria

### Primary Goals
1. Complete production-ready DNS server with full zone type support
2. Web console for comprehensive DNS management
3. Persistent configuration with hot-reload support
4. Observable operations via query logs, response logs, and metrics
5. Full E2E test coverage ensuring reliability

### Success Criteria
- DNS server handles all common record types (A, AAAA, CNAME, MX, TXT, SRV, PTR, NS, SOA)
- Views with ACL-based routing work correctly with custom CIDR rules
- All zone types function according to RFC specifications
- Configuration persists across restarts and supports hot-reload
- Console provides real-time visibility into DNS operations
- E2E tests achieve 100% coverage of critical paths

---

## 2. Architecture Overview

### Current State
```
YellowDog.Dns.Supervisor
├── YellowDog.Dns.Server (Abyss UDP/TCP)
├── YellowDog.Dns.ConnectionManager
├── YellowDog.Dns.ViewManager → View processes
├── YellowDog.Dns.ZoneController → Zone processes
├── YellowDog.Dns.AclRegistry
└── YellowDog.Dns.RateLimiter
```

### Target State Additions
```
YellowDog.Dns.Supervisor
├── ... (existing)
├── YellowDog.Dns.QueryLogger (new)
├── YellowDog.Dns.MetricsCollector (new)
└── YellowDog.Dns.ConfigWatcher (new - hot reload)
```

### Data Storage Layout
```
data/
└── dns/
    ├── views.toml                    # View definitions with ACLs
    ├── acls.toml                     # Named ACL definitions
    └── zones/
        ├── {view_name}/
        │   ├── zone_index.toml       # Zone registry for this view
        │   └── {zone_name}.toml      # Zone data (RRs)
        └── shared/                   # Cross-view shared zones
            └── {zone_name}.toml
```

---

## 3. Feature Specifications

### 3.1 DNS View Management

#### 3.1.1 View CRUD Operations

**Data Model:**
```elixir
%View{
  name: String.t(),           # Unique identifier (e.g., "internal", "external")
  enabled: boolean(),         # Active/inactive state
  priority: integer(),        # Lower = higher priority (0 = highest)
  acls: [String.t()],         # List of ACL names (evaluated in order)
  match_clients: [acl_rule()], # Inline ACL rules (legacy support)
  recursion_enabled: boolean(),
  fallback_forwarders: [ip_addr()],  # Forward on failure
  zones: [zone_ref()],        # Associated zones
  created_at: DateTime.t(),
  updated_at: DateTime.t()
}
```

**API Functions:**
```elixir
# YellowDog.Dns.ViewManager
create_view(name, opts) :: {:ok, View.t()} | {:error, reason}
update_view(name, opts) :: {:ok, View.t()} | {:error, :not_found | reason}
delete_view(name) :: :ok | {:error, :not_found | :is_default}
get_view(name) :: {:ok, View.t()} | {:error, :not_found}
list_views() :: [View.t()]
enable_view(name) :: :ok | {:error, reason}
disable_view(name) :: :ok | {:error, reason}
reload_view(name) :: :ok | {:error, reason}
```

**Constraints:**
- View names must be unique, alphanumeric with hyphens/underscores
- "default" view cannot be deleted (catch-all)
- Disabled views skip query matching but retain configuration
- At least one enabled view must exist

#### 3.1.2 View Enable/Disable

When a view is disabled:
- Removed from active query routing
- Configuration retained in persistence
- Statistics frozen (no new queries processed)
- Can be re-enabled instantly

Console UI:
- Toggle switch on view list
- Confirmation modal for disable action
- Visual indicator (badge) showing enabled/disabled state

#### 3.1.3 Fallback Forwarding

When a view fails to resolve a query (SERVFAIL, timeout, etc.), forward to configured backup nameservers.

**Configuration:**
```toml
[views.internal]
name = "internal"
enabled = true
priority = 10
fallback_forwarders = ["8.8.8.8", "8.8.4.4"]
fallback_timeout_ms = 2000
fallback_retry_count = 2
```

**Behavior:**
1. View attempts resolution via configured zones
2. On failure (SERVFAIL, NXDOMAIN with recursion, timeout):
   - Try first fallback forwarder
   - On failure, try next forwarder
   - Return first successful response or final error
3. Telemetry event: `[:yellow_dog, :dns, :view, :fallback_used]`

---

### 3.2 ACL Management

#### 3.2.1 Named ACL Registry

ACLs are managed centrally and referenced by name in views.

**Data Model:**
```elixir
%NamedAcl{
  name: String.t(),           # Unique identifier
  description: String.t(),
  rules: [acl_rule()],        # Ordered list of rules
  created_at: DateTime.t(),
  updated_at: DateTime.t()
}

# Rule types
@type acl_rule ::
  {:allow, :any} |
  {:deny, :any} |
  {:allow, {:cidr, String.t()}} |       # "192.168.1.0/24"
  {:deny, {:cidr, String.t()}} |
  {:allow, {:ip, tuple()}} |            # {192, 168, 1, 1}
  {:deny, {:ip, tuple()}} |
  {:allow, {:geo, [String.t()]}} |      # ["US", "CA"]
  {:deny, {:geo, [String.t()]}} |
  {:ref, String.t()}                    # Reference another ACL
```

**Built-in ACLs (immutable):**
- `any` - Matches all clients
- `none` - Matches no clients
- `localhost` - Matches 127.0.0.0/8, ::1
- `localnets` - Matches local network interfaces

**API Functions:**
```elixir
# YellowDog.Dns.AclRegistry
create_acl(name, rules, opts) :: {:ok, NamedAcl.t()} | {:error, reason}
update_acl(name, rules, opts) :: {:ok, NamedAcl.t()} | {:error, reason}
delete_acl(name) :: :ok | {:error, :not_found | :in_use | :builtin}
get_acl(name) :: {:ok, NamedAcl.t()} | {:error, :not_found}
list_acls() :: [NamedAcl.t()]
match_client(acl_name, client_ip) :: :allow | :deny | {:error, reason}
validate_rules(rules) :: :ok | {:error, [validation_error()]}
```

#### 3.2.2 Custom IP CIDR Support

CIDR notation parsing and matching:

```elixir
# Supported formats
"192.168.1.0/24"        # IPv4 with prefix
"10.0.0.0/8"            # Class A
"172.16.0.0/12"         # Class B private
"2001:db8::/32"         # IPv6
"fd00::/8"              # IPv6 ULA
"0.0.0.0/0"             # Match all IPv4
"::/0"                  # Match all IPv6
```

**Validation:**
- Parse and validate CIDR on input
- Reject invalid formats with clear error messages
- Support both IPv4 and IPv6
- Normalize representations (e.g., "192.168.001.000" → "192.168.1.0")

#### 3.2.3 View-ACL Association

Views reference ACLs by name:

```toml
[views.internal]
name = "internal"
acls = ["corporate-network", "vpn-clients", "localhost"]
```

**Matching Logic:**
1. For each ACL in order, evaluate rules
2. First matching rule (allow/deny) determines result
3. If no match in ACL, continue to next ACL
4. If no ACL matches, deny by default

---

### 3.3 Zone Types

#### 3.3.1 Authoritative Zone (type: "auth")

Primary DNS zone with full CRUD for resource records.

**Configuration:**
```toml
[zones."example.com"]
type = "auth"
view = "internal"
soa = { primary_ns = "ns1.example.com", admin = "admin.example.com", serial = 2024010101, refresh = 3600, retry = 600, expire = 604800, minimum = 300 }
default_ttl = 3600
dnssec_enabled = false
```

**Features:**
- Full RR CRUD (Create, Read, Update, Delete)
- Bulk import/export (BIND zone file format)
- Auto-increment SOA serial on changes
- AXFR/IXFR zone transfer support (future)
- DNSSEC signing (future)

#### 3.3.2 Forward Zone (type: "forward")

Forwards all queries for a domain to specified nameservers.

**Configuration:**
```toml
[zones."corp.internal"]
type = "forward"
view = "internal"
forwarders = ["10.0.0.53", "10.0.1.53"]
forward_only = true  # Don't recurse if forwarders fail
timeout_ms = 3000
```

**Features:**
- Round-robin or failover forwarder selection
- Configurable timeout per zone
- Optional caching of forwarded responses
- Forward-only vs. forward-first modes

#### 3.3.3 Stub Zone (type: "stub")

Maintains only NS records and glue, delegates resolution to authoritative servers.

**Configuration:**
```toml
[zones."partner.com"]
type = "stub"
view = "external"
masters = ["ns1.partner.com", "ns2.partner.com"]
refresh_interval = 3600
```

**Features:**
- Auto-fetches NS records from masters
- Periodic refresh of delegation info
- Minimal memory footprint
- Useful for delegation-only domains

#### 3.3.4 Response Policy Zone (type: "rpz")

Policy-based response modification for security/filtering.

**Configuration:**
```toml
[zones."rpz.local"]
type = "rpz"
view = "internal"
priority = 1  # Lower = evaluated first
policy_action = "nxdomain"  # nxdomain | nodata | passthru | drop | custom
```

**RPZ Actions:**
| Action | Description |
|--------|-------------|
| `nxdomain` | Return NXDOMAIN for matched queries |
| `nodata` | Return empty answer (NOERROR, no records) |
| `passthru` | Allow query to proceed normally |
| `drop` | Silently drop the query |
| `local` | Return custom local data |
| `redirect` | Redirect to specified IP |

**RPZ Triggers:**
- `qname` - Match query name
- `client-ip` - Match client IP
- `response-ip` - Match response IP (post-resolution)
- `nsdname` - Match authoritative NS name
- `nsip` - Match authoritative NS IP

---

### 3.4 Zone Data Persistence

#### 3.4.1 File Structure

```
data/dns/zones/
├── internal/                      # View: internal
│   ├── zone_index.toml           # Zone registry
│   ├── example.com.toml          # Auth zone data
│   ├── corp.internal.toml        # Forward zone config
│   └── rpz.local.toml            # RPZ rules
├── external/                      # View: external
│   ├── zone_index.toml
│   └── public.example.com.toml
└── shared/                        # Cross-view zones
    └── common-rpz.toml
```

#### 3.4.2 Zone Index Format

`zone_index.toml`:
```toml
# Zone registry for view: internal
version = 1
updated_at = "2024-01-15T10:30:00Z"

[[zones]]
name = "example.com"
type = "auth"
file = "example.com.toml"
enabled = true

[[zones]]
name = "corp.internal"
type = "forward"
file = "corp.internal.toml"
enabled = true
```

#### 3.4.3 Auth Zone Data Format

`example.com.toml`:
```toml
[meta]
zone = "example.com"
type = "auth"
serial = 2024011501
default_ttl = 3600

[soa]
primary_ns = "ns1.example.com"
admin = "hostmaster.example.com"
refresh = 3600
retry = 600
expire = 604800
minimum = 300

[[records]]
name = "@"
type = "NS"
ttl = 86400
data = "ns1.example.com."

[[records]]
name = "@"
type = "NS"
ttl = 86400
data = "ns2.example.com."

[[records]]
name = "@"
type = "A"
ttl = 3600
data = "192.168.1.10"

[[records]]
name = "www"
type = "CNAME"
ttl = 3600
data = "example.com."

[[records]]
name = "mail"
type = "MX"
ttl = 3600
data = { priority = 10, exchange = "mail.example.com." }

[[records]]
name = "@"
type = "TXT"
ttl = 3600
data = "v=spf1 include:_spf.example.com ~all"
```

#### 3.4.4 Forward Zone Format

`corp.internal.toml`:
```toml
[meta]
zone = "corp.internal"
type = "forward"

[config]
forwarders = ["10.0.0.53", "10.0.1.53"]
forward_only = true
timeout_ms = 3000
cache_responses = true
cache_ttl = 300
```

#### 3.4.5 RPZ Format

`rpz.local.toml`:
```toml
[meta]
zone = "rpz.local"
type = "rpz"
priority = 1

[policy]
default_action = "passthru"

[[rules]]
trigger = "qname"
match = "*.malware.example.com"
action = "nxdomain"

[[rules]]
trigger = "qname"
match = "ads.example.net"
action = "redirect"
redirect_to = "0.0.0.0"

[[rules]]
trigger = "response-ip"
match = "10.0.0.0/8"
action = "drop"
comment = "Block internal IPs in responses"
```

---

### 3.5 Resource Record Management

#### 3.5.1 Supported Record Types

| Type | Priority | Description |
|------|----------|-------------|
| A | P0 | IPv4 address |
| AAAA | P0 | IPv6 address |
| CNAME | P0 | Canonical name alias |
| MX | P0 | Mail exchange |
| TXT | P0 | Text record |
| NS | P0 | Name server |
| SOA | P0 | Start of authority |
| PTR | P0 | Pointer (reverse DNS) |
| SRV | P1 | Service location |
| CAA | P1 | Certificate authority authorization |
| DNSKEY | P2 | DNSSEC key |
| DS | P2 | Delegation signer |
| RRSIG | P2 | Resource record signature |
| NAPTR | P2 | Naming authority pointer |
| SSHFP | P2 | SSH fingerprint |
| TLSA | P2 | DANE TLSA |

#### 3.5.2 CRUD Operations

**API Functions:**
```elixir
# YellowDog.Dns.Zone.Auth
add_record(zone, record) :: {:ok, record_id} | {:error, reason}
update_record(zone, record_id, changes) :: {:ok, Record.t()} | {:error, reason}
delete_record(zone, record_id) :: :ok | {:error, reason}
get_record(zone, record_id) :: {:ok, Record.t()} | {:error, :not_found}
list_records(zone, opts \\ []) :: [Record.t()]

# Bulk operations
add_records(zone, [record]) :: {:ok, [record_id]} | {:error, reason, partial_ids}
delete_records(zone, [record_id]) :: {:ok, count} | {:error, reason}
import_zone_file(zone, bind_format_string) :: {:ok, stats} | {:error, reason}
export_zone_file(zone) :: {:ok, String.t()}
```

**Validation Rules:**
- CNAME cannot coexist with other records at same name (except DNSSEC)
- SOA and NS required at zone apex for auth zones
- MX data must include priority
- SRV data must include priority, weight, port
- TTL must be positive integer (0 allowed for volatile records)

#### 3.5.3 Bulk Operations

**Import from BIND format:**
```elixir
YellowDog.Dns.Zone.Auth.import_zone_file("example.com", """
$TTL 3600
@   IN  SOA   ns1.example.com. admin.example.com. (
              2024011501 ; serial
              3600       ; refresh
              600        ; retry
              604800     ; expire
              300 )      ; minimum
    IN  NS    ns1.example.com.
    IN  NS    ns2.example.com.
    IN  A     192.168.1.10
www IN  CNAME example.com.
""")
```

**Export to BIND format:**
```elixir
{:ok, zone_file} = YellowDog.Dns.Zone.Auth.export_zone_file("example.com")
# Returns RFC 1035 compliant zone file
```

**Bulk add via TOML:**
```elixir
records = [
  %{name: "app1", type: "A", ttl: 300, data: "192.168.1.20"},
  %{name: "app2", type: "A", ttl: 300, data: "192.168.1.21"},
  %{name: "app3", type: "A", ttl: 300, data: "192.168.1.22"}
]
YellowDog.Dns.Zone.Auth.add_records("example.com", records)
```

---

### 3.6 Query & Response Logging

#### 3.6.1 Query Logger

**Log Entry Structure:**
```elixir
%QueryLog{
  id: UUID.t(),
  timestamp: DateTime.t(),
  client_ip: tuple(),
  client_port: integer(),
  view: String.t(),
  qname: String.t(),
  qtype: atom(),
  qclass: atom(),
  protocol: :udp | :tcp,
  edns: boolean(),
  dnssec_ok: boolean(),
  response_code: atom(),   # :noerror, :nxdomain, :servfail, etc.
  response_time_us: integer(),
  answer_count: integer(),
  authority_count: integer(),
  additional_count: integer(),
  cache_hit: boolean(),
  zone_used: String.t() | nil,
  fallback_used: boolean(),
  error: String.t() | nil
}
```

**Configuration:**
```toml
[dns.logging]
enabled = true
log_queries = true
log_responses = true
log_level = "info"  # debug | info | warning | error
buffer_size = 1000  # In-memory buffer for console
persist_to_file = false
file_path = "logs/dns_queries.log"
rotation = "daily"
retention_days = 7
```

**API:**
```elixir
# YellowDog.Dns.QueryLogger
start_link(opts) :: GenServer.on_start()
log_query(query_log) :: :ok
get_recent_logs(limit \\ 100) :: [QueryLog.t()]
get_logs_by_client(ip, opts) :: [QueryLog.t()]
get_logs_by_view(view, opts) :: [QueryLog.t()]
get_logs_by_qname(pattern, opts) :: [QueryLog.t()]
clear_buffer() :: :ok
export_logs(path, opts) :: {:ok, count} | {:error, reason}
```

#### 3.6.2 Console Log Viewer

**Features:**
- Real-time log streaming via LiveView
- Filtering by: client IP, view, qname, qtype, response code
- Search with regex/glob patterns
- Time range selection
- Export to CSV/JSON
- Pause/resume streaming

**LiveView Implementation:**
- Subscribe to PubSub topic: `"dns:query_logs"`
- Circular buffer in assigns (configurable size)
- Virtual scrolling for performance
- Filter state in URL params (shareable)

---

### 3.7 Server Metrics

#### 3.7.1 Metrics Categories

**Server Metrics:**
| Metric | Type | Description |
|--------|------|-------------|
| `dns.queries.total` | Counter | Total queries received |
| `dns.queries.by_protocol` | Counter | Queries by UDP/TCP |
| `dns.queries.by_view` | Counter | Queries per view |
| `dns.queries.by_type` | Counter | Queries by record type |
| `dns.responses.by_code` | Counter | Responses by RCODE |
| `dns.response_time` | Histogram | Response latency (μs) |
| `dns.cache.hits` | Counter | Cache hit count |
| `dns.cache.misses` | Counter | Cache miss count |
| `dns.cache.size` | Gauge | Current cache entries |
| `dns.rate_limit.rejected` | Counter | Rate-limited queries |

**Zone Metrics:**
| Metric | Type | Description |
|--------|------|-------------|
| `dns.zone.records` | Gauge | Records per zone |
| `dns.zone.queries` | Counter | Queries per zone |
| `dns.zone.transfers` | Counter | Zone transfers (AXFR) |

**View Metrics:**
| Metric | Type | Description |
|--------|------|-------------|
| `dns.view.queries` | Counter | Queries per view |
| `dns.view.fallbacks` | Counter | Fallback forward count |
| `dns.view.cache_size` | Gauge | View cache size |

#### 3.7.2 Telemetry Events

```elixir
# Query received
:telemetry.execute(
  [:yellow_dog, :dns, :query, :received],
  %{count: 1},
  %{client_ip: ip, qname: name, qtype: type, protocol: proto}
)

# Response sent
:telemetry.execute(
  [:yellow_dog, :dns, :response, :sent],
  %{duration: microseconds, answer_count: n},
  %{client_ip: ip, qname: name, rcode: code, cache_hit: bool}
)

# Cache operation
:telemetry.execute(
  [:yellow_dog, :dns, :cache, :lookup],
  %{count: 1},
  %{view: view, hit: boolean}
)

# Fallback triggered
:telemetry.execute(
  [:yellow_dog, :dns, :view, :fallback],
  %{count: 1, forwarder: ip},
  %{view: view, qname: name, reason: reason}
)
```

#### 3.7.3 Console Metrics Dashboard

**Overview Cards:**
- Total queries (24h, trend indicator)
- Average response time (ms)
- Cache hit rate (%)
- Active zones count

**Charts:**
- Queries per second (real-time line chart)
- Response time distribution (histogram)
- Queries by type (pie chart)
- Response codes distribution (stacked bar)
- Top queried domains (table)
- Top clients (table)

**Implementation:**
- Use `phoenix_live_dashboard` integration
- Custom telemetry reporters for metrics
- ETS-based metrics aggregation
- 5-second refresh for real-time charts

---

### 3.8 Hot Reload

#### 3.8.1 Configuration Watcher

**Implementation:**
```elixir
defmodule YellowDog.Dns.ConfigWatcher do
  use GenServer

  # Watch data/dns/ directory for changes
  # Debounce rapid changes (500ms)
  # Validate before applying
  # Emit telemetry on reload
end
```

**Watched Files:**
- `data/dns/views.toml` → Reload views
- `data/dns/acls.toml` → Reload ACLs
- `data/dns/zones/{view}/*.toml` → Reload specific zones

**Reload Behavior:**
1. Detect file change (via `:fs` or polling)
2. Parse and validate new configuration
3. If valid, apply changes atomically
4. If invalid, log error and keep current config
5. Emit telemetry event with reload status

#### 3.8.2 Manual Reload API

```elixir
# YellowDog.Dns
reload_config() :: :ok | {:error, reason}
reload_views() :: :ok | {:error, reason}
reload_zones() :: :ok | {:error, reason}
reload_zone(view, zone_name) :: :ok | {:error, reason}
reload_acls() :: :ok | {:error, reason}
```

**Console Integration:**
- "Reload Configuration" button in DNS settings
- Status indicator showing last reload time
- Error display for failed reloads
- Diff view for pending changes (optional)

---

### 3.9 Console UI Specifications

#### 3.9.1 Navigation Structure

```
/dns
├── /dns                    # Overview dashboard
├── /dns/views              # View management
│   ├── /dns/views/new
│   ├── /dns/views/:name
│   └── /dns/views/:name/zones
│       ├── /dns/views/:name/zones/new
│       └── /dns/views/:name/zones/:zone_type/:zone_name
│           └── /dns/views/:name/zones/:zone_type/:zone_name/records
├── /dns/acls               # ACL management
│   ├── /dns/acls/new
│   └── /dns/acls/:name
├── /dns/logs               # Query/response logs
└── /dns/metrics            # Metrics dashboard
```

#### 3.9.2 View Management Page

**List View (`/dns/views`):**
```
┌─────────────────────────────────────────────────────────────────┐
│ DNS Views                                           [+ New View]│
├─────────────────────────────────────────────────────────────────┤
│ ┌─────────┬──────────┬────────┬──────────┬─────────┬─────────┐ │
│ │ Name    │ Priority │ ACLs   │ Zones    │ Status  │ Actions │ │
│ ├─────────┼──────────┼────────┼──────────┼─────────┼─────────┤ │
│ │internal │ 10       │ 3      │ 5        │ ●Active │ ⚙ ✎ 🗑  │ │
│ │external │ 20       │ 2      │ 3        │ ●Active │ ⚙ ✎ 🗑  │ │
│ │default  │ ∞        │ 1(any) │ 1        │ ●Active │ ⚙ ✎    │ │
│ └─────────┴──────────┴────────┴──────────┴─────────┴─────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**View Detail/Edit (`/dns/views/:name`):**
```
┌─────────────────────────────────────────────────────────────────┐
│ ← Views / internal                                              │
├─────────────────────────────────────────────────────────────────┤
│ General Settings                                                │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ Name: [internal        ]  Priority: [10  ]                  │ │
│ │ Enabled: [✓]              Recursion: [✓]                    │ │
│ └─────────────────────────────────────────────────────────────┘ │
│                                                                 │
│ Access Control Lists                               [+ Add ACL] │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ 1. corporate-network    [↑] [↓] [×]                         │ │
│ │ 2. vpn-clients          [↑] [↓] [×]                         │ │
│ │ 3. localhost            [↑] [↓] [×]                         │ │
│ └─────────────────────────────────────────────────────────────┘ │
│                                                                 │
│ Fallback Forwarders                           [+ Add Forwarder]│
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ 1. 8.8.8.8              [×]                                 │ │
│ │ 2. 8.8.4.4              [×]                                 │ │
│ └─────────────────────────────────────────────────────────────┘ │
│ Timeout: [2000 ] ms   Retries: [2 ]                            │
│                                                                 │
│                                        [Cancel] [Save Changes] │
└─────────────────────────────────────────────────────────────────┘
```

#### 3.9.3 ACL Management Page

**List View (`/dns/acls`):**
```
┌─────────────────────────────────────────────────────────────────┐
│ Access Control Lists                                [+ New ACL]│
├─────────────────────────────────────────────────────────────────┤
│ Built-in ACLs (read-only)                                       │
│ ┌─────────┬──────────────────────────────┬───────────────────┐ │
│ │ any     │ Matches all clients          │ System            │ │
│ │ none    │ Matches no clients           │ System            │ │
│ │ local.. │ Matches 127.0.0.0/8, ::1     │ System            │ │
│ │ local.. │ Matches local interfaces     │ System            │ │
│ └─────────┴──────────────────────────────┴───────────────────┘ │
│                                                                 │
│ Custom ACLs                                                     │
│ ┌─────────────────┬─────────────────┬───────────┬───────────┐ │
│ │ Name            │ Description     │ Rules     │ Used By   │ │
│ ├─────────────────┼─────────────────┼───────────┼───────────┤ │
│ │ corporate-net   │ Corp networks   │ 4 rules   │ 2 views   │ │
│ │ vpn-clients     │ VPN IP ranges   │ 2 rules   │ 1 view    │ │
│ │ blocked-ranges  │ Blocked IPs     │ 12 rules  │ 0 views   │ │
│ └─────────────────┴─────────────────┴───────────┴───────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**ACL Editor (`/dns/acls/:name`):**
```
┌─────────────────────────────────────────────────────────────────┐
│ ← ACLs / corporate-network                                      │
├─────────────────────────────────────────────────────────────────┤
│ Name: [corporate-network ]                                      │
│ Description: [Corporate office and datacenter networks       ]  │
│                                                                 │
│ Rules (evaluated in order)                          [+ Add Rule]│
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ 1. [Allow ▼] [CIDR ▼] [192.168.0.0/16  ]    [↑] [↓] [×]    │ │
│ │ 2. [Allow ▼] [CIDR ▼] [10.0.0.0/8      ]    [↑] [↓] [×]    │ │
│ │ 3. [Deny  ▼] [CIDR ▼] [10.99.0.0/16    ]    [↑] [↓] [×]    │ │
│ │ 4. [Allow ▼] [Geo  ▼] [US, CA          ]    [↑] [↓] [×]    │ │
│ └─────────────────────────────────────────────────────────────┘ │
│                                                                 │
│ Test ACL: [Enter IP address    ] [Test]                         │
│ Result: ✓ ALLOW (matched rule 1: 192.168.0.0/16)               │
│                                                                 │
│ Used by views: internal, dmz                                    │
│                                                                 │
│                                        [Cancel] [Save Changes] │
└─────────────────────────────────────────────────────────────────┘
```

#### 3.9.4 Zone Management

**Zone List (`/dns/views/:name/zones`):**
```
┌─────────────────────────────────────────────────────────────────┐
│ ← Views / internal / Zones                          [+ New Zone]│
├─────────────────────────────────────────────────────────────────┤
│ ┌────────────────┬──────┬─────────┬─────────┬────────┬───────┐ │
│ │ Zone           │ Type │ Records │ Queries │ Status │ Action│ │
│ ├────────────────┼──────┼─────────┼─────────┼────────┼───────┤ │
│ │ example.com    │ Auth │ 24      │ 1.2k    │ ●Ok    │ ⚙ ✎ 🗑│ │
│ │ corp.internal  │ Fwd  │ -       │ 456     │ ●Ok    │ ⚙ ✎ 🗑│ │
│ │ partner.com    │ Stub │ 2 NS    │ 89      │ ●Ok    │ ⚙ ✎ 🗑│ │
│ │ rpz.local      │ RPZ  │ 156     │ 12.5k   │ ●Ok    │ ⚙ ✎ 🗑│ │
│ └────────────────┴──────┴─────────┴─────────┴────────┴───────┘ │
└─────────────────────────────────────────────────────────────────┘
```

**Zone Detail - Auth Zone (`/dns/views/:name/zones/auth/:zone_name`):**
```
┌─────────────────────────────────────────────────────────────────┐
│ ← Zones / example.com                                           │
├─────────────────────────────────────────────────────────────────┤
│ Zone: example.com                    Type: Authoritative        │
│ Serial: 2024011501                   Default TTL: 3600          │
│                                                                 │
│ SOA Record                                                      │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ Primary NS: ns1.example.com.  Admin: admin@example.com      │ │
│ │ Refresh: 3600  Retry: 600  Expire: 604800  Minimum: 300     │ │
│ └─────────────────────────────────────────────────────────────┘ │
│                                                                 │
│ Resource Records                [Import] [Export] [+ Add Record]│
│ Filter: [         ] Type: [All ▼]  [Search]                    │
│ ┌──────┬──────┬──────┬────────────────────────────┬───────────┐│
│ │ Name │ Type │ TTL  │ Data                       │ Actions   ││
│ ├──────┼──────┼──────┼────────────────────────────┼───────────┤│
│ │ @    │ NS   │ 86400│ ns1.example.com.           │ ✎ 🗑      ││
│ │ @    │ NS   │ 86400│ ns2.example.com.           │ ✎ 🗑      ││
│ │ @    │ A    │ 3600 │ 192.168.1.10               │ ✎ 🗑      ││
│ │ @    │ MX   │ 3600 │ 10 mail.example.com.       │ ✎ 🗑      ││
│ │ www  │ CNAME│ 3600 │ example.com.               │ ✎ 🗑      ││
│ │ mail │ A    │ 3600 │ 192.168.1.20               │ ✎ 🗑      ││
│ └──────┴──────┴──────┴────────────────────────────┴───────────┘│
│ Showing 1-6 of 24 records                    [< 1 2 3 4 5 >]   │
│                                                                 │
│ Bulk Actions: [Select All] Selected: 0   [Delete Selected]     │
└─────────────────────────────────────────────────────────────────┘
```

**Add Record Modal:**
```
┌─────────────────────────────────────────────────────────────────┐
│ Add Resource Record                                         [×] │
├─────────────────────────────────────────────────────────────────┤
│ Name: [              ] .example.com                             │
│ Type: [A            ▼]                                          │
│ TTL:  [3600          ] seconds                                  │
│                                                                 │
│ ── A Record Data ──                                             │
│ IPv4 Address: [                 ]                               │
│                                                                 │
│ [Add Another] [Cancel] [Add Record]                             │
└─────────────────────────────────────────────────────────────────┘
```

**Bulk Import Modal:**
```
┌─────────────────────────────────────────────────────────────────┐
│ Import Zone Records                                         [×] │
├─────────────────────────────────────────────────────────────────┤
│ Paste BIND zone file format:                                    │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ $TTL 3600                                                   │ │
│ │ www    IN  A     192.168.1.100                              │ │
│ │ api    IN  A     192.168.1.101                              │ │
│ │ db     IN  A     192.168.1.102                              │ │
│ │ cache  IN  CNAME api.example.com.                           │ │
│ │                                                             │ │
│ └─────────────────────────────────────────────────────────────┘ │
│                                                                 │
│ Or upload file: [Choose File] No file selected                  │
│                                                                 │
│ Options:                                                        │
│ [✓] Validate before import                                      │
│ [ ] Replace existing records with same name/type                │
│                                                                 │
│ Preview: 4 records to add, 0 conflicts                          │
│                                                                 │
│                                        [Cancel] [Import Records]│
└─────────────────────────────────────────────────────────────────┘
```

#### 3.9.5 Query Logs Page

**Log Viewer (`/dns/logs`):**
```
┌─────────────────────────────────────────────────────────────────┐
│ DNS Query Logs                              [▶ Live] [⏸ Pause] │
├─────────────────────────────────────────────────────────────────┤
│ Filters:                                                        │
│ View: [All ▼]  Type: [All ▼]  Response: [All ▼]                │
│ Client IP: [          ]  Query Name: [              ] [Apply]  │
│ Time Range: [Last 1 hour ▼]                          [Clear]   │
├─────────────────────────────────────────────────────────────────┤
│ ┌───────────┬────────────┬───────┬─────┬──────────┬──────┬────┐│
│ │ Timestamp │ Client     │ Query │ Type│ Response │ Time │View││
│ ├───────────┼────────────┼───────┼─────┼──────────┼──────┼────┤│
│ │ 10:45:23  │ 192.168.1.5│ www.. │ A   │ NOERROR  │ 2ms  │int ││
│ │ 10:45:22  │ 192.168.1.8│ mail. │ MX  │ NOERROR  │ 5ms  │int ││
│ │ 10:45:22  │ 10.0.0.15  │ api.. │ A   │ NXDOMAIN │ 1ms  │ext ││
│ │ 10:45:21  │ 192.168.1.5│ ns1.. │ A   │ NOERROR  │ 45ms │int ││
│ │ 10:45:20  │ 172.16.0.9 │ bad.. │ A   │ REFUSED  │ 0ms  │-   ││
│ └───────────┴────────────┴───────┴─────┴──────────┴──────┴────┘│
│ Showing 50 of 1,234 entries                   [Export CSV/JSON] │
└─────────────────────────────────────────────────────────────────┘
```

#### 3.9.6 Metrics Dashboard

**DNS Metrics (`/dns/metrics`):**
```
┌─────────────────────────────────────────────────────────────────┐
│ DNS Metrics                                    [Refresh: 5s ▼]  │
├─────────────────────────────────────────────────────────────────┤
│ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐│
│ │ Queries/24h │ │ Avg Latency │ │ Cache Hit % │ │ Active Zones││
│ │   125.4k    │ │    4.2ms    │ │    87.3%    │ │     12      ││
│ │  ↑ +12.5%   │ │  ↓ -0.8ms   │ │  ↑ +2.1%    │ │             ││
│ └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘│
│                                                                 │
│ Queries Per Second (Real-time)                                  │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │     ╭──╮      ╭───╮                                         │ │
│ │ 100─┤  ╰──────╯   ╰─────╮     ╭─────╮                       │ │
│ │  50─┤                   ╰─────╯     ╰───────                │ │
│ │   0─┴───────────────────────────────────────────────────    │ │
│ │     10:40  10:41  10:42  10:43  10:44  10:45               │ │
│ └─────────────────────────────────────────────────────────────┘ │
│                                                                 │
│ ┌─────────────────────────┐ ┌─────────────────────────────────┐│
│ │ Response Codes          │ │ Query Types                     ││
│ │ ┌─────────────────────┐ │ │ ┌─────────────────────────────┐ ││
│ │ │ ████████ NOERROR 85%│ │ │ │ A     ████████████████ 65%  │ ││
│ │ │ ██ NXDOMAIN 12%     │ │ │ │ AAAA  ████████ 25%          │ ││
│ │ │ █ SERVFAIL 2%       │ │ │ │ MX    ██ 5%                 │ ││
│ │ │ REFUSED 1%          │ │ │ │ Other █ 5%                  │ ││
│ │ └─────────────────────┘ │ │ └─────────────────────────────┘ ││
│ └─────────────────────────┘ └─────────────────────────────────┘│
│                                                                 │
│ Top Queried Domains                 Top Clients                 │
│ ┌───────────────────────────┐ ┌───────────────────────────────┐│
│ │ 1. www.example.com  12.5k │ │ 1. 192.168.1.5      8.2k     ││
│ │ 2. api.example.com  8.3k  │ │ 2. 192.168.1.8      6.1k     ││
│ │ 3. mail.example.com 5.1k  │ │ 3. 10.0.0.15        4.5k     ││
│ │ 4. ns1.example.com  2.4k  │ │ 4. 172.16.0.9       3.2k     ││
│ │ 5. cdn.example.com  1.8k  │ │ 5. 192.168.1.100    2.8k     ││
│ └───────────────────────────┘ └───────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

---

### 3.10 E2E Test Specifications

#### 3.10.1 Test Categories

**Category 1: Server Lifecycle**
- Server starts with valid configuration
- Server handles graceful shutdown
- Server recovers from configuration errors
- Hot reload applies changes correctly

**Category 2: View Routing**
- Client matches correct view by ACL
- Priority ordering works correctly
- Disabled views are skipped
- Default view catches unmatched clients

**Category 3: ACL Matching**
- IPv4 CIDR matching
- IPv6 CIDR matching
- Built-in ACLs (any, none, localhost, localnets)
- Geo-based ACLs (if enabled)
- Rule ordering (first match wins)
- Nested ACL references

**Category 4: Zone Types**
- Authoritative zone resolves correctly
- Forward zone forwards queries
- Stub zone maintains NS delegation
- RPZ blocks/redirects as configured

**Category 5: Resource Records**
- All supported record types resolve correctly
- CNAME following works
- Wildcards match correctly
- Negative caching (NXDOMAIN)

**Category 6: Caching**
- Positive cache works (TTL respected)
- Negative cache works (SOA minimum)
- Cache eviction on memory pressure
- Cache flush API works

**Category 7: Fallback Forwarding**
- Fallback triggers on zone failure
- Multiple forwarders tried in order
- Timeout respected
- Success after fallback logged

**Category 8: Persistence**
- Configuration loads on startup
- Changes persist across restarts
- Invalid config rejected with error
- Hot reload applies file changes

#### 3.10.2 Test File Structure

```
e2e_test/
├── dns_e2e_test.exs               # Existing basic tests
├── dns_view_e2e_test.exs          # View routing tests
├── dns_acl_e2e_test.exs           # ACL matching tests
├── dns_zone_auth_e2e_test.exs     # Auth zone tests
├── dns_zone_forward_e2e_test.exs  # Forward zone tests
├── dns_zone_stub_e2e_test.exs     # Stub zone tests
├── dns_zone_rpz_e2e_test.exs      # RPZ tests
├── dns_cache_e2e_test.exs         # Caching tests
├── dns_fallback_e2e_test.exs      # Fallback forwarding tests
├── dns_persistence_e2e_test.exs   # Config persistence tests
├── dns_records_e2e_test.exs       # RR CRUD tests
└── support/
    ├── dns_test_helper.ex         # DNS-specific helpers
    └── zone_fixtures.ex           # Test zone data
```

#### 3.10.3 Sample Test Cases

```elixir
# dns_view_e2e_test.exs
defmodule YellowDog.Dns.ViewE2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag :dns

  alias E2ETest.Support.{ServiceHelper, DnsClient}

  setup do
    config = %{
      views: [
        %{name: "internal", priority: 10, acls: ["192.168.0.0/24"]},
        %{name: "external", priority: 20, acls: ["any"]},
        %{name: "default", priority: :infinity, acls: ["any"]}
      ],
      zones: [
        %{view: "internal", name: "example.com", type: :auth,
          records: [%{name: "@", type: :A, data: "192.168.1.10"}]},
        %{view: "external", name: "example.com", type: :auth,
          records: [%{name: "@", type: :A, data: "203.0.113.10"}]}
      ]
    }

    {:ok, ctx} = ServiceHelper.start_dns_server(config: config)
    on_exit(fn -> ServiceHelper.stop_service(ctx) end)
    {:ok, ctx}
  end

  test "internal client gets internal zone response", ctx do
    # Query from 192.168.0.100 (matches internal view)
    {:ok, response} = DnsClient.query(
      ctx.host, ctx.port, "example.com", :A,
      source_ip: {192, 168, 0, 100}
    )

    assert response.answers == [{:A, "192.168.1.10"}]
  end

  test "external client gets external zone response", ctx do
    # Query from 8.8.8.8 (matches external view)
    {:ok, response} = DnsClient.query(
      ctx.host, ctx.port, "example.com", :A,
      source_ip: {8, 8, 8, 8}
    )

    assert response.answers == [{:A, "203.0.113.10"}]
  end

  test "disabled view is skipped", ctx do
    # Disable internal view
    :ok = YellowDog.Dns.ViewManager.disable_view("internal")

    # Query from internal IP should now match external
    {:ok, response} = DnsClient.query(
      ctx.host, ctx.port, "example.com", :A,
      source_ip: {192, 168, 0, 100}
    )

    assert response.answers == [{:A, "203.0.113.10"}]
  end
end
```

```elixir
# dns_zone_rpz_e2e_test.exs
defmodule YellowDog.Dns.ZoneRpzE2ETest do
  use ExUnit.Case, async: false

  @moduletag :e2e
  @moduletag :dns

  alias E2ETest.Support.{ServiceHelper, DnsClient}

  setup do
    config = %{
      views: [%{name: "default", acls: ["any"]}],
      zones: [
        %{view: "default", name: "example.com", type: :auth,
          records: [
            %{name: "@", type: :A, data: "192.168.1.10"},
            %{name: "blocked", type: :A, data: "192.168.1.99"}
          ]},
        %{view: "default", name: "rpz.local", type: :rpz,
          priority: 1,
          rules: [
            %{trigger: :qname, match: "blocked.example.com", action: :nxdomain},
            %{trigger: :qname, match: "*.malware.com", action: :nxdomain}
          ]}
      ]
    }

    {:ok, ctx} = ServiceHelper.start_dns_server(config: config)
    on_exit(fn -> ServiceHelper.stop_service(ctx) end)
    {:ok, ctx}
  end

  test "RPZ blocks query with NXDOMAIN", ctx do
    {:ok, response} = DnsClient.query(
      ctx.host, ctx.port, "blocked.example.com", :A
    )

    assert response.rcode == :nxdomain
    assert response.answers == []
  end

  test "RPZ allows non-blocked query", ctx do
    {:ok, response} = DnsClient.query(
      ctx.host, ctx.port, "example.com", :A
    )

    assert response.rcode == :noerror
    assert response.answers == [{:A, "192.168.1.10"}]
  end

  test "RPZ wildcard blocks subdomains", ctx do
    {:ok, response} = DnsClient.query(
      ctx.host, ctx.port, "anything.malware.com", :A
    )

    assert response.rcode == :nxdomain
  end
end
```

---

## 4. Implementation Phases

### Phase 1: Core DNS Completion (2-3 weeks)

**Week 1:**
- [ ] Complete Zone type implementations (Auth, Forward, Stub, RPZ)
- [ ] Implement zone data persistence to TOML
- [ ] Add zone CRUD operations with validation
- [ ] Implement resource record CRUD with bulk operations

**Week 2:**
- [ ] Enhance ACL system with full CIDR support
- [ ] Implement named ACL registry
- [ ] Add view enable/disable functionality
- [ ] Implement fallback forwarding

**Week 3:**
- [ ] Add QueryLogger with configurable buffer
- [ ] Implement MetricsCollector with telemetry
- [ ] Add ConfigWatcher for hot reload
- [ ] Write unit tests for new components

### Phase 2: Console Implementation (2-3 weeks)

**Week 4:**
- [ ] Create DNS overview dashboard
- [ ] Implement View management pages (list, create, edit)
- [ ] Add ACL management pages
- [ ] Connect to DNS service APIs

**Week 5:**
- [ ] Implement Zone management for all types
- [ ] Add Resource Record editor with bulk import
- [ ] Create zone file import/export
- [ ] Add real-time validation

**Week 6:**
- [ ] Build Query Logs viewer with streaming
- [ ] Implement Metrics dashboard with charts
- [ ] Add configuration reload UI
- [ ] Polish UI/UX and error handling

### Phase 3: Testing & Polish (1-2 weeks)

**Week 7:**
- [ ] Write comprehensive E2E tests
- [ ] Performance testing and optimization
- [ ] Documentation updates
- [ ] Bug fixes from testing

**Week 8 (if needed):**
- [ ] Additional edge case testing
- [ ] Security review
- [ ] Final polish and release prep

---

## 5. Technical Considerations

### 5.1 Performance

- ETS tables for hot data (cache, active zones)
- Lazy loading of zone data from TOML
- Connection pooling for forwarders
- Rate limiting to prevent DoS
- Batch telemetry event processing

### 5.2 Security

- ACL validation prevents open resolver
- Rate limiting per client IP
- RPZ for threat protection
- Input validation on all configuration
- Secure defaults (recursion disabled by default)

### 5.3 Reliability

- Supervisor trees for fault tolerance
- Graceful degradation on component failure
- Transaction-like config updates (validate before apply)
- Automatic recovery on parse errors

### 5.4 Observability

- Telemetry events for all operations
- Structured logging with correlation IDs
- Prometheus metrics export (future)
- Health check endpoints

---

## 6. Dependencies

### New Dependencies (if any)

| Package | Version | Purpose |
|---------|---------|---------|
| `:fs` | ~> 8.0 | File system watching for hot reload |
| `:contex` | ~> 0.5 | SVG chart generation for metrics (optional) |

### Existing Dependencies

- `ex_dns` - DNS protocol (in umbrella)
- `abyss` - UDP server (in umbrella)
- `toml` - Configuration parsing
- `phoenix_live_view` - Console UI
- `telemetry` - Metrics/events

---

## 7. Open Questions

1. **DNSSEC Support**: Should Phase 1 include DNSSEC signing, or defer to future?
   - Recommendation: Defer DNSSEC to Phase 2/3

2. **Zone Transfer (AXFR/IXFR)**: Required for multi-server deployments
   - Recommendation: Defer to future phase

3. **Geo-IP Database**: Built-in or external service?
   - Recommendation: Optional integration with MaxMind GeoLite2

4. **Metrics Storage**: In-memory only or persist to time-series DB?
   - Recommendation: In-memory with optional Prometheus export

5. **Multi-tenancy**: Support for multiple organizations?
   - Recommendation: Out of scope for Phase 1

---

## 8. Appendices

### A. TOML Schema Reference

See Section 3.4 for complete TOML file formats.

### B. API Reference

All API functions documented in Section 3.x with type specs.

### C. Telemetry Events Reference

See Section 3.7.2 for complete telemetry event specifications.

### D. Console Component Reference

Uses existing DaisyUI components from `YellowDog.Console.CoreComponents`:
- `stat`, `badge`, `card`, `modal`, `table`, `progress`, `status_indicator`, `toast`, `loading`

---

## Changelog

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2024-02-07 | Claude | Initial PRD creation |
