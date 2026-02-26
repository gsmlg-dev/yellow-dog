defmodule YellowDog.Dhcpv4.PoolConfigTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv4.PoolConfig

  describe "validate/1" do
    test "validates a complete pool configuration" do
      config = %{
        "name" => "office",
        "enabled" => true,
        "subnet" => "192.168.1.0/24",
        "ranges" => ["192.168.1.100-192.168.1.200"],
        "gateway" => "192.168.1.1",
        "dns_servers" => ["8.8.8.8", "8.8.4.4"],
        "domain" => "office.local",
        "lease_time" => 3600,
        "max_leases" => 100,
        "priority" => 10
      }

      assert {:ok, pool} = PoolConfig.validate(config)
      assert pool.name == "office"
      assert pool.enabled == true
      assert pool.subnet_mask == {255, 255, 255, 0}
      assert pool.gateway == {192, 168, 1, 1}
      assert pool.dns_servers == [{8, 8, 8, 8}, {8, 8, 4, 4}]
      assert pool.domain_name == "office.local"
      assert pool.lease_time == 3600
      assert pool.max_leases == 100
      assert pool.priority == 10
    end

    test "validates pool with ranges" do
      config = %{
        "name" => "test",
        "subnet" => "10.0.0.0/8",
        "gateway" => "10.0.0.1",
        "ranges" => ["10.0.0.100-10.0.0.200", "10.0.1.100-10.0.1.200"]
      }

      assert {:ok, pool} = PoolConfig.validate(config)
      assert length(pool.ranges) == 2

      [{start1, end1}, {start2, end2}] = pool.ranges
      assert start1 == {10, 0, 0, 100}
      assert end1 == {10, 0, 0, 200}
      assert start2 == {10, 0, 1, 100}
      assert end2 == {10, 0, 1, 200}
    end

    test "validates pool with reservations" do
      config = %{
        "name" => "test",
        "subnet" => "192.168.1.0/24",
        "gateway" => "192.168.1.1",
        "ranges" => ["192.168.1.100-192.168.1.200"],
        "reservations" => [
          %{
            "mac" => "aa:bb:cc:dd:ee:ff",
            "address" => "192.168.1.50"
          }
        ]
      }

      assert {:ok, pool} = PoolConfig.validate(config)
      assert map_size(pool.static_reservations) == 1

      # MAC is stored as uppercase string
      assert pool.static_reservations["AA:BB:CC:DD:EE:FF"] == {192, 168, 1, 50}
    end

    test "uses defaults for optional fields" do
      config = %{
        "name" => "minimal",
        "gateway" => "192.168.1.1",
        "ranges" => ["192.168.1.100-192.168.1.200"]
      }

      assert {:ok, pool} = PoolConfig.validate(config)
      assert pool.enabled == true
      assert pool.lease_time == 86400
      assert pool.max_leases == 1000
      assert pool.priority == 100
      assert pool.static_reservations == %{}
      # Default subnet mask is /24
      assert pool.subnet_mask == {255, 255, 255, 0}
    end

    test "returns error for missing name" do
      config = %{
        "gateway" => "192.168.1.1",
        "ranges" => ["192.168.1.100-192.168.1.200"]
      }

      assert {:error, :missing_name} = PoolConfig.validate(config)
    end

    test "returns error for missing gateway" do
      config = %{
        "name" => "test",
        "ranges" => ["192.168.1.100-192.168.1.200"]
      }

      assert {:error, :missing_gateway} = PoolConfig.validate(config)
    end

    test "returns error for missing ranges" do
      config = %{
        "name" => "test",
        "gateway" => "192.168.1.1"
      }

      assert {:error, :missing_ranges} = PoolConfig.validate(config)
    end

    test "returns error for empty ranges list" do
      config = %{
        "name" => "test",
        "gateway" => "192.168.1.1",
        "ranges" => []
      }

      assert {:error, :empty_ranges} = PoolConfig.validate(config)
    end

    test "returns error for invalid subnet format" do
      config = %{
        "name" => "test",
        "subnet" => "invalid",
        "gateway" => "192.168.1.1",
        "ranges" => ["192.168.1.100-192.168.1.200"]
      }

      assert {:error, {:invalid_subnet_format, "invalid"}} = PoolConfig.validate(config)
    end

    test "returns error for invalid IP in range" do
      config = %{
        "name" => "test",
        "gateway" => "192.168.1.1",
        "ranges" => ["192.168.1.100-invalid"]
      }

      assert {:error, {:invalid_ranges, _}} = PoolConfig.validate(config)
    end

    test "returns error for invalid MAC in reservation" do
      config = %{
        "name" => "test",
        "gateway" => "192.168.1.1",
        "ranges" => ["192.168.1.100-192.168.1.200"],
        "reservations" => [
          %{
            "mac" => "invalid-mac",
            "address" => "192.168.1.50"
          }
        ]
      }

      assert {:error, {:invalid_reservations, _}} = PoolConfig.validate(config)
    end
  end

  describe "to_address_pool_config/1" do
    test "converts pool config to AddressPool format" do
      pool = %{
        name: "office",
        enabled: true,
        ranges: [{{192, 168, 1, 100}, {192, 168, 1, 200}}],
        range_start: {192, 168, 1, 100},
        range_end: {192, 168, 1, 200},
        excluded_ranges: [],
        subnet_mask: {255, 255, 255, 0},
        gateway: {192, 168, 1, 1},
        dns_servers: [{8, 8, 8, 8}],
        domain_name: "office.local",
        lease_time: 3600,
        max_leases: 100,
        priority: 10,
        static_reservations: %{}
      }

      result = PoolConfig.to_address_pool_config(pool)

      assert result.name == "office"
      assert result.range_start == {192, 168, 1, 100}
      assert result.range_end == {192, 168, 1, 200}
      assert result.subnet_mask == {255, 255, 255, 0}
      assert result.gateway == {192, 168, 1, 1}
      assert result.dns_servers == [{8, 8, 8, 8}]
      assert result.domain_name == "office.local"
      assert result.lease_time == 3600
    end

    test "calculates subnet mask correctly for /8" do
      config = %{
        "name" => "test",
        "subnet" => "10.0.0.0/8",
        "gateway" => "10.0.0.1",
        "ranges" => ["10.0.0.100-10.0.0.200"]
      }

      {:ok, pool} = PoolConfig.validate(config)
      assert pool.subnet_mask == {255, 0, 0, 0}
    end

    test "calculates subnet mask correctly for /16" do
      config = %{
        "name" => "test",
        "subnet" => "172.16.0.0/16",
        "gateway" => "172.16.0.1",
        "ranges" => ["172.16.0.100-172.16.0.200"]
      }

      {:ok, pool} = PoolConfig.validate(config)
      assert pool.subnet_mask == {255, 255, 0, 0}
    end
  end

  describe "load_with_fallback/1" do
    test "returns default list for non-existent file" do
      assert PoolConfig.load_with_fallback("/nonexistent/path.toml") == []
    end

    test "returns provided defaults for non-existent file" do
      defaults = [%{name: "default", ranges: []}]
      assert PoolConfig.load_with_fallback("/nonexistent/path.toml", defaults) == defaults
    end
  end
end
