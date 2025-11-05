defmodule YellowDog.Dns.View.ACLTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.View.ACL

  describe "ACL creation" do
    test "creates ACL with name and rules" do
      acl = ACL.new("test", [{:allow, {10, 0, 0, 0}, 8}])

      assert acl.name == "test"
      assert acl.rules == [{:allow, {10, 0, 0, 0}, 8}]
    end

    test "creates ACL with multiple rules" do
      rules = [
        {:allow, {10, 0, 0, 0}, 8},
        {:deny, {10, 1, 2, 0}, 24},
        {:allow, {192, 168, 0, 0}, 16}
      ]

      acl = ACL.new("multi", rules)
      assert length(acl.rules) == 3
    end
  end

  describe "Built-in ACLs" do
    test "lists all built-in ACLs" do
      builtins = ACL.list_builtins()

      assert "any" in builtins
      assert "none" in builtins
      assert "localhost" in builtins
      assert "localnets" in builtins
    end

    test "gets 'any' built-in ACL" do
      {:ok, acl} = ACL.get_builtin("any")
      assert acl.name == "any"

      # Should match any IP
      assert ACL.matches?(acl, {8, 8, 8, 8})
      assert ACL.matches?(acl, {192, 168, 1, 1})
    end

    test "gets 'none' built-in ACL" do
      {:ok, acl} = ACL.get_builtin("none")
      assert acl.name == "none"

      # Should match no IPs
      refute ACL.matches?(acl, {8, 8, 8, 8})
      refute ACL.matches?(acl, {192, 168, 1, 1})
    end

    test "gets 'localhost' built-in ACL" do
      {:ok, acl} = ACL.get_builtin("localhost")

      # Should match localhost
      assert ACL.matches?(acl, {127, 0, 0, 1})
      assert ACL.matches?(acl, {0, 0, 0, 0, 0, 0, 0, 1})

      # Should not match other IPs
      refute ACL.matches?(acl, {192, 168, 1, 1})
    end

    test "gets 'localnets' built-in ACL" do
      {:ok, acl} = ACL.get_builtin("localnets")

      # Should match RFC 1918 private networks
      assert ACL.matches?(acl, {10, 1, 2, 3})
      assert ACL.matches?(acl, {172, 16, 0, 1})
      assert ACL.matches?(acl, {192, 168, 1, 1})

      # Should not match public IPs
      refute ACL.matches?(acl, {8, 8, 8, 8})
      refute ACL.matches?(acl, {1, 1, 1, 1})
    end

    test "returns error for unknown built-in ACL" do
      assert {:error, :not_found} = ACL.get_builtin("unknown")
    end
  end

  describe "IPv4 matching" do
    test "matches exact IPv4 address" do
      acl = ACL.new("exact", [{:allow, {192, 168, 1, 100}}])

      assert ACL.matches?(acl, {192, 168, 1, 100})
      refute ACL.matches?(acl, {192, 168, 1, 101})
    end

    test "matches IPv4 /24 subnet" do
      acl = ACL.new("subnet", [{:allow, {192, 168, 1, 0}, 24}])

      assert ACL.matches?(acl, {192, 168, 1, 1})
      assert ACL.matches?(acl, {192, 168, 1, 100})
      assert ACL.matches?(acl, {192, 168, 1, 255})
      refute ACL.matches?(acl, {192, 168, 2, 1})
    end

    test "matches IPv4 /16 subnet" do
      acl = ACL.new("large", [{:allow, {10, 0, 0, 0}, 16}])

      assert ACL.matches?(acl, {10, 0, 1, 1})
      assert ACL.matches?(acl, {10, 0, 255, 255})
      refute ACL.matches?(acl, {10, 1, 0, 0})
    end

    test "matches IPv4 /8 subnet" do
      acl = ACL.new("huge", [{:allow, {10, 0, 0, 0}, 8}])

      assert ACL.matches?(acl, {10, 0, 0, 1})
      assert ACL.matches?(acl, {10, 1, 2, 3})
      assert ACL.matches?(acl, {10, 255, 255, 255})
      refute ACL.matches?(acl, {11, 0, 0, 1})
    end

    test "matches IPv4 /32 subnet (single host)" do
      acl = ACL.new("single", [{:allow, {192, 168, 1, 100}, 32}])

      assert ACL.matches?(acl, {192, 168, 1, 100})
      refute ACL.matches?(acl, {192, 168, 1, 101})
    end
  end

  describe "IPv6 matching" do
    test "matches exact IPv6 address" do
      acl = ACL.new("ipv6-exact", [{:allow, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}}])

      assert ACL.matches?(acl, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      refute ACL.matches?(acl, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 2})
    end

    test "matches IPv6 /64 subnet" do
      acl = ACL.new("ipv6-subnet", [{:allow, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 64}])

      assert ACL.matches?(acl, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      assert ACL.matches?(acl, {0x2001, 0xDB8, 0, 0, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF})
      refute ACL.matches?(acl, {0x2001, 0xDB8, 0, 1, 0, 0, 0, 0})
    end

    test "matches IPv6 /32 subnet" do
      acl = ACL.new("ipv6-large", [{:allow, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}])

      assert ACL.matches?(acl, {0x2001, 0xDB8, 1, 2, 3, 4, 5, 6})
      assert ACL.matches?(acl, {0x2001, 0xDB8, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF})
      refute ACL.matches?(acl, {0x2001, 0xDB9, 0, 0, 0, 0, 0, 0})
    end
  end

  describe "CIDR string parsing" do
    test "parses IPv4 CIDR notation" do
      assert {:ok, {{192, 168, 1, 0}, 24}} = ACL.parse_cidr("192.168.1.0/24")
      assert {:ok, {{10, 0, 0, 0}, 8}} = ACL.parse_cidr("10.0.0.0/8")
      assert {:ok, {{172, 16, 0, 0}, 12}} = ACL.parse_cidr("172.16.0.0/12")
    end

    test "parses IPv6 CIDR notation" do
      assert {:ok, {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}} = ACL.parse_cidr("2001:db8::/32")
      assert {:ok, {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 64}} = ACL.parse_cidr("2001:db8::/64")
    end

    test "rejects invalid CIDR notation" do
      assert {:error, :invalid_cidr} = ACL.parse_cidr("invalid")
      assert {:error, :invalid_cidr} = ACL.parse_cidr("192.168.1.0")
      assert {:error, :invalid_cidr} = ACL.parse_cidr("192.168.1.0/abc")
      assert {:error, :invalid_cidr} = ACL.parse_cidr("192.168.1.0/33")
    end

    test "matches using CIDR string in rules" do
      acl = ACL.new("cidr-test", [{:allow, "192.168.1.0/24"}])

      assert ACL.matches?(acl, {192, 168, 1, 100})
      refute ACL.matches?(acl, {192, 168, 2, 100})
    end
  end

  describe "Rule evaluation order" do
    test "first matching rule wins" do
      # Allow 10.0.0.0/8 but deny 10.1.2.0/24
      acl =
        ACL.new("ordered", [
          {:deny, {10, 1, 2, 0}, 24},
          {:allow, {10, 0, 0, 0}, 8}
        ])

      # Should be denied (first rule matches)
      refute ACL.matches?(acl, {10, 1, 2, 100})

      # Should be allowed (second rule matches)
      assert ACL.matches?(acl, {10, 0, 0, 100})
    end

    test "reverse order changes result" do
      # Allow 10.0.0.0/8 first, then deny 10.1.2.0/24
      acl =
        ACL.new("reversed", [
          {:allow, {10, 0, 0, 0}, 8},
          {:deny, {10, 1, 2, 0}, 24}
        ])

      # Should be allowed (first rule matches broader range)
      assert ACL.matches?(acl, {10, 1, 2, 100})
    end

    test "default deny when no rules match" do
      acl = ACL.new("limited", [{:allow, {192, 168, 1, 0}, 24}])

      refute ACL.matches?(acl, {8, 8, 8, 8})
    end
  end

  describe "Complex ACL scenarios" do
    test "multiple allows and denies" do
      # Rules are evaluated in order - more specific rules must come first
      # To create exceptions within denied ranges, the exception must come first
      acl =
        ACL.new("complex", [
          {:allow, {10, 1, 1, 0}, 24},
          {:deny, {10, 1, 0, 0}, 16},
          {:allow, {10, 0, 0, 0}, 8},
          {:allow, {192, 168, 0, 0}, 16}
        ])

      # Allowed by third rule (10.0.0.0/8)
      assert ACL.matches?(acl, {10, 0, 0, 1})

      # Denied by second rule (10.1.0.0/16)
      refute ACL.matches?(acl, {10, 1, 0, 1})

      # Allowed by first rule (10.1.1.0/24) - exception within denied range
      assert ACL.matches?(acl, {10, 1, 1, 1})

      # Allowed by fourth rule
      assert ACL.matches?(acl, {192, 168, 1, 1})

      # Not matched by any rule
      refute ACL.matches?(acl, {8, 8, 8, 8})
    end

    test "combining CIDR strings and tuples" do
      # NOTE: More specific rules must come first in ACLs
      # (first matching rule wins)
      acl =
        ACL.new("mixed", [
          {:deny, {10, 1, 2, 0}, 24},
          {:allow, "10.0.0.0/8"},
          {:allow, {192, 168, 1, 100}}
        ])

      assert ACL.matches?(acl, {10, 0, 0, 1})
      refute ACL.matches?(acl, {10, 1, 2, 1})
      assert ACL.matches?(acl, {192, 168, 1, 100})
    end
  end

  describe "Built-in ACL name matching" do
    test "matches using built-in ACL name directly" do
      assert ACL.matches?("any", {8, 8, 8, 8})
      assert ACL.matches?("localhost", {127, 0, 0, 1})
      assert ACL.matches?("localnets", {10, 1, 2, 3})
      refute ACL.matches?("none", {8, 8, 8, 8})
    end

    test "returns false for unknown ACL name" do
      refute ACL.matches?("unknown", {192, 168, 1, 1})
    end
  end
end
