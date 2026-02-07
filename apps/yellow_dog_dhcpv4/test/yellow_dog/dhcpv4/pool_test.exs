defmodule YellowDog.Dhcpv4.PoolTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv4.Pool

  @valid_config %{
    name: "lan",
    subnet: "192.168.1.0/24",
    range: %{start: "192.168.1.100", end: "192.168.1.200"}
  }

  describe "new/1" do
    test "creates pool from CIDR string" do
      assert {:ok, pool} = Pool.new(@valid_config)
      assert pool.name == "lan"
      assert pool.subnet == {{192, 168, 1, 0}, 24}
      assert pool.range == {{192, 168, 1, 100}, {192, 168, 1, 200}}
    end

    test "creates pool from structured subnet" do
      config = %{
        name: "lan",
        subnet: %{address: "192.168.1.0", prefix_len: 24},
        range: %{start: "192.168.1.100", end: "192.168.1.200"}
      }

      assert {:ok, pool} = Pool.new(config)
      assert pool.subnet == {{192, 168, 1, 0}, 24}
    end

    test "creates pool from string-keyed map" do
      config = %{
        "name" => "lan",
        "subnet" => %{"address" => "192.168.1.0", "prefix_len" => 24},
        "range" => %{"start" => "192.168.1.100", "end" => "192.168.1.200"}
      }

      assert {:ok, pool} = Pool.new(config)
      assert pool.name == "lan"
    end

    test "parses gateway" do
      config = Map.put(@valid_config, :gateway, "192.168.1.1")
      assert {:ok, pool} = Pool.new(config)
      assert pool.gateway == {192, 168, 1, 1}
    end

    test "parses dns_servers" do
      config = Map.put(@valid_config, :dns_servers, ["8.8.8.8", "8.8.4.4"])
      assert {:ok, pool} = Pool.new(config)
      assert pool.dns_servers == [{8, 8, 8, 8}, {8, 8, 4, 4}]
    end

    test "parses reservations and normalizes MACs" do
      config = Map.put(@valid_config, :reservations, %{"aa:bb:cc:dd:ee:ff" => "192.168.1.50"})
      assert {:ok, pool} = Pool.new(config)
      assert pool.reservations == %{"AA:BB:CC:DD:EE:FF" => {192, 168, 1, 50}}
    end

    test "sets default lease_time" do
      assert {:ok, pool} = Pool.new(@valid_config)
      assert pool.lease_time == %{default: 3600, max: 86400}
    end

    test "parses lease_time from integer" do
      config = Map.put(@valid_config, :lease_time, 1800)
      assert {:ok, pool} = Pool.new(config)
      assert pool.lease_time == %{default: 1800, max: 3600}
    end

    test "parses ACL rules" do
      config = Map.put(@valid_config, :acl, %{
        allow: [%{type: "mac", pattern: "AA:BB:*"}],
        deny: [%{type: "vendor_class", value: "blocked"}]
      })

      assert {:ok, pool} = Pool.new(config)
      assert pool.acl.allow == [{:mac, "AA:BB:*"}]
      assert pool.acl.deny == [{:vendor_class, "blocked"}]
    end

    test "returns error for missing name" do
      assert {:error, _} = Pool.new(%{subnet: "192.168.1.0/24", range: %{start: "192.168.1.100", end: "192.168.1.200"}})
    end

    test "returns error for missing subnet" do
      assert {:error, _} = Pool.new(%{name: "lan", range: %{start: "192.168.1.100", end: "192.168.1.200"}})
    end

    test "returns error for missing range" do
      assert {:error, _} = Pool.new(%{name: "lan", subnet: "192.168.1.0/24"})
    end

    test "returns error for range outside subnet" do
      config = %{
        name: "lan",
        subnet: "10.0.0.0/24",
        range: %{start: "192.168.1.100", end: "192.168.1.200"}
      }

      assert {:error, _} = Pool.new(config)
    end

    test "returns error for inverted range" do
      config = %{
        name: "lan",
        subnet: "192.168.1.0/24",
        range: %{start: "192.168.1.200", end: "192.168.1.100"}
      }

      assert {:error, _} = Pool.new(config)
    end
  end

  describe "validate/1" do
    test "returns :ok for valid pool" do
      {:ok, pool} = Pool.new(@valid_config)
      assert :ok = Pool.validate(pool)
    end

    test "returns error for nil name" do
      {:ok, pool} = Pool.new(@valid_config)
      assert {:error, _} = Pool.validate(%{pool | name: nil})
    end

    test "returns error for empty name" do
      {:ok, pool} = Pool.new(@valid_config)
      assert {:error, _} = Pool.validate(%{pool | name: ""})
    end
  end

  describe "to_toml_map/1" do
    test "serializes pool to map" do
      {:ok, pool} = Pool.new(@valid_config)
      toml = Pool.to_toml_map(pool)

      assert toml["name"] == "lan"
      assert toml["enabled"] == true
      assert toml["subnet"]["address"] == "192.168.1.0"
      assert toml["subnet"]["prefix_len"] == 24
      assert toml["range"]["start"] == "192.168.1.100"
      assert toml["range"]["end"] == "192.168.1.200"
      assert toml["max_leases"] == 1000
    end

    test "includes gateway when set" do
      config = Map.put(@valid_config, :gateway, "192.168.1.1")
      {:ok, pool} = Pool.new(config)
      toml = Pool.to_toml_map(pool)

      assert toml["gateway"] == "192.168.1.1"
    end

    test "omits empty optional fields" do
      {:ok, pool} = Pool.new(@valid_config)
      toml = Pool.to_toml_map(pool)

      refute Map.has_key?(toml, "gateway")
      refute Map.has_key?(toml, "domain_name")
      refute Map.has_key?(toml, "dns_servers")
      refute Map.has_key?(toml, "reservations")
      refute Map.has_key?(toml, "acl")
    end
  end
end
