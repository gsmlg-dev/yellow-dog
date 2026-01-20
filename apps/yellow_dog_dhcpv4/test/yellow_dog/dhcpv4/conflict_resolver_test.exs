defmodule YellowDog.Dhcpv4.ConflictResolverTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dhcpv4.{ConflictResolver, LeaseManager, LeaseStorage}

  setup do
    # LeaseStorage needs to be initialized
    LeaseStorage.init()

    # Start LeaseManager first (required by ConflictResolver)
    pool_config = %{
      name: "default",
      range_start: {192, 168, 1, 100},
      range_end: {192, 168, 1, 200},
      subnet_mask: {255, 255, 255, 0},
      gateway: {192, 168, 1, 1},
      dns_servers: [{192, 168, 1, 1}],
      domain_name: "test.local",
      lease_time: 86400,
      static_reservations: %{}
    }

    {:ok, _lease_mgr} = start_supervised({LeaseManager, pools: [pool_config]})

    # Start the ConflictResolver
    {:ok, _resolver} = start_supervised(ConflictResolver)

    :ok
  end

  describe "quarantined?/1" do
    test "returns false for non-quarantined IP" do
      ip = {10, 0, 0, 1}
      assert ConflictResolver.quarantined?(ip) == false
    end
  end

  describe "stats/0" do
    test "returns conflict statistics" do
      stats = ConflictResolver.stats()

      assert is_map(stats)
      assert Map.has_key?(stats, :total_conflicts)
      assert Map.has_key?(stats, :active_quarantines)
      assert is_integer(stats.total_conflicts)
      assert is_integer(stats.active_quarantines)
    end

    test "has expected fields" do
      stats = ConflictResolver.stats()

      assert Map.has_key?(stats, :total_conflicts)
      assert Map.has_key?(stats, :total_reassignments)
      assert Map.has_key?(stats, :active_quarantines)
      assert Map.has_key?(stats, :quarantine_time_seconds)
    end
  end

  describe "list_quarantined/0" do
    test "returns empty list when no conflicts" do
      quarantined = ConflictResolver.list_quarantined()
      assert is_list(quarantined)
      assert quarantined == []
    end
  end

  describe "release_quarantine/1" do
    test "returns ok for non-quarantined IP" do
      ip = {10, 10, 10, 10}
      result = ConflictResolver.release_quarantine(ip)
      assert result == :ok
    end
  end

  describe "handle_conflict/3 with LeaseManager" do
    test "quarantines the conflicted IP address" do
      # First allocate a lease
      mac = <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>
      {:ok, lease} = LeaseManager.allocate_lease(mac, nil, nil, "default")
      conflicted_ip = lease.ip_address

      # Before conflict, IP should not be quarantined
      assert ConflictResolver.quarantined?(conflicted_ip) == false

      # Handle the conflict - note: order is (ip, mac, pool_name)
      result = ConflictResolver.handle_conflict(conflicted_ip, mac, "default")
      # Returns {:ok, new_ip} or {:error, reason}
      assert match?({:ok, _new_ip}, result) or match?({:error, _reason}, result)

      # After conflict, original IP should be quarantined
      assert ConflictResolver.quarantined?(conflicted_ip) == true
    end

    test "increments conflict count in stats" do
      # First allocate a lease
      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      {:ok, lease} = LeaseManager.allocate_lease(mac, nil, nil, "default")
      conflicted_ip = lease.ip_address

      # Get initial stats
      initial_stats = ConflictResolver.stats()
      initial_count = initial_stats.total_conflicts

      # Handle the conflict
      ConflictResolver.handle_conflict(conflicted_ip, mac, "default")

      # Stats should show the conflict
      stats = ConflictResolver.stats()
      assert stats.total_conflicts == initial_count + 1
    end

    test "list_quarantined returns conflict records" do
      # First allocate a lease
      mac = <<0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC>>
      {:ok, lease} = LeaseManager.allocate_lease(mac, nil, nil, "default")
      conflicted_ip = lease.ip_address

      # Handle the conflict
      ConflictResolver.handle_conflict(conflicted_ip, mac, "default")

      quarantined = ConflictResolver.list_quarantined()

      assert is_list(quarantined)
      assert length(quarantined) >= 1

      # Each record should have the expected fields
      record = hd(quarantined)
      assert Map.has_key?(record, :ip_address)
      assert Map.has_key?(record, :client_mac)
      assert Map.has_key?(record, :pool_name)
      assert Map.has_key?(record, :conflict_count)
      assert Map.has_key?(record, :expires_at)
    end

    test "release_quarantine removes IP from quarantine" do
      # First allocate a lease
      mac = <<0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01>>
      {:ok, lease} = LeaseManager.allocate_lease(mac, nil, nil, "default")
      conflicted_ip = lease.ip_address

      # Handle the conflict
      ConflictResolver.handle_conflict(conflicted_ip, mac, "default")
      assert ConflictResolver.quarantined?(conflicted_ip) == true

      # Release the quarantine
      result = ConflictResolver.release_quarantine(conflicted_ip)
      assert result == :ok

      # Should no longer be quarantined
      assert ConflictResolver.quarantined?(conflicted_ip) == false
    end
  end
end
