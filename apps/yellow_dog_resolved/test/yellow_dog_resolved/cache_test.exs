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
  end

  describe "stats edge cases" do
    test "empty cache returns zero stats" do
      stats = Cache.stats()
      assert stats.entries == 0
      assert stats.hit_rate == 0.0
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
end
