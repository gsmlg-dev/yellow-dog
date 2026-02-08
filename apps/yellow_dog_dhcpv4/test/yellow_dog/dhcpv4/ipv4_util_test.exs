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
end
