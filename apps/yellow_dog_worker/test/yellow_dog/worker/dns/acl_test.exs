defmodule YellowDog.Worker.Dns.AclTest do
  use ExUnit.Case, async: true

  alias YellowDog.Worker.Dns.Acl

  test "allows addresses inside an IPv4 CIDR and rejects others" do
    {:ok, acl} = Acl.compile(["10.10.10.0/24"])
    assert Acl.allowed?(acl, {10, 10, 10, 54})
    refute Acl.allowed?(acl, {10, 10, 11, 1})
  end

  test "empty list denies everything" do
    {:ok, acl} = Acl.compile([])
    refute Acl.allowed?(acl, {10, 10, 10, 54})
    refute Acl.allowed?(acl, {0, 0, 0, 0, 0, 0, 0, 1})
  end

  test "matches IPv6 CIDR" do
    {:ok, acl} = Acl.compile(["::1/128"])
    assert Acl.allowed?(acl, {0, 0, 0, 0, 0, 0, 0, 1})
    refute Acl.allowed?(acl, {0, 0, 0, 0, 0, 0, 0, 2})
    refute Acl.allowed?(acl, {127, 0, 0, 1})
  end

  test "IPv4-mapped IPv6 addresses match IPv4 rules" do
    {:ok, acl} = Acl.compile(["10.0.0.0/8"])
    assert Acl.allowed?(acl, {0, 0, 0, 0, 0, 0xFFFF, 0x0A01, 0x0203})
    refute Acl.allowed?(acl, {0, 0, 0, 0, 0, 0xFFFF, 0x0B01, 0x0203})
  end

  test "supports multiple entries and /0 and /32" do
    {:ok, acl} = Acl.compile(["192.168.1.7/32", "fd00::/8"])
    assert Acl.allowed?(acl, {192, 168, 1, 7})
    refute Acl.allowed?(acl, {192, 168, 1, 8})
    assert Acl.allowed?(acl, {0xFD12, 0, 0, 0, 0, 0, 0, 1})
    {:ok, all} = Acl.compile(["0.0.0.0/0"])
    assert Acl.allowed?(all, {8, 8, 8, 8})
  end
end
