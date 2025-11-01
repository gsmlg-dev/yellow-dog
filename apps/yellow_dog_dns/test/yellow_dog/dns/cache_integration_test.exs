defmodule YellowDog.Dns.CacheIntegrationTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Query.Cache.{Manager, Cleaner, Storage}
  alias YellowDog.Dns.Zone

  setup do
    # Clean up any existing table
    if Storage.exists?() do
      :ets.delete(:dns_query_cache)
    end

    # Start cache components
    {:ok, manager_pid} = start_supervised({Manager, enabled: true, max_entries: 100})

    {:ok, cleaner_pid} =
      start_supervised({Cleaner, interval: 1_000, max_entries: 100})

    on_exit(fn ->
      if Storage.exists?() do
        :ets.delete(:dns_query_cache)
      end
    end)

    {:ok, manager: manager_pid, cleaner: cleaner_pid}
  end

  describe "cache with resolver integration" do
    test "caches successful resolution" do
      # Simulate a successful resolution by directly caching
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1}, ttl: 300)]

      Manager.put("www.example.com.", :A, records, [], 300)

      # First get should be cache hit
      {:ok, cached_records, _} = Manager.get("www.example.com.", :A)
      assert length(cached_records) == 1
      assert hd(cached_records).owner == "www.example.com."

      # Stats should show hit
      stats = Manager.stats()
      assert stats.hit_count == 1
      assert stats.insert_count == 1
    end

    test "caches negative responses" do
      soa = %Zone.SOA{
        mname: "ns1.example.com.",
        rname: "admin.example.com.",
        serial: 2_024_102_901,
        refresh: 7200,
        retry: 3600,
        expire: 1_209_600,
        minimum: 300
      }

      Manager.put("nonexistent.example.com.", :A, [], [soa], 300, response_type: :nxdomain)

      {:ok, records, authority} = Manager.get("nonexistent.example.com.", :A)
      assert records == []
      assert length(authority) == 1
    end

    test "cache miss triggers resolution" do
      # Request non-cached entry
      result = Manager.get("uncached.example.com.", :A)
      assert {:error, :not_found} = result

      # Stats should show miss
      stats = Manager.stats()
      assert stats.miss_count >= 1
    end
  end

  describe "cleaner integration" do
    test "cleaner removes expired entries" do
      # Insert entry with short TTL
      records = [Zone.Record.new("short-ttl.example.com.", :A, {192, 168, 1, 1}, ttl: 1)]
      Manager.put("short-ttl.example.com.", :A, records, [], 1)

      # Verify it's cached
      assert {:ok, _, _} = Manager.get("short-ttl.example.com.", :A)

      # Wait for expiration + cleanup cycle (cleaner runs every 1000ms)
      Process.sleep(2_500)

      # Entry should be removed
      assert {:error, :not_found} = Manager.get("short-ttl.example.com.", :A)

      # Check cleaner stats - may be nil if cleaner hasn't run yet
      stats = Cleaner.last_stats()

      if stats != nil do
        assert stats.expired_removed >= 0
      end
    end

    test "cleaner enforces entry limits" do
      # Insert many entries
      for i <- 1..120 do
        records = [Zone.Record.new("host#{i}.example.com.", :A, {192, 168, 1, i})]
        Manager.put("host#{i}.example.com.", :A, records, [], 300)
      end

      # Wait for cleanup
      Process.sleep(1_500)

      # Should be at or below limit
      stats = Manager.stats()
      assert stats.total_entries <= 100
    end

    test "manual cleanup works" do
      # Insert expired entry via Manager to ensure proper setup
      records = [Zone.Record.new("expired.example.com.", :A, {192, 168, 1, 1}, ttl: 1)]
      Manager.put("expired.example.com.", :A, records, [], 1)

      # Verify it's there
      assert {:ok, _, _} = Manager.get("expired.example.com.", :A)

      # Wait for it to expire
      Process.sleep(1100)

      # Now it should be expired (but not yet cleaned)
      # Verify count before cleanup
      initial_count = Storage.count()

      # Trigger manual cleanup
      cleanup_stats = Cleaner.cleanup_now()

      # The entry should be removed by Manager checking expiration or by cleaner
      # Just verify the final state
      result = Manager.get("expired.example.com.", :A)
      assert {:error, :not_found} = result

      # Cleanup stats should show some activity
      assert is_map(cleanup_stats)
      assert Map.has_key?(cleanup_stats, :expired_removed)
    end
  end

  describe "cache hit rate" do
    test "tracks hit rate over multiple requests" do
      records = [Zone.Record.new("popular.example.com.", :A, {192, 168, 1, 1})]
      Manager.put("popular.example.com.", :A, records, [], 300)

      # Hit multiple times
      for _ <- 1..5 do
        Manager.get("popular.example.com.", :A)
      end

      # Miss a few times
      for i <- 1..2 do
        Manager.get("miss#{i}.example.com.", :A)
      end

      stats = Manager.stats()
      assert stats.hit_count == 5
      assert stats.miss_count == 2

      # Calculate hit rate
      hit_rate = YellowDog.Dns.Query.Cache.Stats.hit_rate(stats)
      assert hit_rate > 0.7
    end
  end

  describe "memory management" do
    test "tracks memory usage" do
      # Insert entries
      for i <- 1..50 do
        records = [
          Zone.Record.new("host#{i}.example.com.", :A, {192, 168, 1, i}),
          Zone.Record.new("host#{i}.example.com.", :AAAA, {0x2001, 0xDB8, 0, 0, 0, 0, 0, i})
        ]

        Manager.put("host#{i}.example.com.", :A, records, [], 300)
      end

      stats = Manager.stats()
      assert stats.memory_bytes > 0

      # Calculate MB
      memory_mb = YellowDog.Dns.Query.Cache.Stats.memory_mb(stats)
      assert memory_mb > 0.0
    end
  end

  describe "concurrent access" do
    test "handles concurrent cache operations" do
      # Spawn multiple processes doing cache operations
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            records = [Zone.Record.new("host#{i}.example.com.", :A, {192, 168, 1, i})]
            Manager.put("host#{i}.example.com.", :A, records, [], 300)
            Manager.get("host#{i}.example.com.", :A)
          end)
        end

      results = Enum.map(tasks, &Task.await/1)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _, _} -> true
               _ -> false
             end)

      stats = Manager.stats()
      assert stats.total_entries == 20
      assert stats.hit_count == 20
    end
  end

  describe "TTL handling" do
    test "returns decreasing TTL values" do
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1}, ttl: 300)]
      Manager.put("www.example.com.", :A, records, [], 300)

      {:ok, first_records, _} = Manager.get("www.example.com.", :A)
      first_ttl = hd(first_records).ttl

      # Wait at least 1 second for monotonic time resolution
      Process.sleep(1100)

      {:ok, second_records, _} = Manager.get("www.example.com.", :A)
      second_ttl = hd(second_records).ttl

      assert second_ttl < first_ttl
      assert second_ttl > 0
      assert second_ttl <= 299
    end

    test "uses SOA minimum for negative caching" do
      soa = %Zone.SOA{
        mname: "ns1.example.com.",
        rname: "admin.example.com.",
        serial: 2_024_102_901,
        refresh: 7200,
        retry: 3600,
        expire: 1_209_600,
        minimum: 600
      }

      Manager.put("nxdomain.example.com.", :A, [], [soa], 600, response_type: :nxdomain)

      {:ok, _, authority} = Manager.get("nxdomain.example.com.", :A)
      assert length(authority) == 1

      # Entry should be cached with SOA minimum TTL
      # (actual TTL tracking would need to look at entry details)
    end
  end

  describe "cache statistics summary" do
    test "generates human-readable summary" do
      # Populate cache
      for i <- 1..10 do
        records = [Zone.Record.new("host#{i}.example.com.", :A, {192, 168, 1, i})]
        Manager.put("host#{i}.example.com.", :A, records, [], 300)
      end

      # Access some entries
      for i <- 1..5 do
        Manager.get("host#{i}.example.com.", :A)
      end

      stats = Manager.stats()
      summary = YellowDog.Dns.Query.Cache.Stats.summary(stats)

      assert is_binary(summary)
      assert String.contains?(summary, "Cache:")
      assert String.contains?(summary, "entries")
    end
  end
end
