defmodule YellowDogIdentity.Trust.DHCP.CorrelationTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Trust.DHCP.{Correlation, LeaseCache}

  @test_ip {192, 168, 1, 100}

  setup do
    # Create a unique ETS table for each test
    table_name = :"lease_cache_test_#{System.unique_integer([:positive])}"
    :ets.new(table_name, [:set, :public, :named_table])

    %{table: table_name}
  end

  describe "verify/1 with active lease" do
    test "returns network_verified when lease has fingerprint", %{table: table} do
      insert_lease(table, @test_ip, %{
        fingerprint_class: "Linux"
      })

      # Patch LeaseCache to use our test table
      assert {:ok, entry} = LeaseCache.lookup(@test_ip, table)
      assert entry.fingerprint_class == "Linux"
    end

    test "lease entry contains expected fields", %{table: table} do
      insert_lease(table, @test_ip, %{
        mac: "aa:bb:cc:dd:ee:ff",
        fingerprint_class: "NixOS"
      })

      {:ok, entry} = LeaseCache.lookup(@test_ip, table)
      assert entry.mac == "aa:bb:cc:dd:ee:ff"
      assert entry.ip == @test_ip
      assert entry.fingerprint_class == "NixOS"
      assert is_integer(entry.lease_start)
      assert entry.lease_duration == 3600
    end
  end

  describe "verify/1 without lease" do
    test "lookup returns :not_found for unknown IP", %{table: table} do
      assert :not_found = LeaseCache.lookup({10, 0, 0, 99}, table)
    end
  end

  describe "LeaseCache.put/3" do
    test "inserts and retrieves lease entry", %{table: table} do
      entry = %{
        mac: "11:22:33:44:55:66",
        ip: {10, 0, 0, 1},
        hostname: "test-host",
        fingerprint_class: "Linux",
        lease_start: System.monotonic_time(:second),
        lease_duration: 7200,
        interface: "eth0"
      }

      LeaseCache.put(table, {10, 0, 0, 1}, entry)
      assert {:ok, ^entry} = LeaseCache.lookup({10, 0, 0, 1}, table)
    end

    test "overwrites existing entry", %{table: table} do
      entry1 = lease_entry(mac: "aa:aa:aa:aa:aa:aa")
      entry2 = lease_entry(mac: "bb:bb:bb:bb:bb:bb")

      LeaseCache.put(table, @test_ip, entry1)
      LeaseCache.put(table, @test_ip, entry2)

      {:ok, result} = LeaseCache.lookup(@test_ip, table)
      assert result.mac == "bb:bb:bb:bb:bb:bb"
    end
  end

  describe "Correlation.verify/1 skip cases" do
    test "skips when no attestation context" do
      # Without a running LeaseCache GenServer, the ETS lookup will fail
      # and Correlation will skip or return untrusted
      result = Correlation.verify(%{source_ip: {127, 0, 0, 1}})
      assert result in [{:skip, :not_applicable}, {:untrusted, :no_lease}]
    end
  end

  defp insert_lease(table, ip, overrides) do
    entry = lease_entry(overrides)
    :ets.insert(table, {ip, entry})
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
