defmodule DHCPv4.Message.Option.SerializerTest do
  @moduledoc """
  Comprehensive unit tests for DHCPv4.Message.Option.Serializer module.

  Tests cover:
  - Module structure and exports
  - to_dhcp_binary/1 - option serialization with magic cookie
  - Binary format verification
  - Multiple option handling
  """
  use ExUnit.Case, async: true

  alias DHCPv4.Message.Option.Serializer
  alias DHCPv4.Message.Option.Helpers

  @magic_cookie <<99, 130, 83, 99>>
  @end_option 0xFF

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Serializer)
    end

    test "exports to_dhcp_binary/1" do
      Code.ensure_loaded!(Serializer)
      assert Kernel.function_exported?(Serializer, :to_dhcp_binary, 1)
    end
  end

  describe "to_dhcp_binary/1 - basic functionality" do
    test "returns binary" do
      options = []
      result = Serializer.to_dhcp_binary(options)

      assert is_binary(result)
    end

    test "includes magic cookie at start" do
      options = []
      result = Serializer.to_dhcp_binary(options)

      <<cookie::binary-size(4), _rest::binary>> = result
      assert cookie == @magic_cookie
    end

    test "ends with end option (0xFF)" do
      options = []
      result = Serializer.to_dhcp_binary(options)

      binary_size = byte_size(result)
      <<_head::binary-size(binary_size - 1), end_byte>> = result
      assert end_byte == @end_option
    end

    test "empty options returns magic cookie + end option" do
      result = Serializer.to_dhcp_binary([])

      assert result == <<@magic_cookie::binary, @end_option>>
    end
  end

  describe "to_dhcp_binary/1 - single option" do
    test "serializes single subnet mask option" do
      option = Helpers.new(1, 4, <<255, 255, 255, 0>>)
      result = Serializer.to_dhcp_binary([option])

      # Should be: magic cookie + option binary + end option
      assert byte_size(result) > 5
      assert String.starts_with?(result, @magic_cookie)
    end

    test "serializes single router option" do
      option = Helpers.new(3, 4, <<192, 168, 1, 1>>)
      result = Serializer.to_dhcp_binary([option])

      assert is_binary(result)
      assert byte_size(result) > 5
    end

    test "serializes single DNS option" do
      option = Helpers.new(6, 4, <<8, 8, 8, 8>>)
      result = Serializer.to_dhcp_binary([option])

      assert is_binary(result)
    end

    test "serializes DHCP message type option" do
      option = Helpers.new(53, 1, <<1>>)  # DISCOVER
      result = Serializer.to_dhcp_binary([option])

      assert is_binary(result)
    end
  end

  describe "to_dhcp_binary/1 - multiple options" do
    test "serializes multiple options" do
      options = [
        Helpers.new(1, 4, <<255, 255, 255, 0>>),   # Subnet mask
        Helpers.new(3, 4, <<192, 168, 1, 1>>),     # Router
        Helpers.new(6, 4, <<8, 8, 8, 8>>)          # DNS server
      ]

      result = Serializer.to_dhcp_binary(options)

      # Should include all options between magic cookie and end option
      # 4 (cookie) + 3*(2+4) (3 options with type+length+4byte value) + 1 (end) = 23
      assert byte_size(result) >= 23
    end

    test "options are serialized in order" do
      options = [
        Helpers.new(1, 4, <<255, 255, 255, 0>>),
        Helpers.new(3, 4, <<192, 168, 1, 1>>)
      ]

      result = Serializer.to_dhcp_binary(options)

      # Remove magic cookie
      <<_cookie::binary-size(4), rest::binary>> = result
      # First option should be type 1
      <<first_type, _rest::binary>> = rest
      assert first_type == 1
    end

    test "serializes standard DHCP message options" do
      # Typical DHCP DISCOVER message options
      options = [
        Helpers.new(53, 1, <<1>>),              # DHCP Message Type: DISCOVER
        Helpers.new(55, 4, <<1, 3, 6, 15>>),    # Parameter Request List
        Helpers.new(61, 7, <<1, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55>>)  # Client Identifier
      ]

      result = Serializer.to_dhcp_binary(options)

      assert is_binary(result)
      assert String.starts_with?(result, @magic_cookie)
    end
  end

  describe "to_dhcp_binary/1 - option types" do
    test "handles zero-length option" do
      # Some options have no data
      option = Helpers.new(80, 0, <<>>)  # Rapid Commit (RFC 4039)
      result = Serializer.to_dhcp_binary([option])

      assert is_binary(result)
    end

    test "handles single-byte option" do
      option = Helpers.new(53, 1, <<2>>)  # DHCP Message Type: OFFER
      result = Serializer.to_dhcp_binary([option])

      assert is_binary(result)
    end

    test "handles variable-length option" do
      # Hostname option
      hostname = "testclient"
      option = Helpers.new(12, byte_size(hostname), hostname)
      result = Serializer.to_dhcp_binary([option])

      assert is_binary(result)
    end

    test "handles IP address list option" do
      # Multiple DNS servers
      dns_servers = <<8, 8, 8, 8, 8, 8, 4, 4>>  # 8.8.8.8 and 8.8.4.4
      option = Helpers.new(6, 8, dns_servers)
      result = Serializer.to_dhcp_binary([option])

      assert is_binary(result)
    end
  end

  describe "to_dhcp_binary/1 - binary format verification" do
    test "magic cookie is RFC 2131 compliant" do
      result = Serializer.to_dhcp_binary([])

      <<cookie::binary-size(4), _rest::binary>> = result

      # RFC 2131 magic cookie: 99.130.83.99 (decimal) = 0x63.0x82.0x53.0x63
      assert cookie == <<0x63, 0x82, 0x53, 0x63>>
    end

    test "option format is TLV (Type-Length-Value)" do
      option = Helpers.new(53, 1, <<3>>)  # DHCP Message Type: REQUEST
      result = Serializer.to_dhcp_binary([option])

      <<_cookie::binary-size(4), type, length, value, _end::binary>> = result

      assert type == 53
      assert length == 1
      assert value == 3
    end

    test "end option has no length or value" do
      result = Serializer.to_dhcp_binary([])

      binary_size = byte_size(result)
      <<_head::binary-size(binary_size - 1), end_byte>> = result

      # End option is just 0xFF with no length/value
      assert end_byte == 255
    end
  end

  describe "to_dhcp_binary/1 - edge cases" do
    test "handles large option value" do
      # Maximum option length is 255 bytes
      large_value = :binary.copy(<<0>>, 255)
      option = Helpers.new(67, 255, large_value)
      result = Serializer.to_dhcp_binary([option])

      assert is_binary(result)
      assert byte_size(result) > 255
    end

    test "handles many options" do
      options =
        for i <- 1..50 do
          Helpers.new(i, 1, <<i>>)
        end

      result = Serializer.to_dhcp_binary(options)

      assert is_binary(result)
    end
  end

  describe "to_dhcp_binary/1 - integration" do
    test "produces parseable output" do
      options = [
        Helpers.new(53, 1, <<1>>),
        Helpers.new(1, 4, <<255, 255, 255, 0>>)
      ]

      binary = Serializer.to_dhcp_binary(options)

      # Should be parseable: magic cookie + options + end
      <<cookie::binary-size(4), rest::binary>> = binary
      assert cookie == @magic_cookie

      # Find end option
      binary_size = byte_size(rest)
      <<_options::binary-size(binary_size - 1), end_byte>> = rest
      assert end_byte == @end_option
    end
  end
end
