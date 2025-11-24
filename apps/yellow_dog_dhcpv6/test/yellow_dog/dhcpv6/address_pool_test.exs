defmodule YellowDog.Dhcpv6.AddressPoolTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv6.AddressPool

  @test_duid <<0, 3, 0, 1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

  describe "new/1" do
    test "creates pool with single range (legacy format)" do
      config = %{
        name: "test-pool",
        range_start: "fd00::1000",
        range_end: "fd00::2000",
        dns_servers: ["fd00::1", "fd00::2"],
        domain_name: "example.com",
        preferred_lifetime: 3600,
        valid_lifetime: 7200
      }

      assert {:ok, pool} = AddressPool.new(config)
      assert pool.name == "test-pool"
      assert length(pool.ranges) == 1
      assert pool.range_start == {0xFD00, 0, 0, 0, 0, 0, 0, 0x1000}
      assert pool.range_end == {0xFD00, 0, 0, 0, 0, 0, 0, 0x2000}
      assert length(pool.dns_servers) == 2
    end

    test "creates pool with multiple ranges" do
      config = %{
        name: "multi-range-pool",
        ranges: [
          %{start: "fd00::1000", end: "fd00::2000"},
          %{start: "fd00::5000", end: "fd00::6000"}
        ],
        dns_servers: ["fd00::1"],
        preferred_lifetime: 3600,
        valid_lifetime: 7200
      }

      assert {:ok, pool} = AddressPool.new(config)
      assert length(pool.ranges) == 2
    end

    test "handles address exclusions" do
      config = %{
        name: "test-pool",
        range_start: "fd00::1000",
        range_end: "fd00::2000",
        exclude_addresses: ["fd00::1500", "fd00::1600"],
        preferred_lifetime: 3600,
        valid_lifetime: 7200
      }

      assert {:ok, pool} = AddressPool.new(config)
      assert MapSet.size(pool.exclude_addresses) == 2
    end

    test "handles static reservations" do
      config = %{
        name: "test-pool",
        range_start: "fd00::1000",
        range_end: "fd00::2000",
        static_reservations: [
          %{duid: @test_duid, address: "fd00::100"}
        ],
        preferred_lifetime: 3600,
        valid_lifetime: 7200
      }

      assert {:ok, pool} = AddressPool.new(config)
      assert map_size(pool.static_reservations) == 1
    end
  end

  describe "get_available_ip/3" do
    test "returns static reservation when available" do
      config = %{
        name: "test-pool",
        range_start: "fd00::1000",
        range_end: "fd00::2000",
        static_reservations: [
          %{duid: @test_duid, address: "fd00::100"}
        ]
      }

      {:ok, pool} = AddressPool.new(config)
      allocated = MapSet.new()

      assert {:ok, {0xFD00, 0, 0, 0, 0, 0, 0, 0x100}} =
               AddressPool.get_available_ip(pool, allocated, @test_duid)
    end

    test "returns available IP from range" do
      config = %{
        name: "test-pool",
        range_start: "fd00::1000",
        range_end: "fd00::2000"
      }

      {:ok, pool} = AddressPool.new(config)
      allocated = MapSet.new()

      assert {:ok, ip} = AddressPool.get_available_ip(pool, allocated, @test_duid)
      assert AddressPool.in_range?(pool, ip)
    end

    test "avoids excluded addresses" do
      excluded_ip = {0xFD00, 0, 0, 0, 0, 0, 0, 0x1500}

      config = %{
        name: "test-pool",
        range_start: {0xFD00, 0, 0, 0, 0, 0, 0, 0x1000},
        range_end: {0xFD00, 0, 0, 0, 0, 0, 0, 0x2000},
        exclude_addresses: [excluded_ip]
      }

      {:ok, pool} = AddressPool.new(config)
      allocated = MapSet.new()

      # Get multiple IPs to increase chance of hitting excluded address
      ips =
        for _ <- 1..10 do
          {:ok, ip} = AddressPool.get_available_ip(pool, allocated, @test_duid)
          ip
        end

      # Ensure excluded address is never returned
      refute Enum.member?(ips, excluded_ip)
    end
  end

  describe "in_range?/2" do
    test "returns true for IP in range" do
      config = %{
        name: "test-pool",
        range_start: "fd00::1000",
        range_end: "fd00::2000"
      }

      {:ok, pool} = AddressPool.new(config)

      assert AddressPool.in_range?(pool, {0xFD00, 0, 0, 0, 0, 0, 0, 0x1500})
      refute AddressPool.in_range?(pool, {0xFD00, 0, 0, 0, 0, 0, 0, 0x3000})
    end

    test "checks multiple ranges" do
      config = %{
        name: "multi-range-pool",
        ranges: [
          %{start: "fd00::1000", end: "fd00::2000"},
          %{start: "fd00::5000", end: "fd00::6000"}
        ]
      }

      {:ok, pool} = AddressPool.new(config)

      assert AddressPool.in_range?(pool, {0xFD00, 0, 0, 0, 0, 0, 0, 0x1500})
      assert AddressPool.in_range?(pool, {0xFD00, 0, 0, 0, 0, 0, 0, 0x5500})
      refute AddressPool.in_range?(pool, {0xFD00, 0, 0, 0, 0, 0, 0, 0x3000})
    end
  end

  describe "pool_size/1" do
    test "calculates total pool size" do
      config = %{
        name: "test-pool",
        range_start: {0xFD00, 0, 0, 0, 0, 0, 0, 0x1000},
        range_end: {0xFD00, 0, 0, 0, 0, 0, 0, 0x1010}
      }

      {:ok, pool} = AddressPool.new(config)

      # 0x1010 - 0x1000 + 1 = 17
      assert AddressPool.pool_size(pool) == 17
    end

    test "accounts for exclusions in pool size" do
      config = %{
        name: "test-pool",
        range_start: {0xFD00, 0, 0, 0, 0, 0, 0, 0x1000},
        range_end: {0xFD00, 0, 0, 0, 0, 0, 0, 0x1010},
        exclude_addresses: [
          {0xFD00, 0, 0, 0, 0, 0, 0, 0x1005},
          {0xFD00, 0, 0, 0, 0, 0, 0, 0x1006}
        ]
      }

      {:ok, pool} = AddressPool.new(config)

      # 17 - 2 exclusions = 15
      assert AddressPool.pool_size(pool) == 15
    end

    test "sums multiple ranges" do
      config = %{
        name: "multi-range-pool",
        ranges: [
          %{
            start: {0xFD00, 0, 0, 0, 0, 0, 0, 0x1000},
            end: {0xFD00, 0, 0, 0, 0, 0, 0, 0x1010}
          },
          %{
            start: {0xFD00, 0, 0, 0, 0, 0, 0, 0x2000},
            end: {0xFD00, 0, 0, 0, 0, 0, 0, 0x2010}
          }
        ]
      }

      {:ok, pool} = AddressPool.new(config)

      # 17 + 17 = 34
      assert AddressPool.pool_size(pool) == 34
    end
  end
end
