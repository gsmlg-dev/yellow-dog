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
  # DHCPv4-specific events (allocated / renewed)
  # ---------------------------------------------------------------------------

  describe "DHCPv4 event types" do
    test "dhcpv4 allocated event inserts lease", %{table: table} do
      ip = {192, 168, 2, 100}

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcpv4, :lease, :allocated],
        %{},
        %{ip: ip, mac: "de:ad:be:ef:00:01", lease_duration: 7200},
        %{table: table}
      )

      assert {:ok, entry} = LeaseCache.lookup(ip, table)
      assert entry.mac == "de:ad:be:ef:00:01"
      assert entry.lease_duration == 7200
    end

    test "dhcpv4 renewed event updates existing lease", %{table: table} do
      ip = {192, 168, 2, 101}
      old = lease_entry(ip: ip, mac: "aa:aa:aa:aa:aa:aa", lease_duration: 3600)
      LeaseCache.put(table, ip, old)

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcpv4, :lease, :renewed],
        %{},
        %{ip: ip, mac: "aa:aa:aa:aa:aa:aa", lease_duration: 7200},
        %{table: table}
      )

      assert {:ok, renewed} = LeaseCache.lookup(ip, table)
      assert renewed.lease_duration == 7200
    end

    test "unknown telemetry event is silently ignored", %{table: table} do
      ip = {192, 168, 2, 200}
      entry = lease_entry(ip: ip)
      LeaseCache.put(table, ip, entry)

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcp, :lease, :unknown_event],
        %{},
        %{ip: ip},
        %{table: table}
      )

      # Lease should still exist — unknown events are no-ops
      assert {:ok, _} = LeaseCache.lookup(ip, table)
    end
  end

  # ---------------------------------------------------------------------------
  # Fallback metadata key variants
  # ---------------------------------------------------------------------------

  describe "metadata fallback keys" do
    test "release with :released_ip key removes lease", %{table: table} do
      ip = {10, 0, 0, 10}
      LeaseCache.put(table, ip, lease_entry(ip: ip))

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcp, :lease, :release],
        %{},
        %{released_ip: ip},
        %{table: table}
      )

      assert :not_found = LeaseCache.lookup(ip, table)
    end

    test "expire with :expired_ip key removes lease", %{table: table} do
      ip = {10, 0, 0, 11}
      LeaseCache.put(table, ip, lease_entry(ip: ip))

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcp, :lease, :expire],
        %{},
        %{expired_ip: ip},
        %{table: table}
      )

      assert :not_found = LeaseCache.lookup(ip, table)
    end

    test "commit with :client_ip inserts lease", %{table: table} do
      ip = {10, 0, 0, 20}

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcp, :lease, :commit],
        %{},
        %{client_ip: ip, mac: "cc:dd:ee:ff:00:11", lease_duration: 3600},
        %{table: table}
      )

      assert {:ok, entry} = LeaseCache.lookup(ip, table)
      assert entry.ip == ip
    end

    test "commit with :mac_address fallback stores mac", %{table: table} do
      ip = {10, 0, 0, 21}

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcp, :lease, :commit],
        %{},
        %{ip: ip, mac_address: "11:22:33:44:55:66", lease_duration: 3600},
        %{table: table}
      )

      assert {:ok, entry} = LeaseCache.lookup(ip, table)
      assert entry.mac == "11:22:33:44:55:66"
    end

    test "commit with :client_hostname fallback stores hostname", %{table: table} do
      ip = {10, 0, 0, 22}

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcp, :lease, :commit],
        %{},
        %{ip: ip, mac: "aa:bb:cc:dd:ee:ff", client_hostname: "fallback-host", lease_duration: 3600},
        %{table: table}
      )

      assert {:ok, entry} = LeaseCache.lookup(ip, table)
      assert entry.hostname == "fallback-host"
    end

    test "commit with :lease_time fallback when lease_duration absent", %{table: table} do
      ip = {10, 0, 0, 23}

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcp, :lease, :commit],
        %{},
        %{ip: ip, mac: "ff:ee:dd:cc:bb:aa", lease_time: 1800},
        %{table: table}
      )

      assert {:ok, entry} = LeaseCache.lookup(ip, table)
      assert entry.lease_duration == 1800
    end
  end

  # ---------------------------------------------------------------------------
  # Telemetry integration
  # ---------------------------------------------------------------------------

  describe "telemetry integration" do
    test "real telemetry event triggers cache update via handler", %{table: table} do
      ip = {10, 99, 0, 1}

      # Fire a real telemetry event — the handler dispatches to our test table
      # only if the handler config uses our table name. Since handlers are attached
      # with the default table, we call the handler directly with our test table config.
      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcp, :lease, :commit],
        %{duration: 100},
        %{ip: ip, mac: "ff:00:ff:00:ff:00", hostname: "telemetry-host", lease_duration: 1800},
        %{table: table}
      )

      assert {:ok, entry} = LeaseCache.lookup(ip, table)
      assert entry.mac == "ff:00:ff:00:ff:00"
      assert entry.hostname == "telemetry-host"
      assert entry.lease_duration == 1800

      # Now fire a release event
      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcp, :lease, :release],
        %{},
        %{ip: ip},
        %{table: table}
      )

      assert :not_found = LeaseCache.lookup(ip, table)
    end

    test "dhcpv4 allocated event via telemetry handler", %{table: table} do
      ip = {10, 99, 0, 2}

      LeaseCache.handle_telemetry_event(
        [:yellow_dog, :dhcpv4, :lease, :allocated],
        %{},
        %{ip: ip, mac: "aa:bb:cc:dd:ee:01", lease_duration: 3600, hostname: "v4-host"},
        %{table: table}
      )

      assert {:ok, entry} = LeaseCache.lookup(ip, table)
      assert entry.mac == "aa:bb:cc:dd:ee:01"
      assert entry.hostname == "v4-host"
    end

    test "handler does not crash on unexpected event names", %{table: table} do
      # Should be a no-op, not a crash
      assert :ok =
               LeaseCache.handle_telemetry_event(
                 [:something, :completely, :different],
                 %{},
                 %{},
                 %{table: table}
               )
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
