defmodule DHCPv6.IpUtilTest do
  use ExUnit.Case, async: true

  alias DHCPv6.IpUtil

  @loopback {0, 0, 0, 0, 0, 0, 0, 1}
  @all_zeros {0, 0, 0, 0, 0, 0, 0, 0}
  @all_ones {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
  @example {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}

  describe "ip6_to_int/1" do
    test "converts all-zeros to 0" do
      assert IpUtil.ip6_to_int(@all_zeros) == 0
    end

    test "converts loopback to 1" do
      assert IpUtil.ip6_to_int(@loopback) == 1
    end

    test "converts all-ones to max 128-bit value" do
      max = Bitwise.bsl(1, 128) - 1
      assert IpUtil.ip6_to_int(@all_ones) == max
    end

    test "converts 2001:db8::1" do
      int = IpUtil.ip6_to_int(@example)
      assert int > 0
    end
  end

  describe "int_to_ip6/1" do
    test "converts 0 to all-zeros" do
      assert IpUtil.int_to_ip6(0) == @all_zeros
    end

    test "converts 1 to loopback" do
      assert IpUtil.int_to_ip6(1) == @loopback
    end
  end

  describe "round-trip" do
    test "ip6_to_int then int_to_ip6 returns original" do
      for ip <- [@all_zeros, @loopback, @all_ones, @example] do
        assert ip |> IpUtil.ip6_to_int() |> IpUtil.int_to_ip6() == ip
      end
    end
  end

  describe "ip6_to_binary/1" do
    test "converts loopback to 16-byte binary" do
      binary = IpUtil.ip6_to_binary(@loopback)
      assert byte_size(binary) == 16
      assert binary == <<0::112, 1::16>>
    end

    test "converts all-zeros" do
      assert IpUtil.ip6_to_binary(@all_zeros) == <<0::128>>
    end

    test "converts 2001:db8::1" do
      binary = IpUtil.ip6_to_binary(@example)
      assert byte_size(binary) == 16
      assert binary == <<0x2001::16, 0x0DB8::16, 0::80, 1::16>>
    end
  end
end
