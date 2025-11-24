defmodule YellowDog.Dns.Query.Cache.ManagerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Query.Cache.Manager
  alias YellowDog.Dns.Query.Cache.Storage
  alias YellowDog.Dns.Zone

  setup do
    # Clean up any existing table
    if Storage.exists?() do
      :ets.delete(:dns_query_cache)
    end

    # Start the manager
    {:ok, pid} = start_supervised({Manager, enabled: true, max_entries: 100})

    on_exit(fn ->
      if Storage.exists?() do
        :ets.delete(:dns_query_cache)
      end
    end)

    {:ok, manager: pid}
  end

  describe "start_link/1" do
    test "starts with default configuration" do
      assert Process.whereis(Manager) != nil
      assert Manager.enabled?()
    end

    test "respects configuration options", %{manager: _pid} do
      # Stop current manager
      stop_supervised(Manager)

      # Start with custom config
      {:ok, _pid} =
        start_supervised({Manager, enabled: false, max_entries: 500, min_ttl: 60})

      config = Manager.get_config()
      refute config.enabled
      assert config.max_entries == 500
      assert config.min_ttl == 60
    end
  end

  describe "get/3 and put/6" do
    test "caches and retrieves successful responses" do
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1}, ttl: 300)]

      assert :ok = Manager.put("www.example.com.", :A, records, [], 300)
      assert {:ok, retrieved_records, []} = Manager.get("www.example.com.", :A)

      assert length(retrieved_records) == 1
      assert hd(retrieved_records).owner == "www.example.com."
    end

    test "returns error for cache miss" do
      assert {:error, :not_found} = Manager.get("nonexistent.com.", :A)
    end

    test "caches negative responses (NXDOMAIN)" do
      soa = %Zone.SOA{
        mname: "ns1.example.com.",
        rname: "admin.example.com.",
        serial: 2_024_102_901,
        refresh: 7200,
        retry: 3600,
        expire: 1_209_600,
        minimum: 300
      }

      assert :ok =
               Manager.put("nonexistent.example.com.", :A, [], [soa], 300,
                 response_type: :nxdomain
               )

      assert {:ok, [], [^soa]} = Manager.get("nonexistent.example.com.", :A)
    end

    test "caches negative responses (NODATA)" do
      soa = %Zone.SOA{
        mname: "ns1.example.com.",
        rname: "admin.example.com.",
        serial: 2_024_102_901,
        refresh: 7200,
        retry: 3600,
        expire: 1_209_600,
        minimum: 300
      }

      assert :ok = Manager.put("www.example.com.", :MX, [], [soa], 300, response_type: :nodata)

      assert {:ok, [], [^soa]} = Manager.get("www.example.com.", :MX)
    end

    test "updates TTL in cached records" do
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1}, ttl: 300)]

      Manager.put("www.example.com.", :A, records, [], 300)

      # Wait enough time for TTL to decrease (at least 1 second for monotonic time resolution)
      Process.sleep(1100)

      {:ok, retrieved, _} = Manager.get("www.example.com.", :A)
      retrieved_ttl = hd(retrieved).ttl

      # TTL should be less than original (at least 1 second less)
      assert retrieved_ttl < 300
      assert retrieved_ttl > 0
      # Should have decreased by at least 1
      assert retrieved_ttl <= 299
    end

    test "removes expired entries" do
      # Insert entry with very short TTL
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1}, ttl: 1)]
      Manager.put("www.example.com.", :A, records, [], 1)

      # Should be cached
      assert {:ok, _, _} = Manager.get("www.example.com.", :A)

      # Wait for expiration
      Process.sleep(1100)

      # Should be removed
      assert {:error, :not_found} = Manager.get("www.example.com.", :A)
    end

    test "applies TTL clamping (min)" do
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1}, ttl: 1)]

      # Update config to have min_ttl of 60
      Manager.update_config(%{min_ttl: 60})

      Manager.put("www.example.com.", :A, records, [], 1)
      {:ok, retrieved, _} = Manager.get("www.example.com.", :A)

      # TTL should be clamped to min_ttl
      assert hd(retrieved).ttl >= 59
    end

    test "applies TTL clamping (max)" do
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1}, ttl: 100_000)]

      # Update config to have max_ttl of 3600
      Manager.update_config(%{max_ttl: 3600})

      Manager.put("www.example.com.", :A, records, [], 100_000)
      {:ok, retrieved, _} = Manager.get("www.example.com.", :A)

      # TTL should be clamped to max_ttl
      assert hd(retrieved).ttl <= 3600
    end

    test "increments hit count on cache access" do
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1})]
      Manager.put("www.example.com.", :A, records, [], 300)

      # Access multiple times
      Manager.get("www.example.com.", :A)
      Manager.get("www.example.com.", :A)
      Manager.get("www.example.com.", :A)

      stats = Manager.stats()
      assert stats.hit_count == 3
    end

    test "tracks misses" do
      Manager.get("nonexistent1.com.", :A)
      Manager.get("nonexistent2.com.", :A)

      stats = Manager.stats()
      assert stats.miss_count == 2
    end
  end

  describe "invalidate/3" do
    test "removes entry from cache" do
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1})]
      Manager.put("www.example.com.", :A, records, [], 300)

      assert {:ok, _, _} = Manager.get("www.example.com.", :A)

      assert :ok = Manager.invalidate("www.example.com.", :A)

      assert {:error, :not_found} = Manager.get("www.example.com.", :A)
    end

    test "is idempotent" do
      assert :ok = Manager.invalidate("nonexistent.com.", :A)
      assert :ok = Manager.invalidate("nonexistent.com.", :A)
    end
  end

  describe "flush/0" do
    test "removes all entries and resets counters" do
      # Insert multiple entries
      for i <- 1..5 do
        records = [Zone.Record.new("host#{i}.example.com.", :A, {192, 168, 1, i})]
        Manager.put("host#{i}.example.com.", :A, records, [], 300)
      end

      # Access some entries to increment hit count
      Manager.get("host1.example.com.", :A)
      Manager.get("host2.example.com.", :A)

      stats_before = Manager.stats()
      assert stats_before.total_entries == 5
      assert stats_before.hit_count == 2

      assert :ok = Manager.flush()

      stats_after = Manager.stats()
      assert stats_after.total_entries == 0
      assert stats_after.hit_count == 0
      assert stats_after.miss_count == 0
    end
  end

  describe "stats/0" do
    test "returns comprehensive statistics" do
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1})]
      Manager.put("www.example.com.", :A, records, [], 300)
      Manager.get("www.example.com.", :A)
      Manager.get("nonexistent.com.", :A)

      stats = Manager.stats()

      assert stats.total_entries == 1
      assert stats.hit_count == 1
      assert stats.miss_count == 1
      assert stats.insert_count == 1
      assert is_integer(stats.memory_bytes)
    end
  end

  describe "enabled?/0" do
    test "returns cache enabled status" do
      assert Manager.enabled?()
    end
  end

  describe "get_config/0 and update_config/1" do
    test "gets current configuration" do
      config = Manager.get_config()

      assert is_map(config)
      assert Map.has_key?(config, :enabled)
      assert Map.has_key?(config, :max_entries)
      assert Map.has_key?(config, :min_ttl)
      assert Map.has_key?(config, :max_ttl)
    end

    test "updates configuration" do
      assert :ok = Manager.update_config(%{max_entries: 500, min_ttl: 120})

      config = Manager.get_config()
      assert config.max_entries == 500
      assert config.min_ttl == 120
    end
  end

  describe "entry limit enforcement" do
    test "evicts old entries when max_entries exceeded" do
      # Set low limit
      Manager.update_config(%{max_entries: 5})

      # Insert more than max_entries
      for i <- 1..10 do
        records = [Zone.Record.new("host#{i}.example.com.", :A, {192, 168, 1, i})]
        Manager.put("host#{i}.example.com.", :A, records, [], 300)
      end

      stats = Manager.stats()
      # Should have evicted entries to stay at or near max_entries
      assert stats.total_entries <= 5
      assert stats.eviction_count > 0
    end
  end

  describe "disabled cache" do
    setup do
      stop_supervised(Manager)
      {:ok, _pid} = start_supervised({Manager, enabled: false})
      :ok
    end

    test "returns error when disabled" do
      records = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1})]

      assert {:error, :disabled} = Manager.put("www.example.com.", :A, records, [], 300)
      assert {:error, :disabled} = Manager.get("www.example.com.", :A)
    end

    test "enabled? returns false" do
      refute Manager.enabled?()
    end
  end

  describe "different query classes" do
    test "caches entries for different classes separately" do
      records_in = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 1})]
      records_ch = [Zone.Record.new("www.example.com.", :A, {192, 168, 1, 2})]

      Manager.put("www.example.com.", :A, records_in, [], 300, query_class: :IN)
      Manager.put("www.example.com.", :A, records_ch, [], 300, query_class: :CH)

      {:ok, in_records, _} = Manager.get("www.example.com.", :A, :IN)
      {:ok, ch_records, _} = Manager.get("www.example.com.", :A, :CH)

      assert hd(in_records).rdata == {192, 168, 1, 1}
      assert hd(ch_records).rdata == {192, 168, 1, 2}
    end
  end
end
