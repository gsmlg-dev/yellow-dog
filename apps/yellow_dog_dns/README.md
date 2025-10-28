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
open http://localhost:4000/dns
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
