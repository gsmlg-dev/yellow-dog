defmodule YellowDog.Netman.Types.ProfileTest do
  use ExUnit.Case, async: true

  alias YellowDog.Netman.Types.Profile

  describe "from_toml/1" do
    test "parses a valid DHCP ethernet profile" do
      toml = %{
        "connection" => %{
          "id" => "test-eth",
          "type" => "ethernet",
          "interface" => "eth0",
          "autoconnect" => true,
          "autoconnect_priority" => 100,
          "zone" => "trusted"
        },
        "ethernet" => %{"mtu" => 1500},
        "ipv4" => %{"method" => "auto"},
        "ipv6" => %{"method" => "auto"}
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.id == "test-eth"
      assert profile.type == :ethernet
      assert profile.interface == "eth0"
      assert profile.autoconnect == true
      assert profile.autoconnect_priority == 100
      assert profile.zone == "trusted"
      assert profile.ethernet.mtu == 1500
      assert profile.ipv4.method == :auto
      assert profile.ipv6.method == :auto
    end

    test "parses a static IP profile" do
      toml = %{
        "connection" => %{
          "id" => "static-test",
          "type" => "ethernet"
        },
        "ipv4" => %{
          "method" => "manual",
          "address" => "192.168.1.100/24",
          "gateway" => "192.168.1.1",
          "dns" => ["192.168.1.1", "8.8.8.8"]
        }
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.ipv4.method == :manual
      assert profile.ipv4.address == "192.168.1.100/24"
      assert profile.ipv4.gateway == "192.168.1.1"
      assert profile.ipv4.dns == ["192.168.1.1", "8.8.8.8"]
    end

    test "uses defaults for missing optional fields" do
      toml = %{
        "connection" => %{
          "id" => "minimal",
          "type" => "ethernet"
        }
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.autoconnect == true
      assert profile.autoconnect_priority == 0
      assert profile.zone == "default"
      assert profile.ethernet.mtu == nil
      assert profile.ipv4.method == :auto
      assert profile.ipv6.method == :auto
    end

    test "rejects missing connection.id" do
      toml = %{"connection" => %{"type" => "ethernet"}}
      assert {:error, _} = Profile.from_toml(toml)
    end

    test "rejects missing connection.type" do
      toml = %{"connection" => %{"id" => "test"}}
      assert {:error, _} = Profile.from_toml(toml)
    end

    test "rejects invalid connection.type" do
      toml = %{"connection" => %{"id" => "test", "type" => "bluetooth"}}
      assert {:error, _} = Profile.from_toml(toml)
    end

    test "rejects invalid ipv4.method" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ipv4" => %{"method" => "invalid"}
      }

      assert {:error, _} = Profile.from_toml(toml)
    end

    test "rejects invalid MTU" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ethernet" => %{"mtu" => 10}
      }

      assert {:error, _} = Profile.from_toml(toml)
    end

    test "parses link-local IPv6" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ipv6" => %{"method" => "link-local"}
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.ipv6.method == :link_local
    end
  end

  describe "to_toml/1" do
    test "round-trips a profile" do
      original = %Profile{
        id: "round-trip",
        type: :ethernet,
        interface: "eth0",
        autoconnect: true,
        autoconnect_priority: 100,
        zone: "trusted",
        ethernet: %{mtu: 1500},
        ipv4: %{method: :manual, address: "10.0.0.1/24", gateway: "10.0.0.1", dns: ["8.8.8.8"]},
        ipv6: %{method: :disabled, address: nil, gateway: nil, dns: []}
      }

      toml_map = Profile.to_toml(original)
      assert {:ok, parsed} = Profile.from_toml(toml_map)

      assert parsed.id == original.id
      assert parsed.type == original.type
      assert parsed.interface == original.interface
      assert parsed.ipv4.method == original.ipv4.method
      assert parsed.ipv4.address == original.ipv4.address
    end

    test "minimal profile round-trips" do
      original = %Profile{
        id: "minimal",
        type: :ethernet,
        ipv4: %{method: :auto, address: nil, gateway: nil, dns: []},
        ipv6: %{method: :auto, address: nil, gateway: nil, dns: []}
      }

      toml_map = Profile.to_toml(original)
      assert {:ok, parsed} = Profile.from_toml(toml_map)
      assert parsed.id == original.id
      assert parsed.type == original.type
    end
  end
end
