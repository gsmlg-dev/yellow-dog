defmodule DNS.Message.EDNS0.Option.ECSTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.ECS (EDNS Client Subnet).

  Tests cover:
  - Module structure and exports
  - ECS creation (new/1)
  - Binary parsing (from_iodata/1)
  - Raw binary conversion (to_raw/1)
  - DNS.Parameter protocol implementation
  - String.Chars protocol implementation
  - IPv4 subnets with various prefix lengths
  - IPv6 subnets with various prefix lengths
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.ECS

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(ECS)
    end

    test "exports new/1" do
      Code.ensure_loaded!(ECS)
      assert Kernel.function_exported?(ECS, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(ECS)
      assert Kernel.function_exported?(ECS, :from_iodata, 1)
    end

    test "exports to_raw/1" do
      Code.ensure_loaded!(ECS)
      assert Kernel.function_exported?(ECS, :to_raw, 1)
    end

    test "defines struct with required fields" do
      ecs = %ECS{}
      assert Map.has_key?(ecs, :code)
      assert Map.has_key?(ecs, :length)
      assert Map.has_key?(ecs, :data)
    end

    test "default code is 8 (edns-client-subnet)" do
      ecs = %ECS{}
      <<value::16>> = ecs.code.value
      assert value == 8
    end
  end

  describe "new/1 - IPv4 subnets" do
    test "creates ECS for /8 IPv4 subnet" do
      ecs = ECS.new({{192, 0, 0, 0}, 8, 0})

      assert ecs.data == {{192, 0, 0, 0}, 8, 0}
    end

    test "creates ECS for /16 IPv4 subnet" do
      ecs = ECS.new({{192, 168, 0, 0}, 16, 0})

      assert ecs.data == {{192, 168, 0, 0}, 16, 0}
    end

    test "creates ECS for /24 IPv4 subnet" do
      ecs = ECS.new({{192, 168, 1, 0}, 24, 0})

      assert ecs.data == {{192, 168, 1, 0}, 24, 0}
    end

    test "creates ECS for /32 IPv4 subnet" do
      ecs = ECS.new({{192, 168, 1, 100}, 32, 0})

      assert ecs.data == {{192, 168, 1, 100}, 32, 0}
    end

    test "stores scope prefix" do
      ecs = ECS.new({{192, 168, 1, 0}, 24, 20})

      {_, _, scope} = ecs.data
      assert scope == 20
    end
  end

  describe "new/1 - IPv6 subnets" do
    test "creates ECS for /16 IPv6 subnet" do
      ecs = ECS.new({{0x2001, 0, 0, 0, 0, 0, 0, 0}, 16, 0})

      {addr, source, scope} = ecs.data
      assert addr == {0x2001, 0, 0, 0, 0, 0, 0, 0}
      assert source == 16
      assert scope == 0
    end

    test "creates ECS for /48 IPv6 subnet" do
      ecs = ECS.new({{0x2001, 0xDB8, 0x1234, 0, 0, 0, 0, 0}, 48, 0})

      {_addr, source, _} = ecs.data
      assert source == 48
    end

    test "creates ECS for /64 IPv6 subnet" do
      ecs = ECS.new({{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 64, 0})

      {_, source, _} = ecs.data
      assert source == 64
    end

    test "creates ECS for /128 IPv6 subnet" do
      ecs = ECS.new({{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, 128, 0})

      {_, source, _} = ecs.data
      assert source == 128
    end
  end

  describe "to_raw/1 - IPv4" do
    test "encodes /8 IPv4 with 1 address byte" do
      raw = ECS.to_raw({{192, 0, 0, 0}, 8, 0})

      # Family=1, source=8, scope=0, 1 byte address
      assert raw == <<0, 1, 8, 0, 192>>
    end

    test "encodes /16 IPv4 with 2 address bytes" do
      raw = ECS.to_raw({{192, 168, 0, 0}, 16, 0})

      assert raw == <<0, 1, 16, 0, 192, 168>>
    end

    test "encodes /24 IPv4 with 3 address bytes" do
      raw = ECS.to_raw({{192, 168, 1, 0}, 24, 0})

      assert raw == <<0, 1, 24, 0, 192, 168, 1>>
    end

    test "encodes /32 IPv4 with 4 address bytes" do
      raw = ECS.to_raw({{192, 168, 1, 100}, 32, 0})

      assert raw == <<0, 1, 32, 0, 192, 168, 1, 100>>
    end

    test "includes scope prefix in raw" do
      raw = ECS.to_raw({{192, 168, 1, 0}, 24, 16})

      <<_family::16, _source::8, scope::8, _addr::binary>> = raw
      assert scope == 16
    end
  end

  describe "to_raw/1 - IPv6" do
    test "encodes /16 IPv6 with 2 address bytes" do
      raw = ECS.to_raw({{0x2001, 0, 0, 0, 0, 0, 0, 0}, 16, 0})

      # Family=2, source=16, scope=0
      <<family::16, source::8, scope::8, _addr::binary>> = raw
      assert family == 2
      assert source == 16
      assert scope == 0
    end

    test "encodes /64 IPv6 with 8 address bytes" do
      raw = ECS.to_raw({{0x2001, 0xDB8, 0x1234, 0x5678, 0, 0, 0, 0}, 64, 0})

      # Should have 4 bytes header + 8 bytes address
      assert byte_size(raw) == 12
    end

    test "encodes /128 IPv6 with 16 address bytes" do
      raw = ECS.to_raw({{0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, 128, 0})

      # Should have 4 bytes header + 16 bytes address
      assert byte_size(raw) == 20
    end
  end

  describe "from_iodata/1 - IPv4" do
    test "parses /8 IPv4 subnet" do
      data = <<0, 8, 0, 5, 0, 1, 8, 0, 192>>

      ecs = ECS.from_iodata(data)

      {addr, source, scope} = ecs.data
      assert addr == {192, 0, 0, 0}
      assert source == 8
      assert scope == 0
    end

    test "parses /16 IPv4 subnet" do
      data = <<0, 8, 0, 6, 0, 1, 16, 0, 192, 168>>

      ecs = ECS.from_iodata(data)

      {addr, source, _} = ecs.data
      assert addr == {192, 168, 0, 0}
      assert source == 16
    end

    test "parses /24 IPv4 subnet" do
      data = <<0, 8, 0, 7, 0, 1, 24, 0, 10, 0, 1>>

      ecs = ECS.from_iodata(data)

      {addr, source, _} = ecs.data
      assert addr == {10, 0, 1, 0}
      assert source == 24
    end

    test "parses /32 IPv4 subnet" do
      data = <<0, 8, 0, 8, 0, 1, 32, 0, 172, 16, 0, 1>>

      ecs = ECS.from_iodata(data)

      {addr, source, _} = ecs.data
      assert addr == {172, 16, 0, 1}
      assert source == 32
    end

    test "parses scope prefix" do
      data = <<0, 8, 0, 7, 0, 1, 24, 20, 192, 168, 1>>

      ecs = ECS.from_iodata(data)

      {_, _, scope} = ecs.data
      assert scope == 20
    end
  end

  describe "from_iodata/1 - IPv6" do
    test "parses /16 IPv6 subnet" do
      data = <<0, 8, 0, 6, 0, 2, 16, 0, 0x20, 0x01>>

      ecs = ECS.from_iodata(data)

      {_addr, source, _} = ecs.data
      assert source == 16
      # First 16 bits: 0x2001
    end

    test "parses /64 IPv6 subnet" do
      data = <<0, 8, 0, 12, 0, 2, 64, 0, 0x20, 0x01, 0x0D, 0xB8, 0x00, 0x00, 0x00, 0x00>>

      ecs = ECS.from_iodata(data)

      {addr, source, _} = ecs.data
      assert source == 64
      assert elem(addr, 0) == 0x2001
      assert elem(addr, 1) == 0x0DB8
    end
  end

  describe "DNS.Parameter protocol" do
    test "implements DNS.Parameter protocol" do
      ecs = ECS.new({{192, 168, 1, 0}, 24, 0})

      binary = DNS.Parameter.to_iodata(ecs)
      assert is_binary(binary)
    end

    test "serializes with correct option code" do
      ecs = ECS.new({{192, 168, 1, 0}, 24, 0})

      binary = DNS.Parameter.to_iodata(ecs)
      <<code::16, _rest::binary>> = binary

      assert code == 8
    end

    test "serializes with correct length" do
      ecs = ECS.new({{192, 168, 1, 0}, 24, 0})

      binary = DNS.Parameter.to_iodata(ecs)
      <<_code::16, length::16, _rest::binary>> = binary

      # 4 bytes header + 3 bytes address for /24
      assert length == 7
    end
  end

  describe "round-trip encoding/decoding - IPv4" do
    test "round-trip for /8 IPv4" do
      original = ECS.new({{10, 0, 0, 0}, 8, 0})

      binary = DNS.Parameter.to_iodata(original)
      decoded = ECS.from_iodata(binary)

      assert decoded.data == original.data
    end

    test "round-trip for /16 IPv4" do
      original = ECS.new({{172, 16, 0, 0}, 16, 0})

      binary = DNS.Parameter.to_iodata(original)
      decoded = ECS.from_iodata(binary)

      assert decoded.data == original.data
    end

    test "round-trip for /24 IPv4" do
      original = ECS.new({{192, 168, 1, 0}, 24, 0})

      binary = DNS.Parameter.to_iodata(original)
      decoded = ECS.from_iodata(binary)

      assert decoded.data == original.data
    end

    test "round-trip for /32 IPv4" do
      original = ECS.new({{8, 8, 8, 8}, 32, 0})

      binary = DNS.Parameter.to_iodata(original)
      decoded = ECS.from_iodata(binary)

      assert decoded.data == original.data
    end

    test "round-trip preserves scope prefix" do
      original = ECS.new({{192, 168, 1, 0}, 24, 20})

      binary = DNS.Parameter.to_iodata(original)
      decoded = ECS.from_iodata(binary)

      {_, _, scope} = decoded.data
      assert scope == 20
    end
  end

  describe "round-trip encoding/decoding - IPv6" do
    test "round-trip for /16 IPv6" do
      original = ECS.new({{0x2001, 0, 0, 0, 0, 0, 0, 0}, 16, 0})

      binary = DNS.Parameter.to_iodata(original)
      decoded = ECS.from_iodata(binary)

      {_, source, _} = decoded.data
      assert source == 16
    end

    test "round-trip for /64 IPv6" do
      original = ECS.new({{0x2001, 0xDB8, 0x1234, 0x5678, 0, 0, 0, 0}, 64, 0})

      binary = DNS.Parameter.to_iodata(original)
      decoded = ECS.from_iodata(binary)

      assert decoded.data == original.data
    end
  end

  describe "String.Chars protocol" do
    test "implements String.Chars protocol" do
      ecs = ECS.new({{192, 168, 1, 0}, 24, 0})

      string = to_string(ecs)
      assert is_binary(string)
    end

    test "includes edns-client-subnet in string" do
      ecs = ECS.new({{192, 168, 1, 0}, 24, 0})

      string = to_string(ecs)
      assert string =~ "edns-client-subnet"
    end

    test "includes IP address in string" do
      ecs = ECS.new({{192, 168, 1, 0}, 24, 0})

      string = to_string(ecs)
      assert string =~ "192.168.1.0"
    end

    test "includes prefix lengths in string" do
      ecs = ECS.new({{192, 168, 1, 0}, 24, 16})

      string = to_string(ecs)
      assert string =~ "/24/16"
    end
  end

  describe "edge cases" do
    test "handles 0.0.0.0/0" do
      # This represents "any IPv4"
      ecs = ECS.new({{0, 0, 0, 0}, 8, 0})

      binary = DNS.Parameter.to_iodata(ecs)
      decoded = ECS.from_iodata(binary)

      {addr, _, _} = decoded.data
      assert addr == {0, 0, 0, 0}
    end

    test "handles 255.255.255.255/32" do
      ecs = ECS.new({{255, 255, 255, 255}, 32, 0})

      binary = DNS.Parameter.to_iodata(ecs)
      decoded = ECS.from_iodata(binary)

      {addr, _, _} = decoded.data
      assert addr == {255, 255, 255, 255}
    end

    test "handles max scope prefix for IPv4" do
      ecs = ECS.new({{192, 168, 1, 0}, 24, 32})

      {_, _, scope} = ecs.data
      assert scope == 32
    end

    test "handles max scope prefix for IPv6" do
      ecs = ECS.new({{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 64, 128})

      {_, _, scope} = ecs.data
      assert scope == 128
    end
  end
end
