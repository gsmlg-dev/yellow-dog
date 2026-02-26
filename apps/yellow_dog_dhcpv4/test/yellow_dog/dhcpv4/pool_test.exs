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
      config =
        Map.put(@valid_config, :acl, %{
          allow: [%{type: "mac", pattern: "AA:BB:*"}],
          deny: [%{type: "vendor_class", value: "blocked"}]
        })

      assert {:ok, pool} = Pool.new(config)
      assert pool.acl.allow == [{:mac, "AA:BB:*"}]
      assert pool.acl.deny == [{:vendor_class, "blocked"}]
    end

    test "returns error for missing name" do
      assert {:error, _} =
               Pool.new(%{
                 subnet: "192.168.1.0/24",
                 range: %{start: "192.168.1.100", end: "192.168.1.200"}
               })
    end

    test "returns error for missing subnet" do
      assert {:error, _} =
               Pool.new(%{name: "lan", range: %{start: "192.168.1.100", end: "192.168.1.200"}})
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

    test "parses options with integer keys" do
      config = Map.put(@valid_config, :options, %{6 => "value", 15 => "domain"})
      assert {:ok, pool} = Pool.new(config)
      assert pool.options == %{6 => "value", 15 => "domain"}
    end

    test "parses options with string keys" do
      config = Map.put(@valid_config, :options, %{"6" => "value", "15" => "domain"})
      assert {:ok, pool} = Pool.new(config)
      assert pool.options == %{6 => "value", 15 => "domain"}
    end

    test "defaults to enabled true" do
      assert {:ok, pool} = Pool.new(@valid_config)
      assert pool.enabled == true
    end

    test "sets domain_name" do
      config = Map.put(@valid_config, :domain_name, "example.com")
      assert {:ok, pool} = Pool.new(config)
      assert pool.domain_name == "example.com"
    end

    test "supports legacy range_start/range_end fields" do
      config = %{
        name: "lan",
        subnet: "192.168.1.0/24",
        range_start: "192.168.1.100",
        range_end: "192.168.1.200"
      }

      assert {:ok, pool} = Pool.new(config)
      assert pool.range == {{192, 168, 1, 100}, {192, 168, 1, 200}}
    end

    test "supports legacy network field" do
      config = %{
        name: "lan",
        network: "192.168.1.0/24",
        range: %{start: "192.168.1.100", end: "192.168.1.200"}
      }

      assert {:ok, pool} = Pool.new(config)
      assert pool.subnet == {{192, 168, 1, 0}, 24}
    end

    test "parses lease_time from map with default and max" do
      config = Map.put(@valid_config, :lease_time, %{default: 7200, max: 14400})
      assert {:ok, pool} = Pool.new(config)
      assert pool.lease_time == %{default: 7200, max: 14400}
    end

    test "sets enabled to false when specified" do
      config = Map.put(@valid_config, :enabled, false)
      assert {:ok, pool} = Pool.new(config)
      assert pool.enabled == false
    end

    test "parses ACL option rule" do
      config =
        Map.put(@valid_config, :acl, %{
          allow: [%{type: "option", code: 60, value: "allowed-vendor"}],
          deny: []
        })

      assert {:ok, pool} = Pool.new(config)
      assert pool.acl.allow == [{:option, 60, "allowed-vendor"}]
    end

    test "parses ACL user_class rule" do
      config =
        Map.put(@valid_config, :acl, %{
          allow: [],
          deny: [%{type: "user_class", value: "restricted"}]
        })

      assert {:ok, pool} = Pool.new(config)
      assert pool.acl.deny == [{:user_class, "restricted"}]
    end

    test "returns error for invalid CIDR IP" do
      config = %{
        name: "lan",
        subnet: "999.999.999.999/24",
        range: %{start: "192.168.1.100", end: "192.168.1.200"}
      }

      assert {:error, _} = Pool.new(config)
    end

    test "returns error for invalid CIDR prefix" do
      config = %{
        name: "lan",
        subnet: "192.168.1.0/abc",
        range: %{start: "192.168.1.100", end: "192.168.1.200"}
      }

      assert {:error, _} = Pool.new(config)
    end

    test "returns error for invalid range start IP" do
      config = %{
        name: "lan",
        subnet: "192.168.1.0/24",
        range: %{start: "not-an-ip", end: "192.168.1.200"}
      }

      assert {:error, _} = Pool.new(config)
    end

    test "returns error for invalid range end IP" do
      config = %{
        name: "lan",
        subnet: "192.168.1.0/24",
        range: %{start: "192.168.1.100", end: "not-an-ip"}
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

    test "returns error for reservation outside subnet" do
      {:ok, pool} = Pool.new(@valid_config)

      # Inject a reservation with an IP outside the 192.168.1.0/24 subnet
      pool_with_bad_res = %{pool | reservations: %{"AA:BB:CC:DD:EE:FF" => {10, 0, 0, 1}}}
      assert {:error, _} = Pool.validate(pool_with_bad_res)
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

    test "includes reservations when present" do
      config = Map.put(@valid_config, :reservations, %{"aa:bb:cc:dd:ee:ff" => "192.168.1.50"})
      {:ok, pool} = Pool.new(config)
      toml = Pool.to_toml_map(pool)

      assert Map.has_key?(toml, "reservations")
      assert toml["reservations"]["AA:BB:CC:DD:EE:FF"] == "192.168.1.50"
    end

    test "includes ACL when rules are present" do
      config =
        Map.put(@valid_config, :acl, %{
          allow: [%{type: "mac", pattern: "AA:*"}],
          deny: []
        })

      {:ok, pool} = Pool.new(config)
      toml = Pool.to_toml_map(pool)

      assert Map.has_key?(toml, "acl")
      assert [%{"type" => "mac", "pattern" => "AA:*"}] = toml["acl"]["allow"]
    end

    test "lease_time is serialized as map" do
      config = Map.put(@valid_config, :lease_time, 1800)
      {:ok, pool} = Pool.new(config)
      toml = Pool.to_toml_map(pool)

      assert toml["lease_time"]["default"] == 1800
      assert toml["lease_time"]["max"] == 3600
    end
  end
end
