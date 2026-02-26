defmodule YellowDogIdentity.Trust.DHCP.Correlation.Test do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Trust.DHCP.{Correlation, LeaseCache}

  @test_ip {192, 168, 1, 100}

  setup do
    # Start a fresh LeaseCache GenServer for each test.
    # We use the default name (__MODULE__ = LeaseCache) so that
    # Correlation.verify/1 -> LeaseCache.lookup/1 finds the table.
    #
    # Since we cannot start_supervised! with the default name (it would
    # conflict across tests), we manually create the named ETS table that
    # LeaseCache.lookup/1 expects.
    table = LeaseCache
    ref = :ets.new(table, [:set, :public, :named_table])

    on_exit(fn ->
      try do
        :ets.delete(ref)
      rescue
        ArgumentError -> :ok
      end
    end)

    %{table: table}
  end

  # ---------------------------------------------------------------------------
  # No lease found -- DHCP not configured
  # ---------------------------------------------------------------------------

  describe "verify/1 with no lease and DHCP not configured" do
    test "returns {:skip, :not_applicable} for unknown IP" do
      # No lease inserted; YellowDog.Config is not running in the test env,
      # so dhcp_configured?() returns false -> skip.
      unknown_ip = {10, 255, 255, 1}
      assert {:skip, :not_applicable} = Correlation.verify(%{source_ip: unknown_ip})
    end

    test "returns skip for any arbitrary IP without a lease" do
      assert {:skip, :not_applicable} = Correlation.verify(%{source_ip: {172, 16, 0, 99}})
    end
  end

  # ---------------------------------------------------------------------------
  # Active lease with fingerprint -> :network_verified
  # ---------------------------------------------------------------------------

  describe "verify/1 with active lease and fingerprint_class" do
    test "returns {:trusted, :network_verified, evidence}" do
      insert_lease(@test_ip,
        mac: "aa:bb:cc:dd:ee:ff",
        fingerprint_class: "Linux"
      )

      assert {:trusted, :network_verified, evidence} =
               Correlation.verify(%{source_ip: @test_ip})

      assert evidence.provider == :dhcp
      assert evidence.mac == "aa:bb:cc:dd:ee:ff"
      assert evidence.fingerprint_class == "Linux"
    end

    test "any non-nil fingerprint class is verified when no allowlist is configured" do
      # Without YellowDog.Config running, get_allowed_fingerprint_classes() returns [],
      # so the fallback condition `allowed == []` is true -- any non-nil fingerprint matches.
      insert_lease(@test_ip, fingerprint_class: "SomeUnknownOS")

      assert {:trusted, :network_verified, evidence} =
               Correlation.verify(%{source_ip: @test_ip})

      assert evidence.fingerprint_class == "SomeUnknownOS"
    end
  end

  # ---------------------------------------------------------------------------
  # Active lease without fingerprint -> :network_partial
  # ---------------------------------------------------------------------------

  describe "verify/1 with active lease but no fingerprint_class" do
    test "returns {:trusted, :network_partial, evidence}" do
      insert_lease(@test_ip,
        mac: "cc:dd:ee:ff:00:11",
        fingerprint_class: nil
      )

      assert {:trusted, :network_partial, evidence} =
               Correlation.verify(%{source_ip: @test_ip})

      assert evidence.provider == :dhcp
      assert evidence.mac == "cc:dd:ee:ff:00:11"
      assert evidence.fingerprint_class == nil
    end

    test "assigned_ip in evidence matches the source IP" do
      insert_lease(@test_ip, fingerprint_class: nil)

      {:trusted, :network_partial, evidence} = Correlation.verify(%{source_ip: @test_ip})
      assert evidence.assigned_ip == @test_ip
    end
  end

  # ---------------------------------------------------------------------------
  # Expired lease -> :untrusted :expired
  # ---------------------------------------------------------------------------

  describe "verify/1 with expired lease" do
    test "returns {:untrusted, :expired} when lease exceeds duration + grace window" do
      # Default grace window is 30 seconds. Set lease_start far enough in the past
      # that lease_age > lease_duration + grace_window.
      expired_start = System.monotonic_time(:second) - 7200

      insert_lease(@test_ip,
        lease_start: expired_start,
        lease_duration: 3600,
        fingerprint_class: "Linux"
      )

      assert {:untrusted, :expired} = Correlation.verify(%{source_ip: @test_ip})
    end

    test "lease within grace window is not expired" do
      # lease_duration=100, lease_age=105, grace_window=30 -> 105 < 130 -> NOT expired
      start = System.monotonic_time(:second) - 105

      insert_lease(@test_ip,
        lease_start: start,
        lease_duration: 100,
        fingerprint_class: "Linux"
      )

      assert {:trusted, :network_verified, _evidence} =
               Correlation.verify(%{source_ip: @test_ip})
    end

    test "lease just past grace window is expired" do
      # lease_duration=100, grace_window=30, lease_age=131 -> 131 > 130 -> expired
      start = System.monotonic_time(:second) - 131

      insert_lease(@test_ip,
        lease_start: start,
        lease_duration: 100,
        fingerprint_class: "Linux"
      )

      assert {:untrusted, :expired} = Correlation.verify(%{source_ip: @test_ip})
    end
  end

  # ---------------------------------------------------------------------------
  # Evidence map structure
  # ---------------------------------------------------------------------------

  describe "evidence map structure" do
    test "contains all expected keys" do
      now = System.monotonic_time(:second)

      insert_lease(@test_ip,
        mac: "11:22:33:44:55:66",
        fingerprint_class: "NixOS",
        lease_start: now,
        lease_duration: 7200,
        interface: "eth0"
      )

      {:trusted, :network_verified, evidence} = Correlation.verify(%{source_ip: @test_ip})

      assert Map.has_key?(evidence, :provider)
      assert Map.has_key?(evidence, :mac)
      assert Map.has_key?(evidence, :assigned_ip)
      assert Map.has_key?(evidence, :fingerprint_class)
      assert Map.has_key?(evidence, :lease_start)
      assert Map.has_key?(evidence, :lease_duration)
      assert Map.has_key?(evidence, :dhcp_interface)
    end

    test "evidence values match the lease entry" do
      now = System.monotonic_time(:second)

      insert_lease(@test_ip,
        mac: "de:ad:be:ef:00:01",
        fingerprint_class: "Windows",
        lease_start: now,
        lease_duration: 1800,
        interface: "wlan0"
      )

      {:trusted, :network_verified, evidence} = Correlation.verify(%{source_ip: @test_ip})

      assert evidence.provider == :dhcp
      assert evidence.mac == "de:ad:be:ef:00:01"
      assert evidence.assigned_ip == @test_ip
      assert evidence.fingerprint_class == "Windows"
      assert evidence.lease_start == now
      assert evidence.lease_duration == 1800
      assert evidence.dhcp_interface == "wlan0"
    end

    test "evidence with nil interface" do
      insert_lease(@test_ip, fingerprint_class: "Linux", interface: nil)

      {:trusted, :network_verified, evidence} = Correlation.verify(%{source_ip: @test_ip})

      assert evidence.dhcp_interface == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple IPs in cache
  # ---------------------------------------------------------------------------

  describe "verify/1 with multiple IPs in cache" do
    test "each IP resolves independently" do
      ip_a = {192, 168, 1, 10}
      ip_b = {192, 168, 1, 20}
      ip_c = {192, 168, 1, 30}

      insert_lease(ip_a, mac: "aa:aa:aa:aa:aa:aa", fingerprint_class: "Linux")
      insert_lease(ip_b, mac: "bb:bb:bb:bb:bb:bb", fingerprint_class: nil)
      insert_lease(ip_c, mac: "cc:cc:cc:cc:cc:cc", fingerprint_class: "macOS")

      assert {:trusted, :network_verified, ev_a} = Correlation.verify(%{source_ip: ip_a})
      assert ev_a.mac == "aa:aa:aa:aa:aa:aa"

      assert {:trusted, :network_partial, ev_b} = Correlation.verify(%{source_ip: ip_b})
      assert ev_b.mac == "bb:bb:bb:bb:bb:bb"

      assert {:trusted, :network_verified, ev_c} = Correlation.verify(%{source_ip: ip_c})
      assert ev_c.mac == "cc:cc:cc:cc:cc:cc"
    end

    test "unlisted IP still returns skip" do
      insert_lease({192, 168, 1, 10}, mac: "aa:aa:aa:aa:aa:aa", fingerprint_class: "Linux")

      assert {:skip, :not_applicable} = Correlation.verify(%{source_ip: {10, 0, 0, 99}})
    end
  end

  # ---------------------------------------------------------------------------
  # IPv6 lease
  # ---------------------------------------------------------------------------

  describe "verify/1 with IPv6 address" do
    test "works with IPv6 tuple" do
      ipv6 = {0xFD00, 0, 0, 0, 0, 0, 0, 1}

      insert_lease(ipv6, mac: "aa:bb:cc:dd:ee:ff", fingerprint_class: "Linux")

      assert {:trusted, :network_verified, evidence} =
               Correlation.verify(%{source_ip: ipv6})

      assert evidence.assigned_ip == ipv6
      assert evidence.mac == "aa:bb:cc:dd:ee:ff"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_lease(ip, overrides) do
    entry = lease_entry([{:ip, ip} | overrides])
    LeaseCache.put(LeaseCache, ip, entry)
  end

  defp lease_entry(overrides) do
    defaults = %{
      mac: "aa:bb:cc:dd:ee:ff",
      ip: @test_ip,
      hostname: "test-node",
      fingerprint_class: nil,
      lease_start: System.monotonic_time(:second),
      lease_duration: 3600,
      interface: "eth0"
    }

    Map.merge(defaults, Map.new(overrides))
  end
end
