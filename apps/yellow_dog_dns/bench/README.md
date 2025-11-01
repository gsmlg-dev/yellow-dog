# DNS Cache Benchmarks

This directory contains comprehensive performance benchmarks for the YellowDog DNS cache implementation.

## Overview

The benchmark suite measures:
- **Throughput**: Operations per second for inserts and lookups
- **Latency**: Response times (P50, P95, P99 percentiles)
- **Concurrency**: Performance under concurrent load
- **Memory Usage**: Memory consumption at various cache sizes
- **Cache Effectiveness**: Hit rates under realistic workloads

## Quick Start

### Run All Benchmarks

```bash
cd apps/yellow_dog_dns
./scripts/run_cache_benchmarks.sh
```

### Run Individual Benchmarks

```bash
# Benchee benchmarks (detailed performance metrics)
mix run bench/cache_bench.exs

# Performance tests (verify performance requirements)
mix test test/yellow_dog/dns/cache_performance_test.exs --include performance

# Load tests (realistic workload simulation)
mix test test/yellow_dog/dns/cache_load_test.exs --include load

# Generate comprehensive report
mix run scripts/generate_benchmark_report.exs
```

### Quick vs Full Benchmarks

```bash
# Quick benchmarks (2 seconds per scenario)
./scripts/run_cache_benchmarks.sh --quick

# Full benchmarks (10 seconds per scenario)
./scripts/run_cache_benchmarks.sh --full

# Only performance tests
./scripts/run_cache_benchmarks.sh --performance

# Only load tests
./scripts/run_cache_benchmarks.sh --load
```

## Benchmark Files

### `cache_bench.exs`

Benchee-based benchmarks measuring:

1. **Basic Cache Operations**
   - Insert (small records)
   - Insert (large records)
   - Lookup (cache hit)
   - Lookup (cache miss)

2. **Concurrent Operations**
   - 100 concurrent inserts
   - 1,000 concurrent lookups
   - Mixed workload (1,000 operations, 70% read/30% write)

3. **TTL Management**
   - Cleanup with empty cache
   - Cleanup with 1,000 active entries
   - Cleanup with 1,000 expired entries

4. **Memory Usage**
   - Populate 1,000 entries
   - Populate 10,000 entries

### `cache_performance_test.exs`

Performance tests verifying requirements:

- **Insert Performance**: < 100μs per insert
- **Lookup Performance**: < 50μs per lookup
- **Concurrent Performance**: 10,000 ops in < 2-3s
- **Cleanup Performance**: 10,000 expired entries in < 500ms
- **Memory Usage**: < 100MB for 10,000 entries
- **Throughput**: > 10,000 QPS

### `cache_load_test.exs`

Load tests simulating realistic scenarios:

1. **Realistic Workload**: 70% hot domains, 20% random, 10% negative
2. **Sustained Load**: 30-second continuous query load
3. **Concurrent Clients**: 100 clients with 100 queries each
4. **Stress Test**: 50,000 unique entries
5. **TTL Expiration**: Verify expiration under load
6. **Memory Pressure**: LRU eviction when limits reached

## Expected Results

### Throughput Metrics

- Cache insert: 50,000+ ops/sec
- Cache lookup (hit): 500,000+ ops/sec
- Cache lookup (miss): 450,000+ ops/sec

### Latency Metrics (Microseconds)

| Operation | P50 | P95 | P99 |
|-----------|-----|-----|-----|
| Lookup (hit) | 2μs | 5μs | 10μs |
| Lookup (miss) | 3μs | 6μs | 12μs |

### Query Resolution

| Metric | With Cache | Without Cache | Speedup |
|--------|------------|---------------|---------|
| QPS | 10,000+ | ~1,000 | 10x |
| Avg Latency | 100μs | 1000μs | 10x |

### Memory Usage

| Entries | Memory Usage | Per Entry |
|---------|-------------|-----------|
| 1,000 | 5MB | 5KB |
| 10,000 | 50MB | 5KB |
| 100,000 | 500MB | 5KB |

### Cache Hit Rate

- Realistic workload: 65-70%
- Optimal configuration: 70%+

## Performance Requirements

The cache must meet these requirements:

1. **Throughput**: > 10,000 QPS
2. **Hit Rate**: > 60% under realistic load
3. **Memory**: < 100MB for 10,000 entries
4. **Latency**: P95 < 10μs for lookups
5. **Concurrency**: Handle 1,000+ concurrent operations
6. **Cleanup**: No impact on query performance

## Configuration Recommendations

### High-Traffic Scenarios (>10K QPS)

```elixir
max_entries: 50_000 - 100_000
max_memory_bytes: 200_000_000 - 500_000_000  # 200-500MB
cleanup_interval_ms: 30_000 - 60_000  # 30-60s
```

### Low-Traffic Scenarios (<1K QPS)

```elixir
max_entries: 10_000 - 20_000
max_memory_bytes: 50_000_000 - 100_000_000  # 50-100MB
cleanup_interval_ms: 60_000 - 300_000  # 60-300s
```

## Interpreting Results

### Good Performance Indicators

- ✓ Cache hit rate > 60%
- ✓ QPS > 10,000
- ✓ P95 latency < 10μs
- ✓ Memory < 10KB per entry
- ✓ No evictions under normal load

### Performance Issues

- ✗ Cache hit rate < 50%: Increase max_entries or review query patterns
- ✗ High eviction rate: Increase max_entries or max_memory_bytes
- ✗ High P99 latency: Check for concurrent write contention
- ✗ Memory usage > 10KB per entry: Review record sizes

## Continuous Benchmarking

Run benchmarks:

1. **Before Changes**: Establish baseline performance
2. **After Changes**: Compare against baseline
3. **Regression Detection**: Ensure no performance degradation
4. **CI Integration**: Include performance tests in CI pipeline

## Benchmark Output

Results are saved to `benchmark_results/`:

```
benchmark_results/
├── benchmark_report_20251029_120000.txt  # Comprehensive report
├── benchee_20251029_120000.txt           # Benchee output
├── performance_20251029_120000.txt       # Performance test output
└── load_20251029_120000.txt              # Load test output
```

## Notes

- Benchmarks should run on consistent hardware for valid comparisons
- Some variability is expected due to system load
- Run multiple iterations and average results for production baselines
- Monitor system resources (CPU, memory, I/O) during benchmarks
- Benchmarks use tagged tests (`:performance`, `:load`) to avoid running in regular test suite
