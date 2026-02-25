# YellowDog Resolved PRD

## Overview

`yellow_dog_resolved` is a standalone DNS stub resolver daemon that replaces `systemd-resolved`. It listens on `127.0.0.1:53`, intercepts queries matching configurable domain rules, and forwards everything else to upstream DNS servers. Optionally, if an upstream is a YellowDog DNS instance, the resolver auto-discovers and connects via WebSocket for remote management (cache flush, stats).

**Context:** YellowDog provides DNS/DHCP/mDNS network services. `yellow_dog_resolved` is the client-side counterpart — a lightweight local resolver deployed on workstations and servers that want custom DNS interception with optional centralized management.

**App name:** `yellow_dog_resolved`
**Location:** `apps/yellow_dog_resolved/` in the YellowDog umbrella
**Dependencies:** `ex_dns`, `abyss`
**No dependency on:** `yellow_dog_console`, `yellow_dog_telemetry`, Phoenix, LiveView

## Design Principles

- **Standalone** — Deployable independently from the umbrella; no Phoenix or GUI dependencies
- **Zero-config management** — If upstream is YellowDog DNS, management connection auto-discovers via EDNS; no manual endpoint configuration
- **Offline resilient** — Always functional with local TOML config; management connection is optional enhancement
- **Minimal surface** — Intercept, forward, cache. Nothing else.
- **Observable** — Telemetry events emitted for all operations; no listeners required but available if running in umbrella

## Architecture

```
                        ┌─────────────────────────────────────────────┐
                        │           yellow_dog_resolved               │
                        │                                             │
  Application           │  ┌───────────┐    ┌──────────────────────┐  │
  (dig, curl,    ──UDP──┼─▶│  Listener  │───▶│   Query Router       │  │
   browser)      :53    │  │  (Abyss)   │    │                      │  │
                        │  └───────────┘    │  ┌────────────────┐  │  │
                        │                    │  │ Intercept Rules│  │  │
                        │                    │  │ (*.local.dev)  │──┼──┼──▶ Static response
                        │                    │  └────────────────┘  │  │
                        │                    │                      │  │
                        │                    │  ┌────────────────┐  │  │
                        │  ┌───────────┐    │  │    Cache        │  │  │
                        │  │ Upstream   │◀───┼──│  (ETS + TTL)   │──┼──┼──▶ Cached response
                        │  │ Forwarder  │    │  └────────────────┘  │  │
                        │  │(Abyss.Client)   │                      │  │
                        │  └─────┬─────┘    │  ┌────────────────┐  │  │
                        │        │           │  │   Forward      │──┼──┼──▶ Upstream query
                        │        │           │  └────────────────┘  │  │
                        │        │           └──────────────────────┘  │
                        │        │                                     │
                        │        ▼                                     │
                        │  ┌───────────────┐    ┌──────────────────┐  │
                        │  │ EDNS Discovery │───▶│ WS Management   │  │
                        │  │ (on startup)   │    │ Client          │  │
                        │  └───────────────┘    └──────────────────┘  │
                        └─────────────────────────────────────────────┘
                                    │                    ▲
                                    │ DNS w/ EDNS OPT    │ WebSocket
                                    ▼                    │
                        ┌─────────────────────┐  ┌──────┴──────────┐
                        │  Upstream DNS        │  │ YellowDog DNS   │
                        │  (8.8.8.8, etc.)     │  │ Server (optional)│
                        └─────────────────────┘  └─────────────────┘
```

## Supervision Tree

```
yellow_dog_resolved (Application)
└── YellowDog.Resolved.Supervisor
    ├── YellowDog.Resolved.Config           # Config server (TOML watcher)
    ├── YellowDog.Resolved.Cache            # ETS-based DNS cache
    ├── YellowDog.Resolved.Metrics          # Query counter accumulator (via telemetry)
    ├── YellowDog.Resolved.Forwarder        # Upstream query correlation
    ├── YellowDog.Resolved.Listener         # Abyss UDP listener on 127.0.0.1:53
    └── YellowDog.Resolved.Discovery        # EDNS probe + WS management (optional)
```

---

## Query Router

### Resolution Order

For each incoming DNS query:

1. **Intercept rules** — Match domain against configured rules. If match, return static response immediately.
2. **Cache lookup** — Check ETS cache for non-expired entry. If hit, return cached response.
3. **Forward** — Send query to upstream via `Abyss.Client.send/4`, correlate response by transaction ID, cache result, return to client.

### Intercept Rules

Rules are evaluated in order; first match wins.

```elixir
@type rule :: %{
  match: match_pattern(),
  type: :A | :AAAA | :CNAME | :TXT | :MX | :SRV,
  value: binary(),
  ttl: pos_integer()
}

@type match_pattern ::
  {:exact, String.t()}       |  # "myapp.local.dev"
  {:suffix, String.t()}      |  # "*.local.dev" → matches anything ending in .local.dev
  {:prefix, String.t()}         # "dev-*" → matches anything starting with dev-
```

### Response Construction

Intercepted responses are constructed using `ex_dns`:
- Copy transaction ID from query
- Set QR=1 (response), AA=1 (authoritative), RD=1 (recursion desired), RA=0
- Single answer record with configured type, value, and TTL
- If query type doesn't match rule type, return empty answer (NOERROR with 0 answers)

---

## DNS Cache

### Design

- **Storage:** ETS table, `{domain, type}` as key
- **TTL:** Respect upstream TTL from answer records; configurable minimum and maximum TTL clamps
- **Negative caching:** Cache NXDOMAIN responses with configurable negative TTL (default 60s, per RFC 2308)
- **Eviction:** Lazy expiry on read + periodic sweep (configurable interval, default 60s)
- **Max entries:** Configurable cap (default 10,000); LRU eviction when exceeded

### API

```elixir
@spec lookup(domain :: String.t(), type :: atom()) :: {:hit, dns_message()} | :miss
@spec store(domain :: String.t(), type :: atom(), response :: dns_message(), ttl :: pos_integer()) :: :ok
@spec flush() :: :ok
@spec flush(domain :: String.t()) :: :ok
@spec flush_pattern(pattern :: String.t()) :: non_neg_integer()  # returns count flushed
@spec stats() :: %{
  entries: non_neg_integer(),
  hits: non_neg_integer(),
  misses: non_neg_integer(),
  evictions: non_neg_integer()
}
```

### Cache Key

```elixir
# Key: {normalized_domain, query_type}
# "Google.COM" → "google.com"
defp cache_key(domain, type), do: {String.downcase(domain), type}
```

---

## Upstream Forwarder

### Transaction ID Correlation

The forwarder maintains a correlation table mapping DNS transaction IDs to pending client requests.

```elixir
@type pending :: %{
  txn_id: 0..65535,
  client_addr: :inet.ip_address(),
  client_port: :inet.port_number(),
  query: dns_message(),
  sent_at: integer(),          # monotonic time
  upstream: :inet.ip_address(),
  timer_ref: reference()
}
```

### Flow

1. Receive query from listener
2. Allocate or reuse transaction ID (original client txn_id may collide across clients)
3. Send via `Abyss.Client.send/4` to first configured upstream
4. Start timeout timer (configurable, default 3s)
5. On response: match by txn_id, rewrite txn_id back to client's original, cache, reply
6. On timeout: try next upstream if available, else return SERVFAIL

### Upstream Selection

- Try upstreams in configured order
- On timeout, advance to next upstream
- Track per-upstream failure counts; deprioritize after N consecutive failures (configurable, default 3)
- Reset failure count after successful response

---

## EDNS Discovery Protocol

### Purpose

Allow `yellow_dog_resolved` to auto-discover a YellowDog DNS management server without explicit configuration. Uses EDNS0 (RFC 6891) with a private-use option code.

### EDNS Option

```
Option Code:  65321 (private-use range 65001-65534)
Option Name:  YELLOWDOG_DISCOVERY
Option Data:
  ┌────────────────┬──────────────────────────┐
  │ Version (u8)   │ Instance ID (16 bytes)   │
  ├────────────────┼──────────────────────────┤
  │     0x01       │  <random UUID bytes>     │
  └────────────────┴──────────────────────────┘
```

- **Version:** Protocol version (1 for v1)
- **Instance ID:** Random UUID generated at daemon startup, identifies this resolved instance

### Discovery Flow

```
  resolved                          upstream (yellow_dog_dns)
     │                                       │
     │  DNS Query: _yellowdog._tcp.local      │
     │  + OPT RR w/ option 65321             │
     │  (version=1, instance_id=<uuid>)      │
     ├──────────────────────────────────────▶│
     │                                       │
     │  DNS Response:                        │
     │  Answer: SRV 0 0 4000 yellowdog.local │
     │  Additional: A yellowdog.local <ip>   │
     │  + OPT RR w/ option 65321            │
     │  (version=1, ws_path="/ws/resolved")  │
     │◀──────────────────────────────────────┤
     │                                       │
     │  WebSocket: ws://<ip>:4000/ws/resolved│
     │  (header: X-Instance-Id: <uuid>)     │
     ├──────────────────────────────────────▶│
     │                                       │
     │  Connected ✓                          │
     │◀──────────────────────────────────────┤
```

### Discovery Trigger

1. On daemon startup, after config load
2. Send discovery probe to **each** configured upstream
3. First upstream that returns a valid EDNS 65321 response wins
4. Extract SRV record for host/port, EDNS option data for WebSocket path
5. Connect via WebSocket

### Non-YellowDog Upstreams

If upstream is not a YellowDog DNS server (e.g., 8.8.8.8):
- It will either ignore the unknown EDNS option and answer normally (most servers)
- Or return FORMERR/NOTIMPL
- In both cases: no management connection, resolved operates standalone — this is fine

### EDNS Response Data

```
Response Option 65321 Data:
  ┌────────────────┬──────────────────────────┐
  │ Version (u8)   │ WS Path (UTF-8 string)   │
  ├────────────────┼──────────────────────────┤
  │     0x01       │  "/ws/resolved"          │
  └────────────────┴──────────────────────────┘
```

The WebSocket endpoint is constructed as: `ws://{srv_target}:{srv_port}{ws_path}`

---

## WebSocket Management Protocol

### Connection

- **URL:** Derived from EDNS discovery (see above)
- **Headers:** `X-Instance-Id: <uuid>` (same as EDNS probe)
- **Protocol:** JSON messages over WebSocket text frames
- **Heartbeat:** WebSocket ping/pong, 30s interval

### Message Format

All messages follow a common envelope:

```json
{
  "type": "<message_type>",
  "id": "<request_id>",
  "data": { ... }
}
```

Responses include the original request ID for correlation:

```json
{
  "type": "<response_type>",
  "id": "<original_request_id>",
  "data": { ... }
}
```

### Commands (Server → Resolved)

#### cache_flush

Flush all or matching cache entries.

```json
{
  "type": "cache_flush",
  "id": "req-001",
  "data": {
    "pattern": null
  }
}
```

- `pattern: null` — flush entire cache
- `pattern: "example.com"` — flush exact domain
- `pattern: "*.example.com"` — flush all subdomains

Response:

```json
{
  "type": "cache_flush_result",
  "id": "req-001",
  "data": {
    "flushed": 42
  }
}
```

#### cache_stats

Request current cache statistics.

```json
{
  "type": "cache_stats",
  "id": "req-002",
  "data": {}
}
```

Response:

```json
{
  "type": "cache_stats_result",
  "id": "req-002",
  "data": {
    "entries": 1523,
    "hits": 48291,
    "misses": 12044,
    "evictions": 305,
    "hit_rate": 0.80,
    "oldest_entry_age_s": 3412
  }
}
```

#### ping

Server health check.

```json
{
  "type": "ping",
  "id": "req-003",
  "data": {
    "server_time": 1706000000
  }
}
```

Response:

```json
{
  "type": "pong",
  "id": "req-003",
  "data": {
    "uptime_s": 86400,
    "queries_total": 60335,
    "queries_intercepted": 1200,
    "queries_cached": 48291,
    "queries_forwarded": 10844
  }
}
```

### Events (Resolved → Server)

#### connected

Sent immediately after WebSocket connection established.

```json
{
  "type": "connected",
  "id": "evt-001",
  "data": {
    "instance_id": "<uuid>",
    "version": "0.1.0",
    "hostname": "workstation-01",
    "upstreams": ["192.168.1.1", "8.8.8.8"],
    "intercept_rule_count": 5,
    "cache_max_entries": 10000
  }
}
```

### Reconnection

- On WebSocket disconnect, wait 5s then re-discover via EDNS probe
- Do **not** cache the previous WebSocket URL — always re-discover to handle server migration
- Exponential backoff on repeated failures: 5s, 10s, 20s, 40s, max 60s
- Reset backoff on successful connection

---

## Configuration (TOML)

```toml
[resolved]
# Listen address and port
listen = "127.0.0.1"
port = 53

# Upstream DNS servers (tried in order)
upstreams = ["192.168.1.1", "1.1.1.1", "8.8.8.8"]

# Upstream query timeout
upstream_timeout_ms = 3000

# Consecutive failures before deprioritizing an upstream
upstream_failure_threshold = 3

[resolved.cache]
enabled = true
max_entries = 10000
min_ttl_s = 30           # Clamp minimum TTL
max_ttl_s = 86400        # Clamp maximum TTL (24h)
negative_ttl_s = 60      # NXDOMAIN cache duration
sweep_interval_s = 60    # Periodic expired entry cleanup

[resolved.discovery]
# EDNS YellowDog discovery (enabled by default, no-op if upstream isn't YellowDog)
enabled = true

[resolved.discovery.websocket]
heartbeat_interval_s = 30
reconnect_base_s = 5
reconnect_max_s = 60

# Intercept rules (evaluated in order, first match wins)
[[resolved.intercept]]
match = "*.local.dev"
type = "A"
value = "127.0.0.1"
ttl = 300

[[resolved.intercept]]
match = "*.local.dev"
type = "AAAA"
value = "::1"
ttl = 300

[[resolved.intercept]]
match = "myapp.test"
type = "A"
value = "192.168.1.100"
ttl = 600

[[resolved.intercept]]
match = "db.internal"
type = "CNAME"
value = "postgres.local.dev"
ttl = 300
```

---

## Telemetry Events

```elixir
# Query received
[:yellow_dog, :resolved, :query, :start]
metadata: %{domain: domain, type: type, client: client_addr}

# Query resolved (all paths: intercept, cache, forward)
[:yellow_dog, :resolved, :query, :stop]
measurements: %{duration: native_time}
metadata: %{domain: domain, type: type, source: :intercept | :cache | :forward}

# Query failed
[:yellow_dog, :resolved, :query, :exception]
measurements: %{duration: native_time}
metadata: %{domain: domain, type: type, reason: reason}

# Upstream forward
[:yellow_dog, :resolved, :forward, :start]
metadata: %{upstream: ip, domain: domain, type: type}

[:yellow_dog, :resolved, :forward, :stop]
measurements: %{duration: native_time}
metadata: %{upstream: ip, domain: domain, type: type}

[:yellow_dog, :resolved, :forward, :exception]
measurements: %{duration: native_time}
metadata: %{upstream: ip, reason: :timeout | reason}

# Cache events
[:yellow_dog, :resolved, :cache, :hit]
metadata: %{domain: domain, type: type}

[:yellow_dog, :resolved, :cache, :miss]
metadata: %{domain: domain, type: type}

[:yellow_dog, :resolved, :cache, :store]
metadata: %{domain: domain, type: type, ttl: ttl}

[:yellow_dog, :resolved, :cache, :flush]
metadata: %{pattern: pattern, count: count}

# Discovery
[:yellow_dog, :resolved, :discovery, :probe]
metadata: %{upstream: ip}

[:yellow_dog, :resolved, :discovery, :found]
metadata: %{upstream: ip, ws_endpoint: url}

[:yellow_dog, :resolved, :discovery, :not_found]
metadata: %{upstream: ip}

# WebSocket management
[:yellow_dog, :resolved, :management, :connected]
metadata: %{endpoint: url}

[:yellow_dog, :resolved, :management, :disconnected]
metadata: %{reason: reason}

[:yellow_dog, :resolved, :management, :command]
metadata: %{type: command_type}
```

---

## File Structure

```
apps/yellow_dog_resolved/
├── lib/
│   └── yellow_dog_resolved/
│       ├── application.ex              # OTP Application
│       ├── supervisor.ex               # Top-level supervisor
│       ├── config.ex                   # TOML config loader + watcher
│       ├── listener.ex                 # Abyss UDP listener callbacks
│       ├── router.ex                   # Query routing (intercept → cache → forward)
│       ├── intercept.ex                # Rule matching engine
│       ├── cache.ex                    # ETS DNS cache with TTL
│       ├── forwarder.ex                # Upstream query + txn_id correlation
│       ├── response_builder.ex         # DNS response construction helpers
│       ├── discovery.ex                # EDNS probe + SRV extraction
│       └── management/
│           ├── client.ex               # WebSocket client (GenServer)
│           └── handler.ex              # Command dispatch (flush, stats, ping)
├── test/
│   └── yellow_dog_resolved/
│       ├── router_test.exs
│       ├── intercept_test.exs
│       ├── cache_test.exs
│       ├── forwarder_test.exs
│       ├── discovery_test.exs
│       └── management_test.exs
├── config/
│   └── resolved.toml                  # Default/example config
├── mix.exs
└── README.md
```

---

## Testing Requirements

### Unit Tests

1. **Intercept rules** — exact, suffix, prefix matching; first-match-wins ordering; case insensitivity
2. **Cache** — store/lookup, TTL expiry, negative caching, LRU eviction at max entries, flush by pattern
3. **Router** — intercept → cache → forward priority; correct response construction
4. **Forwarder** — txn_id correlation; timeout handling; upstream failover; failure count tracking
5. **Response builder** — valid DNS response packets for each record type
6. **Discovery** — EDNS option encoding/decoding; SRV record extraction; graceful handling of non-YellowDog responses
7. **Management handler** — cache_flush, cache_stats, ping command dispatch and response formatting

### Integration Tests

1. **End-to-end query** — start resolved, send DNS query via UDP, verify response
2. **Upstream forwarding** — start resolved + mock upstream, verify query forwarded and response relayed
3. **Cache behavior** — query twice, verify second is served from cache (no upstream hit)
4. **Intercept** — query intercepted domain, verify static response without upstream traffic
5. **Discovery + management** — start resolved + mock YellowDog DNS with EDNS support, verify WebSocket connection established, send cache_flush command, verify cache cleared

### Property Tests

1. **Any valid DNS query** → resolved returns a valid DNS response (never crashes, never returns malformed packet)
2. **Cache TTL** → no entry survives beyond max_ttl_s + sweep_interval_s

---

## Acceptance Criteria

- [ ] Binds to `127.0.0.1:53` via Abyss and handles concurrent UDP queries
- [ ] Intercept rules match domains correctly (exact, suffix, prefix) and return valid DNS responses
- [ ] Non-intercepted queries forwarded to upstream and responses relayed with correct txn_id
- [ ] Upstream failover works: timeout on first upstream triggers retry on second
- [ ] DNS cache stores responses with TTL; cache hits avoid upstream queries
- [ ] Negative caching (NXDOMAIN) works per configured TTL
- [ ] Cache flush (full and by pattern) works via management command
- [ ] EDNS discovery probe sent on startup; WebSocket connection established if upstream supports it
- [ ] Management protocol handles `cache_flush`, `cache_stats`, `ping` commands
- [ ] Non-YellowDog upstreams gracefully ignored (no management connection, resolver works standalone)
- [ ] WebSocket reconnection with exponential backoff on disconnect
- [ ] TOML configuration loaded on startup with config file watcher for hot-reload
- [ ] Telemetry events emitted for all operations
- [ ] `SERVFAIL` returned when all upstreams are unreachable
- [ ] `NXDOMAIN` returned correctly for missing intercept records
- [ ] All unit and integration tests pass

## Out of Scope (v1)

- TCP DNS (port 53 TCP fallback for truncated responses)
- DNS-over-HTTPS (DoH) or DNS-over-TLS (DoT)
- DNSSEC validation
- Authentication/encryption on management WebSocket (trusted network only)
- Recursive resolution (stub only — always forwards to upstream)
- GUI / console integration
- Config push from server (server can only send commands, not config updates)

## Dependencies

- `ex_dns` — DNS protocol encoding/decoding
- `abyss` — UDP listener + `Abyss.Client` for upstream sends
- `toml` — Configuration parsing
- `websock_client` (or `mint_web_socket`) — WebSocket client for management connection
- `:telemetry` — Event emission

## NixOS Deployment Notes (Informational)

Not part of the application, but for reference — the host NixOS config to use this:

```nix
{
  services.resolved.enable = false;
  environment.etc."resolv.conf".text = "nameserver 127.0.0.1\n";
  # systemd service for yellow_dog_resolved goes here
}
```