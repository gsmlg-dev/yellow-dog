defmodule YellowDog.Dhcpv6.PrefixPoolTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv6.PrefixPool

  @test_duid <<0, 3, 0, 1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>

  describe "new/1" do
    test "creates prefix pool" do
      config = %{
        name: "test-pd-pool",
        prefix: "2001:db8:1000::",
        prefix_length: 48,
        delegated_length: 56
      }

      assert {:ok, pool} = PrefixPool.new(config)
      assert pool.name == "test-pd-pool"
      assert pool.prefix == {0x2001, 0x0DB8, 0x1000, 0, 0, 0, 0, 0}
      assert pool.prefix_length == 48
      assert pool.delegated_length == 56
    end

    test "validates prefix delegation range" do
      # delegated_length must be > prefix_length
      config = %{
        name: "invalid-pool",
        prefix: "2001:db8::",
        prefix_length: 48,
        delegated_length: 48
      }

      assert {:error, _reason} = PrefixPool.new(config)
    end

    test "handles prefix exclusions" do
      config = %{
        name: "test-pd-pool",
        prefix: "2001:db8:1000::",
        prefix_length: 48,
        delegated_length: 56,
        exclude_prefixes: ["2001:db8:1000::/56", "2001:db8:1001::/56"]
      }

      assert {:ok, pool} = PrefixPool.new(config)
      assert length(pool.exclude_prefixes) == 2
    end

    test "handles static prefix reservations" do
      config = %{
        name: "test-pd-pool",
        prefix: "2001:db8:1000::",
        prefix_length: 48,
        delegated_length: 56,
        static_reservations: [
          %{
            duid: @test_duid,
            prefix: "2001:db8:1000:0100::",
            prefix_length: 56
          }
        ]
      }

      assert {:ok, pool} = PrefixPool.new(config)
      assert map_size(pool.static_reservations) == 1
    end
  end

  describe "allocate_prefix/3" do
    test "returns static reservation when available" do
      config = %{
        name: "test-pd-pool",
        prefix: "2001:db8:1000::",
        prefix_length: 48,
        delegated_length: 56,
        static_reservations: [
          %{
            duid: @test_duid,
            prefix: "2001:db8:1000:0100::",
            prefix_length: 56
          }
        ]
      }

      {:ok, pool} = PrefixPool.new(config)
      allocated = MapSet.new()

      assert {:ok, {{0x2001, 0x0DB8, 0x1000, 0x0100, 0, 0, 0, 0}, 56}} =
               PrefixPool.allocate_prefix(pool, allocated, @test_duid)
    end

    test "allocates available prefix from pool" do
      config = %{
        name: "test-pd-pool",
        prefix: "2001:db8:1000::",
        prefix_length: 48,
        delegated_length: 56
      }

      {:ok, pool} = PrefixPool.new(config)
      allocated = MapSet.new()

      assert {:ok, {prefix_addr, 56}} = PrefixPool.allocate_prefix(pool, allocated, @test_duid)
      assert PrefixPool.in_range?(pool, {prefix_addr, 56})
    end

    test "avoids excluded prefixes" do
      excluded_prefix = {{0x2001, 0x0DB8, 0x1000, 0, 0, 0, 0, 0}, 56}

      config = %{
        name: "test-pd-pool",
        prefix: "2001:db8:1000::",
        prefix_length: 48,
        delegated_length: 56,
        exclude_prefixes: ["2001:db8:1000::/56"]
      }

      {:ok, pool} = PrefixPool.new(config)
      allocated = MapSet.new()

      # Get multiple prefixes to ensure excluded is never returned
      prefixes =
        for _ <- 1..10 do
          {:ok, prefix} = PrefixPool.allocate_prefix(pool, allocated, @test_duid)
          prefix
        end

      refute Enum.member?(prefixes, excluded_prefix)
    end
  end

  describe "in_range?/2" do
    test "returns true for prefix in delegation range" do
      config = %{
        name: "test-pd-pool",
        prefix: "2001:db8:1000::",
        prefix_length: 48,
        delegated_length: 56
      }

      {:ok, pool} = PrefixPool.new(config)

      # Valid prefix within range
      assert PrefixPool.in_range?(pool, {{0x2001, 0x0DB8, 0x1000, 0x0100, 0, 0, 0, 0}, 56})

      # Wrong prefix length
      refute PrefixPool.in_range?(pool, {{0x2001, 0x0DB8, 0x1000, 0x0100, 0, 0, 0, 0}, 64})

      # Outside prefix range
      refute PrefixPool.in_range?(pool, {{0x2001, 0x0DB8, 0x2000, 0, 0, 0, 0, 0}, 56})
    end
  end

  describe "pool_size/1" do
    test "calculates number of delegatable prefixes" do
      config = %{
        name: "test-pd-pool",
        prefix: "2001:db8:1000::",
        prefix_length: 48,
        delegated_length: 56
      }

      {:ok, pool} = PrefixPool.new(config)

      # 56 - 48 = 8 bits = 2^8 = 256 prefixes
      assert PrefixPool.pool_size(pool) == 256
    end

    test "accounts for exclusions in pool size" do
      config = %{
        name: "test-pd-pool",
        prefix: "2001:db8:1000::",
        prefix_length: 48,
        delegated_length: 56,
        exclude_prefixes: ["2001:db8:1000::/56", "2001:db8:1001::/56"]
      }

      {:ok, pool} = PrefixPool.new(config)

      # 256 - 2 exclusions = 254
      assert PrefixPool.pool_size(pool) == 254
    end
  end

  describe "get_static_reservation/2" do
    test "retrieves static reservation for DUID" do
      config = %{
        name: "test-pd-pool",
        prefix: "2001:db8:1000::",
        prefix_length: 48,
        delegated_length: 56,
        static_reservations: [
          %{
            duid: @test_duid,
            prefix: "2001:db8:1000:0100::",
            prefix_length: 56
          }
        ]
      }

      {:ok, pool} = PrefixPool.new(config)

      assert {:ok, {{0x2001, 0x0DB8, 0x1000, 0x0100, 0, 0, 0, 0}, 56}} =
               PrefixPool.get_static_reservation(pool, @test_duid)
    end

    test "returns not_found for missing reservation" do
      config = %{
        name: "test-pd-pool",
        prefix: "2001:db8:1000::",
        prefix_length: 48,
        delegated_length: 56
      }

      {:ok, pool} = PrefixPool.new(config)

      assert :not_found = PrefixPool.get_static_reservation(pool, @test_duid)
    end
  end
end
