defmodule YellowDog.Dhcpv4.PoolStatsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv4.{AddressPool, LeaseStorage, PoolStats}

  setup do
    # Initialize Mnesia with ram_copies for testing
    LeaseStorage.init(storage_type: :ram_copies)

    # Clean up any existing leases
    leases = LeaseStorage.list()
    Enum.each(leases, fn lease -> LeaseStorage.delete(lease.mac_address) end)

    # Create test pool configuration
    {:ok, pool} =
      AddressPool.new(%{
        name: "test_pool",
        range_start: {192, 168, 1, 100},
        range_end: {192, 168, 1, 200},
        subnet_mask: {255, 255, 255, 0},
        gateway: {192, 168, 1, 1},
        dns_servers: [{8, 8, 8, 8}],
        domain_name: "test.local",
        lease_time: 3600,
        static_reservations: %{
          "AA:BB:CC:DD:EE:FF" => {192, 168, 1, 50}
        }
      })

    %{pool: pool}
  end

  describe "get_pool_stats/1" do
    test "returns basic pool statistics with no leases", %{pool: pool} do
      stats = PoolStats.get_pool_stats(pool)

      assert stats.pool_name == "test_pool"
      assert stats.total_addresses == 101
      assert stats.allocated_addresses == 0
      assert stats.available_addresses == 101
      assert stats.utilization_percent == 0.0
      assert stats.static_reservations == 1
      assert stats.leases_by_state == %{}
    end

    test "calculates correct utilization with active leases", %{pool: pool} do
      # Add some test leases
      now = System.system_time(:second)

      lease1 = %{
        mac_address: <<1, 2, 3, 4, 5, 6>>,
        ip_address: {192, 168, 1, 100},
        pool_name: "test_pool",
        state: :active,
        lease_time: 3600,
        expires_at: now + 3600,
        hostname: "host1",
        client_id: nil,
        created_at: now,
        updated_at: now
      }

      lease2 = %{
        mac_address: <<1, 2, 3, 4, 5, 7>>,
        ip_address: {192, 168, 1, 101},
        pool_name: "test_pool",
        state: :active,
        lease_time: 3600,
        expires_at: now + 3600,
        hostname: "host2",
        client_id: nil,
        created_at: now,
        updated_at: now
      }

      {:ok, _} = LeaseStorage.put(lease1)
      {:ok, _} = LeaseStorage.put(lease2)

      stats = PoolStats.get_pool_stats(pool)

      assert stats.allocated_addresses == 2
      assert stats.available_addresses == 99
      assert_in_delta stats.utilization_percent, 1.98, 0.01
      assert stats.leases_by_state[:active] == 2
    end

    test "counts leases by state correctly", %{pool: pool} do
      now = System.system_time(:second)

      # Add leases in different states
      active_lease = %{
        mac_address: <<1, 2, 3, 4, 5, 6>>,
        ip_address: {192, 168, 1, 100},
        pool_name: "test_pool",
        state: :active,
        lease_time: 3600,
        expires_at: now + 3600,
        hostname: nil,
        client_id: nil,
        created_at: now,
        updated_at: now
      }

      offered_lease = %{
        mac_address: <<1, 2, 3, 4, 5, 7>>,
        ip_address: {192, 168, 1, 101},
        pool_name: "test_pool",
        state: :offered,
        lease_time: 3600,
        expires_at: now + 3600,
        hostname: nil,
        client_id: nil,
        created_at: now,
        updated_at: now
      }

      released_lease = %{
        mac_address: <<1, 2, 3, 4, 5, 8>>,
        ip_address: {192, 168, 1, 102},
        pool_name: "test_pool",
        state: :released,
        lease_time: 3600,
        expires_at: now + 3600,
        hostname: nil,
        client_id: nil,
        created_at: now,
        updated_at: now
      }

      {:ok, _} = LeaseStorage.put(active_lease)
      {:ok, _} = LeaseStorage.put(offered_lease)
      {:ok, _} = LeaseStorage.put(released_lease)

      stats = PoolStats.get_pool_stats(pool)

      assert stats.leases_by_state[:active] == 1
      assert stats.leases_by_state[:offered] == 1
      assert stats.leases_by_state[:released] == 1
      # Only active + offered count as allocated
      assert stats.allocated_addresses == 2
    end
  end

  describe "get_all_pool_stats/1" do
    test "returns statistics for multiple pools" do
      {:ok, pool1} =
        AddressPool.new(%{
          name: "pool1",
          range_start: {192, 168, 1, 100},
          range_end: {192, 168, 1, 150},
          subnet_mask: {255, 255, 255, 0},
          gateway: {192, 168, 1, 1},
          dns_servers: [{8, 8, 8, 8}],
          lease_time: 3600
        })

      {:ok, pool2} =
        AddressPool.new(%{
          name: "pool2",
          range_start: {192, 168, 2, 100},
          range_end: {192, 168, 2, 200},
          subnet_mask: {255, 255, 255, 0},
          gateway: {192, 168, 2, 1},
          dns_servers: [{8, 8, 8, 8}],
          lease_time: 3600
        })

      stats = PoolStats.get_all_pool_stats([pool1, pool2])

      assert Map.has_key?(stats, "pool1")
      assert Map.has_key?(stats, "pool2")
      assert stats["pool1"].total_addresses == 51
      assert stats["pool2"].total_addresses == 101
    end
  end

  describe "get_global_utilization/1" do
    test "calculates global utilization across multiple pools" do
      {:ok, pool1} =
        AddressPool.new(%{
          name: "pool1",
          range_start: {192, 168, 1, 100},
          range_end: {192, 168, 1, 200},
          subnet_mask: {255, 255, 255, 0},
          gateway: {192, 168, 1, 1},
          dns_servers: [{8, 8, 8, 8}],
          lease_time: 3600
        })

      {:ok, pool2} =
        AddressPool.new(%{
          name: "pool2",
          range_start: {192, 168, 2, 100},
          range_end: {192, 168, 2, 200},
          subnet_mask: {255, 255, 255, 0},
          gateway: {192, 168, 2, 1},
          dns_servers: [{8, 8, 8, 8}],
          lease_time: 3600
        })

      # Add leases to pool1
      now = System.system_time(:second)

      lease1 = %{
        mac_address: <<1, 2, 3, 4, 5, 6>>,
        ip_address: {192, 168, 1, 100},
        pool_name: "pool1",
        state: :active,
        lease_time: 3600,
        expires_at: now + 3600,
        hostname: nil,
        client_id: nil,
        created_at: now,
        updated_at: now
      }

      {:ok, _} = LeaseStorage.put(lease1)

      global_stats = PoolStats.get_global_utilization([pool1, pool2])

      assert global_stats.total_pools == 2
      assert global_stats.total_addresses == 202
      assert global_stats.total_allocated == 1
      assert global_stats.total_available == 201
      assert_in_delta global_stats.global_utilization_percent, 0.50, 0.01
      assert Map.has_key?(global_stats.pool_stats, "pool1")
      assert Map.has_key?(global_stats.pool_stats, "pool2")
    end
  end

  describe "check_pool_utilization/2" do
    test "returns :ok when utilization is below threshold", %{pool: pool} do
      result = PoolStats.check_pool_utilization(pool, 90.0)
      assert result == :ok
    end

    test "returns warning when utilization exceeds threshold", %{pool: pool} do
      # Fill up the pool to near capacity
      now = System.system_time(:second)

      # Allocate 91 out of 101 addresses
      for i <- 100..190 do
        mac = <<1, 2, 3, 4, div(i, 256), rem(i, 256)>>

        lease = %{
          mac_address: mac,
          ip_address: {192, 168, 1, i},
          pool_name: "test_pool",
          state: :active,
          lease_time: 3600,
          expires_at: now + 3600,
          hostname: nil,
          client_id: nil,
          created_at: now,
          updated_at: now
        }

        {:ok, _} = LeaseStorage.put(lease)
      end

      result = PoolStats.check_pool_utilization(pool, 90.0)
      assert {:warning, percent} = result
      assert percent > 90.0
    end
  end

  describe "get_lease_distribution/1" do
    test "classifies leases by expiration and age", %{pool: pool} do
      now = System.system_time(:second)

      # Lease expiring soon (30 minutes remaining)
      expiring_soon = %{
        mac_address: <<1, 2, 3, 4, 5, 6>>,
        ip_address: {192, 168, 1, 100},
        pool_name: "test_pool",
        state: :active,
        lease_time: 3600,
        expires_at: now + 1800,
        hostname: nil,
        client_id: nil,
        created_at: now - 1800,
        updated_at: now
      }

      # Lease expiring later (2 hours remaining)
      expiring_later = %{
        mac_address: <<1, 2, 3, 4, 5, 7>>,
        ip_address: {192, 168, 1, 101},
        pool_name: "test_pool",
        state: :active,
        lease_time: 7200,
        expires_at: now + 7200,
        hostname: nil,
        client_id: nil,
        created_at: now - 100,
        updated_at: now
      }

      {:ok, _} = LeaseStorage.put(expiring_soon)
      {:ok, _} = LeaseStorage.put(expiring_later)

      distribution = PoolStats.get_lease_distribution(pool)

      assert distribution.total_active_leases == 2
      assert distribution.expiring_soon == 1
      assert distribution.expiring_later == 1
    end
  end

  describe "format_pool_stats/1" do
    test "formats pool statistics as string", %{pool: pool} do
      stats = PoolStats.get_pool_stats(pool)
      formatted = PoolStats.format_pool_stats(stats)

      assert is_binary(formatted)
      assert formatted =~ "Pool: test_pool"
      assert formatted =~ "Total Addresses: 101"
      assert formatted =~ "Utilization: 0.0%"
      assert formatted =~ "Static Reservations: 1"
    end
  end
end
