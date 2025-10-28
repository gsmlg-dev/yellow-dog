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

YellowDog.Dns.Zone.FileWatcher  # Monitor zone file changes
├── watch/1                     # Watch zone file
├── unwatch/1                   # Stop watching
└── handle_change/1             # React to file changes

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

### Phase 1: Foundation (Weeks 1-3)
**Goal**: Basic authoritative server with single zone support

**Milestones**:
1. **Week 1**: Zone storage and management
   - Implement `Zone.Storage` with ETS tables
   - Implement `Zone.Manager` for loading/unloading
   - Basic zone data structures

2. **Week 2**: Zone file parsing
   - Implement `Zone.Parser` for BIND format
   - Support A, AAAA, MX, NS, SOA, TXT, CNAME records
   - Zone validation and error handling

3. **Week 3**: Query resolution
   - Implement `Query.Resolver` for authoritative queries
   - Response building with correct flags
   - Basic error responses (NXDOMAIN, SERVFAIL)

**Deliverables**:
- Load single zone from file
- Answer authoritative queries
- Basic statistics tracking
- Unit tests for core modules

### Phase 2: Multi-Zone and Views (Weeks 4-6)
**Goal**: Support multiple zones, views, and ACLs

**Milestones**:
1. **Week 4**: Multiple zone support
   - Multiple zones in memory
   - Zone listing and management API
   - Per-zone statistics

2. **Week 5**: Views and ACLs
   - Implement `View.Manager` for view routing
   - Implement `ACL` engine
   - View-based query routing

3. **Week 6**: Enhanced query processing
   - CNAME chain resolution
   - Wildcard record support
   - Negative caching

**Deliverables**:
- Multi-zone configuration
- View-based DNS responses
- ACL enforcement
- Integration tests

### Phase 3: Zone Transfer (Weeks 7-9)
**Goal**: Master/slave replication with AXFR/IXFR

**Milestones**:
1. **Week 7**: AXFR implementation
   - Implement `Transfer.AXFR` client
   - Implement `Transfer.AXFR` server
   - Zone serialization/deserialization

2. **Week 8**: IXFR and NOTIFY
   - Implement `Transfer.IXFR` with serial tracking
   - Implement `Transfer.Notify` mechanism
   - Automatic slave zone updates

3. **Week 9**: Transfer reliability
   - Retry mechanisms
   - Transfer validation
   - Multi-master support

**Deliverables**:
- Full zone transfer working
- Incremental updates
- NOTIFY-driven updates
- Transfer statistics

### Phase 4: Advanced Features (Weeks 10-12)
**Goal**: Caching, DNSSEC, and performance optimizations

**Milestones**:
1. **Week 10**: Caching resolver
   - Implement `Query.Cache` with TTL
   - Recursive query support
   - Cache statistics and management

2. **Week 11**: DNSSEC basics
   - Implement `DNSSEC.Signer` for zone signing
   - Key generation and management
   - RRSIG record handling

3. **Week 12**: Performance and RRL
   - Response Rate Limiting
   - Query pipelining
   - Memory optimizations

**Deliverables**:
- Working cache with TTL
- Basic DNSSEC signing
- RRL protection
- Performance benchmarks

### Phase 5: Web Console Integration (Weeks 13-14)
**Goal**: Full management via web interface

**Milestones**:
1. **Week 13**: LiveView pages
   - DNS dashboard with statistics
   - Zone management interface
   - Record editor with validation

2. **Week 14**: Advanced UI features
   - Zone file upload/download
   - Visual zone editor
   - Transfer status monitoring
   - Real-time query log

**Deliverables**:
- Complete web interface
- Real-time updates via PubSub
- Zone CRUD operations
- Query monitoring

---

## 5. Configuration Structure

### 5.1 TOML Configuration

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

### 5.2 Zone File Format (BIND compatible)

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

## 6. Web Console Integration

### 6.1 New LiveView Pages

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

### 6.2 UI Components

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

## 7. Testing Strategy

### 7.1 Unit Tests

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

### 7.2 Integration Tests

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

### 7.3 Performance Tests

```bash
# DNS benchmarking with dnsperf
dnsperf -d queries.txt -s 127.0.0.1 -p 53 -n 100000

# Expected metrics:
# - QPS: > 50,000 queries/second
# - Latency: < 1ms for cached queries
# - Memory: < 1GB for 100,000 zones
```

---

## 8. Success Metrics

### 8.1 Performance Goals
- **Query Performance**: 50,000+ QPS on single node
- **Response Time**: < 1ms for authoritative queries
- **Memory Efficiency**: < 10KB per zone average
- **Cache Hit Rate**: > 90% for recursive queries
- **Zone Load Time**: < 1s for zones with 10,000 records

### 8.2 Feature Completeness
- ✅ All standard record types (A, AAAA, MX, NS, SOA, TXT, CNAME, PTR, SRV)
- ✅ BIND zone file compatibility
- ✅ Master/slave replication
- ✅ Views and ACLs
- ✅ DNSSEC signing
- ✅ Web management interface

### 8.3 Production Readiness
- ✅ Comprehensive test coverage (>90%)
- ✅ Production deployment guide
- ✅ Monitoring and alerting integration
- ✅ Backup and restore procedures
- ✅ Security hardening
- ✅ Performance tuning guide

---

## 9. Dependencies and Tools

### 9.1 Existing Infrastructure
- ✅ `ex_dns` - DNS protocol handling (already available)
- ✅ `abyss` - High-performance UDP server (already available)
- ✅ `YellowDog.Telemetry` - Metrics and monitoring
- ✅ Phoenix LiveView - Web interface
- ✅ DaisyUI - UI components

### 9.2 Additional Dependencies
- `nimble_parsec` - For zone file parsing
- `file_system` - For zone file watching
- `tzdata` - For time zone handling in logs
- `ex_crypto` - For DNSSEC cryptographic operations (optional)

### 9.3 Development Tools
- `dns-tools` - For testing (dig, nslookup, dnsperf)
- `wireshark` - For packet analysis
- `bind-utils` - For zone validation (named-checkzone)

---

## 10. Next Steps

### Immediate Actions
1. **Review and approve this plan**
2. **Set up project tracking** (GitHub project board)
3. **Create detailed task breakdown** for Phase 1
4. **Allocate development resources**
5. **Set up CI/CD for DNS testing**

### Questions to Resolve
1. Should we support legacy record types (A6, HINFO, etc.)?
2. What's the priority: DNSSEC or recursive resolver?
3. Do we need DNS-over-TLS (DoT) or DNS-over-HTTPS (DoH)?
4. Should we implement anycast support?
5. What's the deployment model (single server, cluster, K8s)?

### Risk Mitigation
- **Risk**: Complex zone parsing
  - **Mitigation**: Start with subset of BIND syntax, expand gradually
- **Risk**: Performance under load
  - **Mitigation**: Early benchmarking, profile-driven optimization
- **Risk**: DNSSEC complexity
  - **Mitigation**: Make DNSSEC optional, Phase 4 feature
- **Risk**: Multi-master replication conflicts
  - **Mitigation**: Document limitations, implement conflict detection

---

## Conclusion

This plan provides a comprehensive roadmap to transform YellowDog.Dns into a production-ready, full-featured DNS server. The phased approach allows for incremental delivery of value while maintaining code quality and test coverage.

**Estimated Total Timeline**: 14 weeks (3.5 months)
**Estimated Effort**: 1-2 full-time developers

The architecture leverages Elixir's strengths (concurrency, fault tolerance, hot code reloading) while maintaining compatibility with standard DNS protocols and BIND configuration formats.
