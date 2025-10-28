defmodule YellowDog.Dhcpv6.LeaseStorageTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv6.LeaseStorage

  @test_duid <<0, 3, 0, 1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
  @test_iaid 12345
  @test_ip {0xFD00, 0, 0, 0, 0, 0, 0, 0x100}

  setup do
    # Initialize storage with ram_copies for testing
    LeaseStorage.init(storage_type: :ram_copies)

    # Clear all leases before each test
    LeaseStorage.clear_all()

    :ok
  end

  describe "put/1 and get/2" do
    test "stores and retrieves a lease" do
      lease = %{
        duid: @test_duid,
        iaid: @test_iaid,
        ip_address: @test_ip,
        pool_name: "test-pool",
        ia_type: :ia_na,
        state: :active,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      assert {:ok, stored_lease} = LeaseStorage.put(lease)
      assert stored_lease.duid == @test_duid
      assert stored_lease.iaid == @test_iaid
      assert stored_lease.ip_address == @test_ip

      assert {:ok, retrieved_lease} = LeaseStorage.get(@test_duid, @test_iaid)
      assert retrieved_lease.duid == @test_duid
      assert retrieved_lease.ip_address == @test_ip
    end

    test "updates an existing lease" do
      lease = %{
        duid: @test_duid,
        iaid: @test_iaid,
        ip_address: @test_ip,
        pool_name: "test-pool",
        ia_type: :ia_na,
        state: :offered,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      {:ok, _} = LeaseStorage.put(lease)

      # Update state to active
      updated_lease = %{lease | state: :active}
      {:ok, stored} = LeaseStorage.put(updated_lease)

      assert stored.state == :active
    end

    test "returns error for non-existent lease" do
      assert {:error, :not_found} = LeaseStorage.get(@test_duid, 99999)
    end
  end

  describe "get_by_ip/1" do
    test "retrieves lease by IP address" do
      lease = %{
        duid: @test_duid,
        iaid: @test_iaid,
        ip_address: @test_ip,
        pool_name: "test-pool",
        ia_type: :ia_na,
        state: :active,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      {:ok, _} = LeaseStorage.put(lease)

      assert {:ok, retrieved} = LeaseStorage.get_by_ip(@test_ip)
      assert retrieved.duid == @test_duid
      assert retrieved.ip_address == @test_ip
    end

    test "returns error for non-existent IP" do
      assert {:error, :not_found} = LeaseStorage.get_by_ip({0xFD00, 0, 0, 0, 0, 0, 0, 0x999})
    end
  end

  describe "get_by_duid/1" do
    test "retrieves all leases for a DUID" do
      # Create multiple leases for the same DUID
      lease1 = %{
        duid: @test_duid,
        iaid: 1,
        ip_address: {0xFD00, 0, 0, 0, 0, 0, 0, 0x100},
        pool_name: "test-pool",
        ia_type: :ia_na,
        state: :active,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      lease2 = %{
        duid: @test_duid,
        iaid: 2,
        ip_address: {0xFD00, 0, 0, 0, 0, 0, 0, 0x200},
        pool_name: "test-pool",
        ia_type: :ia_ta,
        state: :active,
        preferred_lifetime: 600,
        valid_lifetime: 1200,
        expires_at: System.system_time(:second) + 1200
      }

      {:ok, _} = LeaseStorage.put(lease1)
      {:ok, _} = LeaseStorage.put(lease2)

      leases = LeaseStorage.get_by_duid(@test_duid)
      assert length(leases) == 2
      assert Enum.any?(leases, fn l -> l.iaid == 1 end)
      assert Enum.any?(leases, fn l -> l.iaid == 2 end)
    end
  end

  describe "delete/2" do
    test "deletes a lease" do
      lease = %{
        duid: @test_duid,
        iaid: @test_iaid,
        ip_address: @test_ip,
        pool_name: "test-pool",
        ia_type: :ia_na,
        state: :active,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      {:ok, _} = LeaseStorage.put(lease)
      assert {:ok, _} = LeaseStorage.get(@test_duid, @test_iaid)

      :ok = LeaseStorage.delete(@test_duid, @test_iaid)
      assert {:error, :not_found} = LeaseStorage.get(@test_duid, @test_iaid)
    end
  end

  describe "list/1" do
    test "lists all leases" do
      lease1 = %{
        duid: @test_duid,
        iaid: 1,
        ip_address: {0xFD00, 0, 0, 0, 0, 0, 0, 0x100},
        pool_name: "pool1",
        ia_type: :ia_na,
        state: :active,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      lease2 = %{
        duid: <<0, 3, 0, 1, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        iaid: 2,
        ip_address: {0xFD00, 0, 0, 0, 0, 0, 0, 0x200},
        pool_name: "pool2",
        ia_type: :ia_pd,
        state: :offered,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      {:ok, _} = LeaseStorage.put(lease1)
      {:ok, _} = LeaseStorage.put(lease2)

      all_leases = LeaseStorage.list()
      assert length(all_leases) == 2
    end

    test "filters leases by state" do
      active_lease = %{
        duid: @test_duid,
        iaid: 1,
        ip_address: {0xFD00, 0, 0, 0, 0, 0, 0, 0x100},
        pool_name: "test-pool",
        ia_type: :ia_na,
        state: :active,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      offered_lease = %{
        duid: <<0, 3, 0, 1, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        iaid: 2,
        ip_address: {0xFD00, 0, 0, 0, 0, 0, 0, 0x200},
        pool_name: "test-pool",
        ia_type: :ia_na,
        state: :offered,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      {:ok, _} = LeaseStorage.put(active_lease)
      {:ok, _} = LeaseStorage.put(offered_lease)

      active_only = LeaseStorage.list(state: :active)
      assert length(active_only) == 1
      assert hd(active_only).state == :active
    end

    test "filters leases by IA type" do
      ia_na_lease = %{
        duid: @test_duid,
        iaid: 1,
        ip_address: {0xFD00, 0, 0, 0, 0, 0, 0, 0x100},
        pool_name: "test-pool",
        ia_type: :ia_na,
        state: :active,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      ia_pd_lease = %{
        duid: <<0, 3, 0, 1, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        iaid: 2,
        delegated_prefix: {{0x2001, 0x0DB8, 0x1000, 0, 0, 0, 0, 0}, 56},
        pool_name: "test-pool",
        ia_type: :ia_pd,
        state: :active,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      {:ok, _} = LeaseStorage.put(ia_na_lease)
      {:ok, _} = LeaseStorage.put(ia_pd_lease)

      pd_only = LeaseStorage.list(ia_type: :ia_pd)
      assert length(pd_only) == 1
      assert hd(pd_only).ia_type == :ia_pd
    end
  end

  describe "update_state/3" do
    test "updates lease state" do
      lease = %{
        duid: @test_duid,
        iaid: @test_iaid,
        ip_address: @test_ip,
        pool_name: "test-pool",
        ia_type: :ia_na,
        state: :offered,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      {:ok, _} = LeaseStorage.put(lease)

      assert {:ok, updated} = LeaseStorage.update_state(@test_duid, @test_iaid, :active)
      assert updated.state == :active

      assert {:ok, retrieved} = LeaseStorage.get(@test_duid, @test_iaid)
      assert retrieved.state == :active
    end
  end

  describe "cleanup_expired/0" do
    test "marks expired leases" do
      # Create a lease that's already expired
      expired_lease = %{
        duid: @test_duid,
        iaid: @test_iaid,
        ip_address: @test_ip,
        pool_name: "test-pool",
        ia_type: :ia_na,
        state: :active,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) - 1
      }

      {:ok, _} = LeaseStorage.put(expired_lease)

      assert {:ok, count} = LeaseStorage.cleanup_expired()
      assert count == 1

      {:ok, lease} = LeaseStorage.get(@test_duid, @test_iaid)
      assert lease.state == :expired
    end
  end

  describe "stats/0" do
    test "returns lease statistics" do
      active_lease = %{
        duid: @test_duid,
        iaid: 1,
        ip_address: {0xFD00, 0, 0, 0, 0, 0, 0, 0x100},
        pool_name: "test-pool",
        ia_type: :ia_na,
        state: :active,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) + 7200
      }

      expired_lease = %{
        duid: <<0, 3, 0, 1, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>,
        iaid: 2,
        ip_address: {0xFD00, 0, 0, 0, 0, 0, 0, 0x200},
        pool_name: "test-pool",
        ia_type: :ia_na,
        state: :active,
        preferred_lifetime: 3600,
        valid_lifetime: 7200,
        expires_at: System.system_time(:second) - 1
      }

      {:ok, _} = LeaseStorage.put(active_lease)
      {:ok, _} = LeaseStorage.put(expired_lease)

      stats = LeaseStorage.stats()
      assert stats.total_leases == 2
      assert stats.active_leases == 1
      assert stats.expired_leases == 1
      assert stats.by_ia_type.ia_na == 2
    end
  end
end
