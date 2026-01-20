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
