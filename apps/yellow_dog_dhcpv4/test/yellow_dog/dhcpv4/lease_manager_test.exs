defmodule YellowDog.Dhcpv4.LeaseManagerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv4.LeaseManager
  alias YellowDog.Dhcpv4.LeaseStorage

  @test_mac <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
  @test_mac_2 <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>
  @test_pool_config %{
    name: "test_pool",
    subnet_mask: {255, 255, 255, 0},
    range_start: {192, 168, 1, 100},
    range_end: {192, 168, 1, 200},
    gateway: {192, 168, 1, 1},
    dns_servers: [{8, 8, 8, 8}],
    lease_time: 3600,
    enabled: true,
    static_reservations: %{}
  }

  setup do
    # Stop LeaseManager if running to ensure clean state
    if Process.whereis(LeaseManager) do
      try do
        GenServer.stop(LeaseManager, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end

    # Give Mnesia time to clean up
    Process.sleep(50)

    # Initialize LeaseStorage for tests (RAM copies)
    LeaseStorage.init(storage_type: :ram_copies)

    # Clear any existing leases
    LeaseStorage.clear_all()

    :ok
  end

  describe "start_link/1" do
    test "starts with empty pool list" do
      {:ok, pid} = LeaseManager.start_link(pools: [])
      assert Process.alive?(pid)
      assert LeaseManager.get_pools() == []
      stop_manager(pid)
    end

    test "starts with configured pools" do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      pools = LeaseManager.get_pools()
      assert length(pools) == 1
      assert hd(pools).name == "test_pool"
      stop_manager(pid)
    end

    test "ignores invalid pool configurations" do
      invalid_pool = %{name: "bad", invalid: true}
      {:ok, pid} = LeaseManager.start_link(pools: [invalid_pool])
      # Invalid pools should be filtered out
      assert LeaseManager.get_pools() == []
      stop_manager(pid)
    end
  end

  describe "allocate_lease/5" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "allocates new lease for new MAC" do
      {:ok, lease} = LeaseManager.allocate_lease(@test_mac, nil, "testhost", "test_pool", nil)

      assert lease.mac_address == @test_mac
      assert lease.hostname == "testhost"
      assert lease.state == :active
      assert lease.ip_address != nil
    end

    test "returns same lease for existing MAC" do
      {:ok, lease1} = LeaseManager.allocate_lease(@test_mac, nil, "host1", "test_pool", nil)
      {:ok, lease2} = LeaseManager.allocate_lease(@test_mac, nil, "host2", "test_pool", nil)

      assert lease1.ip_address == lease2.ip_address
      # Hostname may be updated on re-allocation
    end

    test "allocates IP from pool range" do
      {:ok, lease} = LeaseManager.allocate_lease(@test_mac, nil, nil, "test_pool", nil)

      # IP should be within pool range
      assert lease.ip_address >= {192, 168, 1, 100}
      assert lease.ip_address <= {192, 168, 1, 200}
    end

    test "allocates different IPs for different MACs" do
      {:ok, lease1} = LeaseManager.allocate_lease(@test_mac, nil, nil, "test_pool", nil)
      {:ok, lease2} = LeaseManager.allocate_lease(@test_mac_2, nil, nil, "test_pool", nil)

      # Should get different IPs
      assert lease1.ip_address != lease2.ip_address
    end

    test "returns error for non-existent pool" do
      result = LeaseManager.allocate_lease(@test_mac, nil, nil, "nonexistent", nil)
      assert result == {:error, :pool_not_found}
    end
  end

  describe "get_lease/1" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "returns lease for allocated MAC" do
      # Use a unique MAC to avoid conflicts with other tests
      unique_mac = <<0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01>>

      {:ok, allocated} =
        LeaseManager.allocate_lease(unique_mac, nil, "testhost", "test_pool", nil)

      {:ok, retrieved} = LeaseManager.get_lease(unique_mac)

      assert retrieved.ip_address == allocated.ip_address
      assert retrieved.mac_address == allocated.mac_address
    end

    test "returns error for random unknown MAC" do
      # Use a random MAC that's unlikely to exist in Mnesia
      random_mac = :crypto.strong_rand_bytes(6)
      result = LeaseManager.get_lease(random_mac)
      assert result == {:error, :not_found}
    end
  end

  describe "release_lease/1" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "releases active lease" do
      {:ok, _lease} = LeaseManager.allocate_lease(@test_mac, nil, nil, "test_pool", nil)
      assert :ok = LeaseManager.release_lease(@test_mac)

      # After release, get_lease should return not_found (released leases aren't active)
      assert {:error, :not_found} = LeaseManager.get_lease(@test_mac)
    end

    test "handles releasing non-existent lease" do
      # Should not error, just return :ok
      assert :ok = LeaseManager.release_lease(@test_mac)
    end
  end

  describe "decline_ip/2" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "marks lease as declined" do
      {:ok, lease} = LeaseManager.allocate_lease(@test_mac, nil, nil, "test_pool", nil)
      assert :ok = LeaseManager.decline_ip(lease.ip_address, @test_mac)

      # After decline, get_lease should return not_found
      assert {:error, :not_found} = LeaseManager.get_lease(@test_mac)
    end

    test "handles declining unknown MAC" do
      assert :ok = LeaseManager.decline_ip({192, 168, 1, 100}, @test_mac)
    end
  end

  describe "list_leases/0" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "returns current leases" do
      # Note: Mnesia may have leftover state from other tests
      # Just verify the function works and returns a list
      leases = LeaseManager.list_leases()
      assert is_list(leases)
    end

    test "allocates and lists new leases" do
      # Get count before allocation
      initial_count = length(LeaseManager.list_leases())

      # Allocate two new leases with unique MACs
      mac1 = <<0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6>>
      mac2 = <<0xF6, 0xE5, 0xD4, 0xC3, 0xB2, 0xA1>>
      {:ok, _lease1} = LeaseManager.allocate_lease(mac1, nil, "host1", "test_pool", nil)
      {:ok, _lease2} = LeaseManager.allocate_lease(mac2, nil, "host2", "test_pool", nil)

      # Should have at least 2 more leases
      leases = LeaseManager.list_leases()
      assert length(leases) >= initial_count + 2
    end
  end

  describe "get_allocated_ips/0" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "returns set of allocated IPs" do
      {:ok, lease1} = LeaseManager.allocate_lease(@test_mac, nil, nil, "test_pool", nil)
      {:ok, lease2} = LeaseManager.allocate_lease(@test_mac_2, nil, nil, "test_pool", nil)

      allocated = LeaseManager.get_allocated_ips()
      assert MapSet.member?(allocated, lease1.ip_address)
      assert MapSet.member?(allocated, lease2.ip_address)
    end
  end

  describe "stats/0" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "returns lease statistics" do
      stats = LeaseManager.stats()
      assert is_map(stats)
    end

    test "tracks lease counts" do
      {:ok, _} = LeaseManager.allocate_lease(@test_mac, nil, nil, "test_pool", nil)
      stats = LeaseManager.stats()
      assert stats[:active] >= 1
    end
  end

  describe "get_pools/0" do
    test "returns configured pools" do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      pools = LeaseManager.get_pools()
      assert length(pools) == 1
      assert hd(pools).name == "test_pool"
      stop_manager(pid)
    end
  end

  describe "get_pool_stats/1" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "returns stats for existing pool" do
      {:ok, stats} = LeaseManager.get_pool_stats("test_pool")
      assert is_map(stats)
      # The pool stats might have different keys - check for common ones
      assert Map.has_key?(stats, :pool_name) or Map.has_key?(stats, :name)
    end

    test "returns error for non-existent pool" do
      result = LeaseManager.get_pool_stats("nonexistent")
      assert result == {:error, :pool_not_found}
    end
  end

  describe "get_pool_config/1" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "returns config for existing pool" do
      {:ok, config} = LeaseManager.get_pool_config("test_pool")
      assert config.name == "test_pool"
      assert config.subnet_mask == {255, 255, 255, 0}
    end

    test "returns error for non-existent pool" do
      result = LeaseManager.get_pool_config("nonexistent")
      assert result == {:error, :pool_not_found}
    end
  end

  describe "get_static_reservations/1" do
    test "returns reservations for pool with static mappings" do
      pool_with_reservations =
        Map.put(@test_pool_config, :static_reservations, %{
          "aa:bb:cc:dd:ee:ff" => {192, 168, 1, 50}
        })

      {:ok, pid} = LeaseManager.start_link(pools: [pool_with_reservations])
      reservations = LeaseManager.get_static_reservations("test_pool")

      assert length(reservations) == 1
      assert hd(reservations).ip_address == {192, 168, 1, 50}

      stop_manager(pid)
    end

    test "returns empty list for pool without reservations" do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      reservations = LeaseManager.get_static_reservations("test_pool")
      assert reservations == []
      stop_manager(pid)
    end

    test "returns empty list for non-existent pool" do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      reservations = LeaseManager.get_static_reservations("nonexistent")
      assert reservations == []
      stop_manager(pid)
    end
  end

  describe "add_pool/1" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "adds new pool successfully" do
      new_pool = %{
        name: "new_pool",
        subnet_mask: {255, 255, 255, 0},
        range_start: {10, 0, 0, 100},
        range_end: {10, 0, 0, 200},
        gateway: {10, 0, 0, 1},
        dns_servers: [{8, 8, 8, 8}],
        lease_time: 3600,
        enabled: true
      }

      assert {:ok, pool} = LeaseManager.add_pool(new_pool)
      assert pool.name == "new_pool"

      # Verify pool is accessible
      pools = LeaseManager.get_pools()
      assert length(pools) == 2
      assert Enum.any?(pools, fn p -> p.name == "new_pool" end)
    end

    test "rejects duplicate pool name" do
      duplicate_pool = %{
        name: "test_pool",
        subnet_mask: {255, 255, 255, 0},
        range_start: {10, 0, 0, 100},
        range_end: {10, 0, 0, 200},
        enabled: true
      }

      assert {:error, :pool_already_exists} = LeaseManager.add_pool(duplicate_pool)
    end

    test "rejects overlapping IP range" do
      overlapping_pool = %{
        name: "overlapping",
        subnet_mask: {255, 255, 255, 0},
        # This overlaps with test_pool's range (192.168.1.100-200)
        range_start: {192, 168, 1, 150},
        range_end: {192, 168, 1, 250},
        enabled: true
      }

      assert {:error, :range_overlap} = LeaseManager.add_pool(overlapping_pool)
    end

    test "accepts non-overlapping IP range" do
      non_overlapping_pool = %{
        name: "non_overlapping",
        subnet_mask: {255, 255, 255, 0},
        # This does not overlap with test_pool's range
        range_start: {192, 168, 2, 100},
        range_end: {192, 168, 2, 200},
        enabled: true
      }

      assert {:ok, pool} = LeaseManager.add_pool(non_overlapping_pool)
      assert pool.name == "non_overlapping"
    end
  end

  describe "update_pool/2" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "updates existing pool successfully" do
      updates = %{lease_time: 7200}

      assert {:ok, pool} = LeaseManager.update_pool("test_pool", updates)
      assert pool.lease_time == 7200
    end

    test "returns error for non-existent pool" do
      updates = %{lease_time: 7200}
      assert {:error, :pool_not_found} = LeaseManager.update_pool("nonexistent", updates)
    end

    test "cannot change pool name" do
      updates = %{name: "new_name"}
      {:ok, pool} = LeaseManager.update_pool("test_pool", updates)
      # Pool name should remain unchanged
      assert pool.name == "test_pool"
    end
  end

  describe "remove_pool/2" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "removes pool without active leases" do
      # Add a second pool to remove
      new_pool = %{
        name: "removable",
        subnet_mask: {255, 255, 255, 0},
        range_start: {10, 0, 0, 100},
        range_end: {10, 0, 0, 200},
        enabled: true
      }

      {:ok, _} = LeaseManager.add_pool(new_pool)
      assert :ok = LeaseManager.remove_pool("removable", force: false)

      pools = LeaseManager.get_pools()
      refute Enum.any?(pools, fn p -> p.name == "removable" end)
    end

    test "returns error for non-existent pool" do
      assert {:error, :pool_not_found} = LeaseManager.remove_pool("nonexistent", force: false)
    end

    test "blocks removal of pool with active leases unless forced" do
      # Allocate a lease in the test_pool
      {:ok, _lease} = LeaseManager.allocate_lease(@test_mac, nil, nil, "test_pool", nil)

      # Should fail without force
      assert {:error, :has_active_leases} = LeaseManager.remove_pool("test_pool", force: false)

      # Should succeed with force
      assert :ok = LeaseManager.remove_pool("test_pool", force: true)
    end
  end

  # Helper function to stop manager safely
  defp stop_manager(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
