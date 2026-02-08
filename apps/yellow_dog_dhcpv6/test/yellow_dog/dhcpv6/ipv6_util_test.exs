defmodule YellowDog.Dhcpv6.Ipv6UtilTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv6.Ipv6Util

  describe "to_integer/1" do
    test "converts all-zeros address" do
      assert Ipv6Util.to_integer({0, 0, 0, 0, 0, 0, 0, 0}) == 0
    end

    test "converts loopback address ::1" do
      assert Ipv6Util.to_integer({0, 0, 0, 0, 0, 0, 0, 1}) == 1
    end

    test "converts link-local address" do
      result = Ipv6Util.to_integer({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert result == 0xFE80_0000_0000_0000_0000_0000_0000_0001
    end

    test "converts all-ones address" do
      result = Ipv6Util.to_integer({0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF})
      expected = Bitwise.bsl(1, 128) - 1
      assert result == expected
    end
  end

  describe "from_integer/1" do
    test "converts zero to all-zeros tuple" do
      assert Ipv6Util.from_integer(0) == {0, 0, 0, 0, 0, 0, 0, 0}
    end

    test "converts 1 to ::1 tuple" do
      assert Ipv6Util.from_integer(1) == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "converts link-local integer" do
      int = 0xFE80_0000_0000_0000_0000_0000_0000_0001
      assert Ipv6Util.from_integer(int) == {0xFE80, 0, 0, 0, 0, 0, 0, 1}
    end

    test "round-trips through to_integer" do
      addr = {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0x0001}
      assert addr |> Ipv6Util.to_integer() |> Ipv6Util.from_integer() == addr
    end
  end

  describe "parse_string/1" do
    test "parses full IPv6 address" do
      assert {:ok, {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}} = Ipv6Util.parse_string("2001:db8::1")
    end

    test "parses loopback" do
      assert {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} = Ipv6Util.parse_string("::1")
    end

    test "parses all-zeros" do
      assert {:ok, {0, 0, 0, 0, 0, 0, 0, 0}} = Ipv6Util.parse_string("::")
    end

    test "returns error for invalid string" do
      assert {:error, _} = Ipv6Util.parse_string("not-an-ipv6")
    end

    test "returns error for empty string" do
      assert {:error, _} = Ipv6Util.parse_string("")
    end
  end
end
