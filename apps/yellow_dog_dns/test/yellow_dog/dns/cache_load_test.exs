defmodule YellowDog.Dns.CacheLoadTest do
  @moduledoc """
  Load tests for DNS cache under realistic workloads.

  These tests simulate real-world DNS query patterns and measure
  cache performance under sustained load.

  Run with: mix test test/yellow_dog/dns/cache_load_test.exs --include load
  """

  use ExUnit.Case, async: false

  alias YellowDog.Dns.Query.Cache.Manager
  alias YellowDog.Dns.Query.Cache.Stats
  alias YellowDog.Dns.Zone

  @moduletag :load
  @moduletag timeout: 120_000

  setup do
    # Start cache with production-like configuration
    {:ok, pid} =
      Manager.start_link(
        name: :load_test_cache,
        max_entries: 50_000,
        max_memory_bytes: 200 * 1024 * 1024,
        cleanup_interval_ms: 30_000
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        GenServer.stop(pid)
      end
    end)

    {:ok, cache: pid}
  end

  defp generate_record(name, type, rdata) do
    Zone.Record.new(name, type, rdata, ttl: 300, class: :IN)
  end

  defp generate_hot_domains(count) do
    Enum.map(1..count, fn i ->
      "hot-domain-#{i}.example.com"
    end)
  end

  defp generate_random_domain do
    "random-#{:rand.uniform(1_000_000)}.example.com"
  end

  defp generate_nonexistent_domain do
    "nonexistent-#{:rand.uniform(1_000_000)}.invalid"
  end

  defp populate_hot_domains(hot_domains) do
    Enum.each(hot_domains, fn name ->
      records = [generate_record(name, :A, {192, 168, :rand.uniform(255), :rand.uniform(255)})]
      Manager.put(name, :A, records, [], 300)
    end)
  end

  describe "realistic workload simulation" do
    test "cache handles 10000 queries with realistic pattern" do
      # Generate 100 "hot" domains (frequently queried)
      hot_domains = generate_hot_domains(100)
      populate_hot_domains(hot_domains)

      query_count = 10_000
      start_time = System.monotonic_time(:millisecond)

      results =
        Enum.map(1..query_count, fn i ->
          # Realistic query pattern:
          # - 70% queries to hot domains (cache hits)
          # - 20% queries to random domains (cache misses)
          # - 10% negative queries (NXDOMAIN)
          name =
            cond do
              rem(i, 10) < 7 -> Enum.random(hot_domains)
              rem(i, 10) < 9 -> generate_random_domain()
              true -> generate_nonexistent_domain()
            end

          Manager.get(name, :A)
        end)

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      # Analyze results
      hits = Enum.count(results, fn {:ok, _records, _authority} -> true; _ -> false end)
      misses = Enum.count(results, fn {:error, :not_found} -> true; _ -> false end)

      stats = Manager.stats()

      hit_rate_pct = Stats.hit_rate(stats) * 100

      IO.puts("\n=== Realistic Workload Test Results ===")
      IO.puts("Total queries: #{query_count}")
      IO.puts("Duration: #{duration_ms}ms")
      IO.puts("QPS: #{Float.round(query_count / (duration_ms / 1000), 0)}")
      IO.puts("Cache hits: #{hits} (#{Float.round(hits / query_count * 100, 1)}%)")
      IO.puts("Cache misses: #{misses} (#{Float.round(misses / query_count * 100, 1)}%)")
      IO.puts("Cache hit rate: #{hit_rate_pct}%")
      IO.puts("Cache entries: #{stats.total_entries}")
      IO.puts("Memory usage: #{Stats.memory_mb(stats)}MB")

      # Verify performance requirements
      assert duration_ms < 5000, "10000 queries took #{duration_ms}ms, expected < 5s"
      assert hit_rate_pct > 60.0, "Hit rate #{hit_rate_pct}% is too low, expected > 60%"
    end

    test "cache handles sustained 30-second load" do
      hot_domains = generate_hot_domains(200)
      populate_hot_domains(hot_domains)

      # Run queries for 30 seconds
      duration_ms = 30_000
      start_time = System.monotonic_time(:millisecond)
      query_count = 0

      query_count =
        Stream.iterate(0, &(&1 + 1))
        |> Enum.reduce_while(0, fn i, count ->
          if System.monotonic_time(:millisecond) - start_time < duration_ms do
            # Execute query
            name =
              cond do
                rem(i, 10) < 7 -> Enum.random(hot_domains)
                rem(i, 10) < 9 -> generate_random_domain()
                true -> generate_nonexistent_domain()
              end

            Manager.get(name, :A)

            {:cont, count + 1}
          else
            {:halt, count}
          end
        end)

      end_time = System.monotonic_time(:millisecond)
      actual_duration_ms = end_time - start_time
      actual_duration_s = actual_duration_ms / 1000.0

      stats = Manager.stats()
      qps = query_count / actual_duration_s
      hit_rate_pct = Stats.hit_rate(stats) * 100

      IO.puts("\n=== Sustained Load Test Results ===")
      IO.puts("Duration: #{Float.round(actual_duration_s, 1)}s")
      IO.puts("Total queries: #{query_count}")
      IO.puts("QPS: #{Float.round(qps, 0)}")
      IO.puts("Cache hit rate: #{hit_rate_pct}%")
      IO.puts("Cache entries: #{stats.total_entries}")
      IO.puts("Memory usage: #{Stats.memory_mb(stats)}MB")

      # Verify sustained performance
      assert qps > 1000, "Sustained QPS #{Float.round(qps, 0)} is too low, expected > 1000"
      assert hit_rate_pct > 60.0, "Hit rate #{hit_rate_pct}% is too low"
    end
  end

  describe "concurrent client simulation" do
    test "cache handles 100 concurrent clients" do
      hot_domains = generate_hot_domains(100)
      populate_hot_domains(hot_domains)

      client_count = 100
      queries_per_client = 100

      start_time = System.monotonic_time(:millisecond)

      tasks =
        Enum.map(1..client_count, fn _client_id ->
          Task.async(fn ->
            Enum.map(1..queries_per_client, fn i ->
              name =
                cond do
                  rem(i, 10) < 7 -> Enum.random(hot_domains)
                  rem(i, 10) < 9 -> generate_random_domain()
                  true -> generate_nonexistent_domain()
                end

              Manager.get(name, :A)
            end)
          end)
        end)

      results = Task.await_many(tasks, 30_000) |> List.flatten()
      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time

      total_queries = client_count * queries_per_client
      hits = Enum.count(results, fn {:ok, _records, _authority} -> true; _ -> false end)

      stats = Manager.stats()

      hit_rate_pct = Stats.hit_rate(stats) * 100

      IO.puts("\n=== Concurrent Clients Test Results ===")
      IO.puts("Clients: #{client_count}")
      IO.puts("Queries per client: #{queries_per_client}")
      IO.puts("Total queries: #{total_queries}")
      IO.puts("Duration: #{duration_ms}ms")
      IO.puts("QPS: #{Float.round(total_queries / (duration_ms / 1000), 0)}")
      IO.puts("Successful queries: #{hits}")
      IO.puts("Cache hit rate: #{hit_rate_pct}%")

      # Verify concurrent performance
      assert duration_ms < 5000, "Concurrent queries took #{duration_ms}ms, expected < 5s"
      assert hit_rate_pct > 60.0, "Hit rate #{hit_rate_pct}% is too low"
    end
  end

  describe "cache stress test" do
    test "cache handles 50000 unique entries" do
      # Fill cache to near capacity
      entry_count = 50_000

      IO.puts("\n=== Cache Stress Test ===")
      IO.puts("Inserting #{entry_count} entries...")

      start_time = System.monotonic_time(:millisecond)

      Enum.each(1..entry_count, fn i ->
        name = "stress-test-#{i}.example.com"
        records = [generate_record(name, :A, {10, div(i, 65536), div(rem(i, 65536), 256), rem(i, 256)})]
        Manager.put(name, :A, records, [], 300)

        # Print progress every 10000 entries
        if rem(i, 10_000) == 0 do
          IO.puts("  Inserted #{i} entries...")
        end
      end)

      insert_duration = System.monotonic_time(:millisecond) - start_time

      stats = Manager.stats()

      IO.puts("\nInsertion complete:")
      IO.puts("  Duration: #{insert_duration}ms")
      IO.puts("  Cache entries: #{stats.total_entries}")
      IO.puts("  Memory usage: #{Stats.memory_mb(stats)}MB")

      # Now perform lookups
      IO.puts("\nPerforming 10000 random lookups...")
      lookup_start = System.monotonic_time(:millisecond)

      results =
        Enum.map(1..10_000, fn _ ->
          name = "stress-test-#{:rand.uniform(entry_count)}.example.com"
          Manager.get(name, :A)
        end)

      lookup_duration = System.monotonic_time(:millisecond) - lookup_start

      hits = Enum.count(results, fn {:ok, _records, _authority} -> true; _ -> false end)

      IO.puts("\nLookup results:")
      IO.puts("  Duration: #{lookup_duration}ms")
      IO.puts("  Hits: #{hits}/10000")
      IO.puts("  Average lookup time: #{Float.round(lookup_duration / 10_000, 2)}ms")

      # Verify stress test performance
      assert stats.total_entries <= entry_count,
             "Expected <= #{entry_count} entries, got #{stats.total_entries}"

      memory_mb = Stats.memory_mb(stats)
      assert memory_mb < 200, "Memory usage #{memory_mb}MB exceeds 200MB limit"
      assert lookup_duration < 1000, "10000 lookups took #{lookup_duration}ms, expected < 1s"
    end
  end

  describe "TTL expiration under load" do
    test "cache properly expires entries during high query load" do
      # Insert 1000 entries with 5-second TTL
      Enum.each(1..1000, fn i ->
        name = "expiring-#{i}.example.com"
        records = [generate_record(name, :A, {192, 168, div(i, 256), rem(i, 256)})]
        Manager.put(name, :A, records, [], 5)
      end)

      initial_stats = Manager.stats()
      IO.puts("\n=== TTL Expiration Under Load ===")
      IO.puts("Initial entries: #{initial_stats.total_entries}")

      # Perform continuous queries for 10 seconds
      # This tests that expiration works correctly even under load
      start_time = System.monotonic_time(:millisecond)
      query_duration_ms = 10_000

      query_count =
        Stream.iterate(0, &(&1 + 1))
        |> Enum.reduce_while(0, fn i, count ->
          if System.monotonic_time(:millisecond) - start_time < query_duration_ms do
            name = "expiring-#{rem(i, 1000) + 1}.example.com"
            Manager.get(name, :A)
            {:cont, count + 1}
          else
            {:halt, count}
          end
        end)

      # Trigger cleanup
      removed = Manager.cleanup()
      final_stats = Manager.stats()

      hit_rate_pct = Stats.hit_rate(final_stats) * 100

      IO.puts("Queries performed: #{query_count}")
      IO.puts("Expired entries removed: #{removed}")
      IO.puts("Final entries: #{final_stats.total_entries}")
      IO.puts("Hit rate during test: #{hit_rate_pct}%")

      # After 10 seconds, all entries (5s TTL) should be expired
      assert removed >= 900, "Expected >= 900 expired entries, got #{removed}"
    end
  end

  describe "memory pressure handling" do
    test "cache evicts LRU entries when memory limit is approached" do
      # Configure cache with low memory limit for testing
      GenServer.stop(:load_test_cache)

      {:ok, _pid} =
        Manager.start_link(
          name: :load_test_cache,
          max_entries: 10_000,
          max_memory_bytes: 10 * 1024 * 1024,  # 10MB limit
          cleanup_interval_ms: 60_000
        )

      IO.puts("\n=== Memory Pressure Test ===")
      IO.puts("Memory limit: 10MB")

      # Insert entries until we hit the limit
      inserted = 0

      inserted =
        Stream.iterate(1, &(&1 + 1))
        |> Enum.reduce_while(0, fn i, count ->
          name = "memory-test-#{i}.example.com"
          records = [generate_record(name, :A, {10, div(i, 65536), div(rem(i, 65536), 256), rem(i, 256)})]
          Manager.put(name, :A, records, [], 300)

          stats = Manager.stats()
          memory_mb = Stats.memory_mb(stats)

          if memory_mb >= 9.5 or count >= 15_000 do
            {:halt, count}
          else
            if rem(count, 1000) == 0 do
              IO.puts("  Inserted #{count} entries, memory: #{memory_mb}MB")
            end

            {:cont, count + 1}
          end
        end)

      final_stats = Manager.stats()
      final_memory_mb = Stats.memory_mb(final_stats)

      IO.puts("\nFinal state:")
      IO.puts("  Inserted: #{inserted} entries")
      IO.puts("  Retained: #{final_stats.total_entries} entries")
      IO.puts("  Memory: #{final_memory_mb}MB")
      IO.puts("  Evictions: #{final_stats.eviction_count}")

      # Verify memory limit is respected
      assert final_memory_mb <= 11.0,
             "Memory usage #{final_memory_mb}MB exceeds limit"

      assert final_stats.eviction_count > 0, "Expected some evictions to occur"
    end
  end
end
