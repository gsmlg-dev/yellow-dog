defmodule DNS.Message.Record.Data.AAAATest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.AAAA.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with IPv6 address tuples
  - from_iodata/1, from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 3596)
  - Edge cases and special IPv6 addresses
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.AAAA

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(AAAA)
    end

    test "exports new/1" do
      Code.ensure_loaded!(AAAA)
      assert Kernel.function_exported?(AAAA, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(AAAA)
      assert Kernel.function_exported?(AAAA, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(AAAA)
      assert Kernel.function_exported?(AAAA, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(AAAA)
      assert is_struct(AAAA.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %AAAA{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %AAAA{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %AAAA{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %AAAA{}
      assert Map.has_key?(record, :data)
    end

    test "default rdlength is 16" do
      assert %AAAA{}.rdlength == 16
    end

    test "default type is AAAA (28)" do
      type = %AAAA{}.type
      assert type == DNS.ResourceRecordType.new(28)
    end

    test "default raw is nil" do
      assert %AAAA{}.raw == nil
    end

    test "default data is nil" do
      assert %AAAA{}.data == nil
    end
  end

  describe "new/1" do
    test "creates AAAA record from IPv6 tuple" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2001:4860:4860::8888")
      record = AAAA.new(ip)
      assert %AAAA{} = record
      assert record.data == ip
    end

    test "stores raw binary" do
      ip = {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
      record = AAAA.new(ip)
      assert record.raw == <<0x2001::16, 0x4860::16, 0x4860::16, 0::16, 0::16, 0::16, 0::16, 0x8888::16>>
    end

    test "creates record for Google DNS" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2001:4860:4860::8888")
      record = AAAA.new(ip)
      assert record.data == {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
    end

    test "creates record for Cloudflare DNS" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2606:4700:4700::1111")
      record = AAAA.new(ip)
      assert record.data == {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}
    end

    test "creates record for localhost" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 1})
      assert record.data == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "creates record for unspecified address" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 0})
      assert record.data == {0, 0, 0, 0, 0, 0, 0, 0}
    end

    test "creates record for link-local address" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"fe80::1")
      record = AAAA.new(ip)
      assert record.data == {0xfe80, 0, 0, 0, 0, 0, 0, 1}
    end

    test "creates record with all segments non-zero" do
      ip = {0x2001, 0x0db8, 0x85a3, 0x0000, 0x0000, 0x8a2e, 0x0370, 0x7334}
      record = AAAA.new(ip)
      assert record.data == ip
    end

    test "creates record with max values" do
      ip = {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
      record = AAAA.new(ip)
      assert record.data == ip
    end
  end

  describe "from_iodata/1" do
    test "parses 16-byte binary" do
      raw = <<0x20, 0x01, 0x48, 0x60, 0x48, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0x88, 0x88>>
      record = AAAA.from_iodata(raw)
      assert %AAAA{} = record
      assert record.data == {0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888}
    end

    test "stores raw binary" do
      raw = <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      record = AAAA.from_iodata(raw)
      assert record.raw == raw
    end

    test "parses localhost" do
      raw = <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      record = AAAA.from_iodata(raw)
      assert record.data == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "parses unspecified address" do
      raw = <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
      record = AAAA.from_iodata(raw)
      assert record.data == {0, 0, 0, 0, 0, 0, 0, 0}
    end

    test "parses max address" do
      raw = <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
      record = AAAA.from_iodata(raw)
      assert record.data == {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
    end
  end

  describe "from_iodata/2" do
    test "accepts message parameter (ignored)" do
      raw = <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      record = AAAA.from_iodata(raw, <<>>)
      assert record.data == {0, 0, 0, 0, 0, 0, 0, 1}
    end

    test "message can be nil" do
      raw = <<0x20, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      record = AAAA.from_iodata(raw, nil)
      assert record.data == {0x2001, 0, 0, 0, 0, 0, 0, 1}
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats IPv6 address correctly" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2001:4860:4860::8888")
      record = AAAA.new(ip)
      str = to_string(record)
      # Should be valid IPv6 format (may use compression)
      assert str =~ "2001:4860:4860"
      assert str =~ "8888"
    end

    test "formats localhost" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 1})
      str = to_string(record)
      # inet.ntoa returns "::1" for localhost
      assert str == "::1"
    end

    test "formats unspecified address" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 0})
      str = to_string(record)
      # inet.ntoa returns "::" for all zeros
      assert str == "::"
    end

    test "string interpolation works" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2001:db8::1")
      record = AAAA.new(ip)
      result = "IPv6: #{record}"
      assert result =~ "IPv6:"
      assert result =~ "2001"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      record = AAAA.new({0x2001, 0x4860, 0x4860, 0, 0, 0, 0, 0x8888})
      iodata = DNS.Parameter.to_iodata(record)
      # AAAA record wire format: 2-byte length (16) + 16-byte IP
      <<length::16, ip_bytes::binary>> = iodata
      assert length == 16
      assert byte_size(ip_bytes) == 16
    end

    test "wire format has 18 bytes total" do
      record = AAAA.new({0, 0, 0, 0, 0, 0, 0, 1})
      iodata = DNS.Parameter.to_iodata(record)
      assert byte_size(iodata) == 18
    end

    test "length prefix is always 16" do
      record = AAAA.new({1, 2, 3, 4, 5, 6, 7, 8})
      <<length::16, _rest::binary>> = DNS.Parameter.to_iodata(record)
      assert length == 16
    end

    test "IP segments are in network byte order" do
      record = AAAA.new({0x2001, 0x0db8, 0, 0, 0, 0, 0, 1})
      <<16::16, a::16, b::16, _::binary>> = DNS.Parameter.to_iodata(record)
      assert a == 0x2001
      assert b == 0x0db8
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      original_ip = {0x2001, 0x0db8, 0x85a3, 0, 0, 0x8a2e, 0x0370, 0x7334}
      record = AAAA.new(original_ip)
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      parsed = AAAA.from_iodata(raw)
      assert parsed.data == original_ip
    end

    test "from_iodata -> to_string -> parseable" do
      raw = <<0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      record = AAAA.from_iodata(raw)
      str = to_string(record)
      {:ok, _parsed_ip} = :inet.parse_ipv6_address(String.to_charlist(str))
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"2001:4860:4860::8888")
      record = AAAA.new(ip)
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "all segments at boundary values" do
      record = AAAA.new({0, 0x7FFF, 0xFFFF, 0, 0, 0, 0, 1})
      assert record.data == {0, 0x7FFF, 0xFFFF, 0, 0, 0, 0, 1}
    end

    test "rdlength is always 16" do
      {:ok, ip} = :inet.parse_ipv6_address(~c"::1")
      record = AAAA.new(ip)
      assert record.rdlength == 16
    end

    test "IPv4-mapped IPv6 address" do
      # ::ffff:192.168.1.1 represented as IPv6
      ip = {0, 0, 0, 0, 0, 0xFFFF, 0xC0A8, 0x0101}
      record = AAAA.new(ip)
      assert record.data == ip
    end
  end
end
