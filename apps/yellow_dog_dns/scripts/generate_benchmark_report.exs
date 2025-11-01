#!/usr/bin/env elixir

# DNS Cache Benchmark Report Generator
#
# This script generates a comprehensive performance report for the DNS cache.
# Run with: mix run scripts/generate_benchmark_report.exs

defmodule BenchmarkReport do
  @moduledoc """
  Generates a comprehensive performance report for DNS cache benchmarks.
  """

  alias YellowDog.Dns.Query.Cache.Manager
  alias YellowDog.Dns.Zone

  def generate do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("DNS CACHE PERFORMANCE BENCHMARK REPORT")
    IO.puts(String.duplicate("=", 80) <> "\n")

    print_test_environment()
    print_cache_configuration()

    # Start cache for testing
    {:ok, _pid} =
      Manager.start_link(
        name: :benchmark_cache,
        max_entries: 50_000,
        max_memory_bytes: 200 * 1024 * 1024
      )

    print_throughput_metrics()
    print_latency_metrics()
    print_memory_metrics()
    print_concurrent_performance()
    print_cache_effectiveness()
    print_recommendations()

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("REPORT GENERATION COMPLETE")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  defp print_test_environment do
    IO.puts("## Test Environment")
    IO.puts("")
    IO.puts("- Elixir: #{System.version()}")
    IO.puts("- OTP: #{:erlang.system_info(:otp_release)}")
    IO.puts("- System: #{:erlang.system_info(:system_architecture)}")
    IO.puts("- Schedulers: #{:erlang.system_info(:schedulers_online)}")
    IO.puts("- Date: #{DateTime.utc_now() |> DateTime.to_string()}")
    IO.puts("")
  end

  defp print_cache_configuration do
    IO.puts("## Cache Configuration")
    IO.puts("")
    IO.puts("- Max entries: 50,000")
    IO.puts("- Max memory: 200MB")
    IO.puts("- Cleanup interval: 60s")
    IO.puts("- Table type: ETS :set")
    IO.puts("- Read concurrency: enabled")
    IO.puts("- Write concurrency: enabled")
    IO.puts("")
  end

  defp print_throughput_metrics do
    IO.puts("## Throughput Metrics")
    IO.puts("")

    # Test insert throughput
    insert_qps = measure_insert_throughput(10_000)
    IO.puts("- Cache insert: #{format_number(insert_qps)} ops/sec")

    # Test lookup throughput (hits)
    lookup_hit_qps = measure_lookup_throughput(:hit, 50_000)
    IO.puts("- Cache lookup (hit): #{format_number(lookup_hit_qps)} ops/sec")

    # Test lookup throughput (miss)
    lookup_miss_qps = measure_lookup_throughput(:miss, 50_000)
    IO.puts("- Cache lookup (miss): #{format_number(lookup_miss_qps)} ops/sec")

    IO.puts("")
  end

  defp print_latency_metrics do
    IO.puts("## Latency Metrics")
    IO.puts("")

    # Measure lookup latencies
    hit_latencies = measure_latencies(:hit, 10_000)
    miss_latencies = measure_latencies(:miss, 10_000)

    IO.puts("### Lookup (Hit)")
    print_latency_percentiles(hit_latencies)
    IO.puts("")

    IO.puts("### Lookup (Miss)")
    print_latency_percentiles(miss_latencies)
    IO.puts("")
  end

  defp print_memory_metrics do
    IO.puts("## Memory Usage")
    IO.puts("")

    measurements = [
      {1_000, measure_memory_usage(1_000)},
      {10_000, measure_memory_usage(10_000)},
      {50_000, measure_memory_usage(50_000)}
    ]

    Enum.each(measurements, fn {count, memory_mb} ->
      avg_per_entry = memory_mb * 1024 / count
      IO.puts("- #{format_number(count)} entries: #{Float.round(memory_mb, 2)}MB (#{Float.round(avg_per_entry, 2)}KB per entry)")
    end)

    IO.puts("")
  end

  defp print_concurrent_performance do
    IO.puts("## Concurrent Performance")
    IO.puts("")

    # Test concurrent reads
    {read_qps, read_duration} = measure_concurrent_reads(10_000)
    IO.puts("- 10,000 concurrent reads: #{Float.round(read_qps, 0)} QPS (#{read_duration}ms total)")

    # Test concurrent writes
    {write_qps, write_duration} = measure_concurrent_writes(1_000)
    IO.puts("- 1,000 concurrent writes: #{Float.round(write_qps, 0)} ops/sec (#{write_duration}ms total)")

    # Test mixed workload
    {mixed_qps, mixed_duration} = measure_mixed_workload(10_000)
    IO.puts("- 10,000 mixed operations (70% read): #{Float.round(mixed_qps, 0)} ops/sec (#{mixed_duration}ms total)")

    IO.puts("")
  end

  defp print_cache_effectiveness do
    IO.puts("## Cache Effectiveness")
    IO.puts("")

    # Simulate realistic workload
    {hit_rate, qps} = measure_realistic_workload(10_000)

    IO.puts("### Realistic Workload Simulation")
    IO.puts("- Pattern: 70% hot domains, 20% random, 10% negative")
    IO.puts("- Hit rate: #{Float.round(hit_rate, 2)}%")
    IO.puts("- Throughput: #{Float.round(qps, 0)} QPS")
    IO.puts("")
  end

  defp print_recommendations do
    IO.puts("## Recommendations")
    IO.puts("")
    IO.puts("### Optimal Configuration")
    IO.puts("- For high-traffic scenarios (>10K QPS):")
    IO.puts("  - Max entries: 50,000 - 100,000")
    IO.puts("  - Max memory: 200MB - 500MB")
    IO.puts("  - Cleanup interval: 30s - 60s")
    IO.puts("")
    IO.puts("- For low-traffic scenarios (<1K QPS):")
    IO.puts("  - Max entries: 10,000 - 20,000")
    IO.puts("  - Max memory: 50MB - 100MB")
    IO.puts("  - Cleanup interval: 60s - 300s")
    IO.puts("")
    IO.puts("### Performance Notes")
    IO.puts("- Cache provides significant performance improvement for repeated queries")
    IO.puts("- Hit rate of 60%+ achieves optimal benefit")
    IO.puts("- Memory usage is approximately 5-10KB per cached entry")
    IO.puts("- Concurrent access is highly efficient with ETS read/write concurrency")
    IO.puts("")
  end

  # Helper functions for measurements

  defp generate_record(name, type, rdata) do
    Zone.Record.new(name, type, rdata, ttl: 300, class: :IN)
  end

  defp measure_insert_throughput(count) do
    Manager.clear()

    {time_us, _} =
      :timer.tc(fn ->
        Enum.each(1..count, fn i ->
          name = "test-#{i}.example.com"
          records = [generate_record(name, :A, {192, 168, div(i, 256), rem(i, 256)})]
          Manager.put(name, :A, records, [], 300)
        end)
      end)

    count / (time_us / 1_000_000)
  end

  defp measure_lookup_throughput(type, count) do
    Manager.clear()

    # Pre-populate for hit tests
    if type == :hit do
      Enum.each(1..1000, fn i ->
        name = "cached-#{i}.example.com"
        records = [generate_record(name, :A, {192, 168, div(i, 256), rem(i, 256)})]
        Manager.put(name, :A, records, [], 300)
      end)
    end

    {time_us, _} =
      :timer.tc(fn ->
        Enum.each(1..count, fn i ->
          name =
            if type == :hit do
              "cached-#{rem(i, 1000) + 1}.example.com"
            else
              "nonexistent-#{i}.example.com"
            end

          Manager.get(name, :A)
        end)
      end)

    count / (time_us / 1_000_000)
  end

  defp measure_latencies(type, count) do
    Manager.clear()

    # Pre-populate for hit tests
    if type == :hit do
      Enum.each(1..1000, fn i ->
        name = "cached-#{i}.example.com"
        records = [generate_record(name, :A, {192, 168, div(i, 256), rem(i, 256)})]
        Manager.put(name, :A, records, [], 300)
      end)
    end

    Enum.map(1..count, fn i ->
      name =
        if type == :hit do
          "cached-#{rem(i, 1000) + 1}.example.com"
        else
          "nonexistent-#{i}.example.com"
        end

      {time_us, _} =
        :timer.tc(fn ->
          Manager.get(name, :A)
        end)

      time_us
    end)
  end

  defp measure_memory_usage(count) do
    Manager.clear()

    Enum.each(1..count, fn i ->
      name = "test-#{i}.example.com"
      records = [generate_record(name, :A, {192, 168, div(i, 256), rem(i, 256)})]
      Manager.put(name, :A, records, [], 300)
    end)

    stats = Manager.stats()
    stats.memory_mb
  end

  defp measure_concurrent_reads(count) do
    Manager.clear()

    # Pre-populate cache
    Enum.each(1..1000, fn i ->
      name = "cached-#{i}.example.com"
      records = [generate_record(name, :A, {192, 168, div(i, 256), rem(i, 256)})]
      Manager.put(name, :A, records, [], 300)
    end)

    {time_ms, _} =
      :timer.tc(fn ->
        tasks =
          Enum.map(1..count, fn i ->
            Task.async(fn ->
              name = "cached-#{rem(i, 1000) + 1}.example.com"
              Manager.get(name, :A)
            end)
          end)

        Task.await_many(tasks, 30_000)
      end)

    time_ms = div(time_ms, 1000)
    qps = count / (time_ms / 1000)
    {qps, time_ms}
  end

  defp measure_concurrent_writes(count) do
    Manager.clear()

    {time_ms, _} =
      :timer.tc(fn ->
        tasks =
          Enum.map(1..count, fn i ->
            Task.async(fn ->
              name = "test-#{i}.example.com"
              records = [generate_record(name, :A, {192, 168, div(i, 256), rem(i, 256)})]
              Manager.put(name, :A, records, [], 300)
            end)
          end)

        Task.await_many(tasks, 30_000)
      end)

    time_ms = div(time_ms, 1000)
    ops_per_sec = count / (time_ms / 1000)
    {ops_per_sec, time_ms}
  end

  defp measure_mixed_workload(count) do
    Manager.clear()

    # Pre-populate
    Enum.each(1..100, fn i ->
      name = "cached-#{i}.example.com"
      records = [generate_record(name, :A, {192, 168, div(i, 256), rem(i, 256)})]
      Manager.put(name, :A, records, [], 300)
    end)

    {time_ms, _} =
      :timer.tc(fn ->
        tasks =
          Enum.map(1..count, fn i ->
            Task.async(fn ->
              if rem(i, 10) < 7 do
                # Read (70%)
                name = "cached-#{rem(i, 100) + 1}.example.com"
                Manager.get(name, :A)
              else
                # Write (30%)
                name = "new-#{i}.example.com"
                records = [generate_record(name, :A, {10, 0, div(i, 256), rem(i, 256)})]
                Manager.put(name, :A, records, [], 300)
              end
            end)
          end)

        Task.await_many(tasks, 30_000)
      end)

    time_ms = div(time_ms, 1000)
    ops_per_sec = count / (time_ms / 1000)
    {ops_per_sec, time_ms}
  end

  defp measure_realistic_workload(count) do
    Manager.clear()

    # Create 100 hot domains
    hot_domains =
      Enum.map(1..100, fn i ->
        name = "hot-#{i}.example.com"
        records = [generate_record(name, :A, {192, 168, div(i, 256), rem(i, 256)})]
        Manager.put(name, :A, records, [], 300)
        name
      end)

    {time_ms, _} =
      :timer.tc(fn ->
        Enum.each(1..count, fn i ->
          name =
            cond do
              rem(i, 10) < 7 -> Enum.random(hot_domains)
              rem(i, 10) < 9 -> "random-#{i}.example.com"
              true -> "negative-#{i}.invalid"
            end

          Manager.get(name, :A)
        end)
      end)

    time_ms = div(time_ms, 1000)
    stats = Manager.stats()
    qps = count / (time_ms / 1000)
    {stats.hit_rate, qps}
  end

  defp print_latency_percentiles(latencies) do
    sorted = Enum.sort(latencies)
    count = length(sorted)

    p50 = Enum.at(sorted, div(count, 2))
    p95 = Enum.at(sorted, div(count * 95, 100))
    p99 = Enum.at(sorted, div(count * 99, 100))
    avg = Enum.sum(sorted) / count

    IO.puts("- Average: #{Float.round(avg, 1)}μs")
    IO.puts("- P50: #{p50}μs")
    IO.puts("- P95: #{p95}μs")
    IO.puts("- P99: #{p99}μs")
  end

  defp format_number(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 2)}M"
  end

  defp format_number(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 2)}K"
  end

  defp format_number(num) do
    "#{Float.round(num, 0)}"
  end
end

# Run the report generator
BenchmarkReport.generate()
