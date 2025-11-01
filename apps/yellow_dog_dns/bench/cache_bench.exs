# DNS Cache Performance Benchmarks
#
# Run with: mix run bench/cache_bench.exs
#
# This benchmark suite measures the performance of DNS cache operations
# including inserts, lookups, concurrent access, and cleanup operations.

Mix.install([{:benchee, "~> 1.3"}])

# Setup test data
defmodule BenchHelper do
  alias YellowDog.Dns.Zone

  def generate_record(name, type, rdata) do
    Zone.Record.new(name, type, rdata, ttl: 300, class: :IN)
  end

  def generate_small_record do
    name = "example-#{:rand.uniform(10000)}.com"
    type = :A
    records = [generate_record(name, :A, {192, 168, 1, 100})]
    authority = []
    ttl = 300
    {name, type, records, authority, ttl}
  end

  def generate_large_record do
    name = "large-#{:rand.uniform(10000)}.com"
    type = :TXT
    # Create a large TXT record with multiple strings
    txt_data = String.duplicate("Lorem ipsum dolor sit amet, ", 10)
    records = [generate_record(name, :TXT, txt_data)]
    authority = [
      generate_record("example.com.", :NS, "ns1.example.com."),
      generate_record("example.com.", :NS, "ns2.example.com.")
    ]
    ttl = 3600
    {name, type, records, authority, ttl}
  end

  def generate_queries(count) do
    Enum.map(1..count, fn i ->
      if rem(i, 2) == 0 do
        {"example-#{rem(i, 100)}.com", :A}
      else
        {"test-#{rem(i, 100)}.com", :AAAA}
      end
    end)
  end

  def populate_cache(cache_pid, count) do
    Enum.each(1..count, fn i ->
      name = "cached-#{i}.com"
      type = :A
      records = [generate_record(name, :A, {10, 0, i div 256, rem(i, 256)})]
      YellowDog.Dns.Query.Cache.Manager.put(name, type, records, [], 300)
    end)
  end
end

# Start the cache manager
{:ok, cache_pid} = YellowDog.Dns.Query.Cache.Manager.start_link(
  name: :bench_cache,
  max_entries: 100_000,
  max_memory_bytes: 500 * 1024 * 1024
)

IO.puts("\n=== DNS Cache Performance Benchmarks ===\n")

# Benchmark 1: Basic Cache Operations
IO.puts("Running basic cache operations benchmarks...")

Benchee.run(
  %{
    "cache_insert_small" => fn {name, type, records, authority, ttl} ->
      YellowDog.Dns.Query.Cache.Manager.put(name, type, records, authority, ttl)
    end,
    "cache_insert_large" => fn {name, type, records, authority, ttl} ->
      YellowDog.Dns.Query.Cache.Manager.put(name, type, records, authority, ttl)
    end,
    "cache_lookup_hit" => fn {name, type} ->
      YellowDog.Dns.Query.Cache.Manager.get(name, type)
    end,
    "cache_lookup_miss" => fn {name, type} ->
      YellowDog.Dns.Query.Cache.Manager.get(name, type)
    end
  },
  inputs: %{
    "small_record" => BenchHelper.generate_small_record(),
    "large_record" => BenchHelper.generate_large_record()
  },
  before_scenario: fn input ->
    # Clear cache before each scenario
    YellowDog.Dns.Query.Cache.Manager.clear()

    # For hit scenarios, pre-populate cache
    case input do
      {name, type, records, authority, ttl} ->
        if String.contains?(elem(0, input), "cached") do
          YellowDog.Dns.Query.Cache.Manager.put(name, type, records, authority, ttl)
        end

        input

      {name, type} ->
        # This is a lookup scenario
        if String.contains?(name, "cached") do
          records = [BenchHelper.generate_record(name, type, {192, 168, 1, 1})]
          YellowDog.Dns.Query.Cache.Manager.put(name, type, records, [], 300)
        end

        input
    end
  end,
  time: 5,
  memory_time: 1,
  formatters: [
    Benchee.Formatters.Console
  ]
)

# Benchmark 2: Concurrent Operations
IO.puts("\nRunning concurrent operations benchmarks...")

YellowDog.Dns.Query.Cache.Manager.clear()

Benchee.run(
  %{
    "concurrent_inserts_100" => fn _input ->
      tasks =
        Enum.map(1..100, fn i ->
          Task.async(fn ->
            {name, type, records, authority, ttl} = BenchHelper.generate_small_record()
            name = "concurrent-#{i}-#{name}"
            YellowDog.Dns.Query.Cache.Manager.put(name, type, records, authority, ttl)
          end)
        end)

      Task.await_many(tasks, 5000)
    end,
    "concurrent_lookups_1000" => fn _input ->
      # Pre-populate cache
      BenchHelper.populate_cache(cache_pid, 100)

      tasks =
        Enum.map(1..1000, fn i ->
          Task.async(fn ->
            name = "cached-#{rem(i, 100) + 1}.com"
            YellowDog.Dns.Query.Cache.Manager.get(name, :A)
          end)
        end)

      Task.await_many(tasks, 5000)
    end,
    "mixed_workload_1000" => fn _input ->
      # Pre-populate cache
      BenchHelper.populate_cache(cache_pid, 50)

      tasks =
        Enum.map(1..1000, fn i ->
          Task.async(fn ->
            if rem(i, 3) == 0 do
              # Insert (33%)
              {name, type, records, authority, ttl} = BenchHelper.generate_small_record()
              YellowDog.Dns.Query.Cache.Manager.put(name, type, records, authority, ttl)
            else
              # Lookup (67%)
              name = "cached-#{rem(i, 50) + 1}.com"
              YellowDog.Dns.Query.Cache.Manager.get(name, :A)
            end
          end)
        end)

      Task.await_many(tasks, 5000)
    end
  },
  before_scenario: fn _input ->
    YellowDog.Dns.Query.Cache.Manager.clear()
    :ok
  end,
  time: 5,
  formatters: [Benchee.Formatters.Console]
)

# Benchmark 3: TTL Management and Cleanup
IO.puts("\nRunning TTL management benchmarks...")

Benchee.run(
  %{
    "cleanup_empty_cache" => fn _input ->
      YellowDog.Dns.Query.Cache.Manager.cleanup()
    end,
    "cleanup_1000_active" => fn _input ->
      # Populate with active entries (long TTL)
      Enum.each(1..1000, fn i ->
        name = "active-#{i}.com"
        records = [BenchHelper.generate_record(name, :A, {10, 0, 0, i})]
        YellowDog.Dns.Query.Cache.Manager.put(name, :A, records, [], 3600)
      end)

      YellowDog.Dns.Query.Cache.Manager.cleanup()
    end,
    "cleanup_1000_expired" => fn _input ->
      # Populate with expired entries (TTL = 0)
      Enum.each(1..1000, fn i ->
        name = "expired-#{i}.com"
        records = [BenchHelper.generate_record(name, :A, {10, 0, 0, i})]
        YellowDog.Dns.Query.Cache.Manager.put(name, :A, records, [], 0)
      end)

      # Wait for expiration
      Process.sleep(1000)

      YellowDog.Dns.Query.Cache.Manager.cleanup()
    end
  },
  before_scenario: fn _input ->
    YellowDog.Dns.Query.Cache.Manager.clear()
    :ok
  end,
  time: 3,
  formatters: [Benchee.Formatters.Console]
)

# Benchmark 4: Memory Usage
IO.puts("\nRunning memory usage benchmarks...")

Benchee.run(
  %{
    "populate_1000_entries" => fn _input ->
      BenchHelper.populate_cache(cache_pid, 1000)
    end,
    "populate_10000_entries" => fn _input ->
      BenchHelper.populate_cache(cache_pid, 10000)
    end
  },
  before_scenario: fn _input ->
    YellowDog.Dns.Query.Cache.Manager.clear()
    :ok
  end,
  time: 3,
  memory_time: 2,
  formatters: [Benchee.Formatters.Console]
)

# Print final statistics
IO.puts("\n=== Final Cache Statistics ===")
stats = YellowDog.Dns.Query.Cache.Manager.stats()

IO.puts("""
Entries: #{stats.entries}
Memory: #{stats.memory_mb} MB
Hits: #{stats.hits}
Misses: #{stats.misses}
Hit Rate: #{stats.hit_rate}%
Evictions: #{stats.evictions}
Expirations: #{stats.expirations}
""")

IO.puts("\n=== Benchmarks Complete ===\n")
