defmodule YellowDog.Dns.CachePerformanceTest do
  @moduledoc """
  Performance tests for DNS cache implementation.

  These tests verify that cache operations meet performance requirements
  and don't regress over time.

  Run with: mix test test/yellow_dog/dns/cache_performance_test.exs --include performance
  """

  use ExUnit.Case, async: false

  alias YellowDog.Dns.Query.Cache.Manager
  alias YellowDog.Dns.Zone

  @moduletag :performance

  setup do
    # Start cache with test configuration
    {:ok, pid} =
      Manager.start_link(
        name: :perf_test_cache,
        max_entries: 100_000,
        max_memory_bytes: 500 * 1024 * 1024,
        cleanup_interval_ms: 60_000
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

  defp populate_cache(count) do
    Enum.each(1..count, fn i ->
      name = "test-#{i}.example.com"
      records = [generate_record(name, :A, {192, 168, div(i, 256), rem(i, 256)})]
      Manager.put(name, :A, records, [], 300)
    end)
  end

  describe "insert performance" do
    test "single insert completes within 100μs" do
      name = "test.example.com"
      records = [generate_record(name, :A, {192, 168, 1, 1})]

      {time_us, :ok} =
        :timer.tc(fn ->
          Manager.put(name, :A, records, [], 300)
        end)

      assert time_us < 100,
             "Insert took #{time_us}μs, expected < 100μs"
    end

    test "1000 sequential inserts complete within 100ms" do
      {time_ms, _} =
        :timer.tc(fn ->
          populate_cache(1000)
        end)

      time_ms = div(time_ms, 1000)

      assert time_ms < 100,
             "1000 inserts took #{time_ms}ms, expected < 100ms"
    end

    test "10000 sequential inserts complete within 1s" do
      {time_ms, _} =
        :timer.tc(fn ->
          populate_cache(10000)
        end)

      time_ms = div(time_ms, 1000)

      assert time_ms < 1000,
             "10000 inserts took #{time_ms}ms, expected < 1000ms"
    end
  end

  describe "lookup performance" do
    setup do
      # Pre-populate cache
      populate_cache(1000)
      :ok
    end

    test "cache hit completes within 50μs" do
      name = "test-1.example.com"

      {time_us, {:ok, _records, _authority}} =
        :timer.tc(fn ->
          Manager.get(name, :A)
        end)

      assert time_us < 50,
             "Lookup took #{time_us}μs, expected < 50μs"
    end

    test "cache miss completes within 50μs" do
      name = "nonexistent.example.com"

      {time_us, {:error, :not_found}} =
        :timer.tc(fn ->
          Manager.get(name, :A)
        end)

      assert time_us < 50,
             "Miss lookup took #{time_us}μs, expected < 50μs"
    end

    test "10000 lookups complete within 500ms" do
      {time_ms, _} =
        :timer.tc(fn ->
          Enum.each(1..10000, fn i ->
            name = "test-#{rem(i, 1000) + 1}.example.com"
            Manager.get(name, :A)
          end)
        end)

      time_ms = div(time_ms, 1000)

      assert time_ms < 500,
             "10000 lookups took #{time_ms}ms, expected < 500ms"
    end
  end

  describe "concurrent performance" do
    setup do
      populate_cache(100)
      :ok
    end

    test "1000 concurrent writes complete within 2s" do
      {time_ms, _results} =
        :timer.tc(fn ->
          tasks =
            Enum.map(1..1000, fn i ->
              Task.async(fn ->
                name = "concurrent-#{i}.example.com"
                records = [generate_record(name, :A, {10, 0, div(i, 256), rem(i, 256)})]
                Manager.put(name, :A, records, [], 300)
              end)
            end)

          Task.await_many(tasks, 5000)
        end)

      time_ms = div(time_ms, 1000)

      assert time_ms < 2000,
             "1000 concurrent writes took #{time_ms}ms, expected < 2000ms"
    end

    test "10000 concurrent reads complete within 2s" do
      {time_ms, results} =
        :timer.tc(fn ->
          tasks =
            Enum.map(1..10000, fn i ->
              Task.async(fn ->
                name = "test-#{rem(i, 100) + 1}.example.com"
                Manager.get(name, :A)
              end)
            end)

          Task.await_many(tasks, 10000)
        end)

      time_ms = div(time_ms, 1000)

      # Verify most lookups succeeded
      successes = Enum.count(results, fn {:ok, _records, _authority} -> true; _ -> false end)
      assert successes > 9000, "Expected > 9000 successful lookups, got #{successes}"

      assert time_ms < 2000,
             "10000 concurrent reads took #{time_ms}ms, expected < 2000ms"
    end

    test "mixed 10000 operations (70% read, 30% write) complete within 3s" do
      {time_ms, _results} =
        :timer.tc(fn ->
          tasks =
            Enum.map(1..10000, fn i ->
              Task.async(fn ->
                if rem(i, 10) < 7 do
                  # Read (70%)
                  name = "test-#{rem(i, 100) + 1}.example.com"
                  Manager.get(name, :A)
                else
                  # Write (30%)
                  name = "concurrent-#{i}.example.com"
                  records = [generate_record(name, :A, {10, 0, div(i, 256), rem(i, 256)})]
                  Manager.put(name, :A, records, [], 300)
                end
              end)
            end)

          Task.await_many(tasks, 10000)
        end)

      time_ms = div(time_ms, 1000)

      assert time_ms < 3000,
             "10000 mixed operations took #{time_ms}ms, expected < 3000ms"
    end
  end

  describe "cleanup performance" do
    @tag :skip
    test "cleanup with 1000 active entries completes within 100ms" do
      populate_cache(1000)

      {time_ms, _removed} =
        :timer.tc(fn ->
          Manager.cleanup()
        end)

      time_ms = div(time_ms, 1000)

      assert time_ms < 100,
             "Cleanup took #{time_ms}ms, expected < 100ms"
    end

    @tag :skip
    test "cleanup with 1000 expired entries completes within 200ms" do
      # Insert entries with 0 TTL
      Enum.each(1..1000, fn i ->
        name = "expired-#{i}.example.com"
        records = [generate_record(name, :A, {192, 168, div(i, 256), rem(i, 256)})]
        Manager.put(name, :A, records, [], 0)
      end)

      # Wait for expiration
      Process.sleep(1000)

      {time_ms, removed} =
        :timer.tc(fn ->
          Manager.cleanup()
        end)

      time_ms = div(time_ms, 1000)

      assert removed == 1000, "Expected 1000 removed, got #{removed}"

      assert time_ms < 200,
             "Cleanup of 1000 expired entries took #{time_ms}ms, expected < 200ms"
    end

    @tag :skip
    test "cleanup with 10000 expired entries completes within 500ms" do
      # Insert entries with 0 TTL
      Enum.each(1..10000, fn i ->
        name = "expired-#{i}.example.com"
        records = [generate_record(name, :A, {192, 168, div(i, 256), rem(i, 256)})]
        Manager.put(name, :A, records, [], 0)
      end)

      # Wait for expiration
      Process.sleep(1000)

      {time_ms, removed} =
        :timer.tc(fn ->
          Manager.cleanup()
        end)

      time_ms = div(time_ms, 1000)

      assert removed == 10000, "Expected 10000 removed, got #{removed}"

      assert time_ms < 500,
             "Cleanup of 10000 expired entries took #{time_ms}ms, expected < 500ms"
    end
  end

  describe "memory usage" do
    test "1000 entries use < 10MB" do
      populate_cache(1000)
      stats = Manager.stats()

      assert stats.memory_mb < 10,
             "1000 entries used #{stats.memory_mb}MB, expected < 10MB"
    end

    test "10000 entries use < 100MB" do
      populate_cache(10000)
      stats = Manager.stats()

      assert stats.memory_mb < 100,
             "10000 entries used #{stats.memory_mb}MB, expected < 100MB"
    end
  end

  describe "statistics tracking" do
    test "hit rate calculation is accurate" do
      # Pre-populate 100 entries
      populate_cache(100)

      # Perform 700 hits (cached entries)
      Enum.each(1..700, fn i ->
        name = "test-#{rem(i, 100) + 1}.example.com"
        Manager.get(name, :A)
      end)

      # Perform 300 misses (non-existent entries)
      Enum.each(1..300, fn i ->
        name = "nonexistent-#{i}.example.com"
        Manager.get(name, :A)
      end)

      stats = Manager.stats()

      # Hit rate should be ~70%
      assert stats.hit_rate >= 65.0 and stats.hit_rate <= 75.0,
             "Hit rate is #{stats.hit_rate}%, expected ~70%"

      assert stats.hits >= 700, "Expected >= 700 hits, got #{stats.hits}"
      assert stats.misses >= 300, "Expected >= 300 misses, got #{stats.misses}"
    end
  end

  describe "throughput" do
    test "cache achieves > 10000 queries per second" do
      populate_cache(1000)

      # Measure throughput over 1 second
      start_time = System.monotonic_time(:millisecond)
      query_count = 20_000

      Enum.each(1..query_count, fn i ->
        name = "test-#{rem(i, 1000) + 1}.example.com"
        Manager.get(name, :A)
      end)

      end_time = System.monotonic_time(:millisecond)
      duration_ms = end_time - start_time
      duration_s = duration_ms / 1000.0

      qps = query_count / duration_s

      assert qps > 10_000,
             "Achieved #{Float.round(qps, 0)} QPS, expected > 10000 QPS"
    end
  end
end
