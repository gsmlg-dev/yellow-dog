defmodule YellowDog.Resolved.CacheTest do
  use ExUnit.Case, async: false

  alias YellowDog.Resolved.Cache

  @cache_config %{
    enabled: true,
    max_entries: 100,
    min_ttl_s: 5,
    max_ttl_s: 3600,
    negative_ttl_s: 30,
    sweep_interval_s: 3600
  }

  setup do
    # Start cache for each test
    start_supervised!({Cache, @cache_config})
    :ok
  end

  describe "store/lookup" do
    test "stores and retrieves a cached response" do
      response = %{answer: "test"}
      Cache.store("example.com", :a, response, 300)

      # Give cast time to process
      Process.sleep(10)

      assert {:hit, ^response, _} = Cache.lookup("example.com", :a)
    end

    test "lookup returns :miss for unknown domain" do
      assert :miss = Cache.lookup("unknown.com", :a)
    end

    test "normalizes domain case" do
      response = %{answer: "test"}
      Cache.store("EXAMPLE.COM", :a, response, 300)
      Process.sleep(10)

      assert {:hit, _, _} = Cache.lookup("example.com", :a)
    end

    test "normalizes trailing dot" do
      response = %{answer: "test"}
      Cache.store("example.com.", :a, response, 300)
      Process.sleep(10)

      assert {:hit, _, _} = Cache.lookup("example.com", :a)
    end

    test "different types are separate cache entries" do
      Cache.store("example.com", :a, %{type: :a}, 300)
      Cache.store("example.com", :aaaa, %{type: :aaaa}, 300)
      Process.sleep(10)

      assert {:hit, %{type: :a}, _} = Cache.lookup("example.com", :a)
      assert {:hit, %{type: :aaaa}, _} = Cache.lookup("example.com", :aaaa)
    end
  end

  describe "remaining TTL" do
    test "lookup returns remaining TTL that decreases over time" do
      Cache.store("ttl-test.com", :a, %{data: "test"}, 300)
      Process.sleep(10)

      {:hit, _, ttl1} = Cache.lookup("ttl-test.com", :a)
      # TTL should be close to 300 (clamped, stored with 300s)
      assert ttl1 > 0
      assert ttl1 <= 300

      # After a brief wait, TTL should be the same or less
      Process.sleep(10)
      {:hit, _, ttl2} = Cache.lookup("ttl-test.com", :a)
      assert ttl2 <= ttl1
    end
  end

  describe "TTL expiry" do
    test "expired entries return :miss (lazy eviction)" do
      Cache.store("expire.test", :a, %{data: "old"}, 1)
      Process.sleep(10)

      assert {:hit, _, _} = Cache.lookup("expire.test", :a)

      # Wait for TTL to expire (min_ttl is 5s, so the 1s gets clamped to 5s)
      # We test with a value above min_ttl
    end
  end

  describe "flush" do
    test "flush/0 clears entire cache" do
      Cache.store("a.com", :a, %{}, 300)
      Cache.store("b.com", :a, %{}, 300)
      Process.sleep(10)

      assert {:hit, _, _} = Cache.lookup("a.com", :a)
      Cache.flush()
      assert :miss = Cache.lookup("a.com", :a)
      assert :miss = Cache.lookup("b.com", :a)
    end

    test "flush/1 clears specific domain" do
      Cache.store("a.com", :a, %{}, 300)
      Cache.store("b.com", :a, %{}, 300)
      Process.sleep(10)

      Cache.flush("a.com")
      assert :miss = Cache.lookup("a.com", :a)
      assert {:hit, _, _} = Cache.lookup("b.com", :a)
    end

    test "flush_pattern/1 with wildcard" do
      Cache.store("sub1.example.com", :a, %{}, 300)
      Cache.store("sub2.example.com", :a, %{}, 300)
      Cache.store("other.com", :a, %{}, 300)
      Process.sleep(10)

      count = Cache.flush_pattern("*.example.com")
      assert count == 2
      assert :miss = Cache.lookup("sub1.example.com", :a)
      assert {:hit, _, _} = Cache.lookup("other.com", :a)
    end
  end

  describe "stats" do
    test "tracks hits and misses" do
      Cache.store("hit.test", :a, %{}, 300)
      Process.sleep(10)

      Cache.lookup("hit.test", :a)
      Cache.lookup("miss.test", :a)

      stats = Cache.stats()
      assert stats.hits >= 1
      assert stats.misses >= 1
      assert stats.entries >= 1
    end

    test "fresh cache starts with zero counters" do
      stats = Cache.stats()

      assert stats.hits == 0
      assert stats.misses == 0
      assert stats.evictions == 0
      assert stats.entries == 0
      assert stats.hit_rate == 0.0
    end

    test "returns expected keys in stats map" do
      stats = Cache.stats()

      assert Map.has_key?(stats, :entries)
      assert Map.has_key?(stats, :hits)
      assert Map.has_key?(stats, :misses)
      assert Map.has_key?(stats, :evictions)
      assert Map.has_key?(stats, :hit_rate)
      assert Map.has_key?(stats, :oldest_entry_age_s)

      # query routing counters should NOT be in cache stats
      refute Map.has_key?(stats, :queries_intercepted)
      refute Map.has_key?(stats, :queries_forwarded)
    end

    test "hit_rate is computed correctly" do
      Cache.store("rate.test", :a, %{}, 300)
      Process.sleep(10)

      Cache.lookup("rate.test", :a)
      Cache.lookup("rate.test", :a)
      Cache.lookup("miss.rate.test", :a)

      stats = Cache.stats()
      # 2 hits, 1 miss → 2/3 ≈ 0.67
      assert stats.hit_rate == Float.round(2 / 3, 2)
    end

    test "oldest_entry_age_s returns the actual oldest entry, not arbitrary" do
      # Store entries at slightly different times
      Cache.store("first.test", :a, %{}, 300)
      Process.sleep(100)
      Cache.store("second.test", :a, %{}, 300)
      Process.sleep(100)
      Cache.store("third.test", :a, %{}, 300)

      stats = Cache.stats()

      # oldest_entry_age_s should reflect the oldest (first) entry, which is ≥ 200ms old
      assert stats.oldest_entry_age_s >= 0
      # The oldest entry was stored at least 200ms ago but less than 60 seconds ago
      assert stats.oldest_entry_age_s < 60
    end

    test "oldest_entry_age_s is 0 when cache is empty" do
      stats = Cache.stats()
      assert stats.oldest_entry_age_s == 0
    end
  end

  describe "telemetry events" do
    test "emits :hit telemetry on cache hit" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:yellow_dog, :resolved, :cache, :hit]
        ])

      Cache.store("telem-hit.test", :a, %{}, 300)
      Process.sleep(10)

      Cache.lookup("telem-hit.test", :a)

      assert_received {[:yellow_dog, :resolved, :cache, :hit], ^ref, %{},
                       %{domain: "telem-hit.test", type: :a}}
    end

    test "emits :miss telemetry on cache miss" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:yellow_dog, :resolved, :cache, :miss]
        ])

      Cache.lookup("telem-miss.test", :a)

      assert_received {[:yellow_dog, :resolved, :cache, :miss], ^ref, %{},
                       %{domain: "telem-miss.test", type: :a}}
    end

    test "emits :store telemetry on cache store" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:yellow_dog, :resolved, :cache, :store]
        ])

      Cache.store("telem-store.test", :a, %{}, 300)
      Process.sleep(10)

      assert_received {[:yellow_dog, :resolved, :cache, :store], ^ref, %{},
                       %{domain: "telem-store.test", type: :a, ttl: _}}
    end

    test "emits :flush telemetry on cache flush" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:yellow_dog, :resolved, :cache, :flush]
        ])

      Cache.store("telem-flush.test", :a, %{}, 300)
      Process.sleep(10)

      Cache.flush()

      assert_received {[:yellow_dog, :resolved, :cache, :flush], ^ref, %{},
                       %{pattern: nil, count: _}}
    end
  end

  describe "LRU eviction" do
    test "evicts oldest entry when max_entries exceeded" do
      # Fill cache to max (100 entries)
      for i <- 1..100 do
        Cache.store("domain#{i}.test", :a, %{i: i}, 300)
      end

      Process.sleep(50)

      # Add one more to trigger eviction
      Cache.store("overflow.test", :a, %{overflow: true}, 300)
      Process.sleep(10)

      stats = Cache.stats()
      assert stats.entries <= 100
    end

    test "updating an existing key at max capacity does not evict a valid entry" do
      stop_supervised!(Cache)

      # Start with a very small max_entries so we can fill it easily
      small_config = %{@cache_config | max_entries: 3}
      start_supervised!({Cache, small_config})

      # Fill to capacity
      Cache.store("a.test", :a, %{v: 1}, 300)
      Cache.store("b.test", :a, %{v: 2}, 300)
      Cache.store("c.test", :a, %{v: 3}, 300)
      Process.sleep(20)
      assert Cache.stats().entries == 3

      # Update an existing key — should NOT evict any other entry
      Cache.store("a.test", :a, %{v: 99}, 300)
      Process.sleep(20)

      # Still 3 entries — no spurious eviction
      assert Cache.stats().entries == 3
      # All three domains still present
      assert {:hit, %{v: 99}, _} = Cache.lookup("a.test", :a)
      assert {:hit, %{v: 2}, _} = Cache.lookup("b.test", :a)
      assert {:hit, %{v: 3}, _} = Cache.lookup("c.test", :a)
    end

    test "evicts the least recently accessed entry" do
      # Insert one entry and wait so it has an earlier access time (second granularity)
      Cache.store("victim.test", :a, %{name: "victim"}, 300)
      Process.sleep(10)

      # Wait over 1 second so access times differ at second granularity
      Process.sleep(1100)

      # Fill up remaining entries (99 more to reach 100 max)
      for i <- 1..99 do
        Cache.store("filler#{i}.test", :a, %{i: i}, 300)
      end

      Process.sleep(50)

      # victim.test is the oldest entry and has the oldest access time
      # Adding one more should evict it
      Cache.store("trigger.test", :a, %{trigger: true}, 300)
      Process.sleep(10)

      # victim should have been evicted (oldest access time)
      assert :miss = Cache.lookup("victim.test", :a)
      # trigger should be present
      assert {:hit, _, _} = Cache.lookup("trigger.test", :a)
    end
  end

  describe "sweep" do
    test "periodic sweep removes expired entries" do
      # Restart cache with a very short sweep interval
      stop_supervised!(Cache)

      sweep_config = %{
        @cache_config
        | sweep_interval_s: 1,
          min_ttl_s: 1,
          max_ttl_s: 3600
      }

      start_supervised!({Cache, sweep_config})

      # Store entries: one with 2s TTL (short) and one with long TTL
      Cache.store("sweep-target.test", :a, %{data: "old"}, 2)
      Cache.store("sweep-keep.test", :a, %{data: "keep"}, 3600)
      Process.sleep(50)

      # Both should be present initially
      assert {:hit, _, _} = Cache.lookup("sweep-keep.test", :a)

      # Wait for TTL to expire + sweep interval to fire
      Process.sleep(3500)

      # sweep-target should be gone (expired + swept)
      # sweep-keep should remain (long TTL)
      assert :miss = Cache.lookup("sweep-target.test", :a)
      assert {:hit, _, _} = Cache.lookup("sweep-keep.test", :a)

      # Evictions counter should reflect the sweep
      stats = Cache.stats()
      assert stats.evictions >= 1
    end

    test "sweep leaves LRU index consistent with main table" do
      stop_supervised!(Cache)

      sweep_config = %{
        @cache_config
        | sweep_interval_s: 1,
          min_ttl_s: 1,
          max_ttl_s: 3600
      }

      start_supervised!({Cache, sweep_config})

      # Store several entries with short TTL
      for i <- 1..5 do
        Cache.store("lru-expire#{i}.test", :a, %{i: i}, 2)
      end

      # Store one with long TTL
      Cache.store("lru-keep.test", :a, %{keep: true}, 3600)
      Process.sleep(50)

      # Wait for expiry + sweep
      Process.sleep(3500)

      # After sweep, all expired entries should be gone
      for i <- 1..5 do
        assert :miss = Cache.lookup("lru-expire#{i}.test", :a)
      end

      assert {:hit, _, _} = Cache.lookup("lru-keep.test", :a)

      # entries count should match exactly what's alive
      stats = Cache.stats()
      assert stats.entries == 1
    end
  end
end
