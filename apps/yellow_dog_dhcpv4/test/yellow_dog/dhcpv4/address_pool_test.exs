defmodule YellowDog.Dhcpv4.AddressPoolTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv4.AddressPool

  # Test fixtures
  @legacy_config %{
    name: "test_pool",
    range_start: {192, 168, 1, 100},
    range_end: {192, 168, 1, 200},
    subnet_mask: {255, 255, 255, 0},
    gateway: {192, 168, 1, 1},
    dns_servers: [{8, 8, 8, 8}, {8, 8, 4, 4}],
    domain_name: "test.local",
    lease_time: 86400
  }

  @ranges_config %{
    name: "multi_range_pool",
    ranges: [
      {{192, 168, 1, 100}, {192, 168, 1, 150}},
      {{192, 168, 1, 200}, {192, 168, 1, 250}}
    ],
    subnet_mask: {255, 255, 255, 0},
    gateway: {192, 168, 1, 1},
    dns_servers: [{8, 8, 8, 8}],
    lease_time: 3600
  }

  @config_with_reservations %{
    name: "reserved_pool",
    range_start: {10, 0, 0, 100},
    range_end: {10, 0, 0, 200},
    static_reservations: %{
      "AA:BB:CC:DD:EE:FF" => {10, 0, 0, 50},
      "11:22:33:44:55:66" => {10, 0, 0, 51}
    }
  }

  @config_with_exclusions %{
    name: "exclusion_pool",
    range_start: {172, 16, 0, 1},
    range_end: {172, 16, 0, 254},
    excluded_ranges: [
      {{172, 16, 0, 50}, {172, 16, 0, 60}},
      {{172, 16, 0, 100}, {172, 16, 0, 110}}
    ]
  }

  describe "new/1" do
    test "creates pool from legacy config" do
      assert {:ok, pool} = AddressPool.new(@legacy_config)

      assert pool.name == "test_pool"
      assert pool.ranges == [{{192, 168, 1, 100}, {192, 168, 1, 200}}]
      assert pool.subnet_mask == {255, 255, 255, 0}
      assert pool.gateway == {192, 168, 1, 1}
      assert pool.dns_servers == [{8, 8, 8, 8}, {8, 8, 4, 4}]
      assert pool.domain_name == "test.local"
      assert pool.lease_time == 86400
    end

    test "creates pool from ranges config" do
      assert {:ok, pool} = AddressPool.new(@ranges_config)

      assert pool.name == "multi_range_pool"
      assert length(pool.ranges) == 2

      assert {{192, 168, 1, 100}, {192, 168, 1, 150}} in pool.ranges
      assert {{192, 168, 1, 200}, {192, 168, 1, 250}} in pool.ranges
    end

    test "creates pool with static reservations" do
      assert {:ok, pool} = AddressPool.new(@config_with_reservations)

      assert pool.static_reservations == %{
               "AA:BB:CC:DD:EE:FF" => {10, 0, 0, 50},
               "11:22:33:44:55:66" => {10, 0, 0, 51}
             }
    end

    test "creates pool with excluded ranges" do
      assert {:ok, pool} = AddressPool.new(@config_with_exclusions)

      assert length(pool.excluded_ranges) == 2
      assert {{172, 16, 0, 50}, {172, 16, 0, 60}} in pool.excluded_ranges
      assert {{172, 16, 0, 100}, {172, 16, 0, 110}} in pool.excluded_ranges
    end

    test "uses default values when not specified" do
      minimal_config = %{
        range_start: {192, 168, 1, 100},
        range_end: {192, 168, 1, 200}
      }

      assert {:ok, pool} = AddressPool.new(minimal_config)

      assert pool.name == "default"
      assert pool.subnet_mask == {255, 255, 255, 0}
      # Default gateway is first IP in range
      assert pool.gateway == {192, 168, 1, 100}
      assert pool.lease_time == 86400
      assert pool.static_reservations == %{}
      assert pool.excluded_ranges == []
    end

    test "returns error when both ranges and range_start/end missing" do
      invalid_config = %{name: "invalid"}

      assert {:error, _} = AddressPool.new(invalid_config)
    end

    test "returns error when range_start > range_end" do
      invalid_config = %{
        range_start: {192, 168, 1, 200},
        range_end: {192, 168, 1, 100}
      }

      assert {:error, _} = AddressPool.new(invalid_config)
    end
  end

  describe "validate_pool_config/1" do
    test "validates legacy config format" do
      assert {:ok, validated} = AddressPool.validate_pool_config(@legacy_config)

      assert validated.range_start == {192, 168, 1, 100}
      assert validated.range_end == {192, 168, 1, 200}
    end

    test "validates ranges config format" do
      assert {:ok, validated} = AddressPool.validate_pool_config(@ranges_config)

      assert is_list(validated.ranges)
      assert length(validated.ranges) == 2
    end

    test "returns error for invalid range order" do
      invalid_config = %{
        range_start: {192, 168, 1, 200},
        range_end: {192, 168, 1, 100}
      }

      assert {:error, "range_start must be less than or equal to range_end"} =
               AddressPool.validate_pool_config(invalid_config)
    end

    test "returns error when neither ranges nor range_start/end provided" do
      assert {:error, _} = AddressPool.validate_pool_config(%{})
    end
  end

  describe "get_available_ip/3" do
    setup do
      {:ok, pool} = AddressPool.new(@legacy_config)
      {:ok, pool: pool}
    end

    test "returns first available IP when none allocated", %{pool: pool} do
      allocated_ips = MapSet.new()
      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

      assert {:ok, ip} = AddressPool.get_available_ip(pool, allocated_ips, mac)
      assert ip == {192, 168, 1, 100}
    end

    test "skips allocated IPs", %{pool: pool} do
      allocated_ips = MapSet.new([{192, 168, 1, 100}, {192, 168, 1, 101}])
      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

      assert {:ok, ip} = AddressPool.get_available_ip(pool, allocated_ips, mac)
      assert ip == {192, 168, 1, 102}
    end

    test "returns pool_exhausted when all IPs allocated", %{pool: _pool} do
      # Create a small pool to test exhaustion
      {:ok, small_pool} =
        AddressPool.new(%{
          range_start: {192, 168, 1, 100},
          range_end: {192, 168, 1, 102}
        })

      allocated_ips =
        MapSet.new([
          {192, 168, 1, 100},
          {192, 168, 1, 101},
          {192, 168, 1, 102}
        ])

      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

      assert {:error, :pool_exhausted} =
               AddressPool.get_available_ip(small_pool, allocated_ips, mac)
    end

    test "returns static reservation for matching MAC" do
      {:ok, pool} = AddressPool.new(@config_with_reservations)
      allocated_ips = MapSet.new()
      # MAC matching "AA:BB:CC:DD:EE:FF"
      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

      assert {:ok, ip} = AddressPool.get_available_ip(pool, allocated_ips, mac)
      assert ip == {10, 0, 0, 50}
    end

    test "returns static reservation even if IP is normally out of range" do
      {:ok, pool} = AddressPool.new(@config_with_reservations)
      allocated_ips = MapSet.new()
      # MAC matching "AA:BB:CC:DD:EE:FF" → reserved IP 10.0.0.50
      # which is outside the range 10.0.0.100-200
      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

      assert {:ok, ip} = AddressPool.get_available_ip(pool, allocated_ips, mac)
      assert ip == {10, 0, 0, 50}
    end

    test "returns pool_exhausted when static reservation IP is already allocated to another client" do
      {:ok, pool} = AddressPool.new(@config_with_reservations)
      # Simulate reserved IP 10.0.0.50 already allocated (e.g. to another MAC)
      allocated_ips = MapSet.new([{10, 0, 0, 50}])
      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

      assert {:error, :pool_exhausted} =
               AddressPool.get_available_ip(pool, allocated_ips, mac)
    end

    test "finds IP across multiple ranges" do
      {:ok, pool} = AddressPool.new(@ranges_config)

      # Fill first range completely
      first_range_ips =
        for i <- 100..150, do: {192, 168, 1, i}

      allocated_ips = MapSet.new(first_range_ips)
      mac = <<0x11, 0x22, 0x33, 0x44, 0x55, 0x66>>

      # Should find IP in second range
      assert {:ok, ip} = AddressPool.get_available_ip(pool, allocated_ips, mac)
      assert ip == {192, 168, 1, 200}
    end
  end

  describe "in_range?/2" do
    setup do
      {:ok, pool} = AddressPool.new(@legacy_config)
      {:ok, pool: pool}
    end

    test "returns true for IP at start of range", %{pool: pool} do
      assert AddressPool.in_range?(pool, {192, 168, 1, 100})
    end

    test "returns true for IP at end of range", %{pool: pool} do
      assert AddressPool.in_range?(pool, {192, 168, 1, 200})
    end

    test "returns true for IP in middle of range", %{pool: pool} do
      assert AddressPool.in_range?(pool, {192, 168, 1, 150})
    end

    test "returns false for IP before range", %{pool: pool} do
      refute AddressPool.in_range?(pool, {192, 168, 1, 99})
    end

    test "returns false for IP after range", %{pool: pool} do
      refute AddressPool.in_range?(pool, {192, 168, 1, 201})
    end

    test "returns false for IP in completely different subnet", %{pool: pool} do
      refute AddressPool.in_range?(pool, {10, 0, 0, 1})
    end

    test "handles excluded ranges" do
      {:ok, pool} = AddressPool.new(@config_with_exclusions)

      # In main range but not excluded
      assert AddressPool.in_range?(pool, {172, 16, 0, 1})
      assert AddressPool.in_range?(pool, {172, 16, 0, 49})
      assert AddressPool.in_range?(pool, {172, 16, 0, 61})

      # In excluded range
      refute AddressPool.in_range?(pool, {172, 16, 0, 50})
      refute AddressPool.in_range?(pool, {172, 16, 0, 55})
      refute AddressPool.in_range?(pool, {172, 16, 0, 60})

      # In second excluded range
      refute AddressPool.in_range?(pool, {172, 16, 0, 100})
      refute AddressPool.in_range?(pool, {172, 16, 0, 105})
      refute AddressPool.in_range?(pool, {172, 16, 0, 110})
    end

    test "handles multiple ranges" do
      {:ok, pool} = AddressPool.new(@ranges_config)

      # In first range
      assert AddressPool.in_range?(pool, {192, 168, 1, 100})
      assert AddressPool.in_range?(pool, {192, 168, 1, 150})

      # In second range
      assert AddressPool.in_range?(pool, {192, 168, 1, 200})
      assert AddressPool.in_range?(pool, {192, 168, 1, 250})

      # Between ranges (not in any range)
      refute AddressPool.in_range?(pool, {192, 168, 1, 175})
    end
  end

  describe "get_static_reservation/2" do
    test "returns IP for matching MAC" do
      {:ok, pool} = AddressPool.new(@config_with_reservations)

      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      assert {:ok, {10, 0, 0, 50}} = AddressPool.get_static_reservation(pool, mac)
    end

    test "returns not_found for non-reserved MAC" do
      {:ok, pool} = AddressPool.new(@config_with_reservations)

      mac = <<0x00, 0x11, 0x22, 0x33, 0x44, 0x55>>
      assert :not_found = AddressPool.get_static_reservation(pool, mac)
    end

    test "handles pool without reservations" do
      {:ok, pool} = AddressPool.new(@legacy_config)

      mac = <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      assert :not_found = AddressPool.get_static_reservation(pool, mac)
    end
  end

  describe "pool_size/1" do
    test "calculates size for single range" do
      {:ok, pool} = AddressPool.new(@legacy_config)

      # Range 100-200 = 101 addresses
      assert AddressPool.pool_size(pool) == 101
    end

    test "calculates size for multiple ranges" do
      {:ok, pool} = AddressPool.new(@ranges_config)

      # Range 100-150 = 51 addresses
      # Range 200-250 = 51 addresses
      # Total = 102 addresses
      assert AddressPool.pool_size(pool) == 102
    end

    test "subtracts excluded ranges from total" do
      {:ok, pool} = AddressPool.new(@config_with_exclusions)

      # Range 1-254 = 254 addresses
      # Excluded 50-60 = 11 addresses
      # Excluded 100-110 = 11 addresses
      # Total = 254 - 11 - 11 = 232 addresses
      assert AddressPool.pool_size(pool) == 232
    end

    test "handles small pool" do
      {:ok, pool} =
        AddressPool.new(%{
          range_start: {192, 168, 1, 100},
          range_end: {192, 168, 1, 100}
        })

      # Single IP
      assert AddressPool.pool_size(pool) == 1
    end
  end

  describe "IP string parsing" do
    test "accepts string IP addresses in config" do
      config = %{
        ranges: [
          %{start: "192.168.1.100", end: "192.168.1.200"}
        ]
      }

      assert {:ok, pool} = AddressPool.new(config)
      assert pool.ranges == [{{192, 168, 1, 100}, {192, 168, 1, 200}}]
    end
  end

  describe "edge cases" do
    test "handles Class A address space" do
      {:ok, pool} =
        AddressPool.new(%{
          range_start: {10, 0, 0, 1},
          range_end: {10, 0, 0, 254}
        })

      assert AddressPool.in_range?(pool, {10, 0, 0, 128})
      refute AddressPool.in_range?(pool, {10, 0, 1, 1})
    end

    test "handles Class B address space" do
      {:ok, pool} =
        AddressPool.new(%{
          range_start: {172, 16, 0, 1},
          range_end: {172, 16, 0, 254}
        })

      assert AddressPool.in_range?(pool, {172, 16, 0, 100})
      refute AddressPool.in_range?(pool, {172, 17, 0, 1})
    end

    test "handles adjacent ranges" do
      {:ok, pool} =
        AddressPool.new(%{
          ranges: [
            {{192, 168, 1, 1}, {192, 168, 1, 50}},
            {{192, 168, 1, 51}, {192, 168, 1, 100}}
          ]
        })

      # All IPs should be in range
      assert AddressPool.in_range?(pool, {192, 168, 1, 1})
      assert AddressPool.in_range?(pool, {192, 168, 1, 50})
      assert AddressPool.in_range?(pool, {192, 168, 1, 51})
      assert AddressPool.in_range?(pool, {192, 168, 1, 100})

      # Total size should be 100
      assert AddressPool.pool_size(pool) == 100
    end
  end
end
