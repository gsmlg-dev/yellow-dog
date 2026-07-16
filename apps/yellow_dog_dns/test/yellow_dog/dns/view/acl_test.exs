defmodule YellowDog.Dns.View.ACLTest do
  @moduledoc """
  Unit tests for YellowDog.Dns.View.ACL.

  Tests cover:
  - ACL struct creation
  - Built-in ACLs (any, none, localhost, localnets)
  - IPv4 and IPv6 matching
  - CIDR notation parsing
  - Rule evaluation order
  - Allow/deny logic
  - Edge cases
  """
  use ExUnit.Case, async: true

  alias YellowDog.Dns.View.ACL

  describe "new/2" do
    test "creates ACL with name and rules" do
      acl = ACL.new("test", [{:allow, {10, 0, 0, 0}, 8}])

      assert acl.name == "test"
      assert acl.rules == [{:allow, {10, 0, 0, 0}, 8}]
    end

    test "creates ACL with multiple rules" do
      rules = [
        {:allow, {10, 0, 0, 0}, 8},
        {:deny, {10, 1, 1, 0}, 24},
        {:allow, {192, 168, 0, 0}, 16}
      ]

      acl = ACL.new("multi", rules)

      assert acl.name == "multi"
      assert length(acl.rules) == 3
    end

    test "creates ACL with empty rules" do
      acl = ACL.new("empty", [])

      assert acl.name == "empty"
      assert acl.rules == []
    end
  end

  describe "matches?/2 with ACL struct" do
    test "matches IP in allowed subnet" do
      acl = ACL.new("internal", [{:allow, {10, 0, 0, 0}, 8}])

      assert ACL.matches?(acl, {10, 1, 2, 3})
      assert ACL.matches?(acl, {10, 255, 255, 255})
    end

    test "does not match IP outside allowed subnet" do
      acl = ACL.new("internal", [{:allow, {10, 0, 0, 0}, 8}])

      refute ACL.matches?(acl, {192, 168, 1, 1})
      refute ACL.matches?(acl, {8, 8, 8, 8})
    end

    test "deny rule blocks matching IP" do
      acl = ACL.new("blocked", [{:deny, {192, 168, 1, 0}, 24}])

      refute ACL.matches?(acl, {192, 168, 1, 100})
    end

    test "allow after deny - first match wins" do
      acl =
        ACL.new("order", [
          {:deny, {192, 168, 1, 0}, 24},
          {:allow, {192, 168, 0, 0}, 16}
        ])

      refute ACL.matches?(acl, {192, 168, 1, 1})
      assert ACL.matches?(acl, {192, 168, 2, 1})
    end

    test "default deny when no rules match" do
      acl = ACL.new("specific", [{:allow, {10, 0, 0, 0}, 8}])

      refute ACL.matches?(acl, {172, 16, 1, 1})
    end

    test "exact IP match with allow" do
      acl = ACL.new("exact", [{:allow, {192, 168, 1, 100}}])

      assert ACL.matches?(acl, {192, 168, 1, 100})
      refute ACL.matches?(acl, {192, 168, 1, 101})
    end

    test "exact IP match with deny" do
      acl = ACL.new("blacklist", [{:deny, {192, 168, 1, 100}}])

      refute ACL.matches?(acl, {192, 168, 1, 100})
      refute ACL.matches?(acl, {192, 168, 1, 101})
    end

    test "CIDR string notation in rules" do
      acl = ACL.new("cidr_string", [{:allow, "10.0.0.0/8"}])

      assert ACL.matches?(acl, {10, 1, 2, 3})
      refute ACL.matches?(acl, {192, 168, 1, 1})
    end

    test "multiple CIDR ranges" do
      acl =
        ACL.new("multi_cidr", [
          {:allow, "10.0.0.0/8"},
          {:allow, "172.16.0.0/12"},
          {:allow, "192.168.0.0/16"}
        ])

      assert ACL.matches?(acl, {10, 1, 2, 3})
      assert ACL.matches?(acl, {172, 16, 5, 10})
      assert ACL.matches?(acl, {192, 168, 1, 100})
      refute ACL.matches?(acl, {8, 8, 8, 8})
    end

    test "handles any rule" do
      acl = ACL.new("any", [{:allow, :any}])

      assert ACL.matches?(acl, {1, 2, 3, 4})
      assert ACL.matches?(acl, {255, 255, 255, 255})
    end

    test "handles deny any rule" do
      acl = ACL.new("none", [{:deny, :any}])

      refute ACL.matches?(acl, {1, 2, 3, 4})
    end
  end

  describe "matches?/2 with IPv6" do
    test "matches IPv6 in allowed subnet" do
      acl = ACL.new("ipv6", [{:allow, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}])

      assert ACL.matches?(acl, {0x2001, 0xDB8, 0x1234, 0x5678, 0, 0, 0, 1})
    end

    test "does not match IPv6 outside allowed subnet" do
      acl = ACL.new("ipv6", [{:allow, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}])

      refute ACL.matches?(acl, {0x2001, 0xDB9, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 CIDR string notation" do
      acl = ACL.new("ipv6_cidr", [{:allow, "2001:db8::/32"}])

      assert ACL.matches?(acl, {0x2001, 0xDB8, 0x1234, 0, 0, 0, 0, 1})
      refute ACL.matches?(acl, {0x2001, 0xDB9, 0, 0, 0, 0, 0, 1})
    end

    test "IPv6 loopback matching" do
      acl = ACL.new("loopback", [{:allow, {0, 0, 0, 0, 0, 0, 0, 1}, 128}])

      assert ACL.matches?(acl, {0, 0, 0, 0, 0, 0, 0, 1})
      refute ACL.matches?(acl, {0, 0, 0, 0, 0, 0, 0, 2})
    end
  end

  describe "matches?/2 with built-in ACL names" do
    test "'any' matches all IPs" do
      assert ACL.matches?("any", {1, 2, 3, 4})
      assert ACL.matches?("any", {192, 168, 1, 1})
      assert ACL.matches?("any", {0, 0, 0, 0})
    end

    test "'none' matches no IPs" do
      refute ACL.matches?("none", {1, 2, 3, 4})
      refute ACL.matches?("none", {192, 168, 1, 1})
    end

    test "'localhost' matches loopback addresses" do
      assert ACL.matches?("localhost", {127, 0, 0, 1})
      assert ACL.matches?("localhost", {0, 0, 0, 0, 0, 0, 0, 1})
      refute ACL.matches?("localhost", {192, 168, 1, 1})
    end

    test "'localnets' matches RFC 1918 private networks" do
      assert ACL.matches?("localnets", {10, 0, 0, 1})
      assert ACL.matches?("localnets", {10, 255, 255, 255})
      assert ACL.matches?("localnets", {172, 16, 0, 1})
      assert ACL.matches?("localnets", {172, 31, 255, 255})
      assert ACL.matches?("localnets", {192, 168, 0, 1})
      assert ACL.matches?("localnets", {192, 168, 255, 255})
      refute ACL.matches?("localnets", {8, 8, 8, 8})
    end

    test "unknown ACL name returns false" do
      refute ACL.matches?("unknown_acl", {192, 168, 1, 1})
    end
  end

  describe "get_builtin/1" do
    test "returns built-in ACL for 'any'" do
      {:ok, acl} = ACL.get_builtin("any")

      assert acl.name == "any"
      assert ACL.matches?(acl, {1, 2, 3, 4})
    end

    test "returns built-in ACL for 'none'" do
      {:ok, acl} = ACL.get_builtin("none")

      assert acl.name == "none"
      refute ACL.matches?(acl, {1, 2, 3, 4})
    end

    test "returns built-in ACL for 'localhost'" do
      {:ok, acl} = ACL.get_builtin("localhost")

      assert acl.name == "localhost"
      assert ACL.matches?(acl, {127, 0, 0, 1})
    end

    test "returns built-in ACL for 'localnets'" do
      {:ok, acl} = ACL.get_builtin("localnets")

      assert acl.name == "localnets"
      assert ACL.matches?(acl, {10, 0, 0, 1})
    end

    test "returns error for unknown ACL" do
      assert {:error, :not_found} = ACL.get_builtin("nonexistent")
    end
  end

  describe "list_builtins/0" do
    test "returns sorted list of built-in ACL names" do
      builtins = ACL.list_builtins()

      assert is_list(builtins)
      assert "any" in builtins
      assert "none" in builtins
      assert "localhost" in builtins
      assert "localnets" in builtins
      assert builtins == Enum.sort(builtins)
    end
  end

  describe "parse_cidr/1" do
    test "parses IPv4 CIDR notation" do
      assert {:ok, {{192, 168, 1, 0}, 24}} = ACL.parse_cidr("192.168.1.0/24")
      assert {:ok, {{10, 0, 0, 0}, 8}} = ACL.parse_cidr("10.0.0.0/8")
      assert {:ok, {{172, 16, 0, 0}, 12}} = ACL.parse_cidr("172.16.0.0/12")
    end

    test "parses IPv4 CIDR with /32" do
      assert {:ok, {{192, 168, 1, 1}, 32}} = ACL.parse_cidr("192.168.1.1/32")
    end

    test "parses IPv6 CIDR notation" do
      assert {:ok, {{0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}, 32}} = ACL.parse_cidr("2001:db8::/32")
    end

    test "parses IPv6 loopback CIDR" do
      assert {:ok, {{0, 0, 0, 0, 0, 0, 0, 1}, 128}} = ACL.parse_cidr("::1/128")
    end

    test "returns error for invalid CIDR" do
      assert {:error, :invalid_cidr} = ACL.parse_cidr("invalid")
      assert {:error, :invalid_cidr} = ACL.parse_cidr("192.168.1.0")
      assert {:error, :invalid_cidr} = ACL.parse_cidr("192.168.1.0/")
      assert {:error, :invalid_cidr} = ACL.parse_cidr("/24")
    end

    test "returns error for invalid IP in CIDR" do
      assert {:error, :invalid_cidr} = ACL.parse_cidr("999.999.999.999/24")
    end

    test "returns error for invalid prefix length" do
      assert {:error, :invalid_cidr} = ACL.parse_cidr("192.168.1.0/33")
      assert {:error, :invalid_cidr} = ACL.parse_cidr("192.168.1.0/-1")
    end

    test "returns error for IPv6 with invalid prefix length" do
      assert {:error, :invalid_cidr} = ACL.parse_cidr("2001:db8::/129")
    end
  end

  describe "canonical_cidr/1" do
    test "masks IPv4 host bits and compresses expanded IPv6" do
      assert {:ok, "10.0.0.0/8"} = ACL.canonical_cidr("10.1.2.3/8")

      assert {:ok, "2001:db8::/32"} =
               ACL.canonical_cidr("2001:0db8:0000:0000:0000:0000:0000:1234/32")
    end

    test "canonicalizes tuple CIDRs and rejects malformed values" do
      assert {:ok, "192.0.2.0/24"} = ACL.canonical_cidr({{192, 0, 2, 99}, 24})
      assert {:error, :invalid_cidr} = ACL.canonical_cidr("not-a-cidr")
      assert {:error, :invalid_cidr} = ACL.canonical_cidr({{999, 0, 0, 1}, 24})
    end
  end

  describe "edge cases" do
    test "empty rules list returns false for any IP" do
      acl = ACL.new("empty", [])

      refute ACL.matches?(acl, {192, 168, 1, 1})
    end

    test "handles /0 prefix (matches all)" do
      acl = ACL.new("all", [{:allow, {0, 0, 0, 0}, 0}])

      assert ACL.matches?(acl, {1, 2, 3, 4})
      assert ACL.matches?(acl, {255, 255, 255, 255})
    end

    test "handles /32 prefix (exact match)" do
      acl = ACL.new("exact", [{:allow, {192, 168, 1, 100}, 32}])

      assert ACL.matches?(acl, {192, 168, 1, 100})
      refute ACL.matches?(acl, {192, 168, 1, 101})
    end

    test "invalid CIDR string in rules is ignored" do
      acl = ACL.new("invalid_cidr", [{:allow, "not-a-cidr"}])

      refute ACL.matches?(acl, {192, 168, 1, 1})
    end

    test "mixed IPv4 and IPv6 rules" do
      acl =
        ACL.new("mixed", [
          {:allow, {10, 0, 0, 0}, 8},
          {:allow, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}
        ])

      assert ACL.matches?(acl, {10, 1, 2, 3})
      assert ACL.matches?(acl, {0x2001, 0xDB8, 0x1234, 0, 0, 0, 0, 1})
      refute ACL.matches?(acl, {192, 168, 1, 1})
    end

    test "handles mismatched IP versions in subnet check" do
      acl = ACL.new("ipv4_only", [{:allow, {10, 0, 0, 0}, 8}])

      refute ACL.matches?(acl, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    end
  end

  describe "rule evaluation order" do
    test "more specific deny before broader allow" do
      acl =
        ACL.new("blacklist", [
          {:deny, {192, 168, 1, 100}, 32},
          {:allow, {192, 168, 0, 0}, 16}
        ])

      refute ACL.matches?(acl, {192, 168, 1, 100})
      assert ACL.matches?(acl, {192, 168, 1, 99})
      assert ACL.matches?(acl, {192, 168, 1, 101})
    end

    test "broader deny before specific allow" do
      acl =
        ACL.new("allowlist", [
          {:deny, {192, 168, 0, 0}, 16},
          {:allow, {192, 168, 1, 100}, 32}
        ])

      refute ACL.matches?(acl, {192, 168, 1, 100})
      refute ACL.matches?(acl, {192, 168, 1, 99})
    end

    test "first matching rule wins" do
      acl =
        ACL.new("order_test", [
          {:allow, {192, 168, 1, 0}, 24},
          {:deny, {192, 168, 1, 0}, 24},
          {:allow, {192, 168, 2, 0}, 24}
        ])

      assert ACL.matches?(acl, {192, 168, 1, 50})
      assert ACL.matches?(acl, {192, 168, 2, 50})
    end
  end
end
