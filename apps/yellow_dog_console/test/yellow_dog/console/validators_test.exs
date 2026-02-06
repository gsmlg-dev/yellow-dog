defmodule YellowDog.Console.ValidatorsTest do
  use ExUnit.Case, async: true

  alias YellowDog.Console.Validators

  describe "validate_ip/2" do
    test "validates valid IPv4 addresses" do
      assert :ok == Validators.validate_ip("192.168.1.1", :ipv4)
      assert :ok == Validators.validate_ip("0.0.0.0", :ipv4)
      assert :ok == Validators.validate_ip("255.255.255.255", :ipv4)
    end

    test "validates valid IPv6 addresses" do
      assert :ok == Validators.validate_ip("::1", :ipv6)
      assert :ok == Validators.validate_ip("2001:0db8:85a3:0000:0000:8a2e:0370:7334", :ipv6)
      assert :ok == Validators.validate_ip("::", :ipv6)
    end

    test "rejects invalid IPv4 addresses" do
      assert {:error, _} = Validators.validate_ip("256.1.1.1", :ipv4)
      assert {:error, _} = Validators.validate_ip("192.168.1", :ipv4)
      assert {:error, _} = Validators.validate_ip("invalid", :ipv4)
    end

    test "rejects IPv4 when expecting IPv6" do
      assert {:error, message} = Validators.validate_ip("192.168.1.1", :ipv6)
      assert message =~ "must be a valid IPv6 address"
    end

    test "rejects IPv6 when expecting IPv4" do
      assert {:error, message} = Validators.validate_ip("::1", :ipv4)
      assert message =~ "must be a valid IPv4 address"
    end
  end

  describe "validate_port/1" do
    test "validates valid ports" do
      assert :ok == Validators.validate_port(1)
      assert :ok == Validators.validate_port(53)
      assert :ok == Validators.validate_port(8080)
      assert :ok == Validators.validate_port(65_535)
    end

    test "rejects invalid ports" do
      assert {:error, message} = Validators.validate_port(0)
      assert message =~ "between 1 and 65535"

      assert {:error, message} = Validators.validate_port(99_999)
      assert message =~ "between 1 and 65535"

      assert {:error, message} = Validators.validate_port(-1)
      assert message =~ "between 1 and 65535"
    end
  end

  describe "validate_pool_range/3" do
    test "validates valid IPv4 range" do
      assert :ok == Validators.validate_pool_range("192.168.1.100", "192.168.1.200", :ipv4)
      assert :ok == Validators.validate_pool_range("10.0.0.1", "10.0.0.254", :ipv4)
    end

    test "validates valid IPv6 range" do
      assert :ok ==
               Validators.validate_pool_range(
                 "2001:db8::1",
                 "2001:db8::ffff",
                 :ipv6
               )
    end

    test "rejects range where start > end" do
      assert {:error, message} =
               Validators.validate_pool_range("192.168.1.200", "192.168.1.100", :ipv4)

      assert message =~ "start must be less than"
    end

    test "rejects invalid IP addresses in range" do
      assert {:error, _} = Validators.validate_pool_range("256.1.1.1", "192.168.1.200", :ipv4)
      assert {:error, _} = Validators.validate_pool_range("192.168.1.100", "invalid", :ipv4)
    end
  end

  describe "check_overlapping_pools/2" do
    test "accepts non-overlapping pools" do
      pools = [
        %{name: "Pool1", range_start: "192.168.1.100", range_end: "192.168.1.150"},
        %{name: "Pool2", range_start: "192.168.1.200", range_end: "192.168.1.250"}
      ]

      assert :ok == Validators.check_overlapping_pools(pools, :ipv4)
    end

    test "detects overlapping pools" do
      pools = [
        %{name: "Pool1", range_start: "192.168.1.100", range_end: "192.168.1.200"},
        %{name: "Pool2", range_start: "192.168.1.150", range_end: "192.168.1.250"}
      ]

      assert {:error, message} = Validators.check_overlapping_pools(pools, :ipv4)
      assert message =~ "Pool1"
      assert message =~ "Pool2"
      assert message =~ "overlaps"
    end

    test "handles adjacent pools (no overlap)" do
      pools = [
        %{name: "Pool1", range_start: "192.168.1.100", range_end: "192.168.1.199"},
        %{name: "Pool2", range_start: "192.168.1.200", range_end: "192.168.1.250"}
      ]

      assert :ok == Validators.check_overlapping_pools(pools, :ipv4)
    end

    test "handles single pool" do
      pools = [
        %{name: "Pool1", range_start: "192.168.1.100", range_end: "192.168.1.200"}
      ]

      assert :ok == Validators.check_overlapping_pools(pools, :ipv4)
    end

    test "handles empty pool list" do
      assert :ok == Validators.check_overlapping_pools([], :ipv4)
    end
  end

  describe "validate_domain_name/1" do
    test "validates standard domain names" do
      assert :ok == Validators.validate_domain_name("example.com")
      assert :ok == Validators.validate_domain_name("sub.example.com")
      assert :ok == Validators.validate_domain_name("a.b.c.d.example.com")
    end

    test "validates domain with trailing dot" do
      assert :ok == Validators.validate_domain_name("example.com.")
    end

    test "validates wildcard domain" do
      assert :ok == Validators.validate_domain_name("*.example.com")
    end

    test "validates domain with underscore (SRV records)" do
      assert :ok == Validators.validate_domain_name("_sip._tcp.example.com")
    end

    test "validates domain with hyphens" do
      assert :ok == Validators.validate_domain_name("my-server.example.com")
    end

    test "rejects empty domain" do
      assert {:error, _} = Validators.validate_domain_name("")
    end

    test "rejects label starting with hyphen" do
      assert {:error, msg} = Validators.validate_domain_name("-invalid.com")
      assert msg =~ "hyphen"
    end

    test "rejects label ending with hyphen" do
      assert {:error, msg} = Validators.validate_domain_name("invalid-.com")
      assert msg =~ "hyphen"
    end

    test "rejects label over 63 characters" do
      long_label = String.duplicate("a", 64) <> ".com"
      assert {:error, msg} = Validators.validate_domain_name(long_label)
      assert msg =~ "63 characters"
    end

    test "rejects domain over 253 characters" do
      # Build a domain that exceeds 253 chars
      long_domain = Enum.map_join(1..50, ".", fn _ -> "abcde" end)
      assert {:error, msg} = Validators.validate_domain_name(long_domain)
      assert msg =~ "253 characters"
    end

    test "rejects domain with invalid characters" do
      assert {:error, msg} = Validators.validate_domain_name("exam ple.com")
      assert msg =~ "invalid characters"
    end
  end

  describe "validate_ttl/1" do
    test "validates valid TTL values" do
      assert :ok == Validators.validate_ttl(0)
      assert :ok == Validators.validate_ttl(300)
      assert :ok == Validators.validate_ttl(3600)
      assert :ok == Validators.validate_ttl(86_400)
      assert :ok == Validators.validate_ttl(2_147_483_647)
    end

    test "rejects negative TTL" do
      assert {:error, msg} = Validators.validate_ttl(-1)
      assert msg =~ "between 0 and"
    end

    test "rejects TTL above max" do
      assert {:error, _} = Validators.validate_ttl(2_147_483_648)
    end
  end

  describe "validate_mx_priority/1" do
    test "validates valid MX priorities" do
      assert :ok == Validators.validate_mx_priority(0)
      assert :ok == Validators.validate_mx_priority(10)
      assert :ok == Validators.validate_mx_priority(65_535)
    end

    test "rejects negative MX priority" do
      assert {:error, msg} = Validators.validate_mx_priority(-1)
      assert msg =~ "MX priority"
    end

    test "rejects MX priority above 65535" do
      assert {:error, _} = Validators.validate_mx_priority(70_000)
    end
  end

  describe "validate_srv/4" do
    test "validates valid SRV record" do
      assert :ok == Validators.validate_srv(10, 20, 443, "server.example.com")
    end

    test "rejects invalid SRV priority" do
      assert {:error, _} = Validators.validate_srv(-1, 20, 443, "server.example.com")
    end

    test "rejects invalid SRV weight" do
      assert {:error, _} = Validators.validate_srv(10, 70_000, 443, "server.example.com")
    end

    test "rejects invalid SRV port" do
      assert {:error, _} = Validators.validate_srv(10, 20, 0, "server.example.com")
    end

    test "rejects invalid SRV target" do
      assert {:error, _} = Validators.validate_srv(10, 20, 443, "-invalid.com")
    end
  end

  describe "validate_cidr/2" do
    test "validates valid IPv4 CIDR" do
      assert :ok == Validators.validate_cidr("10.0.0.0/8", :ipv4)
      assert :ok == Validators.validate_cidr("192.168.1.0/24", :ipv4)
      assert :ok == Validators.validate_cidr("0.0.0.0/0", :ipv4)
    end

    test "validates valid IPv6 CIDR" do
      assert :ok == Validators.validate_cidr("2001:db8::/32", :ipv6)
      assert :ok == Validators.validate_cidr("::/0", :ipv6)
    end

    test "rejects invalid CIDR prefix for IPv4" do
      assert {:error, _} = Validators.validate_cidr("10.0.0.0/33", :ipv4)
    end

    test "rejects invalid CIDR format" do
      assert {:error, _} = Validators.validate_cidr("10.0.0.0", :ipv4)
    end
  end
end
