defmodule YellowDog.Config.TransformTest do
  use ExUnit.Case, async: true

  alias YellowDog.Config.Transform

  describe "apply/1 - Complete Section Transformation" do
    test "transforms core section with boolean values" do
      config = %{"core" => %{"dns" => true, "mdns" => false, "dhcpv4" => true, "dhcpv6" => false}}
      result = Transform.apply(config)

      assert result["core"][:dns] == true
      assert result["core"][:mdns] == false
      assert result["core"][:dhcpv4] == true
      assert result["core"][:dhcpv6] == false
    end

    test "transforms DNS section with IP addresses and atom keys" do
      config = %{
        "dns" => %{
          "port" => 5353,
          "listen" => "127.0.0.1",
          "mode" => "authoritative",
          "upstream_servers" => ["8.8.8.8", "1.1.1.1"],
          "worker_pool_size" => 10,
          "cache_ttl" => 300
        }
      }

      result = Transform.apply(config)

      assert result["dns"][:port] == 5353
      assert result["dns"][:listen] == {127, 0, 0, 1}
      assert result["dns"][:mode] == :authoritative
      assert result["dns"][:upstream_servers] == [{{8, 8, 8, 8}, 53}, {{1, 1, 1, 1}, 53}]
      assert result["dns"][:worker_pool_size] == 10
      assert result["dns"][:cache_ttl] == 300
    end

    test "transforms DNS zones with type atoms" do
      config = %{
        "dns" => %{
          "zones" => %{
            "example_com" => %{"type" => "authoritative", "file" => "zones/example.com.zone"},
            "forward_zone" => %{"type" => "forward"}
          }
        }
      }

      result = Transform.apply(config)

      assert result["dns"][:zones]["example_com"][:type] == :authoritative
      assert result["dns"][:zones]["example_com"][:file] == "zones/example.com.zone"
      assert result["dns"][:zones]["forward_zone"][:type] == :forward
    end

    test "transforms mDNS section with multicast addresses" do
      config = %{
        "mdns" => %{
          "port" => 5353,
          "listen" => "224.0.0.251",
          "multicast_address" => "224.0.0.251"
        }
      }

      result = Transform.apply(config)

      assert result["mdns"][:port] == 5353
      assert result["mdns"][:listen] == {224, 0, 0, 251}
      assert result["mdns"][:multicast_address] == {224, 0, 0, 251}
    end

    test "transforms DHCPv4 section with pools" do
      config = %{
        "dhcpv4" => %{
          "port" => 67,
          "listen" => "0.0.0.0",
          "lease_time" => 3600,
          "pools" => [
            %{
              "name" => "office",
              "subnet" => "192.168.1.0/24",
              "range_start" => "192.168.1.100",
              "range_end" => "192.168.1.200",
              "gateway" => "192.168.1.1",
              "dns_servers" => ["8.8.8.8"],
              "lease_time" => 7200
            }
          ]
        }
      }

      result = Transform.apply(config)

      assert result["dhcpv4"][:port] == 67
      assert result["dhcpv4"][:listen] == {0, 0, 0, 0}
      assert result["dhcpv4"][:lease_time] == 3600

      [pool] = result["dhcpv4"][:pools]
      assert pool[:name] == "office"
      assert pool[:subnet] == "192.168.1.0/24"
      assert pool[:range_start] == {192, 168, 1, 100}
      assert pool[:range_end] == {192, 168, 1, 200}
      assert pool[:gateway] == {192, 168, 1, 1}
      assert pool[:dns_servers] == [{8, 8, 8, 8}]
      assert pool[:lease_time] == 7200
    end

    test "transforms DHCPv6 section with IPv6 pools" do
      config = %{
        "dhcpv6" => %{
          "port" => 547,
          "listen" => "::",
          "pools" => [
            %{
              "name" => "ipv6_pool",
              "prefix" => "2001:db8::/64",
              "dns_servers" => ["2001:4860:4860::8888"],
              "lease_time" => 7200
            }
          ]
        }
      }

      result = Transform.apply(config)

      assert result["dhcpv6"][:port] == 547
      assert result["dhcpv6"][:listen] == {0, 0, 0, 0, 0, 0, 0, 0}

      [pool] = result["dhcpv6"][:pools]
      assert pool[:name] == "ipv6_pool"
      assert pool[:prefix] == "2001:db8::/64"
      assert is_list(pool[:dns_servers])
      assert length(pool[:dns_servers]) == 1
      assert pool[:lease_time] == 7200
    end

    test "handles invalid IP addresses gracefully" do
      config = %{
        "dns" => %{"listen" => "invalid.ip.address"},
        "dhcpv6" => %{"listen" => "invalid::ipv6"}
      }

      result = Transform.apply(config)

      # Invalid IPs should remain as strings
      assert result["dns"][:listen] == "invalid.ip.address"
      assert result["dhcpv6"][:listen] == "invalid::ipv6"
    end

    test "preserves sections not defined in transformations" do
      config = %{
        "core" => %{"dns" => true},
        "dns" => %{"port" => 53},
        "unknown_section" => %{"key" => "value"}
      }

      result = Transform.apply(config)

      # Known sections are transformed
      assert result["core"][:dns] == true
      assert result["dns"][:port] == 53

      # Unknown sections are preserved as-is
      assert result["unknown_section"] == %{"key" => "value"}
    end
  end

  describe "Integration with TOML Decoding" do
    test "transforms complete TOML document" do
      toml_content = """
      [core]
      dns = true
      mdns = false
      dhcpv4 = true
      dhcpv6 = false

      [dns]
      port = 5353
      listen = "127.0.0.1"
      mode = "authoritative"
      upstream_servers = ["8.8.8.8", "1.1.1.1"]
      worker_pool_size = 10

      [dhcpv4]
      port = 6767
      listen = "0.0.0.0"
      """

      {:ok, raw_config} = Toml.decode(toml_content)
      config = Transform.apply(raw_config)

      # Verify core section
      assert config["core"][:dns] == true
      assert config["core"][:mdns] == false
      assert config["core"][:dhcpv4] == true
      assert config["core"][:dhcpv6] == false

      # Verify DNS section
      assert config["dns"][:port] == 5353
      assert config["dns"][:listen] == {127, 0, 0, 1}
      assert config["dns"][:mode] == :authoritative
      assert config["dns"][:upstream_servers] == [{{8, 8, 8, 8}, 53}, {{1, 1, 1, 1}, 53}]
      assert config["dns"][:worker_pool_size] == 10

      # Verify DHCPv4 section
      assert config["dhcpv4"][:port] == 6767
      assert config["dhcpv4"][:listen] == {0, 0, 0, 0}
    end
  end
end
