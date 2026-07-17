defmodule YellowDog.Dhcpv6.LeaseManagerTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv6.LeaseManager
  alias YellowDog.Dhcpv6.LeaseStorage

  # Test DUIDs (DHCP Unique Identifiers)
  @test_duid <<0x00, 0x01, 0x00, 0x01, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
  @test_duid_2 <<0x00, 0x01, 0x00, 0x01, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>
  @test_iaid 1
  @test_iaid_2 2

  # Test pool configuration with IPv6 addresses
  @test_pool_config %{
    name: "test_pool",
    range_start: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0100},
    range_end: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x01FF},
    dns_servers: [{0x2001, 0x4860, 0x4860, 0x0000, 0x0000, 0x0000, 0x0000, 0x8888}],
    domain_name: "test.local",
    preferred_lifetime: 3600,
    valid_lifetime: 7200,
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

    # Use a temporary data directory so PoolStore doesn't load real pools
    tmp_dir = Path.join(System.tmp_dir!(), "dhcpv6_lease_mgr_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)
    original_data_dir = Application.get_env(:yellow_dog, :data_dir)
    Application.put_env(:yellow_dog, :data_dir, tmp_dir)

    # Give Mnesia time to clean up
    Process.sleep(50)

    # Initialize LeaseStorage for tests (RAM copies)
    LeaseStorage.init(storage_type: :ram_copies)

    # Clear any existing leases
    LeaseStorage.clear_all()

    on_exit(fn ->
      if original_data_dir do
        Application.put_env(:yellow_dog, :data_dir, original_data_dir)
      else
        Application.delete_env(:yellow_dog, :data_dir)
      end

      File.rm_rf(tmp_dir)
    end)

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

    test "accepts multiple valid pools" do
      pool2 = %{
        @test_pool_config
        | name: "test_pool_2",
          range_start: {0x2001, 0x0DB8, 0x0000, 0x0001, 0x0000, 0x0000, 0x0000, 0x0100},
          range_end: {0x2001, 0x0DB8, 0x0000, 0x0001, 0x0000, 0x0000, 0x0000, 0x01FF}
      }

      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config, pool2])
      pools = LeaseManager.get_pools()
      assert length(pools) == 2
      stop_manager(pid)
    end
  end

  describe "allocate_lease/4" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "allocates new lease for new DUID" do
      {:ok, lease} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")

      assert lease.duid == @test_duid
      assert lease.iaid == @test_iaid
      assert lease.state == :active
      assert lease.ip != nil or lease.ip_address != nil
    end

    test "returns same lease for existing DUID/IAID combination" do
      {:ok, lease1} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")
      {:ok, lease2} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")

      # Should get same IP address (renewed lease)
      ip1 = lease1.ip || lease1.ip_address
      ip2 = lease2.ip || lease2.ip_address
      assert ip1 == ip2
    end

    test "allocates different IPs for different DUIDs" do
      {:ok, lease1} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")
      {:ok, lease2} = LeaseManager.allocate_lease(@test_duid_2, @test_iaid, nil, "test_pool")

      ip1 = lease1.ip || lease1.ip_address
      ip2 = lease2.ip || lease2.ip_address
      assert ip1 != ip2
    end

    test "allocates different IPs for same DUID with different IAIDs" do
      {:ok, lease1} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")
      {:ok, lease2} = LeaseManager.allocate_lease(@test_duid, @test_iaid_2, nil, "test_pool")

      ip1 = lease1.ip || lease1.ip_address
      ip2 = lease2.ip || lease2.ip_address
      assert ip1 != ip2
    end

    test "returns error for non-existent pool" do
      result = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "nonexistent")
      assert result == {:error, :pool_not_found}
    end

    test "allocates IP from pool range" do
      {:ok, lease} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")

      ip = lease.ip || lease.ip_address
      # IP should be within pool range (2001:db8::100 to 2001:db8::1ff)
      {a, b, c, d, e, f, g, h} = ip
      assert a == 0x2001
      assert b == 0x0DB8
      assert c == 0
      assert d == 0
      assert e == 0
      assert f == 0
      assert g == 0
      assert h >= 0x0100 and h <= 0x01FF
    end

    test "sets lease lifetimes from pool config" do
      {:ok, lease} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")

      assert lease.preferred_lifetime == 3600
      assert lease.valid_lifetime == 7200
    end

    test "sets pool name in lease" do
      {:ok, lease} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")

      assert lease.pool_name == "test_pool"
    end
  end

  describe "get_lease/2" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "returns lease for allocated DUID/IAID" do
      # Use a unique DUID to avoid conflicts
      unique_duid = <<0x00, 0x03, 0x00, 0x01, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01>>

      {:ok, allocated} = LeaseManager.allocate_lease(unique_duid, @test_iaid, nil, "test_pool")
      {:ok, retrieved} = LeaseManager.get_lease(unique_duid, @test_iaid)

      allocated_ip = allocated.ip || allocated.ip_address
      retrieved_ip = retrieved.ip || retrieved.ip_address
      assert retrieved_ip == allocated_ip
      assert retrieved.duid == allocated.duid
    end

    test "returns error for unknown DUID" do
      random_duid = :crypto.strong_rand_bytes(10)
      result = LeaseManager.get_lease(random_duid, @test_iaid)
      assert result == {:error, :not_found}
    end

    test "returns error for unknown IAID with valid DUID" do
      {:ok, _allocated} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")
      result = LeaseManager.get_lease(@test_duid, 99999)
      assert result == {:error, :not_found}
    end
  end

  describe "release_lease/2" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "releases active lease" do
      {:ok, _lease} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")
      assert :ok = LeaseManager.release_lease(@test_duid, @test_iaid)

      # After release, get_lease should return not_found
      assert {:error, :not_found} = LeaseManager.get_lease(@test_duid, @test_iaid)
    end

    test "handles releasing non-existent lease" do
      # Should not error, just return :ok
      assert :ok = LeaseManager.release_lease(@test_duid, @test_iaid)
    end
  end

  describe "decline_ip/2" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "marks lease as declined" do
      {:ok, lease} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")
      ip = lease.ip || lease.ip_address
      assert :ok = LeaseManager.decline_ip(ip, @test_duid)

      # After decline, get_lease should return not_found
      assert {:error, :not_found} = LeaseManager.get_lease(@test_duid, @test_iaid)
    end

    test "handles declining unknown IP" do
      unknown_ip = {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0xFFFF}
      assert :ok = LeaseManager.decline_ip(unknown_ip, @test_duid)
    end
  end

  describe "list_leases/0" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "returns empty list when no leases allocated" do
      leases = LeaseManager.list_leases()
      assert is_list(leases)
    end

    test "returns allocated leases" do
      # Get count before allocation
      initial_count = length(LeaseManager.list_leases())

      # Allocate two new leases with unique DUIDs
      duid1 = <<0x00, 0x04, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x00, 0x01>>
      duid2 = <<0x00, 0x04, 0xF6, 0xE5, 0xD4, 0xC3, 0xB2, 0xA1, 0x00, 0x02>>

      {:ok, _lease1} = LeaseManager.allocate_lease(duid1, @test_iaid, nil, "test_pool")
      {:ok, _lease2} = LeaseManager.allocate_lease(duid2, @test_iaid, nil, "test_pool")

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
      {:ok, lease1} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")
      {:ok, lease2} = LeaseManager.allocate_lease(@test_duid_2, @test_iaid, nil, "test_pool")

      allocated = LeaseManager.get_allocated_ips()

      ip1 = lease1.ip || lease1.ip_address
      ip2 = lease2.ip || lease2.ip_address

      assert MapSet.member?(allocated, ip1)
      assert MapSet.member?(allocated, ip2)
    end

    test "returns empty set when no leases" do
      allocated = LeaseManager.get_allocated_ips()
      assert is_struct(allocated, MapSet)
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
      assert Map.has_key?(stats, :total_leases)
      assert Map.has_key?(stats, :active_leases)
      assert Map.has_key?(stats, :expired_leases)
    end

    test "tracks lease counts" do
      {:ok, _} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")
      stats = LeaseManager.stats()
      assert stats[:active_leases] >= 1
    end

    test "includes state breakdown" do
      {:ok, _} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")
      stats = LeaseManager.stats()
      assert Map.has_key?(stats, :by_state)
    end

    test "includes IA type breakdown" do
      {:ok, _} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")
      stats = LeaseManager.stats()
      assert Map.has_key?(stats, :by_ia_type)
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

    test "returns empty list when no pools configured" do
      {:ok, pid} = LeaseManager.start_link(pools: [])
      pools = LeaseManager.get_pools()
      assert pools == []
      stop_manager(pid)
    end
  end

  describe "get_all_pool_stats/0" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "returns stats for all pools" do
      pool_stats = LeaseManager.get_all_pool_stats()
      assert is_map(pool_stats)
      assert Map.has_key?(pool_stats, "test_pool")
    end

    test "pool stats include expected fields" do
      pool_stats = LeaseManager.get_all_pool_stats()
      stats = pool_stats["test_pool"]

      assert Map.has_key?(stats, :total_count)
      assert Map.has_key?(stats, :allocated_count)
      assert Map.has_key?(stats, :available_count)
      assert Map.has_key?(stats, :utilization_percent)
    end

    test "tracks allocations in pool stats" do
      {:ok, _} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")

      pool_stats = LeaseManager.get_all_pool_stats()
      stats = pool_stats["test_pool"]

      assert stats.allocated_count >= 1
    end
  end

  describe "static reservations" do
    test "honors static reservation for DUID" do
      pool_with_reservation = %{
        @test_pool_config
        | static_reservations: [
            %{
              duid: @test_duid,
              address: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0050}
            }
          ]
      }

      {:ok, pid} = LeaseManager.start_link(pools: [pool_with_reservation])

      {:ok, lease} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")

      ip = lease.ip || lease.ip_address
      assert ip == {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0050}

      stop_manager(pid)
    end
  end

  describe "requested IP handling" do
    setup do
      {:ok, pid} = LeaseManager.start_link(pools: [@test_pool_config])
      on_exit(fn -> stop_manager(pid) end)
      :ok
    end

    test "honors requested IP if available and in range" do
      requested_ip = {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0150}

      {:ok, lease} =
        LeaseManager.allocate_lease(@test_duid, @test_iaid, requested_ip, "test_pool")

      ip = lease.ip || lease.ip_address
      assert ip == requested_ip
    end

    test "allocates different IP if requested IP is already allocated" do
      requested_ip = {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0150}

      # First allocation gets the requested IP
      {:ok, lease1} =
        LeaseManager.allocate_lease(@test_duid, @test_iaid, requested_ip, "test_pool")

      assert (lease1.ip || lease1.ip_address) == requested_ip

      # Second allocation should get a different IP since requested is taken
      {:ok, lease2} =
        LeaseManager.allocate_lease(@test_duid_2, @test_iaid, requested_ip, "test_pool")

      ip2 = lease2.ip || lease2.ip_address
      # Should still be a valid IP, possibly different from requested
      assert ip2 != nil
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
        range_start: {0xFD00, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0100},
        range_end: {0xFD00, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x01FF},
        dns_servers: [{0x2001, 0x4860, 0x4860, 0x0000, 0x0000, 0x0000, 0x0000, 0x8888}],
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
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
        range_start: {0xFD00, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0100},
        range_end: {0xFD00, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x01FF},
        enabled: true
      }

      assert {:error, :pool_already_exists} = LeaseManager.add_pool(duplicate_pool)
    end

    test "rejects overlapping IPv6 range" do
      overlapping_pool = %{
        name: "overlapping",
        # This overlaps with test_pool's range (2001:db8::100 to 2001:db8::1ff)
        range_start: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0150},
        range_end: {0x2001, 0x0DB8, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x02FF},
        enabled: true
      }

      assert {:error, :range_overlap} = LeaseManager.add_pool(overlapping_pool)
    end

    test "accepts non-overlapping IPv6 range" do
      non_overlapping_pool = %{
        name: "non_overlapping",
        # Different prefix, no overlap
        range_start: {0x2001, 0x0DB8, 0x0000, 0x0001, 0x0000, 0x0000, 0x0000, 0x0100},
        range_end: {0x2001, 0x0DB8, 0x0000, 0x0001, 0x0000, 0x0000, 0x0000, 0x01FF},
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
      updates = %{valid_lifetime: 14400}

      assert {:ok, pool} = LeaseManager.update_pool("test_pool", updates)
      assert pool.valid_lifetime == 14400
    end

    test "returns error for non-existent pool" do
      updates = %{valid_lifetime: 14400}
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
        range_start: {0xFD00, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0100},
        range_end: {0xFD00, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x01FF},
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
      {:ok, _lease} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "test_pool")

      # Should fail without force
      assert {:error, :has_active_leases} = LeaseManager.remove_pool("test_pool", force: false)

      # Should succeed with force
      assert :ok = LeaseManager.remove_pool("test_pool", force: true)
    end
  end

  describe "control facades" do
    test "reports an absent manager without starting one" do
      assert {:error, :manager_absent} = LeaseManager.control_pool_snapshot()
      assert {:error, :manager_absent} = LeaseManager.control_list_leases()
    end

    test "keeps active leases when applying a force-safe empty pool snapshot" do
      control_pool = %{
        name: "control_pool",
        network: "2001:db8::/64",
        range_start: "2001:db8::100",
        range_end: "2001:db8::1ff",
        preferred_lifetime: 3600,
        valid_lifetime: 3600
      }

      {:ok, pid} = LeaseManager.start_link(pools: [control_pool])
      on_exit(fn -> stop_manager(pid) end)

      {:ok, _lease} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "control_pool")
      assert {:ok, true} = LeaseManager.control_pool_has_active_leases?("control_pool")
      assert :ok = LeaseManager.control_apply_pool_snapshot([])
      assert {:ok, [lease]} = LeaseManager.control_list_leases()
      assert String.starts_with?(lease.lease_id, "lease-")
    end

    test "releases an active lease by opaque identifier after persistence succeeds" do
      control_pool = %{
        name: "control_pool",
        network: "2001:db8::/64",
        range_start: "2001:db8::100",
        range_end: "2001:db8::1ff",
        preferred_lifetime: 3600,
        valid_lifetime: 3600
      }

      {:ok, pid} = LeaseManager.start_link(pools: [control_pool])
      on_exit(fn -> stop_manager(pid) end)

      {:ok, _lease} = LeaseManager.allocate_lease(@test_duid, @test_iaid, nil, "control_pool")
      {:ok, [lease]} = LeaseManager.control_list_leases()

      assert {:ok, %{lease_id: lease_id, state: :active}} =
               LeaseManager.control_release_lease(lease.lease_id)

      assert lease_id == lease.lease_id
      assert {:ok, []} = LeaseManager.control_list_leases()
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
