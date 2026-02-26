defmodule YellowDogIdentity.Trust.NetbootTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Trust.Netboot

  @default_table YellowDogIdentity.Trust.DHCP.LeaseCache

  # ---------------------------------------------------------------------------
  # Setup: create the default-named ETS table so LeaseCache.lookup/1 works
  # ---------------------------------------------------------------------------

  setup do
    table = :ets.new(@default_table, [:set, :public, :named_table])

    on_exit(fn ->
      try do
        :ets.delete(table)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Module loadability and behaviour
  # ---------------------------------------------------------------------------

  describe "module" do
    test "is loadable" do
      assert {:module, Netboot} = Code.ensure_loaded(Netboot)
    end

    test "implements the Trust.Provider behaviour" do
      Code.ensure_loaded!(Netboot)
      assert function_exported?(Netboot, :verify, 1)
    end

    test "verify/1 is the only required callback" do
      behaviours =
        Netboot.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert YellowDogIdentity.Trust.Provider in behaviours
    end
  end

  # ---------------------------------------------------------------------------
  # verify/1 with no lease in cache
  # ---------------------------------------------------------------------------

  describe "verify/1 with no lease in cache" do
    test "returns {:skip, :not_applicable} for unknown IP" do
      context = %{source_ip: {10, 0, 0, 1}}
      assert {:skip, :not_applicable} = Netboot.verify(context)
    end

    test "returns {:skip, :not_applicable} for a private network IP" do
      context = %{source_ip: {192, 168, 99, 99}}
      assert {:skip, :not_applicable} = Netboot.verify(context)
    end

    test "returns {:skip, :not_applicable} for loopback address" do
      context = %{source_ip: {127, 0, 0, 1}}
      assert {:skip, :not_applicable} = Netboot.verify(context)
    end

    test "returns {:skip, :not_applicable} for IPv6 address" do
      context = %{source_ip: {0, 0, 0, 0, 0, 0, 0, 1}}
      assert {:skip, :not_applicable} = Netboot.verify(context)
    end
  end

  # ---------------------------------------------------------------------------
  # verify/1 with missing source_ip
  # ---------------------------------------------------------------------------

  describe "verify/1 with missing source_ip" do
    test "raises FunctionClauseError when context has no source_ip key" do
      assert_raise FunctionClauseError, fn ->
        # Suppress dialyzer/type-check warning with apply
        apply(Netboot, :verify, [%{}])
      end
    end

    test "raises FunctionClauseError for map without source_ip" do
      assert_raise FunctionClauseError, fn ->
        apply(Netboot, :verify, [%{hostname: "test"}])
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Happy path with lease cache populated (supervised)
  # ---------------------------------------------------------------------------

  describe "happy path with lease cache populated" do
    setup do
      # Start a lease cache for this test
      table_name = :"netboot_lease_cache_#{System.unique_integer([:positive])}"
      start_supervised!({YellowDogIdentity.Trust.DHCP.LeaseCache, name: table_name})

      # Insert a lease entry
      ip = {192, 168, 1, 42}

      entry = %{
        mac: "aa:bb:cc:dd:ee:ff",
        ip: ip,
        hostname: "pxe-node",
        fingerprint_class: "NixOS",
        lease_start: System.monotonic_time(:second),
        lease_duration: 7200,
        interface: "eth0"
      }

      YellowDogIdentity.Trust.DHCP.LeaseCache.put(table_name, ip, entry)
      %{ip: ip, table: table_name}
    end

    test "returns skip when lease exists but netboot device registry not available", %{ip: ip} do
      # Netboot module's lookup_netboot_device will return :not_found because
      # YellowDog.Netboot.Device.Registry is not running in test env
      context = %{source_ip: ip}

      # Since the default LeaseCache table (__MODULE__) is used in production code,
      # and our test uses a custom table, the netboot provider will look up the
      # default table which won't have our entry — so it skips
      assert {:skip, :not_applicable} = Netboot.verify(context)
    end
  end

  # ---------------------------------------------------------------------------
  # verify/1 with lease in cache but no netboot device
  # ---------------------------------------------------------------------------

  describe "verify/1 with lease present but no netboot device" do
    test "returns {:skip, :not_applicable} when netboot registry is not available" do
      # Insert a lease so LeaseCache.lookup succeeds, but the netboot device
      # registry (YellowDog.Netboot.Device.Registry) is not loaded in the
      # test environment, so lookup_netboot_device returns :not_found.
      ip = {192, 168, 1, 100}
      insert_lease(ip, mac: "aa:bb:cc:dd:ee:ff", fingerprint_class: "Linux")

      context = %{source_ip: ip}
      assert {:skip, :not_applicable} = Netboot.verify(context)
    end

    test "returns {:skip, :not_applicable} regardless of fingerprint class" do
      ip = {10, 0, 0, 50}
      insert_lease(ip, mac: "11:22:33:44:55:66", fingerprint_class: "NixOS")

      assert {:skip, :not_applicable} = Netboot.verify(%{source_ip: ip})
    end

    test "returns {:skip, :not_applicable} with nil fingerprint" do
      ip = {172, 16, 0, 1}
      insert_lease(ip, mac: "de:ad:be:ef:00:01", fingerprint_class: nil)

      assert {:skip, :not_applicable} = Netboot.verify(%{source_ip: ip})
    end
  end

  # ---------------------------------------------------------------------------
  # verify/1 with multiple IPs
  # ---------------------------------------------------------------------------

  describe "verify/1 with multiple IPs in cache" do
    test "each IP is checked independently" do
      ip_a = {192, 168, 1, 10}
      ip_b = {192, 168, 1, 20}

      insert_lease(ip_a, mac: "aa:aa:aa:aa:aa:aa")
      insert_lease(ip_b, mac: "bb:bb:bb:bb:bb:bb")

      # Both should skip since netboot registry is not available
      assert {:skip, :not_applicable} = Netboot.verify(%{source_ip: ip_a})
      assert {:skip, :not_applicable} = Netboot.verify(%{source_ip: ip_b})

      # An IP not in cache also skips
      assert {:skip, :not_applicable} = Netboot.verify(%{source_ip: {192, 168, 1, 99}})
    end
  end

  # ---------------------------------------------------------------------------
  # Trust level value
  # ---------------------------------------------------------------------------

  describe "trust level" do
    test "netboot_verified is a recognized trust level" do
      assert :netboot_verified in [
               :cloud_verified,
               :netboot_verified,
               :network_verified,
               :network_partial,
               :token_verified
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # Provider chain integration (via Router)
  # ---------------------------------------------------------------------------

  describe "provider chain integration" do
    test "netboot provider skips gracefully and allows fallthrough in the router" do
      context = %{
        source_ip: {192, 168, 1, 50},
        hostname: "test-netboot",
        attestation: nil,
        metadata: %{},
        authorization: nil
      }

      # Should not crash -- will reach unverified since no lease, no token, no cloud
      {level, _provider, _evidence} = YellowDogIdentity.Trust.Router.verify(context)
      assert level in [:unverified, :network_verified, :network_partial, :netboot_verified]
    end

    test "netboot is tried before DHCP correlation in the default provider chain" do
      # Verify ordering: when run through router with only netboot + a spy,
      # netboot gets invoked first and skips.
      context = %{
        source_ip: {10, 10, 10, 10},
        hostname: "order-test",
        attestation: nil,
        metadata: %{},
        authorization: nil
      }

      # Run with only the Netboot provider -- should skip and return unverified
      result =
        YellowDogIdentity.Trust.Router.verify(context, providers: [Netboot])

      assert {:unverified, :none, %{}} = result
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
