# YellowDog DNS Implementation Plan
## Full-Featured Authoritative DNS Server (BIND9-like)

### Executive Summary

Transform `YellowDog.Dns` into a production-ready, full-featured authoritative DNS server comparable to ISC BIND9, with modern Elixir/OTP architecture, real-time management via web console, and comprehensive zone management capabilities.

---

## 1. Core Features Roadmap

### 1.1 Essential Features (Phase 1)
- ✅ UDP server with Abyss (already implemented)
- 🔲 **Authoritative Zone Management**
  - Primary (master) zones
  - Secondary (slave) zones with AXFR/IXFR
  - Zone file parsing (BIND format)
  - Dynamic zone updates (RFC 2136)
  - In-memory zone storage with ETS
- 🔲 **Query Processing**
  - Standard queries (A, AAAA, MX, NS, SOA, TXT, CNAME, PTR, SRV)
  - CNAME chain resolution
  - Wildcard record support
  - Negative caching (NXDOMAIN)
  - Authoritative vs non-authoritative responses
- 🔲 **Access Control Lists (ACLs)**
  - Named ACL definitions
  - IP-based access control
  - Query/transfer restrictions
  - Per-zone ACL overrides

### 1.2 Advanced Features (Phase 2)
- 🔲 **DNS Views**
  - Multiple DNS perspectives for different clients
  - View-specific zones and configurations
  - ACL-based view matching
  - Split-horizon DNS support
- 🔲 **Zone Transfer**
  - AXFR (full zone transfer)
  - IXFR (incremental zone transfer)
  - NOTIFY mechanism for zone updates
  - Serial number tracking
  - Multi-master replication
- 🔲 **Caching Resolver**
  - Recursive query support
  - Cache management with TTL
  - Prefetching popular queries
  - Cache statistics and monitoring
- 🔲 **DNSSEC Support**
  - DNSSEC signing (RRSIG, DNSKEY, DS, NSEC, NSEC3)
  - Automatic key rotation
  - Zone signing workflows
  - DNSSEC validation for recursive queries

### 1.3 Enterprise Features (Phase 3)
- 🔲 **Response Rate Limiting (RRL)**
  - Protection against DNS amplification attacks
  - Configurable rate limits per client
  - Slip mode for legitimate retries
- 🔲 **Statistics and Monitoring**
  - Real-time query statistics
  - Zone statistics (queries per zone)
  - Response time metrics
  - Error rate tracking
  - Telemetry integration
- 🔲 **Performance Optimizations**
  - Query pipelining
  - Connection pooling
  - Memory-efficient zone storage
  - Parallel zone loading
  - Hot reload without downtime
- 🔲 **Advanced Zone Features**
  - $INCLUDE directive support
  - $GENERATE for large zones
  - Zone templates
  - Reverse zone auto-generation
  - ALIAS/ANAME records (non-standard)

---

## 2. Architecture Design

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    YellowDog.Dns.Supervisor                 │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐  ┌──────────────────┐                │
│  │  DNS Server     │  │  Zone Manager    │                │
│  │  (Abyss UDP)    │  │  (GenServer)     │                │
│  └────────┬────────┘  └────────┬─────────┘                │
│           │                     │                           │
│           v                     v                           │
│  ┌─────────────────┐  ┌──────────────────┐                │
│  │  Query Handler  │  │  Zone Storage    │                │
│  │  (Resolver)     │  │  (ETS Tables)    │                │
│  └────────┬────────┘  └────────┬─────────┘                │
│           │                     │                           │
│           v                     v                           │
│  ┌─────────────────┐  ┌──────────────────┐                │
│  │  View Manager   │  │  Transfer Agent  │                │
│  │  (Routing)      │  │  (AXFR/IXFR)     │                │
│  └─────────────────┘  └──────────────────┘                │
│                                                             │
│  ┌─────────────────┐  ┌──────────────────┐                │
│  │  Cache Manager  │  │  ACL Engine      │                │
│  │  (GenServer)    │  │  (Rules)         │                │
│  └─────────────────┘  └──────────────────┘                │
│                                                             │
│  ┌─────────────────┐  ┌──────────────────┐                │
│  │  Stats Collector│  │  DNSSEC Signer   │                │
│  │  (Aggregator)   │  │  (Crypto)        │                │
│  └─────────────────┘  └──────────────────┘                │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Data Flow

```
Query Request Flow:
1. UDP packet arrives at Abyss server
2. Handler.UDP parses DNS message (using ex_dns)
3. View.Matcher selects appropriate view based on source IP
4. Query.Resolver looks up record in zone storage
5. Response builder constructs DNS response
6. Stats.Collector updates metrics
7. Response sent back via UDP

Zone Update Flow:
1. Zone file read from disk or AXFR received
2. Zone.Parser validates and parses zone data
3. Zone.Manager loads into ETS storage
4. Zone.Notifier sends NOTIFY to slaves
5. Stats updated, telemetry emitted
```

---

## 3. Module Breakdown

### 3.1 Core Modules

```elixir
# Public API
YellowDog.Dns
├── start_link/1                # Start DNS supervisor
├── status/0                    # Get service status
├── stats/0                     # Get statistics
├── reload/0                    # Reload configuration
└── reload_zone/1               # Reload specific zone

# Zone Management
YellowDog.Dns.Zone.Manager      # Zone lifecycle management
├── load_zone/2                 # Load zone from file or transfer
├── unload_zone/1               # Unload zone from memory
├── list_zones/0                # List all loaded zones
├── get_zone/1                  # Get zone data
├── update_zone/2               # Dynamic zone updates
└── reload_zone/1               # Reload zone from source

YellowDog.Dns.Zone.Storage      # ETS-based zone storage
├── create_table/1              # Create zone storage table
├── insert_record/2             # Insert DNS record
├── lookup_record/3             # Query DNS record
├── delete_record/2             # Remove DNS record
└── zone_serial/1               # Get/update SOA serial

YellowDog.Dns.Zone.Parser       # BIND zone file parser
├── parse_file/1                # Parse zone file
├── parse_string/1              # Parse zone data string
├── validate/1                  # Validate zone syntax
└── normalize/1                 # Normalize zone data

# Note: FileWatcher removed - manual zone loading only

# Query Processing
YellowDog.Dns.Query.Resolver    # Main query resolution engine
├── resolve/2                   # Resolve DNS query
├── resolve_authoritative/2     # Authoritative lookup
├── resolve_recursive/2         # Recursive resolution
└── build_response/2            # Construct DNS response

YellowDog.Dns.Query.Cache       # Query response caching
├── get/1                       # Lookup cached response
├── put/3                       # Cache response with TTL
├── invalidate/1                # Clear cached entry
└── stats/0                     # Cache statistics

YellowDog.Dns.Query.Validator   # Query validation
├── validate_query/1            # Validate DNS query
├── check_limits/1              # Check query limits
└── sanitize/1                  # Sanitize malformed queries

# Views and ACLs
YellowDog.Dns.View.Manager      # View management
├── create_view/2               # Create DNS view
├── delete_view/1               # Remove view
├── list_views/0                # List all views
├── match_view/1                # Match client to view
└── get_zones/1                 # Get zones for view

YellowDog.Dns.View.ACL          # Access control lists
├── create_acl/2                # Define ACL
├── match/2                     # Check if IP matches ACL
├── allow?/3                    # Check if action allowed
└── deny?/3                     # Check if action denied

# Zone Transfer
YellowDog.Dns.Transfer.AXFR     # Full zone transfer
├── request/2                   # Request AXFR
├── serve/2                     # Serve AXFR request
└── process_response/1          # Process AXFR data

YellowDog.Dns.Transfer.IXFR     # Incremental zone transfer
├── request/3                   # Request IXFR with serial
├── serve/2                     # Serve IXFR request
└── apply_changes/2             # Apply incremental changes

YellowDog.Dns.Transfer.Notify   # NOTIFY mechanism
├── send_notify/2               # Send NOTIFY to slaves
├── handle_notify/1             # Handle NOTIFY message
└── update_serial/2             # Track zone serials

# DNSSEC
YellowDog.Dns.DNSSEC.Signer     # Zone signing
├── sign_zone/2                 # Sign zone with keys
├── generate_keys/1             # Generate key pair
├── rotate_keys/1               # Key rotation
└── verify_signatures/1         # Verify RRSIG

YellowDog.Dns.DNSSEC.KeyManager # Key management
├── load_keys/1                 # Load signing keys
├── store_key/2                 # Store key securely
├── list_keys/0                 # List available keys
└── delete_key/1                # Remove key

# Statistics and Monitoring
YellowDog.Dns.Stats.Collector   # Statistics collection
├── record_query/1              # Record query stats
├── record_response/2           # Record response stats
├── get_stats/0                 # Get current stats
└── reset_stats/0               # Reset counters

YellowDog.Dns.Stats.Aggregator  # Aggregate statistics
├── queries_per_second/0        # Calculate QPS
├── zone_stats/1                # Stats per zone
├── response_time/0             # Average response time
└── error_rate/0                # Calculate error rate

# Configuration
YellowDog.Dns.Config            # DNS-specific configuration
├── load_config/0               # Load DNS configuration
├── get_zone_config/1           # Get zone configuration
├── get_view_config/1           # Get view configuration
└── validate_config/1           # Validate configuration
```

### 3.2 Handler Implementation

```elixir
defmodule YellowDog.Dns.Handler.UDP do
  @behaviour Abyss.Handler

  def handle_data(data, metadata, state) do
    with {:ok, query} <- DNS.Message.decode(data),
         {:ok, view} <- View.Manager.match_view(metadata),
         {:ok, response} <- Query.Resolver.resolve(query, view),
         {:ok, encoded} <- DNS.Message.encode(response) do

      # Record statistics
      Stats.Collector.record_query(query)
      Stats.Collector.record_response(response, metadata)

      # Emit telemetry
      :telemetry.execute(
        [:yellow_dog, :dns, :query],
        %{response_time: response.time, size: byte_size(encoded)},
        %{query_type: query.type, zone: query.domain}
      )

      {:reply, encoded, state}
    else
      {:error, :format_error} ->
        {:reply, build_format_error(), state}
      {:error, :server_failure} ->
        {:reply, build_server_failure(), state}
      {:error, :nxdomain} ->
        {:reply, build_nxdomain(), state}
    end
  end
end
```

---

## 4. Implementation Phases

### Phase 1: Foundation - Authoritative Zones (Weeks 1-3) ✅ COMPLETE
**Goal**: Production-ready authoritative DNS server with manual zone loading

**Milestones**:
1. **Week 1**: Zone storage and management ✅
   - Implement `Zone.Storage` with ETS tables
   - Implement `Zone.Manager` for loading/unloading
   - Basic zone data structures

2. **Week 2**: Zone file parsing and query resolution ✅
   - Implement `Zone.Parser` for BIND format
   - Support A, AAAA, MX, NS, SOA, TXT, CNAME records
   - Implement `Query.Resolver` for authoritative queries
   - RFC 4592 wildcard support

3. **Week 3**: Statistics and documentation ✅
   - Statistics tracking and telemetry
   - Default view stub (single view)
   - Integration with Handler.UDP
   - Documentation updates

**Deliverables**: ✅
- Load zones from file (manual loading only, NO FileWatcher)
- Answer authoritative queries
- Wildcard support (RFC 4592)
- Comprehensive unit tests (71+ tests)

**Note**: FileWatcher removed from scope - manual zone loading only via API

---

### Phase 2: Resolver Core (Weeks 4-8, 5 weeks total)
**Goal**: Forward zones, recursive resolution, and root zone management

**Week 4: Forward Zones**
- Implement forward zone type
- Upstream server configuration
- Query forwarding with UDP/TCP fallback
- Forward zone caching
- Statistics for forwarded queries

**Week 5: Recursive Resolver Foundation**
- Implement recursive query engine
- Iterative resolution algorithm
- NS record following
- Glue record handling
- Query timeout and retry logic

**Week 6: Root Zone Management**
- **Strategy 1**: Root hints (embedded 13 root servers)
  - Hard-coded root server addresses (a.root-servers.net through m.root-servers.net)
  - Fallback mechanism when no authority available
- **Strategy 2**: Fetch from IANA (periodic updates)
  - Download root zone from https://www.internic.net/domain/root.zone
  - Periodic refresh (daily/weekly configurable)
  - Automatic parsing and loading
- **Strategy 3**: Authoritative root zone (manual loading)
  - Load root zone as regular authoritative zone
  - Full control over root resolution
  - Useful for isolated/private networks

**Week 7: Query Cache**
- Implement query response cache with TTL
- Cache key generation (name, type, class)
- TTL-based expiration
- Negative caching (NXDOMAIN, NODATA)
- Cache statistics and monitoring
- Cache invalidation API

**Week 8: Integration and Testing**
- Integration testing for forward zones
- End-to-end recursive resolution tests
- Performance benchmarking
- Documentation updates

**Deliverables**:
- Forward zones working with upstream servers
- Full recursive DNS resolver
- Root zone management with 3 strategies
- Query cache with TTL
- Comprehensive tests

---

### Phase 3: Advanced Resolution (Weeks 9-12, 4 weeks total)
**Goal**: Sub-zone delegation and Response Policy Zones (RPZ)

**Week 9: Sub-zone Delegation**
- NS record delegation support
- Glue record injection
- Referral responses
- Authority section population
- Additional section with glue records

**Week 10: RPZ Foundation**
- RPZ zone type
- RPZ record parsing (CNAME ., CNAME *., A 0.0.0.0)
- Policy matching algorithm
- Action types (NXDOMAIN, NODATA, PASSTHRU, DROP, TCP-ONLY)

**Week 11: RPZ Advanced**
- Multiple RPZ zones with priority
- QNAME, IP, NSDNAME, and NSIP triggers
- RPZ statistics (blocks, policy hits)
- RPZ configuration via TOML

**Week 12: Testing and Documentation**
- Integration tests for delegation
- RPZ test suite
- Performance testing
- Documentation

**Deliverables**:
- Working sub-zone delegation
- Full RPZ implementation
- Configuration examples
- Comprehensive tests

---

### Phase 4: Views and Web Console (Weeks 13-16, 4 weeks total)
**Goal**: Full DNS views with ACLs and web management interface

**Week 13: Views and ACLs**
- Implement full `View.Manager` (beyond stub)
- Multiple view support
- ACL matching engine
- View-based zone selection
- Split-horizon DNS

**Week 14: View Configuration**
- TOML configuration for views
- Per-view recursion settings
- Per-view cache settings
- View statistics

**Week 15: Web Console LiveView Pages**
- DNS dashboard with statistics
- Zone management interface
- Record editor with validation
- View configuration UI

**Week 16: Web Console Advanced**
- Zone file upload/download
- Query log viewer
- Cache statistics
- Real-time monitoring

**Deliverables**:
- Full view support with ACLs
- Complete web interface
- Real-time updates
- Zone CRUD operations

---

### Phase 5: Optional Features (Weeks 17+)
**Goal**: Advanced features - implement as needed

**AXFR/IXFR Zone Transfer** (Optional, 3 weeks):
- Full zone transfer (AXFR) client and server
- Incremental zone transfer (IXFR)
- NOTIFY mechanism
- Serial number tracking
- Master/slave replication

**DNSSEC** (Optional, 3 weeks):
- Zone signing (RRSIG, DNSKEY, DS)
- Key generation and management
- Automatic key rotation
- DNSSEC validation for recursive queries

**Response Rate Limiting (RRL)** (Optional, 1 week):
- Rate limiting per client
- Slip mode for legitimate retries
- Protection against DNS amplification

**Note**: These features are optional and should be implemented based on actual requirements and priorities.

---

## 5. Root Zone Management Strategies

YellowDog DNS provides three strategies for root zone management, allowing flexibility based on deployment needs:

### Strategy 1: Root Hints (Default)
**Description**: Use embedded root server addresses (a.root-servers.net through m.root-servers.net)

**Use Case**: Standard recursive resolver behavior, relies on public internet root servers

**Implementation**:
```elixir
defmodule YellowDog.Dns.RootZone.Hints do
  @root_servers %{
    "a.root-servers.net" => {"198.41.0.4", "2001:503:ba3e::2:30"},
    "b.root-servers.net" => {"199.9.14.201", "2001:500:200::b"},
    "c.root-servers.net" => {"192.33.4.12", "2001:500:2::c"},
    "d.root-servers.net" => {"199.7.91.13", "2001:500:2d::d"},
    "e.root-servers.net" => {"192.203.230.10", "2001:500:a8::e"},
    "f.root-servers.net" => {"192.5.5.241", "2001:500:2f::f"},
    "g.root-servers.net" => {"192.112.36.4", "2001:500:12::d0d"},
    "h.root-servers.net" => {"198.97.190.53", "2001:500:1::53"},
    "i.root-servers.net" => {"192.36.148.17", "2001:7fe::53"},
    "j.root-servers.net" => {"192.58.128.30", "2001:503:c27::2:30"},
    "k.root-servers.net" => {"193.0.14.129", "2001:7fd::1"},
    "l.root-servers.net" => {"199.7.83.42", "2001:500:9f::42"},
    "m.root-servers.net" => {"202.12.27.33", "2001:dc3::35"}
  }

  def get_root_servers, do: @root_servers
  def get_random_root_server, do: Enum.random(@root_servers)
end
```

**Configuration**:
```toml
[dns.root_zone]
strategy = "hints"
prefer_ipv6 = false
```

**Advantages**:
- Simple and standard
- No external dependencies
- Works out of the box
- Follows IETF best practices

**Disadvantages**:
- Requires internet connectivity
- Subject to root server availability
- No control over root content

---

### Strategy 2: Fetch from IANA (Auto-update)
**Description**: Periodically download and parse the root zone from IANA

**Use Case**: Organizations that want local root zone caching with automatic updates

**Implementation**:
```elixir
defmodule YellowDog.Dns.RootZone.Fetcher do
  use GenServer

  @root_zone_url "https://www.internic.net/domain/root.zone"
  @update_interval :timer.hours(24)  # Daily updates

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    schedule_fetch()
    {:ok, %{last_fetch: nil, serial: nil}}
  end

  def handle_info(:fetch, state) do
    case fetch_and_load_root_zone() do
      {:ok, serial} ->
        Logger.info("Root zone updated to serial #{serial}")
        schedule_fetch()
        {:noreply, %{state | last_fetch: DateTime.utc_now(), serial: serial}}

      {:error, reason} ->
        Logger.error("Failed to fetch root zone: #{inspect(reason)}")
        schedule_fetch()
        {:noreply, state}
    end
  end

  defp fetch_and_load_root_zone do
    with {:ok, %{status: 200, body: zone_data}} <- HTTPoison.get(@root_zone_url),
         {:ok, zone} <- Zone.Parser.parse_string(zone_data, zone_name: "."),
         :ok <- Zone.Manager.load_zone_data(".", zone) do
      {:ok, zone.soa.serial}
    end
  end

  defp schedule_fetch do
    Process.send_after(self(), :fetch, @update_interval)
  end
end
```

**Configuration**:
```toml
[dns.root_zone]
strategy = "fetch"
url = "https://www.internic.net/domain/root.zone"
update_interval = "24h"
verify_signature = false  # Optional: verify DNSSEC signature
```

**Advantages**:
- Automatic updates
- Local caching improves performance
- Full root zone available
- Reduces dependency on root servers

**Disadvantages**:
- Requires periodic internet access
- Additional complexity
- Potential for stale data if fetch fails
- HTTP(S) dependency

---

### Strategy 3: Authoritative Root Zone (Manual Loading)
**Description**: Load root zone as a regular authoritative zone file

**Use Case**: Isolated networks, private internets, testing, or organizations with custom root

**Implementation**:
```elixir
# Load root zone just like any other zone
Zone.Manager.load_zone(".", file: "/etc/yellowdog/zones/root.zone")
```

**Configuration**:
```toml
[dns.root_zone]
strategy = "authoritative"

[[dns.zones]]
name = "."
type = "master"
file = "zones/root.zone"
```

**Example Root Zone File**:
```bind
$ORIGIN .
$TTL 518400

.   IN  SOA  a.root-servers.net. nstld.verisign-grs.com. (
              2024102801  ; Serial
              1800        ; Refresh (30 minutes)
              900         ; Retry (15 minutes)
              604800      ; Expire (7 days)
              86400 )     ; Minimum (1 day)

; Root name servers
.   IN  NS  a.root-servers.net.
.   IN  NS  b.root-servers.net.
; ... (all 13 root servers)

; TLD delegations
com.    IN  NS  a.gtld-servers.net.
com.    IN  NS  b.gtld-servers.net.
; ... (complete TLD delegations)

; Root server addresses
a.root-servers.net.  IN  A     198.41.0.4
a.root-servers.net.  IN  AAAA  2001:503:ba3e::2:30
; ... (all root server glue records)
```

**Advantages**:
- Full control over root content
- Works in isolated networks
- No external dependencies
- Can customize TLD delegations
- Useful for testing

**Disadvantages**:
- Manual maintenance required
- Must manually update for changes
- Large zone file (100k+ lines)
- Must maintain glue records

---

### Comparison Matrix

| Feature                    | Hints | Fetch | Authoritative |
|----------------------------|-------|-------|---------------|
| Internet required          | Yes   | Periodic | No         |
| Automatic updates          | N/A   | Yes   | No            |
| Full root zone available   | No    | Yes   | Yes           |
| Custom TLDs supported      | No    | No    | Yes           |
| Maintenance effort         | None  | Low   | High          |
| Network isolation support  | No    | No    | Yes           |
| Performance                | Good  | Best  | Best          |
| Complexity                 | Low   | Medium| Medium        |

---

### Recommended Usage

- **Production recursive resolver**: Use Strategy 1 (Hints) or Strategy 2 (Fetch)
- **Corporate network with internet**: Use Strategy 2 (Fetch) for better performance
- **Isolated/private network**: Use Strategy 3 (Authoritative)
- **Testing/development**: Use Strategy 3 (Authoritative) with custom root
- **Custom private internet**: Use Strategy 3 (Authoritative) with custom TLDs

---

## 6. Configuration Structure

### 6.1 TOML Configuration

```toml
[dns]
enabled = true
listen = "0.0.0.0"
port = 53
ipv6_enabled = true
ipv6_listen = "::"
ipv6_port = 53

# Performance settings
max_connections = 10000
num_listeners = 50
rate_limit_qps = 1000
cache_size_mb = 256
cache_ttl_default = 3600

# Directories
zones_dir = "/etc/yellowdog/zones"
keys_dir = "/etc/yellowdog/keys"

# Global ACLs
[dns.acls]
localhost = ["127.0.0.1", "::1"]
internal_network = ["192.168.0.0/16", "10.0.0.0/8"]
trusted_slaves = ["192.168.1.10", "192.168.1.11"]

# Views
[[dns.views]]
name = "internal"
match_clients = ["localhost", "internal_network"]
recursion = true
cache_enabled = true

[[dns.views]]
name = "external"
match_clients = ["any"]
recursion = false
cache_enabled = false

# Zones
[[dns.zones]]
name = "example.com"
type = "master"
file = "zones/example.com.zone"
view = "internal"
allow_query = ["any"]
allow_transfer = ["trusted_slaves"]
notify = true
notify_slaves = ["192.168.1.10", "192.168.1.11"]
dnssec = true
auto_sign = true

[[dns.zones]]
name = "example.com"
type = "master"
file = "zones/example.com-external.zone"
view = "external"
allow_query = ["any"]
allow_transfer = ["none"]

[[dns.zones]]
name = "internal.example.com"
type = "master"
file = "zones/internal.example.com.zone"
view = "internal"
allow_query = ["internal_network"]

[[dns.zones]]
name = "slave.example.com"
type = "slave"
masters = ["192.168.1.5"]
view = "internal"
```

### 6.2 Zone File Format (BIND compatible)

```bind
; Zone file for example.com
$ORIGIN example.com.
$TTL 3600

@       IN  SOA ns1.example.com. admin.example.com. (
            2024102801  ; Serial (YYYYMMDDNN)
            7200        ; Refresh (2 hours)
            3600        ; Retry (1 hour)
            1209600     ; Expire (2 weeks)
            3600 )      ; Negative TTL (1 hour)

; Name servers
        IN  NS  ns1.example.com.
        IN  NS  ns2.example.com.

; Mail servers
        IN  MX  10 mail1.example.com.
        IN  MX  20 mail2.example.com.

; A records
ns1     IN  A   192.168.1.10
ns2     IN  A   192.168.1.11
mail1   IN  A   192.168.1.20
mail2   IN  A   192.168.1.21
www     IN  A   192.168.1.100

; AAAA records
www     IN  AAAA    2001:db8::1

; CNAME records
ftp     IN  CNAME   www.example.com.
mail    IN  CNAME   mail1.example.com.

; TXT records
@       IN  TXT "v=spf1 mx a -all"
_dmarc  IN  TXT "v=DMARC1; p=quarantine; rua=mailto:dmarc@example.com"

; SRV records
_http._tcp  IN  SRV 0 5 80 www.example.com.
_https._tcp IN  SRV 0 5 443 www.example.com.

; Wildcards
*.app   IN  A   192.168.1.200
```

---

## 7. Web Console Integration

### 7.1 New LiveView Pages

```elixir
# apps/yellow_dog_console/lib/yellow_dog/console/router.ex
scope "/", YellowDog.Console do
  pipe_through :browser

  # DNS Management Routes
  live "/dns", DnsLive.Index              # DNS overview
  live "/dns/zones", DnsLive.ZonesLive    # Zone management
  live "/dns/zones/:zone", DnsLive.ZoneEditor  # Zone editor
  live "/dns/records/:zone", DnsLive.RecordsLive  # Record management
  live "/dns/views", DnsLive.ViewsLive    # View configuration
  live "/dns/acls", DnsLive.AclsLive      # ACL management
  live "/dns/transfers", DnsLive.TransfersLive  # Transfer status
  live "/dns/queries", DnsLive.QueriesLive      # Query log
  live "/dns/stats", DnsLive.StatsLive    # Statistics dashboard
end
```

### 7.2 UI Components

**DNS Dashboard** (`DnsLive.Index`):
- Service status (running/stopped)
- Query statistics (QPS, total queries)
- Zone count and status
- Cache hit rate
- Error rate trends
- Top queried domains
- Recent errors

**Zone Management** (`DnsLive.ZonesLive`):
- List all zones with status
- Add new zone (master/slave)
- Zone actions (reload, delete, transfer)
- Zone file upload/download
- Zone validation
- Serial number display
- Last modified timestamp

**Zone Editor** (`DnsLive.ZoneEditor`):
- Visual record editor
- Syntax-highlighted zone file view
- Add/edit/delete records
- Record validation
- SOA management
- DNSSEC status
- Zone diff viewer (before/after changes)

**Query Log** (`DnsLive.QueriesLive`):
- Real-time query stream
- Filter by domain, type, source IP
- Response time histogram
- Error highlighting
- Export capabilities

---

## 8. Testing Strategy

### 8.1 Unit Tests

```elixir
# Zone parsing
test "parses valid zone file" do
  zone_data = """
  $ORIGIN example.com.
  @  IN  SOA ns1 admin (2024010101 7200 3600 1209600 3600)
     IN  NS  ns1
  ns1 IN A 192.168.1.10
  """

  assert {:ok, zone} = Zone.Parser.parse_string(zone_data)
  assert zone.origin == "example.com."
  assert length(zone.records) == 3
end

# Query resolution
test "resolves A record" do
  zone = create_test_zone()
  query = DNS.Message.new_query("www.example.com", :A)

  assert {:ok, response} = Query.Resolver.resolve(query, zone)
  assert response.header.rcode == :no_error
  assert length(response.answers) == 1
end

# ACL matching
test "ACL denies access from external IP" do
  acl = ACL.create("internal", ["192.168.0.0/16"])

  assert ACL.deny?({203, 0, 113, 1}, acl, :query)
  assert ACL.allow?({192, 168, 1, 10}, acl, :query)
end
```

### 8.2 Integration Tests

```elixir
# Full query flow
test "end-to-end DNS query" do
  # Setup zone
  Zone.Manager.load_zone("example.com", zone_file: "test/fixtures/example.com.zone")

  # Send UDP query
  {:ok, socket} = :gen_udp.open(0, [:binary, active: false])
  query = DNS.Message.encode_query("www.example.com", :A)
  :gen_udp.send(socket, {127, 0, 0, 1}, 53, query)

  # Receive response
  assert {:ok, {_ip, _port, response_data}} = :gen_udp.recv(socket, 0, 5000)
  {:ok, response} = DNS.Message.decode(response_data)

  assert response.header.qr == true
  assert response.header.aa == true
  assert length(response.answers) > 0
end
```

### 8.3 Performance Tests

```bash
# DNS benchmarking with dnsperf
dnsperf -d queries.txt -s 127.0.0.1 -p 53 -n 100000

# Expected metrics:
# - QPS: > 50,000 queries/second
# - Latency: < 1ms for cached queries
# - Memory: < 1GB for 100,000 zones
```

---

## 9. Success Metrics

### 9.1 Performance Goals
- **Query Performance**: 50,000+ QPS on single node
- **Response Time**: < 1ms for authoritative queries
- **Memory Efficiency**: < 10KB per zone average
- **Cache Hit Rate**: > 90% for recursive queries
- **Zone Load Time**: < 1s for zones with 10,000 records

### 9.2 Feature Completeness
- ✅ All standard record types (A, AAAA, MX, NS, SOA, TXT, CNAME, PTR, SRV)
- ✅ BIND zone file compatibility
- ✅ Master/slave replication
- ✅ Views and ACLs
- ✅ DNSSEC signing
- ✅ Web management interface

### 9.3 Production Readiness
- ✅ Comprehensive test coverage (>90%)
- ✅ Production deployment guide
- ✅ Monitoring and alerting integration
- ✅ Backup and restore procedures
- ✅ Security hardening
- ✅ Performance tuning guide

---

## 10. Dependencies and Tools

### 10.1 Existing Infrastructure
- ✅ `ex_dns` - DNS protocol handling (already available)
- ✅ `abyss` - High-performance UDP server (already available)
- ✅ `YellowDog.Telemetry` - Metrics and monitoring
- ✅ Phoenix LiveView - Web interface
- ✅ DaisyUI - UI components

### 10.2 Additional Dependencies
- `nimble_parsec` - For zone file parsing
- `httpoison` - For root zone fetching (Strategy 2)
- `tzdata` - For time zone handling in logs
- `ex_crypto` - For DNSSEC cryptographic operations (optional, Phase 5)

**Note**: `file_system` removed - no automatic file watching

### 10.3 Development Tools
- `dns-tools` - For testing (dig, nslookup, dnsperf)
- `wireshark` - For packet analysis
- `bind-utils` - For zone validation (named-checkzone)

---

## 11. Next Steps

### Immediate Actions
1. **Review and approve this plan**
2. **Set up project tracking** (GitHub project board)
3. **Create detailed task breakdown** for Phase 1
4. **Allocate development resources**
5. **Set up CI/CD for DNS testing**

### Questions to Resolve
1. Should we support legacy record types (A6, HINFO, etc.)? → **No, focus on modern types**
2. What's the priority: DNSSEC or recursive resolver? → **Recursive resolver (Phase 2), DNSSEC optional (Phase 5)**
3. Do we need DNS-over-TLS (DoT) or DNS-over-HTTPS (DoH)? → **Future consideration, not in current plan**
4. Which root zone strategy should be default? → **Strategy 1 (Hints), user-configurable**
5. Should we implement automatic zone file watching? → **No, manual loading only**

### Risk Mitigation
- **Risk**: Complex recursive resolution
  - **Mitigation**: Start with forward zones, build iterative resolver incrementally
- **Risk**: Root zone management complexity
  - **Mitigation**: Provide 3 strategies with clear documentation and examples
- **Risk**: Performance under load
  - **Mitigation**: Early benchmarking, profile-driven optimization
- **Risk**: AXFR/IXFR implementation complexity
  - **Mitigation**: Made optional (Phase 5), implement only if needed

---

## Conclusion

This plan provides a comprehensive roadmap to transform YellowDog.Dns into a production-ready, full-featured DNS server with authoritative, forward, and recursive resolution capabilities. The phased approach prioritizes the most valuable features first while deferring optional features like AXFR/IXFR and DNSSEC to Phase 5.

**Updated Timeline**:
- **Phase 1 (Weeks 1-3)**: ✅ COMPLETE - Authoritative zones with wildcard support
- **Phase 2 (Weeks 4-8)**: Forward zones, recursive resolver, root zone management, query cache (5 weeks)
- **Phase 3 (Weeks 9-12)**: Sub-zones and RPZ (4 weeks)
- **Phase 4 (Weeks 13-16)**: Views/ACLs and web console (4 weeks)
- **Phase 5 (Weeks 17+)**: Optional features (AXFR/IXFR, DNSSEC, RRL)

**Core Timeline**: 16 weeks (4 months) for Phases 1-4
**Optional Features**: Additional 3-7 weeks as needed

**Estimated Effort**: 1-2 full-time developers

**Key Decisions**:
- ✅ Manual zone loading only (NO FileWatcher)
- ✅ AXFR/IXFR moved to optional Phase 5 (implement last if needed)
- ✅ Focus on recursive resolver with 3 root zone strategies
- ✅ Forward zones before recursive resolver for gradual complexity increase
- ✅ RPZ for security and policy enforcement
- ✅ Views deferred to Phase 4 (start with default view)

The architecture leverages Elixir's strengths (concurrency, fault tolerance, hot code reloading) while maintaining compatibility with standard DNS protocols and BIND configuration formats.
