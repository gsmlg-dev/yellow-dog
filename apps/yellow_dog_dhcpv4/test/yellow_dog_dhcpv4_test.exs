defmodule YellowDog.Dhcpv4Test do
  @moduledoc """
  Tests for the YellowDog.Dhcpv4 public API module.

  Since the DHCPv4 server (LeaseManager) is not running in the test
  environment, these tests exercise the "offline" code paths — status
  reporting, pool queries via PoolStore, and module structure.
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv4

  # ── Module structure ──────────────────────────────────────────────

  describe "module structure" do
    test "module is loadable" do
      assert {:module, Dhcpv4} = Code.ensure_loaded(Dhcpv4)
    end

    test "exports start_link/1" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :start_link, 1)
    end

    test "exports child_spec/1" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :child_spec, 1)
    end

    test "exports list_leases/0" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :list_leases, 0)
    end

    test "exports get_lease/1" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :get_lease, 1)
    end

    test "exports release_lease/1" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :release_lease, 1)
    end

    test "exports stats/0" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :stats, 0)
    end

    test "exports status/0" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :status, 0)
    end

    test "exports get_pool_stats/1" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :get_pool_stats, 1)
    end

    test "exports get_all_pool_stats/0" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :get_all_pool_stats, 0)
    end

    test "exports add_pool/2" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :add_pool, 2)
    end

    test "exports update_pool/3" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :update_pool, 3)
    end

    test "exports remove_pool/2" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :remove_pool, 2)
    end

    test "exports get_pools/0" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :get_pools, 0)
    end

    test "exports get_pool/1" do
      Code.ensure_loaded!(Dhcpv4)
      assert function_exported?(Dhcpv4, :get_pool, 1)
    end
  end

  # ── Status when server not running ────────────────────────────────

  describe "status/0 (server offline)" do
    test "returns not running when LeaseManager is not registered" do
      status = Dhcpv4.status()
      assert status.running == false
      assert status.lease_stats == %{}
    end

    test "status is a map" do
      assert is_map(Dhcpv4.status())
    end
  end

  # ── Pool queries when server not running ──────────────────────────

  describe "get_pools/0 (server offline)" do
    test "returns list (may be empty when no pool file exists)" do
      pools = Dhcpv4.get_pools()
      assert is_list(pools)
    end
  end

  describe "get_pool/1 (server offline)" do
    test "returns error for nonexistent pool" do
      assert {:error, :pool_not_found} = Dhcpv4.get_pool("nonexistent_pool_xyz")
    end
  end
end
