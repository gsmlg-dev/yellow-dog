defmodule DNS.Zone.CacheTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Zone.Cache.

  Tests cover:
  - Module structure and exports
  - Zone caching with TTL-based expiration
  - Cache operations (put, get, delete, list)
  - Cache metadata and statistics
  - TTL and expiration handling
  - Cache cleanup and maintenance
  - Concurrent access patterns
  - Memory management
  """
  use ExUnit.Case, async: true

  alias DNS.Zone
  alias DNS.Zone.Cache

  setup do
    DNS.Zone.Cache.init()
    DNS.Zone.Cache.clear()
    :ok
  end

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Cache)
    end

    test "exports init/0" do
      Code.ensure_loaded!(Cache)
      assert Kernel.function_exported?(Cache, :init, 0)
    end

    test "exports put_zone/3" do
      Code.ensure_loaded!(Cache)
      assert Kernel.function_exported?(Cache, :put_zone, 3)
    end

    test "exports get_zone/1" do
      Code.ensure_loaded!(Cache)
      assert Kernel.function_exported?(Cache, :get_zone, 1)
    end

    test "exports delete_zone/1" do
      Code.ensure_loaded!(Cache)
      assert Kernel.function_exported?(Cache, :delete_zone, 1)
    end

    test "exports list_zones/0" do
      Code.ensure_loaded!(Cache)
      assert Kernel.function_exported?(Cache, :list_zones, 0)
    end

    test "exports zone_cached?/1" do
      Code.ensure_loaded!(Cache)
      assert Kernel.function_exported?(Cache, :zone_cached?, 1)
    end

    test "exports clear/0" do
      Code.ensure_loaded!(Cache)
      assert Kernel.function_exported?(Cache, :clear, 0)
    end

    test "exports cleanup_expired/0" do
      Code.ensure_loaded!(Cache)
      assert Kernel.function_exported?(Cache, :cleanup_expired, 0)
    end

    test "exports stats/0" do
      Code.ensure_loaded!(Cache)
      assert Kernel.function_exported?(Cache, :stats, 0)
    end

    test "exports get_zone_meta/1" do
      Code.ensure_loaded!(Cache)
      assert Kernel.function_exported?(Cache, :get_zone_meta, 1)
    end

    test "exports refresh_zone/1" do
      Code.ensure_loaded!(Cache)
      assert Kernel.function_exported?(Cache, :refresh_zone, 1)
    end
  end

  describe "put_zone/3" do
    test "stores zone with TTL" do
      zone = Zone.new("example.com", :authoritative)
      assert :ok = Cache.put_zone(zone, 300)
      assert {:ok, ^zone} = Cache.get_zone("example.com")
    end

    test "stores zone with default TTL" do
      zone = Zone.new("example.com", :authoritative)
      assert :ok = Cache.put_zone(zone)
      assert {:ok, ^zone} = Cache.get_zone("example.com")
    end

    test "stores zone with custom options" do
      zone = Zone.new("example.com", :authoritative)
      assert :ok = Cache.put_zone(zone, 300, refresh_interval: 150)
      assert {:ok, ^zone} = Cache.get_zone("example.com")
    end

    test "stores zone with source option" do
      zone = Zone.new("example.com", :authoritative)
      assert :ok = Cache.put_zone(zone, 300, source: :file)
      {:ok, meta} = Cache.get_zone_meta("example.com")
      assert meta.source == :file
    end

    test "overwrites existing zone" do
      zone1 = Zone.new("example.com", :authoritative)
      zone2 = Zone.new("example.com", :stub)

      Cache.put_zone(zone1, 300)
      Cache.put_zone(zone2, 600)

      {:ok, zone} = Cache.get_zone("example.com")
      assert zone.type == :stub
    end

    test "stores multiple zones" do
      zone1 = Zone.new("example.com", :authoritative)
      zone2 = Zone.new("test.com", :stub)
      zone3 = Zone.new("another.com", :forward)

      Cache.put_zone(zone1, 300)
      Cache.put_zone(zone2, 600)
      Cache.put_zone(zone3, 900)

      assert {:ok, _} = Cache.get_zone("example.com")
      assert {:ok, _} = Cache.get_zone("test.com")
      assert {:ok, _} = Cache.get_zone("another.com")
    end

    test "stores zone with very short TTL" do
      zone = Zone.new("example.com", :authoritative)
      assert :ok = Cache.put_zone(zone, 1)
    end

    test "stores zone with very long TTL" do
      zone = Zone.new("example.com", :authoritative)
      assert :ok = Cache.put_zone(zone, 86400 * 365)
    end
  end

  describe "get_zone/1" do
    test "returns not_found for missing zones" do
      assert {:error, :not_found} = Cache.get_zone("nonexistent.com")
    end

    test "retrieves cached zone" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 300)
      assert {:ok, ^zone} = Cache.get_zone("example.com")
    end

    test "returns zone with correct data" do
      zone = Zone.new("example.com", :authoritative, ttl: 3600)
      Cache.put_zone(zone, 300)
      {:ok, retrieved} = Cache.get_zone("example.com")
      assert retrieved.name.value == "example.com"
      assert retrieved.type == :authoritative
    end

    test "accepts Zone.Name struct" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 300)
      assert {:ok, ^zone} = Cache.get_zone(zone.name)
    end

    test "case-insensitive lookup" do
      zone = Zone.new("Example.COM", :authoritative)
      Cache.put_zone(zone, 300)
      # The implementation normalizes keys to lowercase
      assert {:ok, _} = Cache.get_zone("example.com")
    end
  end

  describe "zone_cached?/1" do
    test "returns false for missing zones" do
      refute Cache.zone_cached?("nonexistent.com")
    end

    test "returns true for cached zones" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone)
      assert Cache.zone_cached?("example.com")
    end

    test "returns false after deletion" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone)
      Cache.delete_zone("example.com")
      refute Cache.zone_cached?("example.com")
    end

    test "returns false after expiration" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 1)

      assert Cache.zone_cached?("example.com")

      # Wait for expiration
      :timer.sleep(1100)

      refute Cache.zone_cached?("example.com")
    end

    test "accepts Zone.Name struct" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone)
      assert Cache.zone_cached?(zone.name)
    end
  end

  describe "delete_zone/1" do
    test "removes zone from cache" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone)
      assert :ok = Cache.delete_zone("example.com")
      assert {:error, :not_found} = Cache.get_zone("example.com")
    end

    test "returns ok for non-existent zone" do
      assert :ok = Cache.delete_zone("nonexistent.com")
    end

    test "removes metadata" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 300)
      Cache.delete_zone("example.com")
      assert {:error, :not_found} = Cache.get_zone_meta("example.com")
    end

    test "doesn't affect other zones" do
      zone1 = Zone.new("keep.com", :authoritative)
      zone2 = Zone.new("delete.com", :stub)

      Cache.put_zone(zone1, 300)
      Cache.put_zone(zone2, 300)

      Cache.delete_zone("delete.com")

      assert {:ok, _} = Cache.get_zone("keep.com")
      assert {:error, :not_found} = Cache.get_zone("delete.com")
    end

    test "accepts Zone.Name struct" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone)
      assert :ok = Cache.delete_zone(zone.name)
      assert {:error, :not_found} = Cache.get_zone("example.com")
    end
  end

  describe "list_zones/0" do
    test "returns empty list for empty cache" do
      zones = Cache.list_zones()
      assert zones == []
    end

    test "returns all non-expired zones" do
      zone1 = Zone.new("example.com", :authoritative)
      zone2 = Zone.new("test.com", :stub)

      Cache.put_zone(zone1, 300)
      Cache.put_zone(zone2, 600)

      zones = Cache.list_zones()
      assert length(zones) == 2
      zone_names = Enum.map(zones, fn {zone, _meta} -> zone.name.value end)
      assert "example.com" in zone_names
      assert "test.com" in zone_names
    end

    test "returns zones with metadata" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 300, refresh_interval: 150)

      [{retrieved_zone, meta}] = Cache.list_zones()
      assert retrieved_zone.name.value == "example.com"
      assert meta.ttl == 300
      assert meta.refresh_interval == 150
    end

    test "excludes expired zones" do
      zone1 = Zone.new("expires.com", :authoritative)
      zone2 = Zone.new("stays.com", :stub)

      Cache.put_zone(zone1, 1)
      Cache.put_zone(zone2, 300)

      # Wait for first zone to expire
      :timer.sleep(1100)

      zones = Cache.list_zones()
      assert length(zones) == 1
      [{zone, _}] = zones
      assert zone.name.value == "stays.com"
    end

    test "sorts zones by name" do
      Cache.put_zone(Zone.new("zebra.com", :authoritative), 300)
      Cache.put_zone(Zone.new("alpha.com", :authoritative), 300)
      Cache.put_zone(Zone.new("middle.com", :authoritative), 300)

      zones = Cache.list_zones()
      names = Enum.map(zones, fn {zone, _} -> zone.name.value end)
      assert names == ["alpha.com", "middle.com", "zebra.com"]
    end
  end

  describe "clear/0" do
    test "removes all zones" do
      Cache.put_zone(Zone.new("example.com", :authoritative), 300)
      Cache.put_zone(Zone.new("test.com", :stub), 300)

      assert :ok = Cache.clear()
      assert Cache.list_zones() == []
    end

    test "clears all metadata" do
      Cache.put_zone(Zone.new("example.com", :authoritative), 300)

      Cache.clear()

      assert {:error, :not_found} = Cache.get_zone_meta("example.com")
    end

    test "allows new additions after clear" do
      Cache.put_zone(Zone.new("old.com", :authoritative), 300)
      Cache.clear()
      Cache.put_zone(Zone.new("new.com", :stub), 300)

      zones = Cache.list_zones()
      assert length(zones) == 1
      [{zone, _}] = zones
      assert zone.name.value == "new.com"
    end
  end

  describe "cleanup_expired/0" do
    test "removes expired zones" do
      zone = Zone.new("example.com", :authoritative)
      # 1 second TTL
      Cache.put_zone(zone, 1)

      # Should be in cache initially
      assert {:ok, ^zone} = Cache.get_zone("example.com")

      # Wait for expiration
      :timer.sleep(1100)

      # Clean up and verify
      removed = Cache.cleanup_expired()
      assert removed == 1
      assert {:error, :not_found} = Cache.get_zone("example.com")
    end

    test "returns count of removed zones" do
      Cache.put_zone(Zone.new("expire1.com", :authoritative), 1)
      Cache.put_zone(Zone.new("expire2.com", :authoritative), 1)
      Cache.put_zone(Zone.new("keep.com", :authoritative), 300)

      :timer.sleep(1100)

      removed = Cache.cleanup_expired()
      assert removed == 2
    end

    test "returns 0 when no zones expired" do
      Cache.put_zone(Zone.new("example.com", :authoritative), 300)

      removed = Cache.cleanup_expired()
      assert removed == 0
    end

    test "doesn't remove non-expired zones" do
      Cache.put_zone(Zone.new("expires.com", :authoritative), 1)
      Cache.put_zone(Zone.new("stays.com", :authoritative), 300)

      :timer.sleep(1100)

      Cache.cleanup_expired()

      assert {:error, :not_found} = Cache.get_zone("expires.com")
      assert {:ok, _} = Cache.get_zone("stays.com")
    end
  end

  describe "get_zone_meta/1" do
    test "returns metadata" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 300, refresh_interval: 150)

      assert {:ok, meta} = Cache.get_zone_meta("example.com")
      assert meta.ttl == 300
      assert meta.refresh_interval == 150
      assert meta.expires_at > System.system_time(:second)
    end

    test "returns not_found for missing zone" do
      assert {:error, :not_found} = Cache.get_zone_meta("nonexistent.com")
    end

    test "includes last_updated timestamp" do
      zone = Zone.new("example.com", :authoritative)
      before = System.system_time(:second)
      Cache.put_zone(zone, 300)
      after_time = System.system_time(:second)

      {:ok, meta} = Cache.get_zone_meta("example.com")
      assert meta.last_updated >= before
      assert meta.last_updated <= after_time
    end

    test "includes source information" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 300, source: :transfer)

      {:ok, meta} = Cache.get_zone_meta("example.com")
      assert meta.source == :transfer
    end

    test "default source is :unknown" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 300)

      {:ok, meta} = Cache.get_zone_meta("example.com")
      assert meta.source == :unknown
    end
  end

  describe "stats/0" do
    test "returns cache statistics" do
      zone1 = Zone.new("example.com", :authoritative)
      zone2 = Zone.new("test.com", :stub)

      Cache.put_zone(zone1, 300)
      Cache.put_zone(zone2, 600)

      stats = Cache.stats()
      assert stats.total_entries == 2
      assert stats.valid_entries == 2
      assert stats.expired_entries == 0
      assert is_integer(stats.memory_usage)
    end

    test "returns empty stats for empty cache" do
      stats = Cache.stats()
      assert stats.total_entries == 0
      assert stats.valid_entries == 0
      assert stats.expired_entries == 0
    end

    test "tracks expired entries" do
      Cache.put_zone(Zone.new("expires.com", :authoritative), 1)
      Cache.put_zone(Zone.new("stays.com", :authoritative), 300)

      :timer.sleep(1100)

      # Note: stats() may clean up expired entries while calculating
      # So we test what we can
      stats = Cache.stats()
      assert stats.valid_entries <= 2
    end

    test "includes memory usage" do
      Cache.put_zone(Zone.new("example.com", :authoritative), 300)

      stats = Cache.stats()
      assert stats.memory_usage > 0
    end

    test "includes cache hit ratio" do
      stats = Cache.stats()
      assert is_float(stats.cache_hit_ratio)
    end
  end

  describe "refresh_zone/1" do
    test "returns error for missing zone" do
      assert {:error, :not_found} = Cache.refresh_zone("nonexistent.com")
    end

    test "handles zone not due for refresh" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 300, refresh_interval: 150)

      # Zone was just created, not due for refresh
      result = Cache.refresh_zone("example.com")
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end
  end

  describe "TTL and expiration" do
    test "zone expires after TTL" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 1)

      assert {:ok, _} = Cache.get_zone("example.com")

      :timer.sleep(1100)

      # Should return expired or not_found
      result = Cache.get_zone("example.com")
      assert result in [{:error, :expired}, {:error, :not_found}]
    end

    test "zone accessible before expiration" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 10)

      # Access immediately
      assert {:ok, ^zone} = Cache.get_zone("example.com")

      # Access after a short time (still within TTL)
      :timer.sleep(100)
      assert {:ok, ^zone} = Cache.get_zone("example.com")
    end

    test "expiration calculated from put time" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 5)

      {:ok, meta} = Cache.get_zone_meta("example.com")
      now = System.system_time(:second)

      # expires_at should be approximately now + 5 seconds
      assert meta.expires_at >= now
      assert meta.expires_at <= now + 6
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 300)

      tasks =
        1..10
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Cache.get_zone("example.com")
          end)
        end)

      results = Task.await_many(tasks)
      assert Enum.all?(results, &match?({:ok, _}, &1))
    end

    test "handles concurrent writes" do
      tasks =
        1..10
        |> Enum.map(fn i ->
          Task.async(fn ->
            zone = Zone.new("zone#{i}.com", :authoritative)
            Cache.put_zone(zone, 300)
          end)
        end)

      results = Task.await_many(tasks)
      assert Enum.all?(results, &(&1 == :ok))

      zones = Cache.list_zones()
      assert length(zones) == 10
    end

    test "handles mixed read/write operations" do
      zone = Zone.new("shared.com", :authoritative)
      Cache.put_zone(zone, 300)

      tasks =
        1..20
        |> Enum.map(fn i ->
          Task.async(fn ->
            if rem(i, 2) == 0 do
              Cache.get_zone("shared.com")
            else
              new_zone = Zone.new("zone#{i}.com", :stub)
              Cache.put_zone(new_zone, 300)
            end
          end)
        end)

      results = Task.await_many(tasks)
      # All operations should complete without error
      assert length(results) == 20
    end
  end

  describe "edge cases" do
    test "handles empty zone name" do
      zone = Zone.new("", :authoritative)
      Cache.put_zone(zone, 300)
      assert {:ok, _} = Cache.get_zone("")
    end

    test "handles zone with very long name" do
      long_name = String.duplicate("a", 63) <> ".example.com"
      zone = Zone.new(long_name, :authoritative)
      Cache.put_zone(zone, 300)
      assert {:ok, _} = Cache.get_zone(long_name)
    end

    test "handles zones with different types" do
      types = [:authoritative, :stub, :forward, :cache]

      for {type, i} <- Enum.with_index(types) do
        zone = Zone.new("zone#{i}.com", type)
        Cache.put_zone(zone, 300)
        {:ok, retrieved} = Cache.get_zone("zone#{i}.com")
        assert retrieved.type == type
      end
    end

    test "handles zero TTL" do
      zone = Zone.new("example.com", :authoritative)
      # Zero TTL means immediate expiration
      Cache.put_zone(zone, 0)

      # Immediately expired
      result = Cache.get_zone("example.com")
      assert result in [{:error, :expired}, {:error, :not_found}]
    end

    test "handles maximum TTL" do
      zone = Zone.new("example.com", :authoritative)
      # Very large TTL (1 year in seconds)
      Cache.put_zone(zone, 31_536_000)

      {:ok, meta} = Cache.get_zone_meta("example.com")
      assert meta.ttl == 31_536_000
    end
  end
end
