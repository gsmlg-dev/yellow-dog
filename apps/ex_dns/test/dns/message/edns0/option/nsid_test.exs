defmodule DNS.Message.EDNS0.Option.NSIDTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.EDNS0.Option.NSID.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with binary data
  - from_iodata/1 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 5001)
  - NSID semantics and common use cases
  """
  use ExUnit.Case, async: true

  alias DNS.Message.EDNS0.Option.NSID
  alias DNS.Message.EDNS0.OptionCode

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(NSID)
    end

    test "exports new/1" do
      Code.ensure_loaded!(NSID)
      assert Kernel.function_exported?(NSID, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(NSID)
      assert Kernel.function_exported?(NSID, :from_iodata, 1)
    end

    test "defines a struct" do
      Code.ensure_loaded!(NSID)
      assert is_struct(NSID.__struct__())
    end
  end

  describe "struct fields" do
    test "has code field" do
      option = %NSID{}
      assert Map.has_key?(option, :code)
    end

    test "has length field" do
      option = %NSID{}
      assert Map.has_key?(option, :length)
    end

    test "has data field" do
      option = %NSID{}
      assert Map.has_key?(option, :data)
    end

    test "default code is NSID (3)" do
      option = %NSID{}
      assert option.code == OptionCode.new(3)
    end

    test "default length is nil" do
      option = %NSID{}
      assert option.length == nil
    end

    test "default data is nil" do
      option = %NSID{}
      assert option.data == nil
    end
  end

  describe "new/1" do
    test "creates NSID option with binary data" do
      nsid_data = "example-nsid"
      option = NSID.new(nsid_data)
      assert %NSID{} = option
    end

    test "stores nsid data" do
      nsid_data = "test-nsid"
      option = NSID.new(nsid_data)
      assert option.data == nsid_data
    end

    test "calculates length from data" do
      nsid_data = "example-nsid"
      option = NSID.new(nsid_data)
      assert option.length == byte_size(nsid_data)
    end

    test "creates NSID option with empty data" do
      option = NSID.new("")
      assert option.code.value == <<3::16>>
      assert option.length == 0
      assert option.data == ""
    end

    test "creates NSID with hostname" do
      hostname = "ns1.example.com"
      option = NSID.new(hostname)
      assert option.data == hostname
      assert option.length == 15
    end

    test "creates NSID with IP address string" do
      ip = "192.168.1.1"
      option = NSID.new(ip)
      assert option.data == ip
      assert option.length == 11
    end

    test "creates NSID with UUID-like identifier" do
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      option = NSID.new(uuid)
      assert option.data == uuid
      assert option.length == 36
    end

    test "creates NSID with binary data" do
      binary_data = <<1, 2, 3, 4, 5>>
      option = NSID.new(binary_data)
      assert option.data == binary_data
      assert option.length == 5
    end

    test "option code is NSID (3)" do
      option = NSID.new("test")
      assert option.code.value == <<3::16>>
    end

    test "handles long NSID data" do
      long_data = String.duplicate("x", 1000)
      option = NSID.new(long_data)
      assert option.length == 1000
      assert option.data == long_data
    end
  end

  describe "from_iodata/1" do
    test "parses NSID option from binary" do
      nsid_data = "test-nsid"
      binary = <<3::16, byte_size(nsid_data)::16, nsid_data::binary>>
      option = NSID.from_iodata(binary)
      assert %NSID{} = option
    end

    test "parses nsid data correctly" do
      nsid_data = "example-nsid"
      binary = <<3::16, byte_size(nsid_data)::16, nsid_data::binary>>
      option = NSID.from_iodata(binary)
      assert option.data == nsid_data
    end

    test "parses length correctly" do
      nsid_data = "test-nsid"
      binary = <<3::16, byte_size(nsid_data)::16, nsid_data::binary>>
      option = NSID.from_iodata(binary)
      assert option.length == byte_size(nsid_data)
    end

    test "parses empty NSID option" do
      binary = <<3::16, 0::16>>
      option = NSID.from_iodata(binary)
      assert option.code.value == <<3::16>>
      assert option.length == 0
      assert option.data == ""
    end

    test "parses NSID with hostname" do
      hostname = "dns1.example.org"
      binary = <<3::16, byte_size(hostname)::16, hostname::binary>>
      option = NSID.from_iodata(binary)
      assert option.data == hostname
    end

    test "parses NSID with binary data" do
      binary_data = <<0xFF, 0xFE, 0xFD, 0xFC>>
      binary = <<3::16, byte_size(binary_data)::16, binary_data::binary>>
      option = NSID.from_iodata(binary)
      assert option.data == binary_data
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      nsid_data = "test-nsid-data"
      option = NSID.new(nsid_data)
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<3::16, byte_size(nsid_data)::16, nsid_data::binary>>
    end

    test "wire format starts with option code 3" do
      option = NSID.new("test")
      <<code::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert code == 3
    end

    test "wire format has correct length" do
      nsid_data = "example-nsid"
      option = NSID.new(nsid_data)
      <<_code::16, length::16, _rest::binary>> = DNS.Parameter.to_iodata(option)
      assert length == byte_size(nsid_data)
    end

    test "encodes empty NSID" do
      option = NSID.new("")
      iodata = DNS.Parameter.to_iodata(option)
      assert iodata == <<3::16, 0::16>>
    end

    test "encodes data correctly" do
      nsid_data = "ns1"
      option = NSID.new(nsid_data)
      <<_code::16, _length::16, data::binary>> = DNS.Parameter.to_iodata(option)
      assert data == nsid_data
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'NSID: HEX_DATA'" do
      nsid_data = "test-nsid"
      option = NSID.new(nsid_data)
      expected_hex = Base.encode16(nsid_data)
      assert to_string(option) == "NSID: #{expected_hex}"
    end

    test "includes hex encoded data" do
      nsid_data = "ABC"
      option = NSID.new(nsid_data)
      str = to_string(option)
      assert str =~ "414243"  # "ABC" in hex
    end

    test "formats empty NSID" do
      option = NSID.new("")
      assert to_string(option) == "NSID: "
    end

    test "formats binary data as hex" do
      option = NSID.new(<<1, 2, 3>>)
      assert to_string(option) == "NSID: 010203"
    end

    test "string interpolation works" do
      option = NSID.new("test")
      result = "Option: #{option}"
      assert result =~ "NSID:"
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> from_iodata preserves data" do
      original = NSID.new("test-nsid")
      iodata = DNS.Parameter.to_iodata(original)
      parsed = NSID.from_iodata(iodata)
      assert parsed.data == original.data
      assert parsed.length == original.length
    end

    test "round-trip preserves empty data" do
      original = NSID.new("")
      iodata = DNS.Parameter.to_iodata(original)
      parsed = NSID.from_iodata(iodata)
      assert parsed.data == ""
      assert parsed.length == 0
    end

    test "round-trip preserves various data" do
      test_cases = [
        "ns1.example.com",
        "192.168.1.1",
        "dns-server-001",
        <<1, 2, 3, 4, 5>>,
        String.duplicate("a", 100)
      ]

      for data <- test_cases do
        original = NSID.new(data)
        iodata = DNS.Parameter.to_iodata(original)
        parsed = NSID.from_iodata(iodata)
        assert parsed.data == data
      end
    end
  end

  describe "NSID semantics" do
    test "NSID identifies name server" do
      # NSID is used to identify which specific name server responded
      option = NSID.new("dns1.example.com")
      assert option.data == "dns1.example.com"
    end

    test "NSID can be any opaque data" do
      # NSID data is opaque - can be hostname, IP, UUID, etc.
      option = NSID.new(<<0xDE, 0xAD, 0xBE, 0xEF>>)
      assert option.data == <<0xDE, 0xAD, 0xBE, 0xEF>>
    end

    test "empty NSID is a request for server's NSID" do
      # Client sends empty NSID to request server's NSID
      request_option = NSID.new("")
      assert request_option.length == 0
    end

    test "common NSID formats" do
      # Hostname format
      option1 = NSID.new("ns1.example.com")
      assert option1.length == 15

      # IP format
      option2 = NSID.new("10.0.0.1")
      assert option2.length == 8

      # Datacenter identifier
      option3 = NSID.new("dc1-rack3-server5")
      assert option3.length == 17
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      option = NSID.new("test")
      inspect_output = inspect(option)
      assert is_binary(inspect_output)
    end

    test "handles null bytes in data" do
      data = <<0, 1, 0, 2, 0>>
      option = NSID.new(data)
      assert option.data == data
      assert option.length == 5
    end

    test "handles UTF-8 data" do
      # While not typically used, NSID can contain UTF-8
      utf8_data = "服务器1"
      option = NSID.new(utf8_data)
      assert option.data == utf8_data
    end

    test "handles max length data" do
      # NSID can be up to 65535 bytes
      long_data = String.duplicate("x", 255)
      option = NSID.new(long_data)
      assert option.length == 255
    end
  end
end
