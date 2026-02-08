defmodule YellowDog.Dhcpv4.Ipv4UtilTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dhcpv4.Ipv4Util

  describe "to_integer/1" do
    test "converts 0.0.0.0" do
      assert Ipv4Util.to_integer({0, 0, 0, 0}) == 0
    end

    test "converts 0.0.0.1" do
      assert Ipv4Util.to_integer({0, 0, 0, 1}) == 1
    end

    test "converts 192.168.1.1" do
      # 192*2^24 + 168*2^16 + 1*2^8 + 1
      assert Ipv4Util.to_integer({192, 168, 1, 1}) == 3_232_235_777
    end

    test "converts 255.255.255.255" do
      assert Ipv4Util.to_integer({255, 255, 255, 255}) == 0xFFFFFFFF
    end

    test "converts 10.0.0.0" do
      assert Ipv4Util.to_integer({10, 0, 0, 0}) == 10 * 256 * 256 * 256
    end
  end

  describe "from_integer/1" do
    test "converts 0 to {0, 0, 0, 0}" do
      assert Ipv4Util.from_integer(0) == {0, 0, 0, 0}
    end

    test "converts 1 to {0, 0, 0, 1}" do
      assert Ipv4Util.from_integer(1) == {0, 0, 0, 1}
    end

    test "converts 3_232_235_777 to {192, 168, 1, 1}" do
      assert Ipv4Util.from_integer(3_232_235_777) == {192, 168, 1, 1}
    end

    test "converts 0xFFFFFFFF to {255, 255, 255, 255}" do
      assert Ipv4Util.from_integer(0xFFFFFFFF) == {255, 255, 255, 255}
    end

    test "round-trips through to_integer" do
      addr = {172, 16, 0, 1}
      assert addr |> Ipv4Util.to_integer() |> Ipv4Util.from_integer() == addr
    end
  end

  describe "format/1" do
    test "formats tuple as dotted-decimal string" do
      assert Ipv4Util.format({192, 168, 1, 1}) == "192.168.1.1"
    end

    test "formats all-zeros tuple" do
      assert Ipv4Util.format({0, 0, 0, 0}) == "0.0.0.0"
    end

    test "formats broadcast address" do
      assert Ipv4Util.format({255, 255, 255, 255}) == "255.255.255.255"
    end

    test "passes through binary strings unchanged" do
      assert Ipv4Util.format("10.0.0.1") == "10.0.0.1"
    end

    test "returns nil for nil" do
      assert Ipv4Util.format(nil) == nil
    end
  end

  describe "parse/1" do
    test "parses valid IPv4 string" do
      assert {:ok, {192, 168, 1, 1}} = Ipv4Util.parse("192.168.1.1")
    end

    test "parses all-zeros string" do
      assert {:ok, {0, 0, 0, 0}} = Ipv4Util.parse("0.0.0.0")
    end

    test "passes through valid 4-tuple" do
      tuple = {10, 0, 0, 1}
      assert {:ok, ^tuple} = Ipv4Util.parse(tuple)
    end

    test "returns error for invalid string" do
      assert {:error, _} = Ipv4Util.parse("not-an-ip")
    end

    test "returns error for IPv6 string" do
      assert {:error, _} = Ipv4Util.parse("::1")
    end

    test "returns error for nil" do
      assert {:error, _} = Ipv4Util.parse(nil)
    end

    test "returns error for integer" do
      assert {:error, _} = Ipv4Util.parse(42)
    end
  end
end
