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

    test "rejects empty connection.id" do
      toml = %{"connection" => %{"id" => "", "type" => "ethernet"}}
      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "must not be empty"
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

    test "rejects interface name longer than 15 characters" do
      toml = %{
        "connection" => %{
          "id" => "test",
          "type" => "ethernet",
          "interface" => "this_name_is_way_too_long"
        }
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "at most 15"
    end

    test "rejects interface name with spaces" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet", "interface" => "eth 0"}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "invalid characters"
    end

    test "rejects empty interface name" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet", "interface" => ""}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "must not be empty"
    end

    test "accepts nil interface (wildcard match)" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"}
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.interface == nil
    end

    test "rejects manual ipv4 without address" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ipv4" => %{"method" => "manual"}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "address is required"
    end

    test "rejects manual ipv4 with invalid CIDR" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ipv4" => %{"method" => "manual", "address" => "not-an-ip"}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "valid CIDR"
    end

    test "rejects manual ipv4 with non-string address (valid_cidr? catch-all, line 284)" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ipv4" => %{"method" => "manual", "address" => 12345}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "valid CIDR"
    end

    test "accepts manual ipv4 with valid CIDR" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ipv4" => %{
          "method" => "manual",
          "address" => "192.168.1.100/24",
          "gateway" => "192.168.1.1"
        }
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.ipv4.address == "192.168.1.100/24"
    end

    test "rejects IPv4 CIDR with prefix > 32" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ipv4" => %{"method" => "manual", "address" => "192.168.1.1/64"}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "valid CIDR"
    end

    test "accepts IPv6 CIDR with prefix <= 128" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet"},
        "ipv6" => %{"method" => "manual", "address" => "2001:db8::1/64"}
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.ipv6.address == "2001:db8::1/64"
    end

    test "rejects interface name with colons" do
      toml = %{
        "connection" => %{"id" => "test", "type" => "ethernet", "interface" => "eth0:0"}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "invalid characters"
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

  describe "connection.id validation" do
    test "rejects id longer than 128 characters" do
      long_id = String.duplicate("a", 129)
      toml = %{"connection" => %{"id" => long_id, "type" => "ethernet"}}
      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "too long"
    end

    test "accepts id of exactly 128 characters" do
      id = String.duplicate("a", 128)
      toml = %{"connection" => %{"id" => id, "type" => "ethernet"}}
      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.id == id
    end

    test "rejects id with slashes" do
      toml = %{"connection" => %{"id" => "path/traversal", "type" => "ethernet"}}
      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "invalid characters"
    end

    test "rejects id with spaces" do
      toml = %{"connection" => %{"id" => "has spaces", "type" => "ethernet"}}
      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "invalid characters"
    end

    test "accepts id with dots, hyphens, underscores" do
      toml = %{"connection" => %{"id" => "my-profile_v1.0", "type" => "ethernet"}}
      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.id == "my-profile_v1.0"
    end
  end

  describe "autoconnect_priority validation" do
    test "accepts minimum boundary (-1000)" do
      toml = %{
        "connection" => %{
          "id" => "pri-min",
          "type" => "ethernet",
          "autoconnect_priority" => -1000
        }
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.autoconnect_priority == -1000
    end

    test "accepts maximum boundary (10000)" do
      toml = %{
        "connection" => %{
          "id" => "pri-max",
          "type" => "ethernet",
          "autoconnect_priority" => 10_000
        }
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.autoconnect_priority == 10_000
    end

    test "rejects priority below minimum (-1001)" do
      toml = %{
        "connection" => %{
          "id" => "pri-low",
          "type" => "ethernet",
          "autoconnect_priority" => -1001
        }
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "autoconnect_priority"
    end

    test "rejects priority above maximum (10001)" do
      toml = %{
        "connection" => %{
          "id" => "pri-high",
          "type" => "ethernet",
          "autoconnect_priority" => 10_001
        }
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "autoconnect_priority"
    end

    test "defaults non-integer priority to 0" do
      toml = %{
        "connection" => %{
          "id" => "pri-str",
          "type" => "ethernet",
          "autoconnect_priority" => "high"
        }
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.autoconnect_priority == 0
    end
  end

  describe "zone validation" do
    test "rejects zone longer than 64 characters" do
      long_zone = String.duplicate("a", 65)

      toml = %{
        "connection" => %{"id" => "zone-long", "type" => "ethernet", "zone" => long_zone}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "zone"
    end

    test "accepts zone of exactly 64 characters" do
      zone = String.duplicate("a", 64)
      toml = %{"connection" => %{"id" => "zone-ok", "type" => "ethernet", "zone" => zone}}
      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.zone == zone
    end

    test "rejects zone with spaces" do
      toml = %{
        "connection" => %{"id" => "zone-sp", "type" => "ethernet", "zone" => "my zone"}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "zone"
    end

    test "defaults non-string zone to default" do
      toml = %{"connection" => %{"id" => "zone-int", "type" => "ethernet", "zone" => 42}}
      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.zone == "default"
    end
  end

  describe "gateway validation" do
    test "rejects invalid gateway IP address" do
      toml = %{
        "connection" => %{"id" => "gw-test", "type" => "ethernet"},
        "ipv4" => %{"method" => "manual", "address" => "10.0.0.1/24", "gateway" => "not-an-ip"}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "ipv4.gateway"
    end

    test "accepts valid gateway IP address" do
      toml = %{
        "connection" => %{"id" => "gw-ok", "type" => "ethernet"},
        "ipv4" => %{
          "method" => "manual",
          "address" => "10.0.0.1/24",
          "gateway" => "10.0.0.254"
        }
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.ipv4.gateway == "10.0.0.254"
    end

    test "accepts nil gateway" do
      toml = %{
        "connection" => %{"id" => "gw-nil", "type" => "ethernet"},
        "ipv4" => %{"method" => "auto"}
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.ipv4.gateway == nil
    end
  end

  describe "DNS validation" do
    test "rejects invalid DNS server address" do
      toml = %{
        "connection" => %{"id" => "dns-test", "type" => "ethernet"},
        "ipv4" => %{"method" => "auto", "dns" => ["8.8.8.8", "not-valid"]}
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "ipv4.dns"
    end

    test "accepts valid DNS server addresses" do
      toml = %{
        "connection" => %{"id" => "dns-ok", "type" => "ethernet"},
        "ipv4" => %{"method" => "auto", "dns" => ["8.8.8.8", "1.1.1.1"]}
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.ipv4.dns == ["8.8.8.8", "1.1.1.1"]
    end

    test "accepts IPv6 DNS servers" do
      toml = %{
        "connection" => %{"id" => "dns6", "type" => "ethernet"},
        "ipv6" => %{"method" => "auto", "dns" => ["2001:4860:4860::8888"]}
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.ipv6.dns == ["2001:4860:4860::8888"]
    end
  end

  describe "dns_search" do
    test "parses ipv4 dns_search domains" do
      toml = %{
        "connection" => %{"id" => "search-test", "type" => "ethernet"},
        "ipv4" => %{
          "method" => "auto",
          "dns" => ["8.8.8.8"],
          "dns_search" => ["example.com", "corp.internal"]
        }
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.ipv4.dns_search == ["example.com", "corp.internal"]
    end

    test "parses ipv6 dns_search domains" do
      toml = %{
        "connection" => %{"id" => "search-test6", "type" => "ethernet"},
        "ipv6" => %{
          "method" => "auto",
          "dns_search" => ["v6.example.com"]
        }
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.ipv6.dns_search == ["v6.example.com"]
    end

    test "defaults dns_search to empty list" do
      toml = %{
        "connection" => %{"id" => "no-search", "type" => "ethernet"}
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      assert profile.ipv4.dns_search == []
      assert profile.ipv6.dns_search == []
    end

    test "rejects invalid dns_search domain names" do
      toml = %{
        "connection" => %{"id" => "bad-search", "type" => "ethernet"},
        "ipv4" => %{
          "method" => "auto",
          "dns_search" => ["valid.com", "inv@lid..com"]
        }
      }

      assert {:error, msg} = Profile.from_toml(toml)
      assert msg =~ "dns_search"
    end

    test "round-trips dns_search through to_toml" do
      toml = %{
        "connection" => %{"id" => "roundtrip", "type" => "ethernet"},
        "ipv4" => %{
          "method" => "manual",
          "address" => "10.0.0.1/24",
          "dns" => ["8.8.8.8"],
          "dns_search" => ["example.com"]
        }
      }

      assert {:ok, profile} = Profile.from_toml(toml)
      serialized = Profile.to_toml(profile)
      assert serialized["ipv4"]["dns_search"] == ["example.com"]
    end
  end
end
