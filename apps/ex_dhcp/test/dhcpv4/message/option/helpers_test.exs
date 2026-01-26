defmodule DHCPv4.Message.Option.HelpersTest do
  @moduledoc """
  Comprehensive unit tests for DHCPv4.Message.Option.Helpers.

  Tests cover:
  - Module structure and exports
  - Magic cookie constant
  - End option constant
  - Option struct creation (new/3)
  - Binary parsing (from_iodata/1)
  - Binary serialization (to_iodata/1)
  - Round-trip encoding/decoding
  """
  use ExUnit.Case, async: true

  alias DHCPv4.Message.Option
  alias DHCPv4.Message.Option.Helpers

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Helpers)
    end

    test "exports magic_cookie/0" do
      Code.ensure_loaded!(Helpers)
      assert Kernel.function_exported?(Helpers, :magic_cookie, 0)
    end

    test "exports end_option/0" do
      Code.ensure_loaded!(Helpers)
      assert Kernel.function_exported?(Helpers, :end_option, 0)
    end

    test "exports new/3" do
      Code.ensure_loaded!(Helpers)
      assert Kernel.function_exported?(Helpers, :new, 3)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Helpers)
      assert Kernel.function_exported?(Helpers, :from_iodata, 1)
    end

    test "exports to_iodata/1" do
      Code.ensure_loaded!(Helpers)
      assert Kernel.function_exported?(Helpers, :to_iodata, 1)
    end
  end

  describe "magic_cookie/0" do
    test "returns expected magic cookie value" do
      cookie = Helpers.magic_cookie()

      assert cookie == <<99, 130, 83, 99>>
    end

    test "magic cookie is 4 bytes" do
      cookie = Helpers.magic_cookie()

      assert byte_size(cookie) == 4
    end

    test "magic cookie matches RFC 2131 specification" do
      # RFC 2131: 99.130.83.99 in decimal (0x63825363)
      cookie = Helpers.magic_cookie()

      <<a, b, c, d>> = cookie
      assert {a, b, c, d} == {99, 130, 83, 99}
    end

    test "magic cookie is consistent across calls" do
      cookie1 = Helpers.magic_cookie()
      cookie2 = Helpers.magic_cookie()

      assert cookie1 == cookie2
    end
  end

  describe "end_option/0" do
    test "returns end option value 0xFF" do
      end_opt = Helpers.end_option()

      assert end_opt == 0xFF
    end

    test "end option is 255 in decimal" do
      end_opt = Helpers.end_option()

      assert end_opt == 255
    end

    test "end option is consistent across calls" do
      end1 = Helpers.end_option()
      end2 = Helpers.end_option()

      assert end1 == end2
    end
  end

  describe "new/3" do
    test "creates option struct with type, length, value" do
      opt = Helpers.new(53, 1, <<1>>)

      assert %Option{} = opt
      assert opt.type == 53
      assert opt.length == 1
      assert opt.value == <<1>>
    end

    test "creates message type option (type 53)" do
      # DHCPDISCOVER
      opt = Helpers.new(53, 1, <<1>>)

      assert opt.type == 53
      assert opt.value == <<1>>
    end

    test "creates subnet mask option (type 1)" do
      opt = Helpers.new(1, 4, <<255, 255, 255, 0>>)

      assert opt.type == 1
      assert opt.length == 4
      assert opt.value == <<255, 255, 255, 0>>
    end

    test "creates router option (type 3)" do
      opt = Helpers.new(3, 4, <<192, 168, 1, 1>>)

      assert opt.type == 3
      assert opt.length == 4
    end

    test "creates DNS server option (type 6)" do
      # Two DNS servers
      opt = Helpers.new(6, 8, <<8, 8, 8, 8, 8, 8, 4, 4>>)

      assert opt.type == 6
      assert opt.length == 8
    end

    test "creates hostname option (type 12)" do
      hostname = "myhost"
      opt = Helpers.new(12, byte_size(hostname), hostname)

      assert opt.type == 12
      assert opt.length == 6
      assert opt.value == "myhost"
    end

    test "creates lease time option (type 51)" do
      # 86400 seconds = 1 day
      opt = Helpers.new(51, 4, <<0, 1, 81, 128>>)

      assert opt.type == 51
      assert opt.length == 4
    end

    test "creates server identifier option (type 54)" do
      opt = Helpers.new(54, 4, <<192, 168, 1, 1>>)

      assert opt.type == 54
      assert opt.length == 4
    end

    test "creates parameter request list (type 55)" do
      # Request subnet, router, DNS, hostname
      opt = Helpers.new(55, 4, <<1, 3, 6, 12>>)

      assert opt.type == 55
      assert opt.length == 4
    end

    test "creates client identifier option (type 61)" do
      # Hardware type 1 (Ethernet) + MAC address
      opt = Helpers.new(61, 7, <<1, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55>>)

      assert opt.type == 61
      assert opt.length == 7
    end

    test "handles empty value" do
      opt = Helpers.new(100, 0, <<>>)

      assert opt.type == 100
      assert opt.length == 0
      assert opt.value == <<>>
    end

    test "handles large value" do
      large_value = :crypto.strong_rand_bytes(255)
      opt = Helpers.new(200, 255, large_value)

      assert opt.type == 200
      assert opt.length == 255
      assert opt.value == large_value
    end
  end

  describe "from_iodata/1" do
    test "parses single byte value option" do
      # Message type option: type=53, length=1, value=1 (DISCOVER)
      data = <<53, 1, 1>>

      opt = Helpers.from_iodata(data)

      assert opt.type == 53
      assert opt.length == 1
      assert opt.value == <<1>>
    end

    test "parses 4-byte IP address option" do
      # Subnet mask: type=1, length=4, value=255.255.255.0
      data = <<1, 4, 255, 255, 255, 0>>

      opt = Helpers.from_iodata(data)

      assert opt.type == 1
      assert opt.length == 4
      assert opt.value == <<255, 255, 255, 0>>
    end

    test "parses variable length string option" do
      # Hostname: type=12, length=7, value="myhost1"
      data = <<12, 7, "myhost1">>

      opt = Helpers.from_iodata(data)

      assert opt.type == 12
      assert opt.length == 7
      assert opt.value == "myhost1"
    end

    test "parses multiple IP addresses option" do
      # DNS servers: type=6, length=8, value=8.8.8.8 and 8.8.4.4
      data = <<6, 8, 8, 8, 8, 8, 8, 8, 4, 4>>

      opt = Helpers.from_iodata(data)

      assert opt.type == 6
      assert opt.length == 8
      assert opt.value == <<8, 8, 8, 8, 8, 8, 4, 4>>
    end

    test "parses 32-bit integer option" do
      # Lease time: type=51, length=4, value=86400 (0x00015180)
      data = <<51, 4, 0, 1, 81, 128>>

      opt = Helpers.from_iodata(data)

      assert opt.type == 51
      assert opt.length == 4
      <<lease_time::32>> = opt.value
      assert lease_time == 86400
    end

    test "parses zero-length option" do
      data = <<100, 0>>

      opt = Helpers.from_iodata(data)

      assert opt.type == 100
      assert opt.length == 0
      assert opt.value == <<>>
    end

    test "parses maximum length option (255 bytes)" do
      value = :crypto.strong_rand_bytes(255)
      data = <<200, 255>> <> value

      opt = Helpers.from_iodata(data)

      assert opt.type == 200
      assert opt.length == 255
      assert opt.value == value
    end
  end

  describe "to_iodata/1" do
    test "serializes single byte value option" do
      opt = %Option{type: 53, length: 1, value: <<1>>}

      result = Helpers.to_iodata(opt)

      assert result == <<53, 1, 1>>
    end

    test "serializes 4-byte IP address option" do
      opt = %Option{type: 1, length: 4, value: <<255, 255, 255, 0>>}

      result = Helpers.to_iodata(opt)

      assert result == <<1, 4, 255, 255, 255, 0>>
    end

    test "serializes variable length string option" do
      opt = %Option{type: 12, length: 6, value: "myhost"}

      result = Helpers.to_iodata(opt)

      assert result == <<12, 6, "myhost">>
    end

    test "serializes multiple IP addresses option" do
      opt = %Option{type: 6, length: 8, value: <<8, 8, 8, 8, 8, 8, 4, 4>>}

      result = Helpers.to_iodata(opt)

      assert result == <<6, 8, 8, 8, 8, 8, 8, 8, 4, 4>>
    end

    test "serializes zero-length option" do
      opt = %Option{type: 100, length: 0, value: <<>>}

      result = Helpers.to_iodata(opt)

      assert result == <<100, 0>>
    end

    test "serializes maximum length option" do
      value = :crypto.strong_rand_bytes(255)
      opt = %Option{type: 200, length: 255, value: value}

      result = Helpers.to_iodata(opt)

      assert result == <<200, 255>> <> value
    end

    test "returns binary type" do
      opt = %Option{type: 1, length: 4, value: <<192, 168, 1, 1>>}

      result = Helpers.to_iodata(opt)

      assert is_binary(result)
    end
  end

  describe "round-trip encoding/decoding" do
    test "message type option survives round-trip" do
      # DHCPREQUEST
      original = Helpers.new(53, 1, <<3>>)

      binary = Helpers.to_iodata(original)
      decoded = Helpers.from_iodata(binary)

      assert decoded.type == original.type
      assert decoded.length == original.length
      assert decoded.value == original.value
    end

    test "subnet mask option survives round-trip" do
      original = Helpers.new(1, 4, <<255, 255, 0, 0>>)

      binary = Helpers.to_iodata(original)
      decoded = Helpers.from_iodata(binary)

      assert decoded == original
    end

    test "hostname option survives round-trip" do
      hostname = "test-host"
      original = Helpers.new(12, byte_size(hostname), hostname)

      binary = Helpers.to_iodata(original)
      decoded = Helpers.from_iodata(binary)

      assert decoded.value == hostname
    end

    test "DNS servers option survives round-trip" do
      servers = <<8, 8, 8, 8, 1, 1, 1, 1, 208, 67, 222, 222>>
      original = Helpers.new(6, byte_size(servers), servers)

      binary = Helpers.to_iodata(original)
      decoded = Helpers.from_iodata(binary)

      assert decoded.value == servers
    end

    test "lease time option survives round-trip" do
      # 3600 seconds
      original = Helpers.new(51, 4, <<0, 0, 14, 16>>)

      binary = Helpers.to_iodata(original)
      decoded = Helpers.from_iodata(binary)

      assert decoded.value == original.value
    end

    test "client identifier option survives round-trip" do
      client_id = <<1, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>
      original = Helpers.new(61, byte_size(client_id), client_id)

      binary = Helpers.to_iodata(original)
      decoded = Helpers.from_iodata(binary)

      assert decoded.value == client_id
    end

    test "parameter request list survives round-trip" do
      params = <<1, 3, 6, 12, 15, 28, 42, 51, 54, 58, 59>>
      original = Helpers.new(55, byte_size(params), params)

      binary = Helpers.to_iodata(original)
      decoded = Helpers.from_iodata(binary)

      assert decoded.value == params
    end

    test "vendor specific option survives round-trip" do
      vendor_data = "PXEClient:Arch:00000:UNDI:002001"
      original = Helpers.new(60, byte_size(vendor_data), vendor_data)

      binary = Helpers.to_iodata(original)
      decoded = Helpers.from_iodata(binary)

      assert decoded.value == vendor_data
    end
  end

  describe "edge cases" do
    test "handles type 0 (pad option)" do
      # Pad option has no length or value
      opt = Helpers.new(0, 0, <<>>)

      assert opt.type == 0
    end

    test "handles all message types" do
      # DHCP message types 1-8
      for msg_type <- 1..8 do
        opt = Helpers.new(53, 1, <<msg_type>>)
        assert opt.value == <<msg_type>>
      end
    end

    test "handles binary with exact length match" do
      value = <<1, 2, 3, 4, 5>>
      opt = Helpers.new(99, 5, value)

      binary = Helpers.to_iodata(opt)
      decoded = Helpers.from_iodata(binary)

      assert decoded.value == value
      assert decoded.length == 5
    end
  end

  describe "DHCP option type coverage" do
    test "subnet mask option (type 1)" do
      opt = Helpers.new(1, 4, <<255, 255, 255, 0>>)
      assert opt.type == 1
    end

    test "time offset option (type 2)" do
      # Signed 32-bit seconds from UTC
      # -18000 (EST)
      opt = Helpers.new(2, 4, <<0xFF, 0xFF, 0xB9, 0xB0>>)
      assert opt.type == 2
    end

    test "routers option (type 3)" do
      opt = Helpers.new(3, 4, <<192, 168, 1, 1>>)
      assert opt.type == 3
    end

    test "domain name server option (type 6)" do
      opt = Helpers.new(6, 4, <<8, 8, 8, 8>>)
      assert opt.type == 6
    end

    test "hostname option (type 12)" do
      opt = Helpers.new(12, 4, "test")
      assert opt.type == 12
    end

    test "domain name option (type 15)" do
      opt = Helpers.new(15, 11, "example.com")
      assert opt.type == 15
    end

    test "broadcast address option (type 28)" do
      opt = Helpers.new(28, 4, <<192, 168, 1, 255>>)
      assert opt.type == 28
    end

    test "requested IP address option (type 50)" do
      opt = Helpers.new(50, 4, <<192, 168, 1, 100>>)
      assert opt.type == 50
    end

    test "IP address lease time option (type 51)" do
      # 3600 seconds
      opt = Helpers.new(51, 4, <<0, 0, 14, 16>>)
      assert opt.type == 51
    end

    test "DHCP message type option (type 53)" do
      opt = Helpers.new(53, 1, <<1>>)
      assert opt.type == 53
    end

    test "server identifier option (type 54)" do
      opt = Helpers.new(54, 4, <<192, 168, 1, 1>>)
      assert opt.type == 54
    end

    test "parameter request list option (type 55)" do
      opt = Helpers.new(55, 3, <<1, 3, 6>>)
      assert opt.type == 55
    end

    test "maximum DHCP message size option (type 57)" do
      # 1500 bytes
      opt = Helpers.new(57, 2, <<5, 220>>)
      assert opt.type == 57
    end

    test "renewal time option (type 58)" do
      # T1 = 1800 seconds
      opt = Helpers.new(58, 4, <<0, 0, 7, 8>>)
      assert opt.type == 58
    end

    test "rebinding time option (type 59)" do
      # T2 = 3168 seconds
      opt = Helpers.new(59, 4, <<0, 0, 12, 96>>)
      assert opt.type == 59
    end

    test "vendor class identifier option (type 60)" do
      opt = Helpers.new(60, 9, "PXEClient")
      assert opt.type == 60
    end

    test "client identifier option (type 61)" do
      opt = Helpers.new(61, 7, <<1, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55>>)
      assert opt.type == 61
    end

    test "TFTP server name option (type 66)" do
      opt = Helpers.new(66, 10, "tftp.local")
      assert opt.type == 66
    end

    test "bootfile name option (type 67)" do
      opt = Helpers.new(67, 15, "pxelinux.0\x00\x00\x00\x00\x00")
      assert opt.type == 67
    end
  end
end
