# Phase 4 Implementation Plan - Performance & Operations

**Phase**: Performance Optimizations and Operational Features
**Status**: Planning
**Start Date**: 2025-11-02
**Target**: Production-hardened DNS server

---

## 🎯 Phase 4 Objectives

Transform the DNS server into a production-hardened system with operational excellence:

1. **Hot-Reload** - Update configuration without downtime
2. **Response Rate Limiting** - DDoS protection and abuse prevention
3. **Per-View Caching** - Prevent cache poisoning across views
4. **Enhanced Telemetry** - Production monitoring and observability

---

## 📋 Implementation Roadmap

### Week 1: Hot-Reload System

**Goal**: Reload view configuration without restarting the DNS handler

#### 1.1 File System Watching
- [ ] Add `file_system` dependency for file watching
- [ ] Create `View.ConfigWatcher` GenServer
- [ ] Watch configuration file for changes
- [ ] Debounce rapid changes (e.g., editor saves)
- [ ] Handle file deletion/recreation

**Estimated Time**: 2-3 hours

#### 1.2 Atomic View Updates
- [ ] Implement `Handler.reload_views/1` function
- [ ] Atomic swap of view list in handler state
- [ ] Validate new configuration before applying
- [ ] Rollback on validation failure
- [ ] Maintain query processing during reload

**Estimated Time**: 3-4 hours

#### 1.3 Reload Telemetry
- [ ] Add reload success/failure events
- [ ] Track reload duration
- [ ] Log configuration changes (added/removed/modified views)
- [ ] Emit warnings for invalid configurations
- [ ] Statistics on reload frequency

**Estimated Time**: 1-2 hours

#### 1.4 Testing
- [ ] Test file change detection
- [ ] Test atomic view updates
- [ ] Test validation and rollback
- [ ] Test concurrent queries during reload
- [ ] Integration tests for hot-reload

**Estimated Time**: 3-4 hours

**Total Week 1**: ~9-13 hours

---

### Week 2: Response Rate Limiting (RRL)

**Goal**: Protect against DNS amplification attacks and abusive clients

#### 2.1 RRL Algorithm
- [ ] Implement token bucket algorithm
- [ ] Per-client IP rate limiting
- [ ] Per-query-type rate limiting
- [ ] Slip mode (1 in N responses for legitimate retries)
- [ ] Configurable rates and windows

**Estimated Time**: 4-5 hours

#### 2.2 RRL State Management
- [ ] ETS-based rate limit tracking
- [ ] Automatic cleanup of expired entries
- [ ] Memory limits for tracking table
- [ ] Statistics on rate-limited queries

**Estimated Time**: 2-3 hours

#### 2.3 Configuration
- [ ] TOML configuration for RRL settings
- [ ] Per-view RRL overrides
- [ ] Whitelist for trusted clients
- [ ] Response size thresholds

**Estimated Time**: 2-3 hours

#### 2.4 Testing
- [ ] Test rate limiting enforcement
- [ ] Test slip mode behavior
- [ ] Test whitelist functionality
- [ ] Performance testing with high query rates
- [ ] Integration tests

**Estimated Time**: 3-4 hours

**Total Week 2**: ~11-15 hours

---

### Week 3: Per-View Caching

**Goal**: Prevent cache poisoning across views with isolated caches

#### 3.1 Cache Namespace Isolation
- [ ] Extend `Cache.Manager` to support namespaces
- [ ] Per-view cache namespaces
- [ ] Namespace-based cache key generation
- [ ] View-specific cache policies (TTL overrides)

**Estimated Time**: 3-4 hours

#### 3.2 Cache Statistics
- [ ] Per-view cache statistics
- [ ] Hit/miss rates per view
- [ ] Memory usage per view
- [ ] Eviction tracking per view

**Estimated Time**: 2-3 hours

#### 3.3 Cache Cleanup
- [ ] Automatic namespace cleanup on view removal
- [ ] Configurable per-view cache sizes
- [ ] LRU eviction within namespaces
- [ ] Manual cache invalidation API

**Estimated Time**: 2-3 hours

#### 3.4 Testing
- [ ] Test cache isolation between views
- [ ] Test cache invalidation
- [ ] Test memory limits
- [ ] Performance testing with multiple views
- [ ] Integration tests

**Estimated Time**: 3-4 hours

**Total Week 3**: ~10-14 hours

---

### Week 4: Enhanced Telemetry

**Goal**: Production-grade monitoring and observability

#### 4.1 Metrics Aggregation
- [ ] Per-view query statistics
- [ ] Response time histograms
- [ ] Error rate tracking
- [ ] Cache performance metrics
- [ ] RRL statistics

**Estimated Time**: 3-4 hours

#### 4.2 Prometheus Integration
- [ ] Add `telemetry_metrics_prometheus` dependency
- [ ] Expose metrics endpoint
- [ ] Configure standard DNS metrics
- [ ] Custom view-based metrics
- [ ] Grafana dashboard examples

**Estimated Time**: 4-5 hours

#### 4.3 Structured Logging
- [ ] Standardize log formats
- [ ] Add request IDs for tracing
- [ ] Log sampling for high-volume events
- [ ] Configurable log levels per component
- [ ] JSON logging option

**Estimated Time**: 2-3 hours

#### 4.4 Health Checks
- [ ] Health check endpoint
- [ ] Readiness probe (zones loaded, cache initialized)
- [ ] Liveness probe (handler responding)
- [ ] Dependency health (upstream servers)

**Estimated Time**: 2-3 hours

**Total Week 4**: ~11-15 hours

---

## 📊 Phase 4 Summary

### Total Estimated Time
- **Week 1** (Hot-Reload): 9-13 hours
- **Week 2** (RRL): 11-15 hours
- **Week 3** (Per-View Caching): 10-14 hours
- **Week 4** (Telemetry): 11-15 hours
- **Total**: 41-57 hours (~1-1.5 months at steady pace)

### Deliverables

**Code Components**:
1. `View.ConfigWatcher` - File system watching for config changes
2. `Handler.reload_views/1` - Atomic view updates
3. `RateLimit.Manager` - RRL implementation
4. `Cache.Namespace` - Per-view cache isolation
5. Prometheus metrics integration
6. Health check endpoints

**Tests**:
- 50+ new tests across all components
- Integration tests for each feature
- Performance tests for RRL and caching

**Documentation**:
- Hot-reload configuration guide
- RRL tuning guide
- Cache configuration reference
- Monitoring and metrics guide
- Health check documentation

### Success Criteria

- [ ] Configuration can be reloaded without downtime
- [ ] RRL protects against amplification attacks
- [ ] Views have isolated cache namespaces
- [ ] Prometheus metrics available for all components
- [ ] Health checks pass in production
- [ ] 100% test coverage for new features
- [ ] Zero breaking changes to existing deployments

---

## 🔧 Technical Design

### Hot-Reload Architecture

```
FileSystem Change → ConfigWatcher
  ↓
Debounce (300ms)
  ↓
Load new configuration → ViewConfig.load_file/1
  ↓
Validate views → View.validate/1
  ↓
If valid: Handler.reload_views(new_views)
  ↓
Atomic swap: old_views → new_views
  ↓
Telemetry event: [:dns, :view, :reload]
  ↓
Log changes: added, removed, modified views
```

### RRL Data Structure

```elixir
# ETS Table: :dns_rate_limits
# Key: {client_ip, query_type, response_size_class}
# Value: {token_count, last_refill_time}

def check_rate_limit(client_ip, qtype, response_size) do
  key = {client_ip, qtype, size_class(response_size)}

  case :ets.lookup(:dns_rate_limits, key) do
    [{^key, {tokens, last_time}}] ->
      refill_tokens(tokens, last_time)

    [] ->
      :ets.insert(:dns_rate_limits, {key, {max_tokens - 1, now()}})
      :allow
  end
end
```

### Per-View Cache Namespacing

```elixir
# Cache key format: {view_name, zone_name, qname, qtype}
# Instead of: {zone_name, qname, qtype}

def cache_lookup(view, zone_name, qname, qtype) do
  key = {view.name, zone_name, qname, qtype}
  Cache.Manager.lookup(key)
end

def cache_insert(view, zone_name, qname, qtype, records, ttl) do
  key = {view.name, zone_name, qname, qtype}
  Cache.Manager.insert(key, records, ttl)
end
```

---

## 🎯 Implementation Priority

### Phase 4.1: Hot-Reload (Week 1) - HIGHEST PRIORITY
**Rationale**: Most requested feature, enables rapid iteration in production

**Why First**:
- Immediate operational value
- Builds on existing View.Config work
- Relatively low risk
- Clear success criteria

### Phase 4.2: RRL (Week 2) - HIGH PRIORITY
**Rationale**: Critical security feature

**Why Second**:
- Protects against DDoS attacks
- Essential for public-facing DNS
- Independent of other Phase 4 features

### Phase 4.3: Per-View Caching (Week 3) - MEDIUM PRIORITY
**Rationale**: Prevents cache poisoning, enhances security

**Why Third**:
- Security enhancement
- Depends on cache system understanding
- Can leverage existing Cache.Manager

### Phase 4.4: Enhanced Telemetry (Week 4) - MEDIUM PRIORITY
**Rationale**: Production observability

**Why Last**:
- Builds on all other features
- Can showcase metrics from RRL, caching, views
- Less critical for initial production deployment

---

## 📚 Dependencies

### New Elixir Dependencies

```elixir
# mix.exs additions
{:file_system, "~> 1.0"},              # File watching for hot-reload
{:telemetry_metrics_prometheus, "~> 1.1"},  # Prometheus metrics
```

### System Requirements
- File system with inotify/fsevents support (for hot-reload)
- Prometheus server (optional, for metrics)
- Grafana (optional, for dashboards)

---

## 🧪 Testing Strategy

### Unit Tests
- ConfigWatcher file watching
- View validation and reload
- RRL token bucket algorithm
- Cache namespace isolation
- Metrics collection

### Integration Tests
- End-to-end hot-reload scenarios
- RRL under load
- Multi-view cache isolation
- Metrics endpoint responses

### Performance Tests
- Reload performance (time to update views)
- RRL throughput with limiting
- Cache performance per view
- Metrics collection overhead

### Load Tests
- Concurrent queries during reload
- High query rate with RRL enabled
- Cache hit rates under load
- Metrics endpoint under load

---

## 🔄 Backward Compatibility

All Phase 4 features are **100% backward compatible**:

- **Hot-Reload**: Optional, disabled if `file_system` not available
- **RRL**: Disabled by default, opt-in via configuration
- **Per-View Caching**: Automatic, no config changes required
- **Telemetry**: Additive, existing telemetry unchanged

**Migration Path**: None required. All features are optional or automatic.

---

## 🚀 Production Deployment

### Configuration Example

```toml
# config/dns.toml

[server]
hot_reload = true
config_watch_path = "/etc/yellowdog/views.toml"

[rate_limiting]
enabled = true
queries_per_second = 100
burst = 200
slip_rate = 2  # 1 in 2 responses during limiting

[cache]
per_view_isolation = true
default_size_mb = 100

[telemetry]
prometheus_port = 9091
log_level = "info"
log_format = "json"

[health_check]
enabled = true
port = 8080
path = "/health"
```

### Monitoring Setup

**Prometheus Metrics**:
```
dns_queries_total{view="internal", qtype="A"}
dns_cache_hits_total{view="internal"}
dns_rate_limited_total{client="192.168.1.0/24"}
dns_reload_duration_seconds
dns_view_queries_per_second{view="external"}
```

**Grafana Dashboard**:
- Query rate by view
- Cache hit rate trends
- RRL effectiveness
- Reload event timeline
- Response time histograms

---

## 🎓 Success Metrics

### Operational Metrics
- Configuration reload time < 100ms
- Zero query drops during reload
- RRL blocks 99%+ of attack traffic
- Cache hit rate > 80% in production
- Metrics collection overhead < 1%

### Quality Metrics
- 100% test coverage for new code
- All integration tests passing
- Performance tests show acceptable overhead
- Documentation complete and reviewed

### Production Readiness
- Successfully deployed in staging
- Load testing completed
- Monitoring dashboards configured
- Runbook created for operations team
- Security review passed

---

## 📖 Documentation Deliverables

1. **HOT_RELOAD.md** - Hot-reload configuration and usage
2. **RRL_GUIDE.md** - Response rate limiting tuning guide
3. **CACHING.md** - Cache configuration and per-view isolation
4. **MONITORING.md** - Metrics, logging, and health checks
5. **PHASE4_COMPLETE.md** - Phase 4 completion summary

---

## 🔮 Future Enhancements (Phase 5+)

After Phase 4 completion, potential next phases:

**Phase 5: Zone Transfer**
- AXFR/IXFR implementation
- NOTIFY mechanism
- Secondary zone support

**Phase 6: DNSSEC**
- DNSSEC signing
- Key management
- Validation

**Phase 7: Management API**
- REST API for zone management
- WebSocket for real-time updates
- CLI tool for administration

---

**Phase 4 Status**: 📋 Planning Complete

**Next Action**: Begin implementation with Week 1 (Hot-Reload)

**Estimated Completion**: 4-6 weeks at steady pace

---

**Last Updated**: 2025-11-02
**Version**: YellowDog DNS 0.1.0
