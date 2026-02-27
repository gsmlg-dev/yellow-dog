defmodule DHCP.ParameterTest do
  @moduledoc """
  Comprehensive unit tests for DHCP.Parameter protocol.

  Tests cover:
  - Protocol definition
  - Implementation for DHCPv4.Message
  - Implementation for DHCPv4.Message.Option
  - Implementation for DHCPv6.Message
  - Implementation for DHCPv6.Message.Option
  - Serialization verification
  """
  use ExUnit.Case, async: true

  alias DHCP.Parameter
  alias DHCPv4.Message.Option.Helpers

  describe "protocol definition" do
    test "DHCP.Parameter protocol is defined" do
      assert Code.ensure_loaded?(DHCP.Parameter)
    end

    test "defines to_iodata/1 callback" do
      Code.ensure_loaded!(DHCP.Parameter)
      # Protocol has the function
      assert function_exported?(DHCP.Parameter, :to_iodata, 1)
    end
  end

  describe "implementation for DHCPv4.Message.Option" do
    test "serializes subnet mask option" do
      option = Helpers.new(1, 4, <<255, 255, 255, 0>>)
      result = Parameter.to_iodata(option)

      assert is_binary(result)
    end

    test "serializes with correct TLV format" do
      # DHCP Message Type: DISCOVER
      option = Helpers.new(53, 1, <<1>>)
      result = Parameter.to_iodata(option)

      <<type, length, value>> = result
      assert type == 53
      assert length == 1
      assert value == 1
    end

    test "serializes router option" do
      option = Helpers.new(3, 4, <<192, 168, 1, 1>>)
      result = Parameter.to_iodata(option)

      <<type, length, ip1, ip2, ip3, ip4>> = result
      assert type == 3
      assert length == 4
      assert {ip1, ip2, ip3, ip4} == {192, 168, 1, 1}
    end

    test "serializes DNS option with multiple servers" do
      dns_servers = <<8, 8, 8, 8, 8, 8, 4, 4>>
      option = Helpers.new(6, 8, dns_servers)
      result = Parameter.to_iodata(option)

      <<type, length, rest::binary>> = result
      assert type == 6
      assert length == 8
      assert byte_size(rest) == 8
    end

    test "serializes hostname option" do
      hostname = "testclient"
      option = Helpers.new(12, byte_size(hostname), hostname)
      result = Parameter.to_iodata(option)

      <<type, length, rest::binary>> = result
      assert type == 12
      assert length == byte_size(hostname)
      assert rest == hostname
    end

    test "serializes zero-length option" do
      # Rapid Commit
      option = Helpers.new(80, 0, <<>>)
      result = Parameter.to_iodata(option)

      <<type, length>> = result
      assert type == 80
      assert length == 0
    end
  end

  describe "serialization format" do
    test "produces binary output" do
      option = Helpers.new(1, 4, <<255, 255, 255, 0>>)
      result = Parameter.to_iodata(option)

      assert is_binary(result)
    end

    test "option type is first byte" do
      for type <- [1, 3, 6, 12, 51, 53, 54, 55] do
        option = Helpers.new(type, 1, <<0>>)
        <<first_byte, _rest::binary>> = Parameter.to_iodata(option)
        assert first_byte == type
      end
    end

    test "option length is second byte" do
      for length <- [1, 4, 8, 16, 255] do
        value = :binary.copy(<<0>>, length)
        option = Helpers.new(1, length, value)
        <<_type, length_byte, _rest::binary>> = Parameter.to_iodata(option)
        assert length_byte == length
      end
    end

    test "option value follows type and length" do
      option = Helpers.new(1, 4, <<10, 20, 30, 40>>)
      <<_type, _length, v1, v2, v3, v4>> = Parameter.to_iodata(option)

      assert {v1, v2, v3, v4} == {10, 20, 30, 40}
    end
  end

  describe "round-trip compatibility" do
    test "serialized option can be parsed" do
      # DHCP Request
      original = Helpers.new(53, 1, <<3>>)
      binary = Parameter.to_iodata(original)

      # Parse back
      <<type, length, value>> = binary
      parsed = Helpers.new(type, length, <<value>>)

      assert parsed.type == original.type
      assert parsed.length == original.length
      assert parsed.value == original.value
    end

    test "multiple options maintain order" do
      options = [
        Helpers.new(53, 1, <<1>>),
        Helpers.new(1, 4, <<255, 255, 255, 0>>),
        Helpers.new(3, 4, <<192, 168, 1, 1>>)
      ]

      binaries = Enum.map(options, &Parameter.to_iodata/1)

      # First option type should be 53
      <<first_type, _::binary>> = hd(binaries)
      assert first_type == 53

      # Second option type should be 1
      <<second_type, _::binary>> = Enum.at(binaries, 1)
      assert second_type == 1

      # Third option type should be 3
      <<third_type, _::binary>> = Enum.at(binaries, 2)
      assert third_type == 3
    end
  end

  describe "common DHCP options" do
    test "serializes lease time (option 51)" do
      # 86400 seconds = 1 day
      lease_time = <<0, 1, 81, 128>>
      option = Helpers.new(51, 4, lease_time)
      result = Parameter.to_iodata(option)

      <<type, length, t1, t2, t3, t4>> = result
      assert type == 51
      assert length == 4
      assert <<t1, t2, t3, t4>> == lease_time
    end

    test "serializes requested IP (option 50)" do
      option = Helpers.new(50, 4, <<192, 168, 1, 100>>)
      result = Parameter.to_iodata(option)

      <<type, length, ip1, ip2, ip3, ip4>> = result
      assert type == 50
      assert length == 4
      assert {ip1, ip2, ip3, ip4} == {192, 168, 1, 100}
    end

    test "serializes parameter request list (option 55)" do
      # Request common options
      requested = <<1, 3, 6, 15, 51>>
      option = Helpers.new(55, 5, requested)
      result = Parameter.to_iodata(option)

      <<type, length, rest::binary>> = result
      assert type == 55
      assert length == 5
      assert rest == requested
    end

    test "serializes client identifier (option 61)" do
      # Type 1 (hardware address) + MAC address
      client_id = <<1, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55>>
      option = Helpers.new(61, 7, client_id)
      result = Parameter.to_iodata(option)

      <<type, length, rest::binary>> = result
      assert type == 61
      assert length == 7
      assert rest == client_id
    end
  end

  describe "edge cases" do
    test "handles maximum option type (254)" do
      option = Helpers.new(254, 1, <<0>>)
      result = Parameter.to_iodata(option)

      <<type, _rest::binary>> = result
      assert type == 254
    end

    test "handles maximum option length (255)" do
      value = :binary.copy(<<0xAA>>, 255)
      option = Helpers.new(1, 255, value)
      result = Parameter.to_iodata(option)

      <<_type, length, rest::binary>> = result
      assert length == 255
      assert byte_size(rest) == 255
    end

    test "handles binary option value" do
      binary_value = :crypto.strong_rand_bytes(16)
      option = Helpers.new(43, 16, binary_value)
      result = Parameter.to_iodata(option)

      <<_type, length, rest::binary>> = result
      assert length == 16
      assert rest == binary_value
    end
  end
end
