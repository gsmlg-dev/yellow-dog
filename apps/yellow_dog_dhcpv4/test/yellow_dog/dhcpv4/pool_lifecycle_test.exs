defmodule YellowDog.Dhcpv4.PoolLifecycleTest do
  @moduledoc """
  Integration tests for DHCPv4 pool lifecycle.

  Tests verify:
  - Pool CRUD operations persist across service restart
  - Lease recovery works after restart
  - Expired leases are filtered on recovery
  """

  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv4.{LeaseManager, PoolStore, LeaseStorage}

  @moduletag :integration

  @test_data_dir "test_data/dhcpv4_lifecycle"

  setup do
    # Create clean test directory
    # PoolStore adds "dhcpv4" subdirectory automatically
    File.rm_rf!(@test_data_dir)
    File.mkdir_p!(Path.join([@test_data_dir, "dhcpv4", "pools"]))
    File.mkdir_p!(Path.join([@test_data_dir, "dhcpv4", "leases"]))

    # Set data directory for this test
    Application.put_env(:yellow_dog, :data_dir, @test_data_dir)

    on_exit(fn ->
      # Cleanup
      File.rm_rf!(@test_data_dir)
      Application.delete_env(:yellow_dog, :data_dir)
    end)

    :ok
  end

  describe "Pool CRUD persistence" do
    test "pool created via PoolStore persists and loads correctly" do
      pool_config = %{
        name: "test_lan",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200",
        subnet_mask: "255.255.255.0",
        gateway: "192.168.1.1",
        dns_servers: ["8.8.8.8", "8.8.4.4"],
        domain_name: "test.local",
        lease_time: 3600,
        max_leases: 100,
        enabled: true
      }

      # Save pool
      assert :ok = PoolStore.save_pool(pool_config)

      # Verify file exists
      pool_path = Path.join([@test_data_dir, "dhcpv4", "pools", "test_lan.toml"])
      assert File.exists?(pool_path)

      # Load pool back
      {:ok, loaded_pools} = PoolStore.load_pools()
      assert length(loaded_pools) == 1

      # PoolStore returns config maps with string IPs (not parsed AddressPool structs)
      loaded_pool = hd(loaded_pools)
      assert loaded_pool.name == "test_lan"
      assert loaded_pool.range_start == "192.168.1.100"
      assert loaded_pool.range_end == "192.168.1.200"
      assert loaded_pool.gateway == "192.168.1.1"
      assert loaded_pool.dns_servers == ["8.8.8.8", "8.8.4.4"]
      assert loaded_pool.domain_name == "test.local"
      assert loaded_pool.lease_time == 3600
    end

    test "pool update persists changes" do
      # Create initial pool
      pool_config = %{
        name: "update_test",
        range_start: "10.0.0.100",
        range_end: "10.0.0.200",
        subnet_mask: "255.255.255.0",
        gateway: "10.0.0.1",
        dns_servers: ["8.8.8.8"],
        lease_time: 3600,
        enabled: true
      }

      assert :ok = PoolStore.save_pool(pool_config)

      # Update pool
      updated_config = %{pool_config | lease_time: 7200, dns_servers: ["1.1.1.1"]}
      assert :ok = PoolStore.save_pool(updated_config)

      # Reload and verify
      {:ok, loaded_pools} = PoolStore.load_pools()
      loaded_pool = Enum.find(loaded_pools, &(&1.name == "update_test"))

      assert loaded_pool.lease_time == 7200
      assert loaded_pool.dns_servers == ["1.1.1.1"]
    end

    test "pool deletion removes file" do
      pool_config = %{
        name: "delete_test",
        range_start: "172.16.0.100",
        range_end: "172.16.0.200",
        subnet_mask: "255.255.255.0",
        gateway: "172.16.0.1",
        dns_servers: ["8.8.8.8"],
        lease_time: 3600,
        enabled: true
      }

      assert :ok = PoolStore.save_pool(pool_config)

      # Verify exists
      pool_path = Path.join([@test_data_dir, "dhcpv4", "pools", "delete_test.toml"])
      assert File.exists?(pool_path)

      # Delete
      assert :ok = PoolStore.remove_pool("delete_test")

      # Verify gone
      refute File.exists?(pool_path)

      # Verify not loaded
      {:ok, loaded_pools} = PoolStore.load_pools()
      refute Enum.any?(loaded_pools, &(&1.name == "delete_test"))
    end

    test "multiple pools persist independently" do
      pools = [
        %{name: "pool_a", range_start: "10.1.0.100", range_end: "10.1.0.200",
          subnet_mask: "255.255.255.0", gateway: "10.1.0.1", dns_servers: ["8.8.8.8"],
          lease_time: 3600, enabled: true},
        %{name: "pool_b", range_start: "10.2.0.100", range_end: "10.2.0.200",
          subnet_mask: "255.255.255.0", gateway: "10.2.0.1", dns_servers: ["8.8.8.8"],
          lease_time: 7200, enabled: true},
        %{name: "pool_c", range_start: "10.3.0.100", range_end: "10.3.0.200",
          subnet_mask: "255.255.255.0", gateway: "10.3.0.1", dns_servers: ["8.8.8.8"],
          lease_time: 1800, enabled: false}
      ]

      # Save all
      Enum.each(pools, &PoolStore.save_pool/1)

      # Load and verify count
      {:ok, loaded_pools} = PoolStore.load_pools()
      assert length(loaded_pools) == 3

      # Verify each pool
      pool_a = Enum.find(loaded_pools, &(&1.name == "pool_a"))
      pool_b = Enum.find(loaded_pools, &(&1.name == "pool_b"))
      pool_c = Enum.find(loaded_pools, &(&1.name == "pool_c"))

      assert pool_a.lease_time == 3600
      assert pool_b.lease_time == 7200
      assert pool_c.lease_time == 1800
      assert pool_c.enabled == false
    end
  end

  describe "Lease persistence and recovery" do
    test "leases save and load correctly" do
      pool_name = "lease_test"

      # Create pool first
      pool_config = %{
        name: pool_name,
        range_start: "192.168.10.100",
        range_end: "192.168.10.200",
        subnet_mask: "255.255.255.0",
        gateway: "192.168.10.1",
        dns_servers: ["8.8.8.8"],
        lease_time: 3600,
        enabled: true
      }
      PoolStore.save_pool(pool_config)

      # Create test leases
      now = DateTime.utc_now()
      leases = [
        %YellowDog.Dhcpv4.Lease{
          ip: {192, 168, 10, 101},
          mac: <<0x00, 0x11, 0x22, 0x33, 0x44, 0x55>>,
          pool_name: pool_name,
          hostname: "client1",
          starts_at: now,
          expires_at: DateTime.add(now, 3600, :second),
          state: :active
        },
        %YellowDog.Dhcpv4.Lease{
          ip: {192, 168, 10, 102},
          mac: <<0x00, 0x11, 0x22, 0x33, 0x44, 0x66>>,
          pool_name: pool_name,
          hostname: "client2",
          starts_at: now,
          expires_at: DateTime.add(now, 3600, :second),
          state: :active
        }
      ]

      # Save leases
      assert :ok = PoolStore.save_leases(pool_name, leases)

      # Verify file exists
      lease_path = Path.join([@test_data_dir, "dhcpv4", "leases", "#{pool_name}.toml"])
      assert File.exists?(lease_path)

      # Load leases back
      {:ok, loaded_leases} = PoolStore.load_leases(pool_name)
      assert length(loaded_leases) == 2

      # Verify lease data
      lease1 = Enum.find(loaded_leases, &(&1.hostname == "client1"))
      assert lease1.ip == {192, 168, 10, 101}
      assert lease1.state == :active
    end

    test "expired leases are filtered on load" do
      pool_name = "expiry_test"

      # Create pool
      pool_config = %{
        name: pool_name,
        range_start: "192.168.20.100",
        range_end: "192.168.20.200",
        subnet_mask: "255.255.255.0",
        gateway: "192.168.20.1",
        dns_servers: ["8.8.8.8"],
        lease_time: 3600,
        enabled: true
      }
      PoolStore.save_pool(pool_config)

      now = DateTime.utc_now()
      past = DateTime.add(now, -7200, :second)  # 2 hours ago

      leases = [
        # Active lease (expires in future)
        %YellowDog.Dhcpv4.Lease{
          ip: {192, 168, 20, 101},
          mac: <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x01>>,
          pool_name: pool_name,
          hostname: "active_client",
          starts_at: now,
          expires_at: DateTime.add(now, 3600, :second),
          state: :active
        },
        # Expired lease
        %YellowDog.Dhcpv4.Lease{
          ip: {192, 168, 20, 102},
          mac: <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x02>>,
          pool_name: pool_name,
          hostname: "expired_client",
          starts_at: past,
          expires_at: DateTime.add(past, 3600, :second),  # Expired 1 hour ago
          state: :active
        }
      ]

      # Save all leases (including expired)
      assert :ok = PoolStore.save_leases(pool_name, leases)

      # Load leases - expired should still be in file but marked
      {:ok, loaded_leases} = PoolStore.load_leases(pool_name)

      # File contains both
      assert length(loaded_leases) == 2

      # But filtering for active shows only non-expired
      active_leases = Enum.filter(loaded_leases, fn lease ->
        case lease.expires_at do
          %DateTime{} = dt -> DateTime.compare(dt, DateTime.utc_now()) == :gt
          unix when is_integer(unix) -> unix > System.system_time(:second)
          _ -> false
        end
      end)

      assert length(active_leases) == 1
      assert hd(active_leases).hostname == "active_client"
    end

    test "lease deletion clears file" do
      pool_name = "delete_lease_test"

      # Create pool and leases
      pool_config = %{
        name: pool_name,
        range_start: "192.168.30.100",
        range_end: "192.168.30.200",
        subnet_mask: "255.255.255.0",
        gateway: "192.168.30.1",
        dns_servers: ["8.8.8.8"],
        lease_time: 3600,
        enabled: true
      }
      PoolStore.save_pool(pool_config)

      now = DateTime.utc_now()
      leases = [
        %YellowDog.Dhcpv4.Lease{
          ip: {192, 168, 30, 101},
          mac: <<0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01>>,
          pool_name: pool_name,
          hostname: "test",
          starts_at: now,
          expires_at: DateTime.add(now, 3600, :second),
          state: :active
        }
      ]
      PoolStore.save_leases(pool_name, leases)

      # Verify exists
      lease_path = Path.join([@test_data_dir, "dhcpv4", "leases", "#{pool_name}.toml"])
      assert File.exists?(lease_path)

      # Delete leases
      assert :ok = PoolStore.delete_leases(pool_name)

      # File should be deleted
      refute File.exists?(lease_path)

      # Load returns empty
      {:ok, loaded} = PoolStore.load_leases(pool_name)
      assert loaded == []
    end
  end

  describe "Full lifecycle simulation" do
    test "complete pool and lease lifecycle" do
      pool_name = "lifecycle_pool"

      # 1. Create pool
      pool_config = %{
        name: pool_name,
        range_start: "10.100.0.100",
        range_end: "10.100.0.200",
        subnet_mask: "255.255.255.0",
        gateway: "10.100.0.1",
        dns_servers: ["8.8.8.8"],
        lease_time: 3600,
        max_leases: 100,
        enabled: true
      }
      assert :ok = PoolStore.save_pool(pool_config)

      # 2. Simulate lease allocations
      now = DateTime.utc_now()
      allocated_leases = for i <- 1..5 do
        %YellowDog.Dhcpv4.Lease{
          ip: {10, 100, 0, 100 + i},
          mac: <<0x00, 0x00, 0x00, 0x00, 0x00, i>>,
          pool_name: pool_name,
          hostname: "client#{i}",
          starts_at: now,
          expires_at: DateTime.add(now, 3600, :second),
          state: :active
        }
      end

      # 3. Save leases (simulating periodic flush)
      assert :ok = PoolStore.save_leases(pool_name, allocated_leases)

      # 4. Simulate service restart - reload everything
      {:ok, reloaded_pools} = PoolStore.load_pools()
      {:ok, reloaded_leases} = PoolStore.load_leases(pool_name)

      # 5. Verify state recovered
      assert length(reloaded_pools) == 1
      assert length(reloaded_leases) == 5

      pool = hd(reloaded_pools)
      assert pool.name == pool_name
      assert pool.max_leases == 100

      # 6. Verify lease IPs recovered
      recovered_ips = Enum.map(reloaded_leases, & &1.ip) |> MapSet.new()
      expected_ips = for i <- 1..5, do: {10, 100, 0, 100 + i}
      assert MapSet.equal?(recovered_ips, MapSet.new(expected_ips))

      # 7. Update pool config
      updated_config = %{pool_config | max_leases: 50, lease_time: 7200}
      assert :ok = PoolStore.save_pool(updated_config)

      # 8. Verify update persisted
      {:ok, updated_pools} = PoolStore.load_pools()
      updated_pool = hd(updated_pools)
      assert updated_pool.max_leases == 50
      assert updated_pool.lease_time == 7200

      # 9. Cleanup - remove pool and leases
      PoolStore.delete_leases(pool_name)
      PoolStore.remove_pool(pool_name)

      # 10. Verify cleanup
      {:ok, final_pools} = PoolStore.load_pools()
      {:ok, final_leases} = PoolStore.load_leases(pool_name)
      assert final_pools == []
      assert final_leases == []
    end
  end
end
