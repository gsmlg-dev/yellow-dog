defmodule DNS.Zone.CacheTest do
  use ExUnit.Case

  alias DNS.Zone
  alias DNS.Zone.Cache

  setup do
    DNS.Zone.Cache.init()
    DNS.Zone.Cache.clear()
    :ok
  end

  describe "zone caching" do
    test "put_zone/3 stores zone with TTL" do
      zone = Zone.new("example.com", :authoritative)
      assert :ok = Cache.put_zone(zone, 300)
      assert {:ok, ^zone} = Cache.get_zone("example.com")
    end

    test "get_zone/1 returns not_found for missing zones" do
      assert {:error, :not_found} = Cache.get_zone("nonexistent.com")
    end

    test "zone_cached?/1 returns boolean based on cache status" do
      zone = Zone.new("example.com", :authoritative)
      refute Cache.zone_cached?("example.com")
      Cache.put_zone(zone)
      assert Cache.zone_cached?("example.com")
    end

    test "delete_zone/1 removes zone from cache" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone)
      assert :ok = Cache.delete_zone("example.com")
      assert {:error, :not_found} = Cache.get_zone("example.com")
    end

    test "list_zones/0 returns all non-expired zones" do
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

    test "cleanup_expired/0 removes expired zones" do
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

    test "get_zone_meta/1 returns metadata" do
      zone = Zone.new("example.com", :authoritative)
      Cache.put_zone(zone, 300, refresh_interval: 150)

      assert {:ok, meta} = Cache.get_zone_meta("example.com")
      assert meta.ttl == 300
      assert meta.refresh_interval == 150
      assert meta.expires_at > System.system_time(:second)
    end

    test "stats/0 returns cache statistics" do
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
  end
end
