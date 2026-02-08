defmodule YellowDog.Dhcpv6.PoolTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv6.Pool

  @valid_config %{
    name: "ipv6-lan",
    prefix: "2001:db8::/48",
    range: %{start: "2001:db8::100", end: "2001:db8::200"}
  }

  describe "new/1" do
    test "creates pool from CIDR string" do
      assert {:ok, pool} = Pool.new(@valid_config)
      assert pool.name == "ipv6-lan"
      assert pool.prefix == {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, 48}

      assert pool.range ==
               {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x100}, {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x200}}
    end

    test "creates pool from structured prefix" do
      config = %{
        name: "ipv6-lan",
        prefix: %{address: "2001:db8::", prefix_len: 48},
        range: %{start: "2001:db8::100", end: "2001:db8::200"}
      }

      assert {:ok, pool} = Pool.new(config)
      assert pool.prefix == {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, 48}
    end

    test "creates pool from string-keyed map" do
      config = %{
        "name" => "ipv6-lan",
        "prefix" => %{"address" => "2001:db8::", "prefix_len" => 48},
        "range" => %{"start" => "2001:db8::100", "end" => "2001:db8::200"}
      }

      assert {:ok, pool} = Pool.new(config)
      assert pool.name == "ipv6-lan"
    end

    test "defaults mode to :stateful" do
      assert {:ok, pool} = Pool.new(@valid_config)
      assert pool.mode == :stateful
    end

    test "parses mode from string" do
      config = Map.put(@valid_config, :mode, "slaac")
      assert {:ok, pool} = Pool.new(config)
      assert pool.mode == :slaac
    end

    test "range is optional for SLAAC mode" do
      config = %{name: "slaac-pool", prefix: "2001:db8::/64", mode: :slaac}
      assert {:ok, pool} = Pool.new(config)
      assert pool.range == nil
    end

    test "parses dns_servers" do
      config =
        Map.put(@valid_config, :dns_servers, ["2001:4860:4860::8888", "2001:4860:4860::8844"])

      assert {:ok, pool} = Pool.new(config)
      assert length(pool.dns_servers) == 2
    end

    test "parses reservations and normalizes DUIDs" do
      config = Map.put(@valid_config, :reservations, %{"aa:bb:cc:dd" => "2001:db8::50"})
      assert {:ok, pool} = Pool.new(config)
      assert pool.reservations == %{"AA:BB:CC:DD" => {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x50}}
    end

    test "parses PD pools" do
      config =
        Map.put(@valid_config, :pd_pools, [
          %{prefix: "2001:db8:1::", length: 48, delegated_len: 56}
        ])

      assert {:ok, pool} = Pool.new(config)

      assert [%{prefix: {0x2001, 0x0DB8, 1, 0, 0, 0, 0, 0}, length: 48, delegated_len: 56}] =
               pool.pd_pools
    end

    test "parses lifetimes" do
      config = Map.put(@valid_config, :lifetimes, %{preferred: 1800, valid: 3600})
      assert {:ok, pool} = Pool.new(config)
      assert pool.lifetimes == %{preferred: 1800, valid: 3600}
    end

    test "sets default lifetimes" do
      assert {:ok, pool} = Pool.new(@valid_config)
      assert pool.lifetimes == %{preferred: 3600, valid: 7200}
    end

    test "parses ACL rules" do
      config =
        Map.put(@valid_config, :acl, %{
          allow: [%{type: "duid", pattern: "0001*"}],
          deny: [%{type: "vendor_class", value: "blocked"}]
        })

      assert {:ok, pool} = Pool.new(config)
      assert pool.acl.allow == [{:duid, "0001*"}]
      assert pool.acl.deny == [{:vendor_class, "blocked"}]
    end

    test "returns error for missing name" do
      assert {:error, _} = Pool.new(%{prefix: "2001:db8::/48"})
    end

    test "returns error for missing prefix" do
      assert {:error, _} = Pool.new(%{name: "pool"})
    end

    test "returns error for invalid prefix address" do
      assert {:error, _} = Pool.new(%{name: "pool", prefix: "not-valid/48"})
    end

    test "parses options with integer keys" do
      config = Map.put(@valid_config, :options, %{23 => "dns-servers", 24 => "domain-list"})
      assert {:ok, pool} = Pool.new(config)
      assert pool.options == %{23 => "dns-servers", 24 => "domain-list"}
    end

    test "parses options with string keys" do
      config = Map.put(@valid_config, :options, %{"23" => "dns-servers", "24" => "domain-list"})
      assert {:ok, pool} = Pool.new(config)
      assert pool.options == %{23 => "dns-servers", 24 => "domain-list"}
    end

    test "parses stateless mode" do
      config = Map.put(@valid_config, :mode, "stateless")
      assert {:ok, pool} = Pool.new(config)
      assert pool.mode == :stateless
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

    test "supports legacy network field" do
      config = %{
        name: "v6-pool",
        network: "2001:db8::/48",
        range: %{start: "2001:db8::100", end: "2001:db8::200"}
      }

      assert {:ok, pool} = Pool.new(config)
      assert {_, 48} = pool.prefix
    end

    test "parses option ACL rules from string-keyed maps" do
      config =
        Map.put(@valid_config, :acl, %{
          "allow" => [%{"type" => "duid", "pattern" => "0001*"}],
          "deny" => [%{"type" => "option", "code" => 16, "value" => "test"}]
        })

      assert {:ok, pool} = Pool.new(config)
      assert pool.acl.allow == [{:duid, "0001*"}]
      assert pool.acl.deny == [{:option, 16, "test"}]
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

    test "returns error for invalid lifetimes" do
      {:ok, pool} = Pool.new(@valid_config)
      assert {:error, _} = Pool.validate(%{pool | lifetimes: %{preferred: 7200, valid: 3600}})
    end
  end

  describe "to_toml_map/1" do
    test "serializes pool to map" do
      {:ok, pool} = Pool.new(@valid_config)
      toml = Pool.to_toml_map(pool)

      assert toml["name"] == "ipv6-lan"
      assert toml["enabled"] == true
      assert toml["mode"] == "stateful"
      assert is_map(toml["prefix"])
      assert is_binary(toml["prefix"]["address"])
      assert toml["prefix"]["prefix_len"] == 48
      assert toml["max_leases"] == 1000
    end

    test "includes range when set" do
      {:ok, pool} = Pool.new(@valid_config)
      toml = Pool.to_toml_map(pool)

      assert is_map(toml["range"])
      assert is_binary(toml["range"]["start"])
      assert is_binary(toml["range"]["end"])
    end

    test "omits nil range for SLAAC pool" do
      config = %{name: "slaac", prefix: "2001:db8::/64", mode: :slaac}
      {:ok, pool} = Pool.new(config)
      toml = Pool.to_toml_map(pool)

      refute Map.has_key?(toml, "range")
    end

    test "omits empty optional fields" do
      {:ok, pool} = Pool.new(@valid_config)
      toml = Pool.to_toml_map(pool)

      refute Map.has_key?(toml, "domain_name")
      refute Map.has_key?(toml, "dns_servers")
      refute Map.has_key?(toml, "reservations")
      refute Map.has_key?(toml, "acl")
      refute Map.has_key?(toml, "pd_pools")
    end
  end
end
