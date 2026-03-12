defmodule YellowDogIdentity.Trust.DHCP.CorrelationTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Trust.DHCP.{Correlation, LeaseCache}

  @test_ip {192, 168, 1, 100}
  @default_table YellowDogIdentity.Trust.DHCP.LeaseCache

  setup do
    # Create the default-named ETS table so Correlation.verify/1 can find leases
    # via LeaseCache.lookup/1 (which uses __MODULE__ as the table name).
    # The table may already exist if started by the app supervisor.
    table =
      case :ets.whereis(@default_table) do
        :undefined ->
          :ets.new(@default_table, [:set, :public, :named_table])

        ref ->
          :ets.delete_all_objects(ref)
          ref
      end

    on_exit(fn ->
      try do
        :ets.delete_all_objects(table)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # LeaseCache.put/3 and LeaseCache.lookup/2
  # ---------------------------------------------------------------------------

  describe "LeaseCache.put/3 and lookup/2" do
    test "inserts and retrieves a lease entry" do
      entry = lease_entry(mac: "11:22:33:44:55:66", ip: {10, 0, 0, 1})

      LeaseCache.put(@default_table, {10, 0, 0, 1}, entry)

      assert {:ok, ^entry} = LeaseCache.lookup({10, 0, 0, 1}, @default_table)
    end

    test "overwrites existing entry for the same IP" do
      entry1 = lease_entry(mac: "aa:aa:aa:aa:aa:aa")
      entry2 = lease_entry(mac: "bb:bb:bb:bb:bb:bb")

      LeaseCache.put(@default_table, @test_ip, entry1)
      LeaseCache.put(@default_table, @test_ip, entry2)

      {:ok, result} = LeaseCache.lookup(@test_ip, @default_table)
      assert result.mac == "bb:bb:bb:bb:bb:bb"
    end

    test "returns :not_found for unknown IP" do
      assert :not_found = LeaseCache.lookup({10, 0, 0, 99}, @default_table)
    end

    test "returns :not_found when table does not exist" do
      assert :not_found = LeaseCache.lookup({10, 0, 0, 1}, :nonexistent_table)
    end
  end

  # ---------------------------------------------------------------------------
  # LeaseCache.lookup/1 (default table)
  # ---------------------------------------------------------------------------

  describe "LeaseCache.lookup/1 (default table)" do
    test "uses the default module table name" do
      entry = lease_entry(mac: "de:fa:ul:tt:ab:le")
      LeaseCache.put(@default_table, @test_ip, entry)

      assert {:ok, result} = LeaseCache.lookup(@test_ip)
      assert result.mac == "de:fa:ul:tt:ab:le"
    end
  end

  # ---------------------------------------------------------------------------
  # Correlation.verify/1 -- no lease found
  # ---------------------------------------------------------------------------

  describe "verify/1 with no lease found" do
    test "returns {:skip, :not_applicable} when DHCP is not configured" do
      # No lease inserted for this IP, and YellowDog.Config is not running,
      # so dhcp_configured?() returns false.
      assert {:skip, :not_applicable} = Correlation.verify(%{source_ip: {10, 255, 255, 1}})
    end
  end

  # ---------------------------------------------------------------------------
  # Correlation.verify/1 -- active lease with fingerprint
  # ---------------------------------------------------------------------------

  describe "verify/1 with active lease and fingerprint" do
    test "returns {:trusted, :network_verified, evidence}" do
      insert_lease(@test_ip, fingerprint_class: "Linux", mac: "aa:bb:cc:dd:ee:ff")

      assert {:trusted, :network_verified, evidence} =
               Correlation.verify(%{source_ip: @test_ip})

      assert evidence.provider == :dhcp
      assert evidence.mac == "aa:bb:cc:dd:ee:ff"
      assert evidence.fingerprint_class == "Linux"
    end

    test "evidence contains all expected fields" do
      now = System.monotonic_time(:second)

      insert_lease(@test_ip,
        mac: "11:22:33:44:55:66",
        fingerprint_class: "NixOS",
        lease_start: now,
        lease_duration: 7200,
        interface: "eth0"
      )

      {:trusted, :network_verified, evidence} = Correlation.verify(%{source_ip: @test_ip})

      assert evidence.provider == :dhcp
      assert evidence.mac == "11:22:33:44:55:66"
      assert evidence.assigned_ip == @test_ip
      assert evidence.fingerprint_class == "NixOS"
      assert evidence.lease_start == now
      assert evidence.lease_duration == 7200
      assert evidence.dhcp_interface == "eth0"
    end
  end

  # ---------------------------------------------------------------------------
  # Correlation.verify/1 -- active lease without fingerprint
  # ---------------------------------------------------------------------------

  describe "verify/1 with active lease but no fingerprint" do
    test "returns {:trusted, :network_partial, evidence}" do
      insert_lease(@test_ip, fingerprint_class: nil, mac: "cc:dd:ee:ff:00:11")

      assert {:trusted, :network_partial, evidence} =
               Correlation.verify(%{source_ip: @test_ip})

      assert evidence.provider == :dhcp
      assert evidence.mac == "cc:dd:ee:ff:00:11"
      assert evidence.fingerprint_class == nil
    end

    test "evidence assigned_ip matches the looked-up IP" do
      insert_lease(@test_ip, fingerprint_class: nil)

      {:trusted, :network_partial, evidence} = Correlation.verify(%{source_ip: @test_ip})
      assert evidence.assigned_ip == @test_ip
    end
  end

  # ---------------------------------------------------------------------------
  # Correlation.verify/1 -- expired lease
  # ---------------------------------------------------------------------------

  describe "verify/1 with expired lease" do
    test "returns {:untrusted, :expired}" do
      # Set lease_start far enough in the past that lease_age > lease_duration
      expired_start = System.monotonic_time(:second) - 7200

      insert_lease(@test_ip,
        lease_start: expired_start,
        lease_duration: 3600,
        fingerprint_class: "Linux"
      )

      assert {:untrusted, :expired} = Correlation.verify(%{source_ip: @test_ip})
    end
  end

  # ---------------------------------------------------------------------------
  # fingerprint_matches? -- no allowlist configured
  # ---------------------------------------------------------------------------

  describe "fingerprint matching with no allowlist" do
    test "any non-nil fingerprint class matches when no allowlist is configured" do
      # Without YellowDog.Config running, get_allowed_fingerprint_classes() returns [],
      # so the condition `allowed == []` is true, meaning any non-nil fingerprint matches.
      insert_lease(@test_ip, fingerprint_class: "SomeUnknownOS")

      assert {:trusted, :network_verified, evidence} =
               Correlation.verify(%{source_ip: @test_ip})

      assert evidence.fingerprint_class == "SomeUnknownOS"
    end

    test "nil fingerprint does not match even without allowlist" do
      # fingerprint_class is nil, so the cond branch checking
      # `lease_entry.fingerprint_class && fingerprint_matches?(...)` is false
      # and we fall through to :network_partial.
      insert_lease(@test_ip, fingerprint_class: nil)

      assert {:trusted, :network_partial, _evidence} =
               Correlation.verify(%{source_ip: @test_ip})
    end
  end

  # ---------------------------------------------------------------------------
  # Multiple IPs
  # ---------------------------------------------------------------------------

  describe "verify/1 with multiple IPs in cache" do
    test "each IP resolves independently" do
      ip_a = {192, 168, 1, 10}
      ip_b = {192, 168, 1, 20}

      insert_lease(ip_a, mac: "aa:aa:aa:aa:aa:aa", fingerprint_class: "Linux")
      insert_lease(ip_b, mac: "bb:bb:bb:bb:bb:bb", fingerprint_class: nil)

      assert {:trusted, :network_verified, ev_a} = Correlation.verify(%{source_ip: ip_a})
      assert ev_a.mac == "aa:aa:aa:aa:aa:aa"

      assert {:trusted, :network_partial, ev_b} = Correlation.verify(%{source_ip: ip_b})
      assert ev_b.mac == "bb:bb:bb:bb:bb:bb"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_lease(ip, overrides) do
    entry = lease_entry([{:ip, ip} | overrides])
    :ets.insert(@default_table, {ip, entry})
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
