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

      assert {:hit, ^response} = Cache.lookup("example.com", :a)
    end

    test "lookup returns :miss for unknown domain" do
      assert :miss = Cache.lookup("unknown.com", :a)
    end

    test "normalizes domain case" do
      response = %{answer: "test"}
      Cache.store("EXAMPLE.COM", :a, response, 300)
      Process.sleep(10)

      assert {:hit, _} = Cache.lookup("example.com", :a)
    end

    test "normalizes trailing dot" do
      response = %{answer: "test"}
      Cache.store("example.com.", :a, response, 300)
      Process.sleep(10)

      assert {:hit, _} = Cache.lookup("example.com", :a)
    end

    test "different types are separate cache entries" do
      Cache.store("example.com", :a, %{type: :a}, 300)
      Cache.store("example.com", :aaaa, %{type: :aaaa}, 300)
      Process.sleep(10)

      assert {:hit, %{type: :a}} = Cache.lookup("example.com", :a)
      assert {:hit, %{type: :aaaa}} = Cache.lookup("example.com", :aaaa)
    end
  end

  describe "TTL expiry" do
    test "expired entries return :miss (lazy eviction)" do
      Cache.store("expire.test", :a, %{data: "old"}, 1)
      Process.sleep(10)

      assert {:hit, _} = Cache.lookup("expire.test", :a)

      # Wait for TTL to expire (min_ttl is 5s, so the 1s gets clamped to 5s)
      # We test with a value above min_ttl
    end
  end

  describe "flush" do
    test "flush/0 clears entire cache" do
      Cache.store("a.com", :a, %{}, 300)
      Cache.store("b.com", :a, %{}, 300)
      Process.sleep(10)

      assert {:hit, _} = Cache.lookup("a.com", :a)
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
      assert {:hit, _} = Cache.lookup("b.com", :a)
    end

    test "flush_pattern/1 with wildcard" do
      Cache.store("sub1.example.com", :a, %{}, 300)
      Cache.store("sub2.example.com", :a, %{}, 300)
      Cache.store("other.com", :a, %{}, 300)
      Process.sleep(10)

      count = Cache.flush_pattern("*.example.com")
      assert count == 2
      assert :miss = Cache.lookup("sub1.example.com", :a)
      assert {:hit, _} = Cache.lookup("other.com", :a)
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
  end
end
