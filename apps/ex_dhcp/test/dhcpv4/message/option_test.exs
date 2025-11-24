defmodule DHCPv4.Message.OptionTest do
  use ExUnit.Case
  alias DHCPv4.Message.Option

  describe "new/3" do
    test "creates a new DHCP option with type, length, and value" do
      option = Option.new(53, 1, <<1>>)
      assert option.type == 53
      assert option.length == 1
      assert option.value == <<1>>
    end

    test "handles different option types" do
      subnet_mask = Option.new(1, 4, <<255, 255, 255, 0>>)
      assert subnet_mask.type == 1
      assert subnet_mask.length == 4
      assert subnet_mask.value == <<255, 255, 255, 0>>

      message_type = Option.new(53, 1, <<2>>)
      assert message_type.type == 53
      assert message_type.length == 1
      assert message_type.value == <<2>>
    end
  end

  describe "from_iodata/1" do
    test "parses option from binary data" do
      binary = <<53, 1, 1>>
      option = Option.from_iodata(binary)
      assert option.type == 53
      assert option.length == 1
      assert option.value == <<1>>
    end

    test "handles different option lengths" do
      # Subnet mask (4 bytes)
      mask_binary = <<1, 4, 255, 255, 255, 0>>
      mask_option = Option.from_iodata(mask_binary)
      assert mask_option.type == 1
      assert mask_option.length == 4
      assert mask_option.value == <<255, 255, 255, 0>>

      # Hostname (variable length)
      hostname_binary = <<12, 6, ?t, ?e, ?s, ?t, ?1, ?2>>
      hostname_option = Option.from_iodata(hostname_binary)
      assert hostname_option.type == 12
      assert hostname_option.length == 6
      assert hostname_option.value == "test12"
    end
  end

  describe "parse/1" do
    test "parses DHCP options from binary with magic cookie" do
      magic_cookie = <<99, 130, 83, 99>>
      options = <<53, 1, 1, 1, 4, 255, 255, 255, 0, 255>>
      binary = magic_cookie <> options

      {:ok, parsed} = Option.parse(binary)
      assert length(parsed) == 2

      [message_type, subnet_mask] = parsed
      assert message_type.type == 53
      assert message_type.length == 1
      assert message_type.value == <<1>>

      assert subnet_mask.type == 1
      assert subnet_mask.length == 4
      assert subnet_mask.value == <<255, 255, 255, 0>>
    end

    test "handles empty options" do
      assert Option.parse(<<99, 130, 83, 99, 255>>) == {:ok, []}
    end

    test "handles only magic cookie and end option" do
      assert Option.parse(<<99, 130, 83, 99, 255>>) == {:ok, []}
    end

    test "parses multiple options correctly" do
      magic_cookie = <<99, 130, 83, 99>>

      options = <<
        # DHCP Message Type: DHCPOFFER
        53,
        1,
        2,
        # Server Identifier
        54,
        4,
        192,
        168,
        1,
        1,
        # Lease Time: 3600 seconds
        51,
        4,
        0,
        0,
        14,
        16,
        # End Option
        255
      >>

      {:ok, parsed} = Option.parse(magic_cookie <> options)
      assert length(parsed) == 3

      [type, server, lease] = parsed
      assert type.type == 53 && type.value == <<2>>
      assert server.type == 54 && server.value == <<192, 168, 1, 1>>
      assert lease.type == 51 && lease.value == <<0, 0, 14, 16>>
    end
  end

  describe "to_dhcp_binary/1" do
    test "serializes options to binary format" do
      options = [
        Option.new(53, 1, <<1>>),
        Option.new(1, 4, <<255, 255, 255, 0>>)
      ]

      binary = Option.to_dhcp_binary(options)
      assert binary == <<99, 130, 83, 99, 53, 1, 1, 1, 4, 255, 255, 255, 0, 255>>
    end

    test "handles empty options list" do
      binary = Option.to_dhcp_binary([])
      assert binary == <<99, 130, 83, 99, 255>>
    end

    test "serializes complex option sets" do
      options = [
        Option.new(53, 1, <<2>>),
        Option.new(54, 4, <<192, 168, 1, 1>>),
        Option.new(51, 4, <<0, 0, 14, 16>>),
        Option.new(3, 4, <<192, 168, 1, 1>>),
        Option.new(6, 8, <<8, 8, 8, 8, 8, 8, 4, 4>>)
      ]

      binary = Option.to_dhcp_binary(options)

      expected =
        <<99, 130, 83, 99, 53, 1, 2, 54, 4, 192, 168, 1, 1, 51, 4, 0, 0, 14, 16, 3, 4, 192, 168,
          1, 1, 6, 8, 8, 8, 8, 8, 8, 8, 4, 4, 255>>

      assert binary == expected
    end
  end

  describe "decode_option_value/3" do
    test "decodes subnet mask option" do
      {name, type, value} = Option.decode_option_value(1, 4, <<255, 255, 255, 0>>)
      assert name == "Subnet Mask"
      assert type == :ip
      assert value == {255, 255, 255, 0}
    end

    test "decodes IP address list" do
      {name, type, value} = Option.decode_option_value(6, 8, <<8, 8, 8, 8, 8, 8, 4, 4>>)
      assert name == "Domain Name Server"
      assert type == :ip_list
      assert value == [{8, 8, 8, 8}, {8, 8, 4, 4}]
    end

    test "decodes integer values" do
      {name, type, value} = Option.decode_option_value(51, 4, <<0, 0, 14, 16>>)
      assert name == "IP Address Lease Time"
      assert type == :int
      assert value == 3600
    end

    test "decodes boolean values" do
      {name, type, value} = Option.decode_option_value(19, 1, <<1>>)
      assert name == "IP Forwarding Enable/Disable"
      assert type == :bool
      assert value == true
    end

    test "decodes string values" do
      {name, type, value} = Option.decode_option_value(12, 6, "test12")
      assert name == "Host Name"
      assert type == :binary
      assert value == "test12"
    end

    test "decodes DHCP message type" do
      {name, type, value} = Option.decode_option_value(53, 1, <<1>>)
      assert name == "DHCP Message Type"
      assert type == :binary
      assert value == "DHCPDISCOVER - Client broadcast to locate available servers"
    end

    test "decodes unknown option types" do
      {name, type, value} = Option.decode_option_value(999, 4, <<1, 2, 3, 4>>)
      assert name == "Unknown"
      assert type == :raw
      assert value == <<1, 2, 3, 4>>
    end

    test "decodes TFTP server name option" do
      {name, type, value} = Option.decode_option_value(66, 11, "tftpserver")
      assert name == "TFTP server name"
      assert type == :binary
      assert value == "tftpserver"
    end

    test "decodes bootfile name option" do
      {name, type, value} = Option.decode_option_value(67, 9, "bootfile")
      assert name == "Bootfile name"
      assert type == :binary
      assert value == "bootfile"
    end
  end

  describe "String.Chars implementation" do
    test "converts option to string representation" do
      option = Option.new(53, 1, <<1>>)
      str = to_string(option)

      assert str =~
               "Option(53): DHCP Message Type: \"DHCPDISCOVER - Client broadcast to locate available servers\""
    end

    test "handles IP address options in string format" do
      option = Option.new(1, 4, <<255, 255, 255, 0>>)
      str = to_string(option)
      assert str =~ "Option(1): Subnet Mask: 255.255.255.0"
    end

    test "handles IP list options" do
      option = Option.new(6, 8, <<8, 8, 8, 8, 8, 8, 4, 4>>)
      str = to_string(option)
      assert str =~ "Option(6): Domain Name Server: 8.8.8.8, 8.8.4.4"
    end
  end

  describe "edge cases" do
    test "handles minimum values" do
      option = Option.new(0, 0, <<>>)
      assert option.type == 0
      assert option.length == 0
      assert option.value == <<>>
    end

    test "handles maximum values" do
      long_value = String.duplicate("a", 255)
      option = Option.new(255, 255, long_value)
      assert option.type == 255
      assert option.length == 255
      assert byte_size(option.value) == 255
    end

    test "handles empty option values" do
      option = Option.new(12, 0, <<>>)
      assert option.type == 12
      assert option.length == 0
      assert option.value == <<>>
    end
  end
end
