defmodule DHCPv4.IpUtilTest do
  use ExUnit.Case, async: true

  alias DHCPv4.IpUtil

  describe "ip_to_int/1" do
    test "converts {0, 0, 0, 0} to 0" do
      assert IpUtil.ip_to_int({0, 0, 0, 0}) == 0
    end

    test "converts {255, 255, 255, 255} to max" do
      assert IpUtil.ip_to_int({255, 255, 255, 255}) == 0xFFFFFFFF
    end

    test "converts {192, 168, 1, 100}" do
      assert IpUtil.ip_to_int({192, 168, 1, 100}) ==
               192 * 16_777_216 + 168 * 65_536 + 1 * 256 + 100
    end
  end

  describe "int_to_ip/1" do
    test "converts 0 to {0, 0, 0, 0}" do
      assert IpUtil.int_to_ip(0) == {0, 0, 0, 0}
    end

    test "converts max to {255, 255, 255, 255}" do
      assert IpUtil.int_to_ip(0xFFFFFFFF) == {255, 255, 255, 255}
    end
  end

  describe "round-trip" do
    test "ip_to_int then int_to_ip returns original" do
      for ip <- [
            {0, 0, 0, 0},
            {127, 0, 0, 1},
            {192, 168, 1, 1},
            {10, 0, 0, 1},
            {255, 255, 255, 255}
          ] do
        assert ip |> IpUtil.ip_to_int() |> IpUtil.int_to_ip() == ip
      end
    end
  end

  describe "ip_to_binary/1" do
    test "converts tuple to 4-byte binary" do
      assert IpUtil.ip_to_binary({192, 168, 1, 1}) == <<192, 168, 1, 1>>
    end

    test "converts {0, 0, 0, 0}" do
      assert IpUtil.ip_to_binary({0, 0, 0, 0}) == <<0, 0, 0, 0>>
    end
  end

  describe "binary_to_ip/1" do
    test "converts 4-byte binary to tuple" do
      assert IpUtil.binary_to_ip(<<192, 168, 1, 1>>) == {192, 168, 1, 1}
    end

    test "binary round-trip" do
      ip = {10, 20, 30, 40}
      assert ip |> IpUtil.ip_to_binary() |> IpUtil.binary_to_ip() == ip
    end
  end
end
