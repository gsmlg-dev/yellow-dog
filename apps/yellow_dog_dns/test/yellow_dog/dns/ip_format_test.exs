defmodule YellowDog.Dns.IpFormatTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.IpFormat

  describe "format/1" do
    test "formats IPv4 tuple to string" do
      assert IpFormat.format({127, 0, 0, 1}) == "127.0.0.1"
    end

    test "formats IPv6 tuple to string" do
      assert IpFormat.format({0, 0, 0, 0, 0, 0, 0, 1}) == "::1"
    end

    test "returns binary as-is" do
      assert IpFormat.format("192.168.1.1") == "192.168.1.1"
    end

    test "returns empty string as-is" do
      assert IpFormat.format("") == ""
    end

    test "inspects other types" do
      assert IpFormat.format(nil) == "nil"
      assert IpFormat.format(42) == "42"
      assert IpFormat.format(:atom) == ":atom"
    end
  end

  describe "parse/1" do
    test "parses IPv4 string" do
      assert IpFormat.parse("192.168.1.1") == {:ok, {192, 168, 1, 1}}
    end

    test "parses IPv6 string" do
      assert IpFormat.parse("::1") == {:ok, {0, 0, 0, 0, 0, 0, 0, 1}}
    end

    test "passes through tuples" do
      ip = {10, 0, 0, 1}
      assert IpFormat.parse(ip) == {:ok, ip}
    end

    test "returns error for invalid string" do
      assert IpFormat.parse("not-an-ip") == {:error, :invalid_ip}
    end

    test "returns error for empty string" do
      assert IpFormat.parse("") == {:error, :invalid_ip}
    end

    test "returns error for non-string/tuple" do
      assert IpFormat.parse(nil) == {:error, :invalid_ip}
      assert IpFormat.parse(42) == {:error, :invalid_ip}
    end
  end

  describe "parse_v4/1" do
    test "parses valid IPv4 string" do
      assert IpFormat.parse_v4("10.0.0.1") == {10, 0, 0, 1}
    end

    test "passes through IPv4 tuple" do
      assert IpFormat.parse_v4({192, 168, 1, 1}) == {192, 168, 1, 1}
    end

    test "returns nil for IPv6 string" do
      assert IpFormat.parse_v4("::1") == nil
    end

    test "returns nil for IPv6 tuple" do
      assert IpFormat.parse_v4({0, 0, 0, 0, 0, 0, 0, 1}) == nil
    end

    test "returns nil for invalid input" do
      assert IpFormat.parse_v4("not-an-ip") == nil
      assert IpFormat.parse_v4(nil) == nil
      assert IpFormat.parse_v4(42) == nil
    end
  end

  describe "parse_v6/1" do
    test "parses valid IPv6 string" do
      assert IpFormat.parse_v6("::1") == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "parses full IPv6 string" do
      assert IpFormat.parse_v6("2001:db8::1") == {8193, 3512, 0, 0, 0, 0, 0, 1}
    end

    test "passes through IPv6 tuple" do
      ip = {0, 0, 0, 0, 0, 0, 0, 1}
      assert IpFormat.parse_v6(ip) == ip
    end

    test "returns nil for IPv4 string" do
      assert IpFormat.parse_v6("192.168.1.1") == nil
    end

    test "returns nil for IPv4 tuple" do
      assert IpFormat.parse_v6({192, 168, 1, 1}) == nil
    end

    test "returns nil for invalid input" do
      assert IpFormat.parse_v6("not-an-ip") == nil
      assert IpFormat.parse_v6(nil) == nil
      assert IpFormat.parse_v6(42) == nil
    end
  end
end
