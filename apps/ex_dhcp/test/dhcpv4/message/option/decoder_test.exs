defmodule DHCPv4.Message.Option.DecoderTest do
  @moduledoc """
  Comprehensive unit tests for DHCPv4.Message.Option.Decoder.

  Tests cover:
  - Module structure and exports
  - parse/1 with magic cookie validation
  - parse/1 with various DHCP options
  - decode_option_value/3 for common option types
  - Error handling for malformed data

  Note: decode_option_value/3 returns {name, type, value} tuples where:
  - name: Human-readable option name string
  - type: Atom indicating value type (:ip, :ip_list, :int, :binary, :bool, etc.)
  - value: Decoded value in appropriate Elixir format
  """
  use ExUnit.Case, async: true

  alias DHCPv4.Message.Option.Decoder

  # DHCP magic cookie (RFC 2131)
  @magic_cookie <<99, 130, 83, 99>>
  @end_option 0xFF

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Decoder)
    end

    test "exports parse/1" do
      Code.ensure_loaded!(Decoder)
      assert Kernel.function_exported?(Decoder, :parse, 1)
    end

    test "exports decode_option_value/3" do
      Code.ensure_loaded!(Decoder)
      assert Kernel.function_exported?(Decoder, :decode_option_value, 3)
    end
  end

  describe "parse/1 - magic cookie validation" do
    test "returns ok tuple for valid options with magic cookie" do
      data = @magic_cookie <> <<@end_option>>

      assert {:ok, []} = Decoder.parse(data)
    end

    test "returns error for missing magic cookie" do
      data = <<1, 4, 255, 255, 255, 0, @end_option>>

      assert {:error, message} = Decoder.parse(data)
      assert message =~ "magic cookie"
    end

    test "returns error for wrong magic cookie" do
      wrong_cookie = <<0, 0, 0, 0>>
      data = wrong_cookie <> <<@end_option>>

      assert {:error, message} = Decoder.parse(data)
      assert message =~ "magic cookie"
    end

    test "returns empty list for empty data" do
      assert {:ok, []} = Decoder.parse(<<>>)
    end
  end

  describe "parse/1 - single options" do
    test "parses subnet mask option (1)" do
      # Option 1: Subnet Mask, length 4, value 255.255.255.0
      data = @magic_cookie <> <<1, 4, 255, 255, 255, 0, @end_option>>

      assert {:ok, options} = Decoder.parse(data)
      assert length(options) == 1

      [opt] = options
      assert opt.type == 1
      assert opt.length == 4
    end

    test "parses router option (3)" do
      # Option 3: Router, length 4, value 192.168.1.1
      data = @magic_cookie <> <<3, 4, 192, 168, 1, 1, @end_option>>

      assert {:ok, options} = Decoder.parse(data)
      assert length(options) == 1

      [opt] = options
      assert opt.type == 3
      assert opt.length == 4
    end

    test "parses DNS servers option (6)" do
      # Option 6: DNS Servers, length 8, two servers
      data = @magic_cookie <> <<6, 8, 8, 8, 8, 8, 8, 8, 4, 4, @end_option>>

      assert {:ok, options} = Decoder.parse(data)
      assert length(options) == 1

      [opt] = options
      assert opt.type == 6
      assert opt.length == 8
    end

    test "parses hostname option (12)" do
      hostname = "test-host"
      len = byte_size(hostname)
      data = @magic_cookie <> <<12, len>> <> hostname <> <<@end_option>>

      assert {:ok, options} = Decoder.parse(data)
      assert length(options) == 1

      [opt] = options
      assert opt.type == 12
      assert opt.length == len
    end

    test "parses requested IP option (50)" do
      # Option 50: Requested IP Address, length 4
      data = @magic_cookie <> <<50, 4, 192, 168, 1, 100, @end_option>>

      assert {:ok, options} = Decoder.parse(data)
      assert length(options) == 1

      [opt] = options
      assert opt.type == 50
      assert opt.length == 4
    end

    test "parses lease time option (51)" do
      # Option 51: IP Address Lease Time, length 4, value 3600 seconds
      data = @magic_cookie <> <<51, 4, 0, 0, 14, 16, @end_option>>

      assert {:ok, options} = Decoder.parse(data)
      assert length(options) == 1

      [opt] = options
      assert opt.type == 51
      assert opt.length == 4
    end

    test "parses message type option (53)" do
      # Option 53: DHCP Message Type, length 1, value 1 (DISCOVER)
      data = @magic_cookie <> <<53, 1, 1, @end_option>>

      assert {:ok, options} = Decoder.parse(data)
      assert length(options) == 1

      [opt] = options
      assert opt.type == 53
      assert opt.length == 1
    end

    test "parses server identifier option (54)" do
      # Option 54: Server Identifier, length 4
      data = @magic_cookie <> <<54, 4, 192, 168, 1, 1, @end_option>>

      assert {:ok, options} = Decoder.parse(data)
      assert length(options) == 1

      [opt] = options
      assert opt.type == 54
      assert opt.length == 4
    end
  end

  describe "parse/1 - multiple options" do
    test "parses multiple options in sequence" do
      # Subnet mask + Router + DNS server
      data =
        @magic_cookie <>
          <<1, 4, 255, 255, 255, 0>> <>
          <<3, 4, 192, 168, 1, 1>> <>
          <<6, 4, 8, 8, 8, 8>> <>
          <<@end_option>>

      assert {:ok, options} = Decoder.parse(data)
      assert length(options) == 3

      types = Enum.map(options, & &1.type)
      assert types == [1, 3, 6]
    end

    test "parses typical DHCP DISCOVER options" do
      # Message type (DISCOVER) + Requested IP + Parameter Request List
      data =
        @magic_cookie <>
          <<53, 1, 1>> <>
          <<50, 4, 192, 168, 1, 100>> <>
          <<55, 4, 1, 3, 6, 15>> <>
          <<@end_option>>

      assert {:ok, options} = Decoder.parse(data)
      assert length(options) == 3
    end

    test "parses typical DHCP OFFER options" do
      # Message type (OFFER) + Server ID + Lease time + Subnet + Router
      data =
        @magic_cookie <>
          <<53, 1, 2>> <>
          <<54, 4, 192, 168, 1, 1>> <>
          <<51, 4, 0, 0, 14, 16>> <>
          <<1, 4, 255, 255, 255, 0>> <>
          <<3, 4, 192, 168, 1, 1>> <>
          <<@end_option>>

      assert {:ok, options} = Decoder.parse(data)
      assert length(options) == 5
    end
  end

  describe "parse/1 - end option handling" do
    test "stops parsing at end option" do
      # Data after end option should be ignored
      data =
        @magic_cookie <>
          <<53, 1, 1>> <>
          <<@end_option>> <>
          <<3, 4, 192, 168, 1, 1>>

      assert {:ok, options} = Decoder.parse(data)
      # Only the message type option should be parsed
      assert length(options) == 1
    end

    test "handles end option with padding after it" do
      data =
        @magic_cookie <>
          <<53, 1, 1>> <>
          <<@end_option>> <>
          <<0, 0, 0, 0>>

      assert {:ok, options} = Decoder.parse(data)
      assert length(options) == 1
    end
  end

  describe "decode_option_value/3 - common options" do
    test "decodes subnet mask (option 1)" do
      value = <<255, 255, 255, 0>>
      {"Subnet Mask", :ip, ip} = Decoder.decode_option_value(1, 4, value)

      assert ip == {255, 255, 255, 0}
    end

    test "decodes router (option 3)" do
      value = <<192, 168, 1, 1>>
      {"Router", :ip_list, routers} = Decoder.decode_option_value(3, 4, value)

      assert routers == [{192, 168, 1, 1}]
    end

    test "decodes multiple routers (option 3)" do
      value = <<192, 168, 1, 1, 192, 168, 1, 2>>
      {"Router", :ip_list, routers} = Decoder.decode_option_value(3, 8, value)

      assert routers == [{192, 168, 1, 1}, {192, 168, 1, 2}]
    end

    test "decodes DNS servers (option 6)" do
      value = <<8, 8, 8, 8, 8, 8, 4, 4>>
      {"Domain Name Server", :ip_list, servers} = Decoder.decode_option_value(6, 8, value)

      assert servers == [{8, 8, 8, 8}, {8, 8, 4, 4}]
    end

    test "decodes hostname (option 12)" do
      value = "test-host"
      {"Host Name", :binary, hostname} = Decoder.decode_option_value(12, byte_size(value), value)

      assert hostname == "test-host"
    end

    test "decodes domain name (option 15)" do
      value = "example.com"
      {"Domain Name", :binary, domain} = Decoder.decode_option_value(15, byte_size(value), value)

      assert domain == "example.com"
    end

    test "decodes broadcast address (option 28)" do
      value = <<192, 168, 1, 255>>
      {"Broadcast Address", :ip, addr} = Decoder.decode_option_value(28, 4, value)

      assert addr == {192, 168, 1, 255}
    end

    test "decodes requested IP address (option 50)" do
      value = <<192, 168, 1, 100>>
      {"Requested IP Address", :ip, ip} = Decoder.decode_option_value(50, 4, value)

      assert ip == {192, 168, 1, 100}
    end

    test "decodes lease time (option 51)" do
      # 3600 seconds in big-endian
      value = <<0, 0, 14, 16>>
      {"IP Address Lease Time", :int, lease_time} = Decoder.decode_option_value(51, 4, value)

      assert lease_time == 3600
    end

    test "decodes DHCP message type (option 53) - DISCOVER" do
      {"DHCP Message Type", :binary, message} = Decoder.decode_option_value(53, 1, <<1>>)
      assert message =~ "DHCPDISCOVER"
    end

    test "decodes DHCP message type (option 53) - OFFER" do
      {"DHCP Message Type", :binary, message} = Decoder.decode_option_value(53, 1, <<2>>)
      assert message =~ "DHCPOFFER"
    end

    test "decodes DHCP message type (option 53) - REQUEST" do
      {"DHCP Message Type", :binary, message} = Decoder.decode_option_value(53, 1, <<3>>)
      assert message =~ "DHCPREQUEST"
    end

    test "decodes DHCP message type (option 53) - DECLINE" do
      {"DHCP Message Type", :binary, message} = Decoder.decode_option_value(53, 1, <<4>>)
      assert message =~ "DHCPDECLINE"
    end

    test "decodes DHCP message type (option 53) - ACK" do
      {"DHCP Message Type", :binary, message} = Decoder.decode_option_value(53, 1, <<5>>)
      assert message =~ "DHCPACK"
    end

    test "decodes DHCP message type (option 53) - NAK" do
      {"DHCP Message Type", :binary, message} = Decoder.decode_option_value(53, 1, <<6>>)
      assert message =~ "DHCPNAK"
    end

    test "decodes DHCP message type (option 53) - RELEASE" do
      {"DHCP Message Type", :binary, message} = Decoder.decode_option_value(53, 1, <<7>>)
      assert message =~ "DHCPRELEASE"
    end

    test "decodes DHCP message type (option 53) - INFORM" do
      {"DHCP Message Type", :binary, message} = Decoder.decode_option_value(53, 1, <<8>>)
      assert message =~ "DHCPINFORM"
    end

    test "decodes server identifier (option 54)" do
      value = <<192, 168, 1, 1>>
      {"Server Identifier", :ip, server_id} = Decoder.decode_option_value(54, 4, value)

      assert server_id == {192, 168, 1, 1}
    end

    test "decodes parameter request list (option 55)" do
      value = <<1, 3, 6, 15, 51>>
      {"Parameter Request List", :int_list, params} = Decoder.decode_option_value(55, 5, value)

      assert params == [1, 3, 6, 15, 51]
    end

    test "decodes DHCP message (option 56)" do
      message = "Error: no available addresses"

      {"Message", :binary, decoded_message} =
        Decoder.decode_option_value(56, byte_size(message), message)

      assert decoded_message == message
    end

    test "decodes maximum message size (option 57)" do
      # 576 bytes in big-endian
      value = <<2, 64>>
      {"Maximum DHCP Message Size", :int, max_size} = Decoder.decode_option_value(57, 2, value)

      assert max_size == 576
    end

    test "decodes renewal time T1 (option 58)" do
      # 1800 seconds in big-endian
      value = <<0, 0, 7, 8>>
      {"Renewal (T1) Time Value", :int, t1} = Decoder.decode_option_value(58, 4, value)

      assert t1 == 1800
    end

    test "decodes rebinding time T2 (option 59)" do
      # 3150 seconds in big-endian
      value = <<0, 0, 12, 78>>
      {"Rebinding (T2) Time Value", :int, t2} = Decoder.decode_option_value(59, 4, value)

      assert t2 == 3150
    end

    test "decodes vendor class identifier (option 60)" do
      value = "MSFT 5.0"

      {"Vendor class identifier", :int_list, decoded} =
        Decoder.decode_option_value(60, byte_size(value), value)

      # Returns list of bytes (int_list)
      assert is_list(decoded)
    end

    test "decodes client identifier (option 61) - Ethernet" do
      # Hardware type 1 (Ethernet) + MAC address
      value = <<1, 0, 17, 34, 51, 68, 85>>

      {"Client-identifier", :type_identifier, {hw_type, identifier}} =
        Decoder.decode_option_value(61, 7, value)

      assert hw_type == "Ethernet"
      assert is_binary(identifier)
    end

    test "decodes client identifier (option 61) - Non-hardware" do
      # Hardware type 0 (Non-hardware) + identifier
      value = <<0, "custom-id">>

      {"Client-identifier", :type_identifier, {hw_type, identifier}} =
        Decoder.decode_option_value(61, byte_size(value), value)

      assert hw_type == "Non-hardware"
      assert identifier == "custom-id"
    end

    test "decodes unknown option type" do
      value = <<1, 2, 3, 4>>
      {"Unknown", :raw, decoded} = Decoder.decode_option_value(200, 4, value)

      # Unknown options return the raw value
      assert decoded == value
    end
  end

  describe "decode_option_value/3 - network configuration options" do
    test "decodes time offset (option 2)" do
      # UTC offset in seconds (signed 32-bit)
      value = <<0, 0, 0, 0>>
      {"Time Offset", :int, offset} = Decoder.decode_option_value(2, 4, value)

      assert offset == 0
    end

    test "decodes NTP servers (option 42)" do
      value = <<129, 6, 15, 28, 129, 6, 15, 29>>
      {"NTP Servers", :ip_list, servers} = Decoder.decode_option_value(42, 8, value)

      assert servers == [{129, 6, 15, 28}, {129, 6, 15, 29}]
    end

    test "decodes interface MTU (option 26)" do
      # 1500 bytes in big-endian
      value = <<5, 220>>
      {"Interface MTU", :int, mtu} = Decoder.decode_option_value(26, 2, value)

      assert mtu == 1500
    end

    test "decodes default TTL (option 23)" do
      value = <<64>>
      {"Default IP Time-to-Live", :int, ttl} = Decoder.decode_option_value(23, 1, value)

      assert ttl == 64
    end
  end

  describe "decode_option_value/3 - boolean options" do
    test "decodes IP forwarding enabled (option 19)" do
      {"IP Forwarding Enable/Disable", :bool, enabled} =
        Decoder.decode_option_value(19, 1, <<1>>)

      assert enabled == true

      {"IP Forwarding Enable/Disable", :bool, disabled} =
        Decoder.decode_option_value(19, 1, <<0>>)

      assert disabled == false
    end

    test "decodes all subnets local (option 27)" do
      {"All Subnets are Local", :bool, enabled} = Decoder.decode_option_value(27, 1, <<1>>)
      assert enabled == true

      {"All Subnets are Local", :bool, disabled} = Decoder.decode_option_value(27, 1, <<0>>)
      assert disabled == false
    end

    test "decodes perform router discovery (option 31)" do
      {"Perform Router Discovery", :bool, enabled} = Decoder.decode_option_value(31, 1, <<1>>)
      assert enabled == true

      {"Perform Router Discovery", :bool, disabled} = Decoder.decode_option_value(31, 1, <<0>>)
      assert disabled == false
    end
  end

  describe "decode_option_value/3 - file/path options" do
    test "decodes root path (option 17)" do
      value = "/tftpboot/vmlinuz"
      {"Root Path", :binary, path} = Decoder.decode_option_value(17, byte_size(value), value)

      assert path == value
    end

    test "decodes TFTP server name (option 66)" do
      value = "tftp.example.com"

      {"TFTP server name", :binary, server_name} =
        Decoder.decode_option_value(66, byte_size(value), value)

      assert server_name == value
    end

    test "decodes bootfile name (option 67)" do
      value = "pxelinux.0"

      {"Bootfile name", :binary, bootfile} =
        Decoder.decode_option_value(67, byte_size(value), value)

      assert bootfile == value
    end
  end

  describe "decode_option_value/3 - vendor options" do
    test "decodes vendor specific information (option 43)" do
      value = <<1, 2, 65, 66>>

      {"Vendor Specific Information", :binary, vendor_data} =
        Decoder.decode_option_value(43, 4, value)

      # Vendor specific is returned as raw binary
      assert is_binary(vendor_data)
    end
  end

  describe "decode_option_value/3 - NetBIOS options" do
    test "decodes NetBIOS name servers (option 44)" do
      value = <<192, 168, 1, 10, 192, 168, 1, 11>>

      {"NetBIOS over TCP/IP Name Server", :ip_list, servers} =
        Decoder.decode_option_value(44, 8, value)

      assert servers == [{192, 168, 1, 10}, {192, 168, 1, 11}]
    end

    test "decodes NetBIOS node type (option 46)" do
      # Node types: 1=B-node, 2=P-node, 4=M-node, 8=H-node
      {"NetBIOS over TCP/IP Node Type", :int, node_type_1} =
        Decoder.decode_option_value(46, 1, <<1>>)

      assert node_type_1 == 1

      {"NetBIOS over TCP/IP Node Type", :int, node_type_8} =
        Decoder.decode_option_value(46, 1, <<8>>)

      assert node_type_8 == 8
    end

    test "decodes NetBIOS scope (option 47)" do
      value = "WORKGROUP"

      {"NetBIOS over TCP/IP Scope", :binary, scope} =
        Decoder.decode_option_value(47, byte_size(value), value)

      assert scope == value
    end
  end

  describe "decode_option_value/3 - timezone options" do
    test "decodes POSIX timezone string (option 100)" do
      value = "EST5EDT,M3.2.0,M11.1.0"
      {"TZ-POSIX String", :binary, tz} = Decoder.decode_option_value(100, byte_size(value), value)

      assert tz == value
    end

    test "decodes TZ database string (option 101)" do
      value = "America/New_York"

      {"TZ-Database String", :binary, tz} =
        Decoder.decode_option_value(101, byte_size(value), value)

      assert tz == value
    end
  end

  describe "decode_option_value/3 - additional server options" do
    test "decodes swap server (option 16)" do
      value = <<10, 0, 0, 1>>
      {"Swap Server", :ip, server} = Decoder.decode_option_value(16, 4, value)

      assert server == {10, 0, 0, 1}
    end

    test "decodes time servers (option 4)" do
      value = <<10, 0, 0, 1, 10, 0, 0, 2>>
      {"Time Server", :ip_list, servers} = Decoder.decode_option_value(4, 8, value)

      assert servers == [{10, 0, 0, 1}, {10, 0, 0, 2}]
    end

    test "decodes name servers (option 5)" do
      value = <<10, 0, 0, 1>>
      {"Name Server", :ip_list, servers} = Decoder.decode_option_value(5, 4, value)

      assert servers == [{10, 0, 0, 1}]
    end

    test "decodes log servers (option 7)" do
      value = <<10, 0, 0, 1>>
      {"Log Server", :ip_list, servers} = Decoder.decode_option_value(7, 4, value)

      assert servers == [{10, 0, 0, 1}]
    end

    test "decodes NIS domain (option 40)" do
      value = "example.com"

      {"Network Information Service Domain", :binary, domain} =
        Decoder.decode_option_value(40, byte_size(value), value)

      assert domain == value
    end

    test "decodes NIS servers (option 41)" do
      value = <<10, 0, 0, 1, 10, 0, 0, 2>>

      {"Network Information Servers", :ip_list, servers} =
        Decoder.decode_option_value(41, 8, value)

      assert servers == [{10, 0, 0, 1}, {10, 0, 0, 2}]
    end
  end

  describe "decode_option_value/3 - return tuple format" do
    test "all options return {name, type, value} tuples" do
      # Test a variety of options to ensure consistent tuple format
      options_to_test = [
        {1, 4, <<255, 255, 255, 0>>},
        {3, 4, <<192, 168, 1, 1>>},
        {12, 9, "test-host"},
        {51, 4, <<0, 0, 14, 16>>},
        {53, 1, <<1>>},
        {54, 4, <<192, 168, 1, 1>>},
        {200, 4, <<1, 2, 3, 4>>}
      ]

      for {code, length, value} <- options_to_test do
        result = Decoder.decode_option_value(code, length, value)

        assert is_tuple(result), "Option #{code} should return a tuple"
        assert tuple_size(result) == 3, "Option #{code} should return 3-tuple"

        {name, type, _value} = result
        assert is_binary(name), "Option #{code} name should be string"
        assert is_atom(type), "Option #{code} type should be atom"
      end
    end
  end
end
