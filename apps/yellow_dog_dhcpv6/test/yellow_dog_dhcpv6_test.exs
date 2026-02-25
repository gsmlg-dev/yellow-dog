defmodule YellowDog.Dhcpv6Test do
  @moduledoc """
  Tests for the YellowDog.Dhcpv6 public API module.

  Since the DHCPv6 server (LeaseManager) is not running in the test
  environment, these tests exercise the "offline" code paths — status
  reporting, pool queries via PoolStore, and module structure.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv6

  # ── Module structure ──────────────────────────────────────────────

  describe "module structure" do
    test "module is loadable" do
      assert {:module, Dhcpv6} = Code.ensure_loaded(Dhcpv6)
    end

    test "exports start_link/1" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :start_link, 1)
    end

    test "exports child_spec/1" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :child_spec, 1)
    end

    test "exports list_leases/0" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :list_leases, 0)
    end

    test "exports get_lease/2" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :get_lease, 2)
    end

    test "exports release_lease/2" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :release_lease, 2)
    end

    test "exports stats/0" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :stats, 0)
    end

    test "exports status/0" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :status, 0)
    end

    test "exports get_all_pool_stats/0" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :get_all_pool_stats, 0)
    end

    test "exports add_pool/2" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :add_pool, 2)
    end

    test "exports update_pool/3" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :update_pool, 3)
    end

    test "exports remove_pool/2" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :remove_pool, 2)
    end

    test "exports get_pools/0" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :get_pools, 0)
    end

    test "exports get_pool/1" do
      Code.ensure_loaded!(Dhcpv6)
      assert function_exported?(Dhcpv6, :get_pool, 1)
    end
  end

  # ── Status when server not running ────────────────────────────────

  describe "status/0 (server offline)" do
    test "returns not running when LeaseManager is not registered" do
      status = Dhcpv6.status()
      assert status.running == false
      assert status.lease_stats == %{}
    end

    test "status is a map" do
      assert is_map(Dhcpv6.status())
    end
  end

  # ── Pool queries when server not running ──────────────────────────

  describe "get_pools/0 (server offline)" do
    test "returns list (may be empty when no pool file exists)" do
      pools = Dhcpv6.get_pools()
      assert is_list(pools)
    end
  end

  describe "get_pool/1 (server offline)" do
    test "returns error for nonexistent pool" do
      assert {:error, :pool_not_found} = Dhcpv6.get_pool("nonexistent_pool_xyz")
    end
  end
end
