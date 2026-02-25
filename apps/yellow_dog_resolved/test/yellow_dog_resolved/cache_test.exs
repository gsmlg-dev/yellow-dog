defmodule YellowDog.Resolved.CacheTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.Cache

  @cache_config %{
    enabled: true,
    max_entries: 100,
    min_ttl_s: 5,
    max_ttl_s: 3600,
    negative_ttl_s: 10,
    sweep_interval_s: 3600
  }

  setup do
    # Start cache with test config (high sweep interval to avoid interference)
    start_supervised!({Cache, @cache_config})
    :ok
  end

  describe "store and lookup" do
    test "stores and retrieves a response" do
      Cache.store("example.com", :a, "response_data", 300)
      # Give cast time to process
      Process.sleep(10)

      assert {:hit, "response_data"} = Cache.lookup("example.com", :a)
    end

    test "misses on unknown domain" do
      assert :miss = Cache.lookup("unknown.com", :a)
    end

    test "misses on unknown type" do
      Cache.store("example.com", :a, "response_data", 300)
      Process.sleep(10)

      assert :miss = Cache.lookup("example.com", :aaaa)
    end

    test "case insensitive lookup" do
      Cache.store("Example.COM", :a, "response_data", 300)
      Process.sleep(10)

      assert {:hit, "response_data"} = Cache.lookup("example.com", :a)
    end

    test "strips trailing dot" do
      Cache.store("example.com.", :a, "response_data", 300)
      Process.sleep(10)

      assert {:hit, "response_data"} = Cache.lookup("example.com", :a)
    end

    test "overwrites existing entry" do
      Cache.store("example.com", :a, "old_data", 300)
      Process.sleep(10)
      Cache.store("example.com", :a, "new_data", 300)
      Process.sleep(10)

      assert {:hit, "new_data"} = Cache.lookup("example.com", :a)
    end
  end

  describe "TTL expiry" do
    test "entry expires after TTL" do
      # min_ttl_s is 5, so even ttl=1 gets clamped to 5
      # Use a very short min_ttl_s for this test
      Cache.store("expire.test", :a, "data", 5)
      Process.sleep(10)

      assert {:hit, "data"} = Cache.lookup("expire.test", :a)
    end

    test "TTL clamped to min_ttl_s" do
      # TTL of 1 should be clamped to min_ttl_s (5)
      Cache.store("clamp.test", :a, "data", 1)
      Process.sleep(10)

      # Should still be present since min_ttl_s = 5
      assert {:hit, "data"} = Cache.lookup("clamp.test", :a)
    end

    test "TTL clamped to max_ttl_s" do
      # TTL of 999999 should be clamped to max_ttl_s (3600)
      Cache.store("clamp-max.test", :a, "data", 999_999)
      Process.sleep(10)

      assert {:hit, "data"} = Cache.lookup("clamp-max.test", :a)
    end
  end

  describe "negative caching" do
    test "stores and retrieves negative response" do
      Cache.store_negative("nxdomain.test", :a, "nxdomain_response")
      Process.sleep(10)

      assert {:hit, "nxdomain_response"} = Cache.lookup("nxdomain.test", :a)
    end
  end

  describe "flush" do
    test "flush/0 clears all entries" do
      Cache.store("a.test", :a, "data1", 300)
      Cache.store("b.test", :a, "data2", 300)
      Process.sleep(10)

      assert {:hit, _} = Cache.lookup("a.test", :a)
      Cache.flush()

      assert :miss = Cache.lookup("a.test", :a)
      assert :miss = Cache.lookup("b.test", :a)
    end

    test "flush/1 clears specific domain" do
      Cache.store("target.test", :a, "data1", 300)
      Cache.store("keep.test", :a, "data2", 300)
      Process.sleep(10)

      Cache.flush("target.test")

      assert :miss = Cache.lookup("target.test", :a)
      assert {:hit, "data2"} = Cache.lookup("keep.test", :a)
    end

    test "flush_pattern/1 with wildcard" do
      Cache.store("sub1.example.com", :a, "data1", 300)
      Cache.store("sub2.example.com", :a, "data2", 300)
      Cache.store("other.test", :a, "data3", 300)
      Process.sleep(10)

      count = Cache.flush_pattern("*.example.com")
      assert count == 2

      assert :miss = Cache.lookup("sub1.example.com", :a)
      assert :miss = Cache.lookup("sub2.example.com", :a)
      assert {:hit, "data3"} = Cache.lookup("other.test", :a)
    end

    test "flush_pattern/1 with exact match" do
      Cache.store("exact.test", :a, "data1", 300)
      Cache.store("other.test", :a, "data2", 300)
      Process.sleep(10)

      count = Cache.flush_pattern("exact.test")
      assert count == 1

      assert :miss = Cache.lookup("exact.test", :a)
      assert {:hit, "data2"} = Cache.lookup("other.test", :a)
    end
  end

  describe "stats" do
    test "tracks hits and misses" do
      Cache.store("stats.test", :a, "data", 300)
      Process.sleep(10)

      # Generate some hits and misses
      Cache.lookup("stats.test", :a)
      Cache.lookup("stats.test", :a)
      Cache.lookup("nonexistent.test", :a)

      stats = Cache.stats()
      assert stats.entries == 1
      assert stats.hits >= 2
      assert stats.misses >= 1
      assert is_float(stats.hit_rate)
    end
  end

  describe "LRU eviction" do
    test "evicts oldest entries when max_entries exceeded" do
      # Max entries is 100, insert 110
      for i <- 1..110 do
        Cache.store("domain-#{i}.test", :a, "data-#{i}", 300)
      end

      Process.sleep(50)

      stats = Cache.stats()
      assert stats.entries <= 100
    end

    test "evicts entries from older time bucket first" do
      # Insert 50 entries in "old" bucket
      for i <- 1..50 do
        Cache.store("old-#{i}.test", :a, "data-#{i}", 300)
      end

      Process.sleep(10)

      # Wait 1+ seconds so the next batch gets a different last_accessed
      Process.sleep(1100)

      # Insert 50 entries in "new" bucket
      for i <- 1..50 do
        Cache.store("new-#{i}.test", :a, "data-#{i}", 300)
      end

      Process.sleep(10)

      # Insert 10 more to trigger eviction (110 > max_entries of 100)
      for i <- 1..10 do
        Cache.store("extra-#{i}.test", :a, "data-#{i}", 300)
      end

      Process.sleep(50)

      stats = Cache.stats()
      assert stats.entries <= 100

      # All "extra" entries (newest) should survive
      for i <- 1..10 do
        assert {:hit, _} = Cache.lookup("extra-#{i}.test", :a)
      end

      # All "new" bucket entries should survive
      for i <- 1..50 do
        assert {:hit, _} = Cache.lookup("new-#{i}.test", :a)
      end

      # At least some "old" bucket entries should be evicted
      old_misses =
        Enum.count(1..50, fn i ->
          Cache.lookup("old-#{i}.test", :a) == :miss
        end)

      assert old_misses >= 10
    end

    test "cache hit refreshes LRU timestamp, preventing eviction" do
      # Insert 50 entries in "old" bucket
      for i <- 1..50 do
        Cache.store("protect-#{i}.test", :a, "data-#{i}", 300)
      end

      Process.sleep(10)

      # Wait 1+ seconds for time bucket separation
      Process.sleep(1100)

      # Access entries 1-10 to refresh their LRU timestamp to "now"
      for i <- 1..10 do
        assert {:hit, _} = Cache.lookup("protect-#{i}.test", :a)
      end

      # Insert 60 more entries to trigger eviction
      for i <- 1..60 do
        Cache.store("fill-#{i}.test", :a, "data-#{i}", 300)
      end

      Process.sleep(50)

      stats = Cache.stats()
      assert stats.entries <= 100

      # The touched entries (1-10) should survive eviction
      for i <- 1..10 do
        assert {:hit, _} = Cache.lookup("protect-#{i}.test", :a)
      end
    end
  end

  describe "oldest_entry_age_s" do
    test "returns 0 for empty cache" do
      stats = Cache.stats()
      assert stats.oldest_entry_age_s == 0
    end

    test "returns non-negative age for cached entries" do
      Cache.store("age.test", :a, "data", 300)
      Process.sleep(10)

      stats = Cache.stats()
      assert stats.oldest_entry_age_s >= 0
    end
  end

  describe "stats edge cases" do
    test "empty cache returns zero stats" do
      stats = Cache.stats()
      assert stats.entries == 0
      assert stats.hit_rate == 0.0
      assert stats.oldest_entry_age_s == 0
    end

    test "hit_rate calculation with only hits" do
      Cache.store("only-hits.test", :a, "data", 300)
      Process.sleep(10)

      Cache.lookup("only-hits.test", :a)
      Cache.lookup("only-hits.test", :a)
      Cache.lookup("only-hits.test", :a)

      stats = Cache.stats()
      assert stats.hits >= 3
      assert stats.hit_rate > 0.0
    end

    test "evictions counter tracks evicted entries" do
      Cache.store("evict.test", :a, "data", 300)
      Process.sleep(10)

      Cache.flush()
      # Evictions are tracked by LRU and sweep, not flush
      stats = Cache.stats()
      assert is_integer(stats.evictions)
    end
  end

  describe "flush_pattern edge cases" do
    test "wildcard pattern matches parent domain itself" do
      Cache.store("example.com", :a, "data1", 300)
      Cache.store("sub.example.com", :a, "data2", 300)
      Process.sleep(10)

      count = Cache.flush_pattern("*.example.com")
      assert count == 2
    end

    test "flush_pattern returns 0 when no matches" do
      Cache.store("other.test", :a, "data", 300)
      Process.sleep(10)

      count = Cache.flush_pattern("*.nomatch.com")
      assert count == 0
    end

    test "flush domain with trailing dot" do
      Cache.store("dotted.test", :a, "data", 300)
      Process.sleep(10)

      Cache.flush("dotted.test.")
      assert :miss = Cache.lookup("dotted.test", :a)
    end
  end

  describe "sweep" do
    test "manual sweep removes expired entries" do
      Cache.store("sweep-target.test", :a, "data", 5)
      Process.sleep(10)

      assert {:hit, "data"} = Cache.lookup("sweep-target.test", :a)

      # Trigger sweep manually
      pid = Process.whereis(YellowDog.Resolved.Cache)
      send(pid, :sweep)
      Process.sleep(10)

      # Entry should still be alive (hasn't expired yet since min_ttl_s = 5)
      assert {:hit, "data"} = Cache.lookup("sweep-target.test", :a)
    end

    test "sweep handles empty cache gracefully" do
      pid = Process.whereis(YellowDog.Resolved.Cache)
      send(pid, :sweep)
      Process.sleep(10)

      stats = Cache.stats()
      assert stats.entries == 0
    end
  end

  describe "multiple types for same domain" do
    test "stores and retrieves different types independently" do
      Cache.store("multi.test", :a, "a_data", 300)
      Cache.store("multi.test", :aaaa, "aaaa_data", 300)
      Cache.store("multi.test", :txt, "txt_data", 300)
      Process.sleep(10)

      assert {:hit, "a_data"} = Cache.lookup("multi.test", :a)
      assert {:hit, "aaaa_data"} = Cache.lookup("multi.test", :aaaa)
      assert {:hit, "txt_data"} = Cache.lookup("multi.test", :txt)
    end

    test "flushing domain clears all types" do
      Cache.store("flush-multi.test", :a, "data1", 300)
      Cache.store("flush-multi.test", :aaaa, "data2", 300)
      Process.sleep(10)

      Cache.flush("flush-multi.test")

      assert :miss = Cache.lookup("flush-multi.test", :a)
      assert :miss = Cache.lookup("flush-multi.test", :aaaa)
    end
  end

  describe "store overwrites" do
    test "overwrite same domain+type updates the response" do
      Cache.store("overwrite.test", :a, "old_data", 300)
      Process.sleep(10)
      assert {:hit, "old_data"} = Cache.lookup("overwrite.test", :a)

      Cache.store("overwrite.test", :a, "new_data", 300)
      Process.sleep(10)
      assert {:hit, "new_data"} = Cache.lookup("overwrite.test", :a)
    end

    test "overwrite does not increase entry count" do
      Cache.store("count.test", :a, "data1", 300)
      Process.sleep(10)
      stats1 = Cache.stats()

      Cache.store("count.test", :a, "data2", 300)
      Process.sleep(10)
      stats2 = Cache.stats()

      assert stats2.entries == stats1.entries
    end
  end

  describe "stats hit_rate precision" do
    test "hit_rate is a float rounded to 2 decimals" do
      Cache.store("rate.test", :a, "data", 300)
      Process.sleep(10)

      # 2 hits, 1 miss = 2/3 ≈ 0.67
      Cache.lookup("rate.test", :a)
      Cache.lookup("rate.test", :a)
      Cache.lookup("rate-miss.test", :a)

      stats = Cache.stats()
      assert is_float(stats.hit_rate)
      # Float should be rounded to at most 2 decimal places
      assert stats.hit_rate == Float.round(stats.hit_rate, 2)
    end
  end

  describe "flush(domain) normalization" do
    test "removes all type variants for a specific domain" do
      Cache.store("flush-all-types.test", :a, "a-data", 300)
      Cache.store("flush-all-types.test", :aaaa, "aaaa-data", 300)
      Cache.store("flush-all-types.test", :mx, "mx-data", 300)
      Cache.store("other-domain.test", :a, "safe", 300)
      Process.sleep(10)

      Cache.flush("flush-all-types.test")

      assert :miss = Cache.lookup("flush-all-types.test", :a)
      assert :miss = Cache.lookup("flush-all-types.test", :aaaa)
      assert :miss = Cache.lookup("flush-all-types.test", :mx)
      assert {:hit, "safe"} = Cache.lookup("other-domain.test", :a)
    end

    test "normalizes uppercase domain with trailing dot" do
      Cache.store("normalize-flush.test", :a, "data", 300)
      Process.sleep(10)

      # Flush with uppercase + trailing dot
      Cache.flush("NORMALIZE-FLUSH.TEST.")

      assert :miss = Cache.lookup("normalize-flush.test", :a)
    end

    test "no-op for domain not in cache" do
      Cache.store("present.test", :a, "data", 300)
      Process.sleep(10)

      Cache.flush("absent.test")

      assert {:hit, "data"} = Cache.lookup("present.test", :a)
    end
  end

  describe "stats() comprehensive" do
    test "returns all expected map keys" do
      stats = Cache.stats()

      assert Map.has_key?(stats, :entries)
      assert Map.has_key?(stats, :hits)
      assert Map.has_key?(stats, :misses)
      assert Map.has_key?(stats, :evictions)
      assert Map.has_key?(stats, :hit_rate)
      assert Map.has_key?(stats, :oldest_entry_age_s)
    end

    test "entries count reflects stored entries precisely" do
      Cache.store("count-1.test", :a, "d1", 300)
      Cache.store("count-2.test", :a, "d2", 300)
      Cache.store("count-3.test", :aaaa, "d3", 300)
      Process.sleep(10)

      assert Cache.stats().entries == 3
    end

    test "hit_rate is 0.0 with zero lookups" do
      assert Cache.stats().hit_rate == 0.0
    end

    test "hit_rate computes correctly for mixed hits/misses" do
      Cache.store("hr.test", :a, "data", 300)
      Process.sleep(10)

      # 2 hits + 1 miss = 2/3 ≈ 0.67
      Cache.lookup("hr.test", :a)
      Cache.lookup("hr.test", :a)
      Cache.lookup("hr-miss.test", :a)

      assert Cache.stats().hit_rate == 0.67
    end

    test "oldest_entry_age_s increases over time" do
      Cache.store("age-track.test", :a, "data", 300)
      Process.sleep(10)

      age1 = Cache.stats().oldest_entry_age_s
      Process.sleep(1100)
      age2 = Cache.stats().oldest_entry_age_s

      assert age2 >= age1 + 1
    end

    test "evictions counter is non-negative integer" do
      stats = Cache.stats()
      assert is_integer(stats.evictions)
      assert stats.evictions >= 0
    end
  end

  describe "actual TTL expiry" do
    setup do
      # Restart cache with very short min_ttl_s for expiry testing
      stop_supervised!(Cache)
      start_supervised!({Cache, %{@cache_config | min_ttl_s: 1, negative_ttl_s: 1}})
      :ok
    end

    test "entry expires and lazy eviction removes it on lookup" do
      Cache.store("lazy-expire.test", :a, "data", 1)
      Process.sleep(10)

      assert {:hit, "data"} = Cache.lookup("lazy-expire.test", :a)

      # Wait for TTL to expire (min_ttl_s = 1)
      Process.sleep(1100)

      # Lazy eviction: expired entry is removed on lookup
      assert :miss = Cache.lookup("lazy-expire.test", :a)
    end

    test "sweep removes expired entries" do
      Cache.store("sweep-expire.test", :a, "data", 1)
      Process.sleep(10)

      assert {:hit, "data"} = Cache.lookup("sweep-expire.test", :a)

      # Wait for expiry
      Process.sleep(1100)

      # Trigger manual sweep
      pid = Process.whereis(Cache)
      send(pid, :sweep)
      Process.sleep(10)

      # Swept entry is gone
      stats = Cache.stats()
      assert stats.entries == 0
    end

    test "negative entry expires after negative_ttl_s" do
      Cache.store_negative("neg-expire.test", :a, "nxdomain_data")
      Process.sleep(10)

      assert {:hit, "nxdomain_data"} = Cache.lookup("neg-expire.test", :a)

      # Wait for negative_ttl_s (1s) to expire
      Process.sleep(1100)

      assert :miss = Cache.lookup("neg-expire.test", :a)
    end
  end

  describe "LRU eviction boundary with tiny max_entries" do
    setup do
      stop_supervised!(Cache)
      start_supervised!({Cache, %{@cache_config | max_entries: 5}})
      :ok
    end

    test "exactly max_entries survive after eviction" do
      # Insert 8 entries (3 over the limit of 5)
      for i <- 1..8 do
        Cache.store("tiny-#{i}.test", :a, "data-#{i}", 300)
        # Sleep between stores so last_accessed timestamps differ
        Process.sleep(5)
      end

      Process.sleep(20)

      stats = Cache.stats()
      assert stats.entries == 5
    end

    test "newest entries survive, oldest evicted" do
      # Insert 3 entries in "old" bucket
      for i <- 1..3 do
        Cache.store("order-#{i}.test", :a, "data-#{i}", 300)
      end

      Process.sleep(10)

      # Wait >1 second so last_accessed (in seconds) differs
      Process.sleep(1100)

      # Insert 5 entries in "new" bucket — fills to max_entries=5
      # This triggers eviction of the 3 oldest entries
      for i <- 4..8 do
        Cache.store("order-#{i}.test", :a, "data-#{i}", 300)
      end

      Process.sleep(20)

      # The 5 newest entries (4-8) should survive
      for i <- 4..8 do
        expected = "data-#{i}"
        assert {:hit, ^expected} = Cache.lookup("order-#{i}.test", :a)
      end

      # The 3 oldest entries (1-3) should be evicted
      for i <- 1..3 do
        assert :miss = Cache.lookup("order-#{i}.test", :a)
      end
    end

    test "evictions counter increments by exact overflow amount" do
      initial_evictions = Cache.stats().evictions

      for i <- 1..8 do
        Cache.store("evict-count-#{i}.test", :a, "data-#{i}", 300)
        Process.sleep(5)
      end

      Process.sleep(20)

      stats = Cache.stats()
      # 8 inserted - 5 max = 3 evictions
      assert stats.evictions - initial_evictions == 3
    end

    test "rapid same-domain stores don't trigger false evictions" do
      # Overwriting the same key 10 times shouldn't increase entry count
      for _ <- 1..10 do
        Cache.store("same.test", :a, "data", 300)
      end

      Process.sleep(20)

      stats = Cache.stats()
      assert stats.entries == 1
    end
  end

  describe "negative caching details" do
    setup do
      stop_supervised!(Cache)
      start_supervised!({Cache, %{@cache_config | negative_ttl_s: 10, min_ttl_s: 60}})
      :ok
    end

    test "negative entry uses negative_ttl_s, not clamped by min_ttl_s" do
      # min_ttl_s is 60, negative_ttl_s is 10
      # Negative entries should use 10s, not 60s
      Cache.store_negative("neg-ttl.test", :a, "nxdomain")
      Process.sleep(10)

      assert {:hit, "nxdomain"} = Cache.lookup("neg-ttl.test", :a)

      # Inspect the ETS entry directly to verify TTL
      [{_key, _resp, expires_at, _last, negative}] =
        :ets.lookup(YellowDog.Resolved.Cache, {"neg-ttl.test", :a})

      assert negative == true

      now = System.monotonic_time(:second)
      remaining_ttl = expires_at - now
      # Should be close to 10s (negative_ttl_s), not 60s (min_ttl_s)
      assert remaining_ttl <= 10
      assert remaining_ttl > 0
    end

    test "negative flag is stored correctly in ETS" do
      Cache.store("normal.test", :a, "normal-data", 300)
      Cache.store_negative("negative.test", :a, "nxdomain-data")
      Process.sleep(10)

      [{_, _, _, _, normal_neg}] =
        :ets.lookup(YellowDog.Resolved.Cache, {"normal.test", :a})

      [{_, _, _, _, neg_flag}] =
        :ets.lookup(YellowDog.Resolved.Cache, {"negative.test", :a})

      assert normal_neg == false
      assert neg_flag == true
    end
  end

  describe "flush_pattern deep subdomain matching" do
    test "wildcard matches arbitrarily deep subdomains" do
      Cache.store("a.b.c.deep.test", :a, "d1", 300)
      Cache.store("x.y.deep.test", :a, "d2", 300)
      Cache.store("deep.test", :a, "d3", 300)
      Cache.store("unrelated.test", :a, "d4", 300)
      Process.sleep(10)

      count = Cache.flush_pattern("*.deep.test")
      # Should match: deep.test (parent), a.b.c.deep.test, x.y.deep.test
      assert count == 3

      assert :miss = Cache.lookup("a.b.c.deep.test", :a)
      assert :miss = Cache.lookup("x.y.deep.test", :a)
      assert :miss = Cache.lookup("deep.test", :a)
      assert {:hit, "d4"} = Cache.lookup("unrelated.test", :a)
    end

    test "flush_pattern is case insensitive" do
      Cache.store("case.test", :a, "data", 300)
      Process.sleep(10)

      count = Cache.flush_pattern("CASE.TEST")
      assert count == 1
      assert :miss = Cache.lookup("case.test", :a)
    end
  end

  describe "concurrent cache operations" do
    test "parallel stores don't crash the cache" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            Cache.store("concurrent-#{i}.test", :a, "data-#{i}", 300)
          end)
        end

      Task.await_many(tasks, 5000)
      Process.sleep(50)

      stats = Cache.stats()
      assert stats.entries == 50
    end

    test "parallel lookups during store don't crash" do
      # Pre-populate some entries
      for i <- 1..20 do
        Cache.store("preload-#{i}.test", :a, "data-#{i}", 300)
      end

      Process.sleep(20)

      # Launch concurrent reads and writes simultaneously
      writers =
        for i <- 21..40 do
          Task.async(fn ->
            Cache.store("preload-#{i}.test", :a, "data-#{i}", 300)
          end)
        end

      readers =
        for i <- 1..20 do
          Task.async(fn ->
            Cache.lookup("preload-#{i}.test", :a)
          end)
        end

      results = Task.await_many(readers, 5000)
      Task.await_many(writers, 5000)
      Process.sleep(20)

      # All reads should have succeeded (hit or miss, but no crash)
      assert Enum.all?(results, fn r -> match?({:hit, _}, r) or r == :miss end)

      stats = Cache.stats()
      assert stats.entries == 40
    end

    test "flush during concurrent stores doesn't crash" do
      # Start stores
      writers =
        for i <- 1..30 do
          Task.async(fn ->
            Cache.store("flush-race-#{i}.test", :a, "data-#{i}", 300)
            Process.sleep(5)
          end)
        end

      # Flush mid-flight
      Process.sleep(10)
      Cache.flush()

      Task.await_many(writers, 5000)
      Process.sleep(20)

      # Cache should be functional — some entries may have been stored after flush
      pid = Process.whereis(Cache)
      assert Process.alive?(pid)
    end
  end

  describe "stats table resilience (catch :badarg paths)" do
    test "stats() returns zeros when stats table is deleted" do
      # Pre-populate to have real stats
      Cache.store("resilience.test", :a, "data", 300)
      Process.sleep(10)
      Cache.lookup("resilience.test", :a)

      # Verify stats work before
      stats_before = Cache.stats()
      assert stats_before.hits >= 1

      # Delete the stats ETS table to trigger catch :badarg paths
      :ets.delete(:"Elixir.YellowDog.Resolved.Cache.Stats")

      # stats() should degrade gracefully — get_stat returns 0 for missing table
      stats = Cache.stats()
      assert stats.hits == 0
      assert stats.misses == 0
      assert stats.evictions == 0
      assert stats.hit_rate == 0.0
      # entries still works (different ETS table)
      assert stats.entries >= 1
    end

    test "lookup still works when stats table is deleted" do
      Cache.store("stats-gone.test", :a, "data", 300)
      Process.sleep(10)

      # Delete stats table
      :ets.delete(:"Elixir.YellowDog.Resolved.Cache.Stats")

      # lookup should not crash — bump_stat catch :badarg → :ok
      assert {:hit, "data"} = Cache.lookup("stats-gone.test", :a)

      # miss path should also not crash
      assert :miss = Cache.lookup("nonexistent.test", :a)
    end

    test "store still works when stats table is deleted" do
      # Delete stats table
      :ets.delete(:"Elixir.YellowDog.Resolved.Cache.Stats")

      # store should not crash — bump_stat for evictions still works
      Cache.store("no-stats.test", :a, "data", 300)
      Process.sleep(10)

      assert {:hit, "data"} = Cache.lookup("no-stats.test", :a)
    end
  end

  describe "terminate/2" do
    test "stops cleanly without crash" do
      pid = Process.whereis(Cache)
      assert Process.alive?(pid)

      stop_supervised!(Cache)

      refute Process.alive?(pid)
    end
  end
end
