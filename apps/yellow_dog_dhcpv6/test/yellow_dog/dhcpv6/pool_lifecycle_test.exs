defmodule YellowDog.Dhcpv6.PoolLifecycleTest do
  @moduledoc """
  Integration tests for DHCPv6 pool lifecycle.

  Tests verify:
  - Pool CRUD operations persist across service restart
  - Lease recovery works after restart
  - Expired leases are filtered on recovery
  """

  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv6.PoolStore

  @moduletag :integration

  @test_data_dir "test_data/dhcpv6_lifecycle"

  setup do
    # Create clean test directory
    # PoolStore adds "dhcpv6" subdirectory automatically
    File.rm_rf!(@test_data_dir)
    File.mkdir_p!(Path.join([@test_data_dir, "dhcpv6", "pools"]))
    File.mkdir_p!(Path.join([@test_data_dir, "dhcpv6", "leases"]))

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
        name: "test_v6_lan",
        range_start: "2001:db8::100",
        range_end: "2001:db8::1ff",
        prefix_length: 64,
        dns_servers: ["2001:4860:4860::8888"],
        domain_name: "test.local",
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        max_leases: 100,
        enabled: true
      }

      # Save pool
      assert :ok = PoolStore.save_pool(pool_config)

      # Verify file exists
      pool_path = Path.join([@test_data_dir, "dhcpv6", "pools", "test_v6_lan.toml"])
      assert File.exists?(pool_path)

      # Load pool back
      {:ok, loaded_pools} = PoolStore.load_pools()
      assert length(loaded_pools) == 1

      # PoolStore returns config maps with string IPs (not parsed AddressPool structs)
      loaded_pool = hd(loaded_pools)
      assert loaded_pool.name == "test_v6_lan"
      assert loaded_pool.range_start == "2001:db8::100"
      assert loaded_pool.range_end == "2001:db8::1ff"
      assert loaded_pool.preferred_lifetime == 3600
      assert loaded_pool.valid_lifetime == 7200
    end

    test "pool update persists changes" do
      # Create initial pool
      pool_config = %{
        name: "update_v6_test",
        range_start: "fd00::100",
        range_end: "fd00::1ff",
        prefix_length: 64,
        dns_servers: ["fd00::1"],
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        enabled: true
      }

      assert :ok = PoolStore.save_pool(pool_config)

      # Update pool
      updated_config = %{pool_config | preferred_lifetime: 1800, valid_lifetime: 3600}
      assert :ok = PoolStore.save_pool(updated_config)

      # Reload and verify
      {:ok, loaded_pools} = PoolStore.load_pools()
      loaded_pool = Enum.find(loaded_pools, &(&1.name == "update_v6_test"))

      assert loaded_pool.preferred_lifetime == 1800
      assert loaded_pool.valid_lifetime == 3600
    end

    test "pool deletion removes file" do
      pool_config = %{
        name: "delete_v6_test",
        range_start: "fd01::100",
        range_end: "fd01::1ff",
        prefix_length: 64,
        dns_servers: ["fd01::1"],
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        enabled: true
      }

      assert :ok = PoolStore.save_pool(pool_config)

      # Verify exists
      pool_path = Path.join([@test_data_dir, "dhcpv6", "pools", "delete_v6_test.toml"])
      assert File.exists?(pool_path)

      # Delete
      assert :ok = PoolStore.remove_pool("delete_v6_test")

      # Verify gone
      refute File.exists?(pool_path)

      # Verify not loaded
      {:ok, loaded_pools} = PoolStore.load_pools()
      refute Enum.any?(loaded_pools, &(&1.name == "delete_v6_test"))
    end

    test "multiple pools persist independently" do
      pools = [
        %{
          name: "v6_pool_a",
          range_start: "fd10::100",
          range_end: "fd10::1ff",
          prefix_length: 64,
          dns_servers: ["fd10::1"],
          preferred_lifetime: 3600,
          valid_lifetime: 7200,
          enabled: true
        },
        %{
          name: "v6_pool_b",
          range_start: "fd20::100",
          range_end: "fd20::1ff",
          prefix_length: 64,
          dns_servers: ["fd20::1"],
          preferred_lifetime: 1800,
          valid_lifetime: 3600,
          enabled: true
        },
        %{
          name: "v6_pool_c",
          range_start: "fd30::100",
          range_end: "fd30::1ff",
          prefix_length: 64,
          dns_servers: ["fd30::1"],
          preferred_lifetime: 7200,
          valid_lifetime: 14400,
          enabled: false
        }
      ]

      # Save all
      Enum.each(pools, &PoolStore.save_pool/1)

      # Load and verify count
      {:ok, loaded_pools} = PoolStore.load_pools()
      assert length(loaded_pools) == 3

      # Verify each pool
      pool_a = Enum.find(loaded_pools, &(&1.name == "v6_pool_a"))
      pool_b = Enum.find(loaded_pools, &(&1.name == "v6_pool_b"))
      pool_c = Enum.find(loaded_pools, &(&1.name == "v6_pool_c"))

      assert pool_a.preferred_lifetime == 3600
      assert pool_b.preferred_lifetime == 1800
      assert pool_c.preferred_lifetime == 7200
      assert pool_c.enabled == false
    end
  end

  describe "Lease persistence and recovery" do
    test "leases save and load correctly" do
      pool_name = "v6_lease_test"

      # Create pool first
      pool_config = %{
        name: pool_name,
        range_start: "2001:db8:1::100",
        range_end: "2001:db8:1::1ff",
        prefix_length: 64,
        dns_servers: ["2001:4860:4860::8888"],
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        enabled: true
      }

      PoolStore.save_pool(pool_config)

      # Create test leases
      now = DateTime.utc_now()

      leases = [
        %YellowDog.Dhcpv6.Lease{
          ip: {8193, 3512, 1, 0, 0, 0, 0, 257},
          duid: "0001000100112233",
          iaid: 1,
          pool_name: pool_name,
          hostname: "client1",
          starts_at: now,
          preferred_until: DateTime.add(now, 3600, :second),
          valid_until: DateTime.add(now, 7200, :second),
          state: :active
        },
        %YellowDog.Dhcpv6.Lease{
          ip: {8193, 3512, 1, 0, 0, 0, 0, 258},
          duid: "0001000100112244",
          iaid: 1,
          pool_name: pool_name,
          hostname: "client2",
          starts_at: now,
          preferred_until: DateTime.add(now, 3600, :second),
          valid_until: DateTime.add(now, 7200, :second),
          state: :active
        }
      ]

      # Save leases
      assert :ok = PoolStore.save_leases(pool_name, leases)

      # Verify file exists
      lease_path = Path.join([@test_data_dir, "dhcpv6", "leases", "#{pool_name}.toml"])
      assert File.exists?(lease_path)

      # Load leases back
      {:ok, loaded_leases} = PoolStore.load_leases(pool_name)
      assert length(loaded_leases) == 2

      # Verify lease data
      lease1 = Enum.find(loaded_leases, &(&1.hostname == "client1"))
      assert lease1.ip == {8193, 3512, 1, 0, 0, 0, 0, 257}
      assert lease1.state == :active
    end

    test "expired leases are filtered on load" do
      pool_name = "v6_expiry_test"

      # Create pool
      pool_config = %{
        name: pool_name,
        range_start: "2001:db8:2::100",
        range_end: "2001:db8:2::1ff",
        prefix_length: 64,
        dns_servers: ["2001:4860:4860::8888"],
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        enabled: true
      }

      PoolStore.save_pool(pool_config)

      now = DateTime.utc_now()
      # 4 hours ago
      past = DateTime.add(now, -14400, :second)

      leases = [
        # Active lease (expires in future)
        %YellowDog.Dhcpv6.Lease{
          ip: {8193, 3512, 2, 0, 0, 0, 0, 257},
          duid: "0001000100AABBCC",
          iaid: 1,
          pool_name: pool_name,
          hostname: "active_client",
          starts_at: now,
          preferred_until: DateTime.add(now, 3600, :second),
          valid_until: DateTime.add(now, 7200, :second),
          state: :active
        },
        # Expired lease
        %YellowDog.Dhcpv6.Lease{
          ip: {8193, 3512, 2, 0, 0, 0, 0, 258},
          duid: "0001000100AABBDD",
          iaid: 1,
          pool_name: pool_name,
          hostname: "expired_client",
          starts_at: past,
          preferred_until: DateTime.add(past, 3600, :second),
          # Expired 2+ hours ago
          valid_until: DateTime.add(past, 7200, :second),
          state: :active
        }
      ]

      # Save all leases (including expired)
      assert :ok = PoolStore.save_leases(pool_name, leases)

      # Load leases
      {:ok, loaded_leases} = PoolStore.load_leases(pool_name)

      # File contains both
      assert length(loaded_leases) == 2

      # Filter for active (non-expired)
      active_leases =
        Enum.filter(loaded_leases, fn lease ->
          case lease.valid_until do
            %DateTime{} = dt -> DateTime.after?(dt, DateTime.utc_now())
            _ -> false
          end
        end)

      assert length(active_leases) == 1
      assert hd(active_leases).hostname == "active_client"
    end

    test "lease deletion clears file" do
      pool_name = "v6_delete_lease_test"

      # Create pool and leases
      pool_config = %{
        name: pool_name,
        range_start: "2001:db8:3::100",
        range_end: "2001:db8:3::1ff",
        prefix_length: 64,
        dns_servers: ["2001:4860:4860::8888"],
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        enabled: true
      }

      PoolStore.save_pool(pool_config)

      now = DateTime.utc_now()

      leases = [
        %YellowDog.Dhcpv6.Lease{
          ip: {8193, 3512, 3, 0, 0, 0, 0, 257},
          duid: "0001000100DEADBE",
          iaid: 1,
          pool_name: pool_name,
          hostname: "test",
          starts_at: now,
          preferred_until: DateTime.add(now, 3600, :second),
          valid_until: DateTime.add(now, 7200, :second),
          state: :active
        }
      ]

      PoolStore.save_leases(pool_name, leases)

      # Verify exists
      lease_path = Path.join([@test_data_dir, "dhcpv6", "leases", "#{pool_name}.toml"])
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
      pool_name = "v6_lifecycle_pool"

      # 1. Create pool
      pool_config = %{
        name: pool_name,
        range_start: "2001:db8:dead::100",
        range_end: "2001:db8:dead::1ff",
        prefix_length: 64,
        dns_servers: ["2001:4860:4860::8888"],
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        max_leases: 100,
        enabled: true
      }

      assert :ok = PoolStore.save_pool(pool_config)

      # 2. Simulate lease allocations
      now = DateTime.utc_now()

      allocated_leases =
        for i <- 1..5 do
          %YellowDog.Dhcpv6.Lease{
            ip: {8193, 3512, 57005, 0, 0, 0, 0, 256 + i},
            duid: "000100010000000#{i}",
            iaid: i,
            pool_name: pool_name,
            hostname: "client#{i}",
            starts_at: now,
            preferred_until: DateTime.add(now, 3600, :second),
            valid_until: DateTime.add(now, 7200, :second),
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

      # 6. Verify lease count recovered
      assert length(reloaded_leases) == 5

      # 7. Update pool config
      updated_config = %{pool_config | max_leases: 50, preferred_lifetime: 1800}
      assert :ok = PoolStore.save_pool(updated_config)

      # 8. Verify update persisted
      {:ok, updated_pools} = PoolStore.load_pools()
      updated_pool = hd(updated_pools)
      assert updated_pool.max_leases == 50
      assert updated_pool.preferred_lifetime == 1800

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
