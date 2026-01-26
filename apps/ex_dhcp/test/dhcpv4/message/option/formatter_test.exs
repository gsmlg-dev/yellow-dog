defmodule DHCPv4.Message.Option.FormatterTest do
  @moduledoc """
  Comprehensive unit tests for DHCPv4.Message.Option.Formatter module.

  Tests cover:
  - Module structure and exports
  - format/1 - option display formatting
  - parse_decoded_value/1 - value type formatting
  - IP address formatting
  - Various option type handling
  """
  use ExUnit.Case, async: true

  alias DHCPv4.Message.Option.Formatter
  alias DHCPv4.Message.Option.Helpers

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Formatter)
    end

    test "exports format/1" do
      Code.ensure_loaded!(Formatter)
      assert Kernel.function_exported?(Formatter, :format, 1)
    end

    test "exports parse_decoded_value/1" do
      Code.ensure_loaded!(Formatter)
      assert Kernel.function_exported?(Formatter, :parse_decoded_value, 1)
    end
  end

  describe "format/1" do
    test "formats subnet mask option" do
      option = Helpers.new(1, 4, <<255, 255, 255, 0>>)
      result = Formatter.format(option)

      assert is_binary(result)
      assert String.contains?(result, "Option")
      assert String.contains?(result, "1")
    end

    test "formats router option" do
      option = Helpers.new(3, 4, <<192, 168, 1, 1>>)
      result = Formatter.format(option)

      assert is_binary(result)
    end

    test "formats DNS server option" do
      option = Helpers.new(6, 4, <<8, 8, 8, 8>>)
      result = Formatter.format(option)

      assert is_binary(result)
    end

    test "formats DHCP message type option" do
      option = Helpers.new(53, 1, <<1>>)
      result = Formatter.format(option)

      assert is_binary(result)
    end

    test "includes option type number" do
      option = Helpers.new(12, 4, "test")
      result = Formatter.format(option)

      assert String.contains?(result, "12")
    end
  end

  describe "parse_decoded_value/1 - :ip type" do
    test "formats IPv4 address" do
      result = Formatter.parse_decoded_value({"Router", :ip, {192, 168, 1, 1}})

      assert String.contains?(result, "Router")
      assert String.contains?(result, "192.168.1.1")
    end

    test "formats loopback address" do
      result = Formatter.parse_decoded_value({"Test", :ip, {127, 0, 0, 1}})

      assert String.contains?(result, "127.0.0.1")
    end

    test "formats broadcast address" do
      result = Formatter.parse_decoded_value({"Broadcast", :ip, {255, 255, 255, 255}})

      assert String.contains?(result, "255.255.255.255")
    end

    test "formats zero address" do
      result = Formatter.parse_decoded_value({"Zero", :ip, {0, 0, 0, 0}})

      assert String.contains?(result, "0.0.0.0")
    end
  end

  describe "parse_decoded_value/1 - :ip_list type" do
    test "formats single IP in list" do
      result = Formatter.parse_decoded_value({"DNS", :ip_list, [{8, 8, 8, 8}]})

      assert String.contains?(result, "DNS")
      assert String.contains?(result, "8.8.8.8")
    end

    test "formats multiple IPs in list" do
      ips = [{8, 8, 8, 8}, {8, 8, 4, 4}]
      result = Formatter.parse_decoded_value({"DNS", :ip_list, ips})

      assert String.contains?(result, "8.8.8.8")
      assert String.contains?(result, "8.8.4.4")
      assert String.contains?(result, ",")
    end

    test "formats empty IP list" do
      result = Formatter.parse_decoded_value({"DNS", :ip_list, []})

      assert String.contains?(result, "DNS")
    end
  end

  describe "parse_decoded_value/1 - :ip_mask_list type" do
    test "formats IP/mask pair" do
      pairs = [{{192, 168, 1, 0}, {255, 255, 255, 0}}]
      result = Formatter.parse_decoded_value({"Routes", :ip_mask_list, pairs})

      assert String.contains?(result, "Routes")
      assert String.contains?(result, "192.168.1.0")
      assert String.contains?(result, "/")
    end

    test "formats multiple IP/mask pairs" do
      pairs = [
        {{10, 0, 0, 0}, {255, 0, 0, 0}},
        {{172, 16, 0, 0}, {255, 255, 0, 0}}
      ]

      result = Formatter.parse_decoded_value({"Routes", :ip_mask_list, pairs})

      assert String.contains?(result, "10.0.0.0")
      assert String.contains?(result, "172.16.0.0")
    end
  end

  describe "parse_decoded_value/1 - :network_mask_router_list type" do
    test "formats network/mask/router triple" do
      routes = [{{192, 168, 2, 0}, 24, {192, 168, 1, 1}}]
      result = Formatter.parse_decoded_value({"Static Routes", :network_mask_router_list, routes})

      assert String.contains?(result, "Static Routes")
      assert String.contains?(result, "192.168.2.0")
      assert String.contains?(result, "/24")
      assert String.contains?(result, "via")
      assert String.contains?(result, "192.168.1.1")
    end
  end

  describe "parse_decoded_value/1 - :int_list type" do
    test "formats single integer" do
      result = Formatter.parse_decoded_value({"Ports", :int_list, [80]})

      assert String.contains?(result, "Ports")
      assert String.contains?(result, "80")
    end

    test "formats multiple integers" do
      result = Formatter.parse_decoded_value({"Options", :int_list, [1, 3, 6, 15]})

      assert String.contains?(result, "1")
      assert String.contains?(result, "3")
      assert String.contains?(result, "6")
      assert String.contains?(result, "15")
      assert String.contains?(result, ",")
    end

    test "formats empty integer list" do
      result = Formatter.parse_decoded_value({"Empty", :int_list, []})

      assert String.contains?(result, "Empty")
    end
  end

  describe "parse_decoded_value/1 - :int type" do
    test "formats positive integer" do
      result = Formatter.parse_decoded_value({"Lease Time", :int, 86400})

      assert String.contains?(result, "Lease Time")
      assert String.contains?(result, "86400")
    end

    test "formats zero" do
      result = Formatter.parse_decoded_value({"Value", :int, 0})

      assert String.contains?(result, "0")
    end

    test "formats large integer" do
      result = Formatter.parse_decoded_value({"Time", :int, 4_294_967_295})

      assert String.contains?(result, "4294967295")
    end
  end

  describe "parse_decoded_value/1 - :bool type" do
    test "formats true value" do
      result = Formatter.parse_decoded_value({"Forward", :bool, true})

      assert String.contains?(result, "Forward")
      assert String.contains?(result, "true")
    end

    test "formats false value" do
      result = Formatter.parse_decoded_value({"Forward", :bool, false})

      assert String.contains?(result, "Forward")
      assert String.contains?(result, "false")
    end
  end

  describe "parse_decoded_value/1 - :binary type" do
    test "formats binary data" do
      result = Formatter.parse_decoded_value({"Data", :binary, <<1, 2, 3, 4>>})

      assert String.contains?(result, "Data")
    end

    test "formats string as binary" do
      result = Formatter.parse_decoded_value({"Hostname", :binary, "testclient"})

      assert String.contains?(result, "Hostname")
      assert String.contains?(result, "testclient")
    end
  end

  describe "parse_decoded_value/1 - :type_identifier type" do
    test "formats type identifier tuple" do
      result =
        Formatter.parse_decoded_value(
          {"Client ID", :type_identifier, {1, <<0x00, 0x11, 0x22, 0x33, 0x44, 0x55>>}}
        )

      assert String.contains?(result, "Client ID")
    end
  end

  describe "parse_decoded_value/1 - :raw type" do
    test "formats raw data" do
      result = Formatter.parse_decoded_value({"Unknown", :raw, <<0xDE, 0xAD, 0xBE, 0xEF>>})

      assert String.contains?(result, "Unknown")
    end

    test "formats raw string" do
      result = Formatter.parse_decoded_value({"Raw", :raw, "raw data"})

      assert String.contains?(result, "Raw")
    end
  end

  describe "format/1 - common DHCP options" do
    test "formats lease time option" do
      # Option 51: IP Address Lease Time
      # 86400 seconds
      option = Helpers.new(51, 4, <<0, 1, 81, 128>>)
      result = Formatter.format(option)

      assert is_binary(result)
    end

    test "formats domain name option" do
      # Option 15: Domain Name
      domain = "example.com"
      option = Helpers.new(15, byte_size(domain), domain)
      result = Formatter.format(option)

      assert is_binary(result)
    end

    test "formats server identifier option" do
      # Option 54: Server Identifier
      option = Helpers.new(54, 4, <<192, 168, 1, 1>>)
      result = Formatter.format(option)

      assert is_binary(result)
    end
  end

  describe "edge cases" do
    test "handles empty name" do
      result = Formatter.parse_decoded_value({"", :int, 42})

      assert String.contains?(result, "42")
    end

    test "handles special characters in name" do
      result = Formatter.parse_decoded_value({"Test-Option_1", :int, 100})

      assert String.contains?(result, "Test-Option_1")
    end
  end
end
