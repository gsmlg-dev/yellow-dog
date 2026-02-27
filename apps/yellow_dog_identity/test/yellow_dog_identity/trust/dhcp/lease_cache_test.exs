defmodule YellowDogIdentity.Trust.DHCP.LeaseCacheTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Trust.DHCP.LeaseCache

  setup do
    table_name = :"test_lease_cache_#{System.unique_integer([:positive])}"
    start_supervised!({LeaseCache, name: table_name})
    %{table: table_name}
  end

  # ---------------------------------------------------------------------------
  # lookup/2 basics
  # ---------------------------------------------------------------------------

  describe "lookup/2" do
    test "returns :not_found for unknown IP", %{table: table} do
      assert :not_found = LeaseCache.lookup({10, 0, 0, 99}, table)
    end

    test "returns :not_found when table does not exist" do
      assert :not_found = LeaseCache.lookup({10, 0, 0, 1}, :nonexistent_table)
    end
  end

  # ---------------------------------------------------------------------------
  # put/3 + lookup/2 round-trip
  # ---------------------------------------------------------------------------

  describe "put/3 + lookup/2" do
    test "round-trip works", %{table: table} do
      entry = lease_entry(mac: "11:22:33:44:55:66", ip: {10, 0, 0, 1})

      LeaseCache.put(table, {10, 0, 0, 1}, entry)

      assert {:ok, ^entry} = LeaseCache.lookup({10, 0, 0, 1}, table)
    end

    test "overwrites existing entry for same IP", %{table: table} do
      ip = {192, 168, 1, 50}
      entry1 = lease_entry(mac: "aa:aa:aa:aa:aa:aa", ip: ip)
      entry2 = lease_entry(mac: "bb:bb:bb:bb:bb:bb", ip: ip)

      LeaseCache.put(table, ip, entry1)
      LeaseCache.put(table, ip, entry2)

      {:ok, result} = LeaseCache.lookup(ip, table)
      assert result.mac == "bb:bb:bb:bb:bb:bb"
    end

    test "multiple IPs can coexist in cache", %{table: table} do
      ip_a = {10, 0, 0, 1}
      ip_b = {10, 0, 0, 2}
      ip_c = {10, 0, 0, 3}

      entry_a = lease_entry(mac: "aa:aa:aa:aa:aa:aa", ip: ip_a)
      entry_b = lease_entry(mac: "bb:bb:bb:bb:bb:bb", ip: ip_b)
      entry_c = lease_entry(mac: "cc:cc:cc:cc:cc:cc", ip: ip_c)

      LeaseCache.put(table, ip_a, entry_a)
      LeaseCache.put(table, ip_b, entry_b)
      LeaseCache.put(table, ip_c, entry_c)

      assert {:ok, ra} = LeaseCache.lookup(ip_a, table)
      assert {:ok, rb} = LeaseCache.lookup(ip_b, table)
      assert {:ok, rc} = LeaseCache.lookup(ip_c, table)

      assert ra.mac == "aa:aa:aa:aa:aa:aa"
      assert rb.mac == "bb:bb:bb:bb:bb:bb"
      assert rc.mac == "cc:cc:cc:cc:cc:cc"
    end
  end

  # ---------------------------------------------------------------------------
  # Lease entry fields
  # ---------------------------------------------------------------------------

  describe "lease entry fields" do
    test "has all expected fields", %{table: table} do
      ip = {172, 16, 0, 1}

      entry = %{
        mac: "de:ad:be:ef:00:01",
        ip: ip,
        hostname: "myhost",
        fingerprint_class: "Linux",
        lease_start: System.monotonic_time(:second),
        lease_duration: 7200,
        interface: "eth0"
      }

      LeaseCache.put(table, ip, entry)

      {:ok, result} = LeaseCache.lookup(ip, table)

      assert result.mac == "de:ad:be:ef:00:01"
      assert result.ip == ip
      assert result.hostname == "myhost"
      assert result.fingerprint_class == "Linux"
      assert is_integer(result.lease_start)
      assert result.lease_duration == 7200
      assert result.interface == "eth0"
    end
  end

  # ---------------------------------------------------------------------------
  # cleanup_expired_leases
  # ---------------------------------------------------------------------------

  describe "cleanup_expired_leases" do
    test "removes expired entries", %{table: table} do
      ip = {10, 0, 0, 1}

      :ets.insert(table, {ip, %{
        mac: "aa:bb:cc:dd:ee:ff",
        ip: ip,
        hostname: "old",
        fingerprint_class: nil,
        lease_start: System.monotonic_time(:second) - 7200,
        lease_duration: 3600,
        interface: nil
      }})

      assert {:ok, _} = LeaseCache.lookup(ip, table)

      send(GenServer.whereis(table), :cleanup)
      Process.sleep(50)

      assert :not_found = LeaseCache.lookup(ip, table)
    end

    test "keeps non-expired entries", %{table: table} do
      expired_ip = {10, 0, 0, 1}
      active_ip = {10, 0, 0, 2}

      :ets.insert(table, {expired_ip, %{
        mac: "aa:bb:cc:dd:ee:ff",
        ip: expired_ip,
        hostname: "old",
        fingerprint_class: nil,
        lease_start: System.monotonic_time(:second) - 7200,
        lease_duration: 3600,
        interface: nil
      }})

      :ets.insert(table, {active_ip, %{
        mac: "11:22:33:44:55:66",
        ip: active_ip,
        hostname: "current",
        fingerprint_class: "Linux",
        lease_start: System.monotonic_time(:second),
        lease_duration: 3600,
        interface: "eth0"
      }})

      send(GenServer.whereis(table), :cleanup)
      Process.sleep(50)

      assert :not_found = LeaseCache.lookup(expired_ip, table)
      assert {:ok, kept} = LeaseCache.lookup(active_ip, table)
      assert kept.hostname == "current"
    end
  end

  # ---------------------------------------------------------------------------
  # handle_telemetry_event/4
  # ---------------------------------------------------------------------------

  describe "handle_telemetry_event/4" do
    test "commit event inserts lease", %{table: table} do
      ip = {192, 168, 1, 10}

      metadata = %{
        ip: ip,
        mac: "aa:bb:cc:dd:ee:ff",
        hostname: "new-host",
        fingerprint_class: "Linux",
        lease_duration: 3600,
        interface: "eth0"
      }

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcp, :lease, :commit],
        %{},
        metadata,
        %{table: table}
      )

      assert {:ok, entry} = LeaseCache.lookup(ip, table)
      assert entry.mac == "aa:bb:cc:dd:ee:ff"
      assert entry.hostname == "new-host"
      assert entry.fingerprint_class == "Linux"
      assert entry.lease_duration == 3600
      assert entry.interface == "eth0"
      assert entry.ip == ip
    end

    test "release event removes lease", %{table: table} do
      ip = {192, 168, 1, 20}
      entry = lease_entry(ip: ip, mac: "11:22:33:44:55:66")
      LeaseCache.put(table, ip, entry)

      assert {:ok, _} = LeaseCache.lookup(ip, table)

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcp, :lease, :release],
        %{},
        %{ip: ip},
        %{table: table}
      )

      assert :not_found = LeaseCache.lookup(ip, table)
    end

    test "expire event removes lease", %{table: table} do
      ip = {192, 168, 1, 30}
      entry = lease_entry(ip: ip, mac: "ff:ee:dd:cc:bb:aa")
      LeaseCache.put(table, ip, entry)

      assert {:ok, _} = LeaseCache.lookup(ip, table)

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcp, :lease, :expire],
        %{},
        %{ip: ip},
        %{table: table}
      )

      assert :not_found = LeaseCache.lookup(ip, table)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp lease_entry(overrides) do
    defaults = %{
      mac: "aa:bb:cc:dd:ee:ff",
      ip: {192, 168, 1, 100},
      hostname: "test-node",
      fingerprint_class: nil,
      lease_start: System.monotonic_time(:second),
      lease_duration: 3600,
      interface: "eth0"
    }

    Map.merge(defaults, Map.new(overrides))
  end
end
