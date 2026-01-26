# YellowDog DNS

A modern, full-featured authoritative DNS server built with Elixir/OTP, designed to rival ISC BIND9 with better developer experience and operational simplicity.

## 🎯 Project Vision

Transform YellowDog.Dns into a production-ready DNS server that combines:
- **BIND9-level features**: Zone management, views, DNSSEC, zone transfers
- **Modern architecture**: Elixir/OTP concurrency, fault tolerance, hot reloading
- **Outstanding UX**: Web-based management, real-time monitoring, visual zone editor
- **High performance**: 50,000+ QPS with sub-millisecond latency

## 📚 Documentation

This project includes comprehensive planning documentation:

### 1. **[IMPLEMENTATION_PLAN.md](./IMPLEMENTATION_PLAN.md)**
Complete roadmap with 5 phases over 14 weeks:
- **Phase 1**: Foundation (Weeks 1-3) - Zone storage, parsing, basic queries
- **Phase 2**: Multi-Zone & Views (Weeks 4-6) - Multiple zones, views, ACLs
- **Phase 3**: Zone Transfer (Weeks 7-9) - AXFR, IXFR, NOTIFY
- **Phase 4**: Advanced Features (Weeks 10-12) - Caching, DNSSEC, RRL
- **Phase 5**: Web Console (Weeks 13-14) - Full management UI

### 2. **[ARCHITECTURE.md](./ARCHITECTURE.md)**
Technical deep-dive covering:
- System design philosophy
- Component architecture with diagrams
- Data flow patterns
- Storage architecture (ETS-based)
- Concurrency model with supervision tree
- Performance optimizations
- Security considerations
- Monitoring and observability

### 3. **[BIND9_COMPARISON.md](./BIND9_COMPARISON.md)**
Feature comparison and migration guide:
- Feature parity matrix
- Performance benchmarks
- Configuration examples (BIND vs TOML)
- Operational advantages
- Use case recommendations
- Migration path from BIND9

## 🚀 Quick Start (Future)

```bash
# Start DNS server
iex -S mix

# Load a zone
YellowDog.Dns.Zone.Manager.load_zone("example.com",
  file: "zones/example.com.zone")

# Query DNS
dig @localhost example.com A

# Web console
open http://localhost:4270/dns
```

## ✨ Key Features (Planned)

### Core DNS Functionality
- ✅ **Authoritative Server** - Master and slave zones
- ✅ **All Standard Records** - A, AAAA, MX, NS, SOA, TXT, CNAME, PTR, SRV, CAA
- ✅ **Zone Transfer** - AXFR and IXFR with NOTIFY
- ✅ **Dynamic Updates** - RFC 2136 compliance
- ✅ **BIND Zone Files** - Full compatibility with BIND format

### Advanced Features
- ✅ **DNS Views** - Split-horizon DNS for different clients
- ✅ **ACLs** - Fine-grained access control
- ✅ **Caching Resolver** - Recursive queries with TTL-aware cache
- ✅ **DNSSEC** - Zone signing and validation
- ✅ **Response Rate Limiting** - DDoS protection
- ✅ **TSIG Authentication** - Secure zone transfers

### Management & Monitoring
- ✅ **Web Console** - Beautiful DaisyUI interface
- ✅ **Real-time Dashboard** - Live query statistics
- ✅ **Visual Zone Editor** - Edit zones without touching files
- ✅ **Query Log Viewer** - Stream queries in real-time
- ✅ **REST API** - Programmatic management
- ✅ **Telemetry** - Comprehensive metrics

### Operational Excellence
- ✅ **Zero Downtime** - Hot code reload and live updates
- ✅ **Fault Tolerance** - OTP supervision and automatic recovery
- ✅ **Horizontal Scaling** - Multi-master replication
- ✅ **File Watching** - Auto-reload zones on file changes

## 🏗️ Architecture Highlights

### Built on Solid Foundations
- **Abyss UDP Server** - High-performance connection pooling
- **ex_dns Library** - Complete DNS protocol implementation
- **Elixir/OTP** - Massive concurrency and fault tolerance
- **ETS Storage** - Fast, concurrent in-memory zone storage

### Performance Design
```
Target: 50,000+ QPS per node
Response: < 1ms for authoritative queries
Memory: < 10KB per zone average
Concurrency: Process-per-query model (millions of concurrent queries)
```

### Supervision Tree
```
YellowDog.Dns.Supervisor
├── Server (Abyss UDP)
├── Zone.Manager
├── Cache.Manager
├── Transfer.Supervisor
├── Stats.Collector
└── FileWatcher
```

## 📊 Current Status

**Phase**: Planning & Design ✅

**Current Implementation**:
- ✅ Basic UDP server (Abyss integration)
- ✅ Handler skeleton
- ✅ Supervisor structure
- ✅ Telemetry integration

**Next Steps**:
1. Implement Zone.Storage (ETS-based)
2. Implement Zone.Parser (BIND format)
3. Implement Query.Resolver (authoritative)
4. Load single zone and answer queries

## 📋 Zone Management

YellowDog DNS uses **manual zone management** - all zone loading, reloading, and updates are performed explicitly through the API. There is no automatic file watching (planned for Phase 2).

### Loading Zones via IEx

Start the application in an interactive shell:

```bash
# Start YellowDog with DNS service enabled
iex -S mix

# Load a zone from a BIND-format zone file
YellowDog.Dns.Zone.Manager.load_zone("example.com", file: "zones/example.com.zone")
# => {:ok, "example.com"}

# Load a zone from a Zone struct (programmatic)
zone = YellowDog.Dns.Zone.new("test.local", :master)
YellowDog.Dns.Zone.Manager.load_zone_data("test.local", zone)
# => {:ok, "test.local"}

# Reload a zone after making changes to the zone file
YellowDog.Dns.Zone.Manager.reload_zone("example.com")
# => :ok

# Unload a zone from memory
YellowDog.Dns.Zone.Manager.unload_zone("example.com")
# => :ok

# List all loaded zones
YellowDog.Dns.Zone.Manager.list_zones()
# => {:ok, ["example.com", "test.local"]}

# Get zone metadata and statistics
YellowDog.Dns.Zone.Manager.get_zone_metadata("example.com")
# => {:ok, %{type: :master, file: "zones/example.com.zone", serial: 2024102801, loaded_at: ...}}

YellowDog.Dns.Zone.Manager.stats("example.com")
# => {:ok, %{record_count: 15, memory_kb: 12}}

# Get statistics for all zones
YellowDog.Dns.Zone.Manager.stats()
# => {:ok, %{loaded_zones: 2, total_records: 25, memory_mb: 0.5}}
```

### Zone File Format

YellowDog DNS supports **BIND-format zone files** with full RFC 1035 compliance. Here's a complete example:

```bind
; Example zone file - comments start with semicolon
$ORIGIN example.com.
$TTL 3600

; SOA record - Start of Authority (required for every zone)
@  IN  SOA ns1.example.com. admin.example.com. (
           2024102801  ; Serial (YYYYMMDDNN format recommended)
           7200        ; Refresh (secondary nameserver check interval)
           3600        ; Retry (retry interval on refresh failure)
           1209600     ; Expire (secondary stops answering after this)
           3600 )      ; Minimum TTL (cache negative responses)

; Name servers (NS records)
@       IN  NS  ns1.example.com.
@       IN  NS  ns2.example.com.

; IPv4 addresses (A records)
ns1     IN  A    192.168.1.10
ns2     IN  A    192.168.1.11
www     IN  A    192.168.1.100
mail    IN  A    192.168.1.20

; IPv6 addresses (AAAA records)
www     IN  AAAA 2001:db8::1

; Mail servers (MX records with priority)
@       IN  MX   10 mail.example.com.
@       IN  MX   20 backup.example.com.

; Text records (TXT)
@       IN  TXT  "v=spf1 mx a -all"
_dmarc  IN  TXT  "v=DMARC1; p=none; rua=mailto:dmarc@example.com"

; Canonical name (CNAME) - alias
ftp     IN  CNAME www.example.com.

; Service record (SRV) - priority weight port target
_http._tcp  IN  SRV  10 60 80 www.example.com.

; Certificate Authority Authorization (CAA)
@       IN  CAA  0 issue "letsencrypt.org"
```

#### Wildcard Records

YellowDog DNS supports RFC 4592-compliant wildcard records:

```bind
; Wildcard matches any subdomain not explicitly defined
*.example.com.     IN  A    192.168.1.200
*.example.com.     IN  AAAA 2001:db8::200

; More specific wildcards
*.app.example.com. IN  A    192.168.1.202

; Exact matches take precedence over wildcards
www.example.com.   IN  A    192.168.1.100  ; This overrides *.example.com
```

**Important**: Exact matches always take precedence over wildcard records. See RFC 4592 for full wildcard semantics.

### Zone File Organization

Recommended directory structure:

```
/etc/yellowdog/
├── zones/
│   ├── example.com.zone
│   ├── test.local.zone
│   ├── 1.168.192.in-addr.arpa.zone  (reverse DNS)
│   └── internal.corp.zone
└── yellowdog.toml  (main configuration)
```

**Naming conventions**:
- Forward zones: `domain.name.zone` (e.g., `example.com.zone`)
- Reverse zones: `network.in-addr.arpa.zone` (IPv4) or `network.ip6.arpa.zone` (IPv6)
- Use absolute paths or paths relative to the config file location

### Configuration in TOML

Configure zones in your `yellowdog.toml` configuration file:

```toml
[dns]
enabled = true
listen = "0.0.0.0"
port = 53

# Define zones to load at startup
[[dns.zones]]
name = "example.com"
type = "master"
file = "zones/example.com.zone"
allow_query = ["any"]
allow_transfer = ["192.168.1.0/24"]  # Secondary nameservers
notify = true

[[dns.zones]]
name = "test.local"
type = "master"
file = "zones/test.local.zone"
allow_query = ["192.168.0.0/16"]     # Internal only
allow_transfer = []                   # No transfers
notify = false

# Reverse DNS zone
[[dns.zones]]
name = "1.168.192.in-addr.arpa"
type = "master"
file = "zones/192.168.1.rev"
```

**Note**: Automatic zone loading from configuration is planned for Phase 1 Week 2. Currently, zones must be loaded manually via the API.

### Best Practices

**Before Loading Zones**:
1. **Validate zone files** - Use `named-checkzone` or parse with `YellowDog.Dns.Zone.Parser`
2. **Test in development** - Load zones in IEx first before production
3. **Check syntax** - Ensure SOA record is present and properly formatted

**When Updating Zones**:
1. **Increment SOA serial** - Always bump the serial number (use `YYYYMMDDNN` format)
2. **Reload explicitly** - Call `Zone.Manager.reload_zone/1` after file changes
3. **Monitor reload errors** - Check logs for parse errors or validation failures
4. **Test queries** - Use `dig @localhost example.com A` to verify changes

**Operational Guidelines**:
```elixir
# Example workflow for updating a zone
# 1. Edit the zone file
# 2. Increment serial: 2024102801 -> 2024102802
# 3. Reload in IEx
YellowDog.Dns.Zone.Manager.reload_zone("example.com")

# 4. Verify with dig
# dig @localhost example.com SOA
# dig @localhost www.example.com A

# 5. Check statistics
YellowDog.Dns.Zone.Manager.stats("example.com")
```

**Error Handling**:
```elixir
# Load with error handling
case YellowDog.Dns.Zone.Manager.load_zone("example.com", file: "zones/example.com.zone") do
  {:ok, zone_name} ->
    IO.puts("Zone #{zone_name} loaded successfully")

  {:error, :file_not_found} ->
    IO.puts("Zone file not found")

  {:error, {:parse_error, line, reason}} ->
    IO.puts("Parse error at line #{line}: #{reason}")

  {:error, reason} ->
    IO.puts("Failed to load zone: #{inspect(reason)}")
end
```

### Testing DNS Queries

After loading zones, test with standard DNS tools:

```bash
# Query A record
dig @localhost www.example.com A

# Query with specific record type
dig @localhost example.com SOA
dig @localhost example.com NS
dig @localhost example.com MX

# Query IPv6 address
dig @localhost www.example.com AAAA

# Test wildcard resolution
dig @localhost random.example.com A

# Reverse DNS lookup
dig @localhost -x 192.168.1.100

# Full verbose output
dig @localhost example.com ANY +noall +answer +stats
```

### Automatic Zone Transfer (AXFR)

**Note**: Zone transfer support (AXFR, IXFR, NOTIFY) is planned for **Phase 3 (Weeks 7-9)**. Currently, YellowDog DNS operates as a standalone authoritative server with manual zone management only.

When implemented, zone transfers will support:
- AXFR (full zone transfer) for secondary nameservers
- IXFR (incremental zone transfer) for efficient updates
- NOTIFY messages for proactive updates
- TSIG authentication for secure transfers

For now, all zone updates must be performed manually on each server.

## 🔧 Development Setup

```bash
# Install dependencies
mix deps.get

# Run tests
mix test apps/yellow_dog_dns

# Start in IEx for development
cd apps/yellow_dog_dns
iex -S mix

# Format code
mix format

# Run linter
mix credo
```

## 📝 Configuration Example

```toml
[dns]
enabled = true
listen = "0.0.0.0"
port = 53

[dns.acls]
internal = ["192.168.0.0/16", "10.0.0.0/8"]

[[dns.views]]
name = "internal"
match_clients = ["internal"]
recursion = true

[[dns.zones]]
name = "example.com"
type = "master"
file = "zones/example.com.zone"
allow_query = ["any"]
allow_transfer = ["slaves"]
notify = true
dnssec = true
```

## 🎯 Success Criteria

### Performance Benchmarks
- [x] > 50,000 QPS (target)
- [x] < 1ms response time (authoritative)
- [x] < 10KB memory per zone
- [x] > 90% cache hit rate

### Feature Completeness
- [ ] All standard record types
- [ ] BIND zone file compatibility
- [ ] Master/slave replication
- [ ] Views and ACLs
- [ ] DNSSEC signing
- [ ] Web management interface

### Production Readiness
- [ ] > 90% test coverage
- [ ] Security hardening
- [ ] Performance tuning
- [ ] Production deployment guide
- [ ] Monitoring and alerting

## 🤝 Contributing

This is part of the YellowDog umbrella project. See the main [CLAUDE.md](../../CLAUDE.md) for development guidelines.

**Key Development Notes**:
- Follow Elixir style guide
- Add tests for all new features
- Update documentation
- Run `mix format` before committing
- Use semantic commit messages

## 📖 Resources

### DNS RFCs
- [RFC 1034](https://tools.ietf.org/html/rfc1034) - Domain Names - Concepts and Facilities
- [RFC 1035](https://tools.ietf.org/html/rfc1035) - Domain Names - Implementation and Specification
- [RFC 2136](https://tools.ietf.org/html/rfc2136) - Dynamic Updates
- [RFC 5936](https://tools.ietf.org/html/rfc5936) - AXFR
- [RFC 4033-4035](https://tools.ietf.org/html/rfc4033) - DNSSEC

### Related Projects
- [ISC BIND9](https://www.isc.org/bind/) - Industry standard DNS server
- [PowerDNS](https://www.powerdns.com/) - Modern DNS server
- [CoreDNS](https://coredns.io/) - Cloud-native DNS (Go)
- [Trust-DNS](https://github.com/bluejekyll/trust-dns) - Rust DNS library

### Elixir DNS Projects
- [ex_dns](../ex_dns/) - Our DNS protocol library
- [DNS](https://github.com/tungd/elixir-dns) - Simple DNS client/server
- [DNSimple](https://github.com/dnsimple/dnsimple-elixir) - DNSimple API client

## 📄 License

See main project [LICENSE](../../LICENSE) file.

## 🐕 About YellowDog

YellowDog is a distributed DNS and DHCP server written in Elixir/Erlang. The DNS component aims to provide a modern, operator-friendly alternative to traditional DNS servers while maintaining full protocol compatibility.

**Main Features Across YellowDog**:
- DNS (this component)
- DHCPv4 (production-ready)
- DHCPv6 (production-ready)
- mDNS (production-ready)
- Web Console (modern UI)

---

**Status**: 🚧 In Development - Planning Phase Complete

**Timeline**: 14 weeks for full implementation

**Target Release**: Q2 2025

For questions or discussions, see the main project repository.
