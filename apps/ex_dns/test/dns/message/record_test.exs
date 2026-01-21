defmodule DNS.Message.RecordTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/5 for creating records
  - from_iodata/1 and from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 1035 Section 4.1.3)
  - Various record types (A, AAAA, MX, TXT, etc.)
  - TTL handling
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Record)
    end

    test "exports new/5" do
      Code.ensure_loaded!(Record)
      assert Kernel.function_exported?(Record, :new, 5)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(Record)
      assert Kernel.function_exported?(Record, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(Record)
      assert Kernel.function_exported?(Record, :from_iodata, 2)
    end

    test "exports list_from_message/3" do
      Code.ensure_loaded!(Record)
      assert Kernel.function_exported?(Record, :list_from_message, 3)
    end

    test "defines a struct" do
      Code.ensure_loaded!(Record)
      assert is_struct(Record.__struct__())
    end
  end

  describe "struct fields" do
    test "has name field" do
      record = %Record{}
      assert Map.has_key?(record, :name)
    end

    test "has type field" do
      record = %Record{}
      assert Map.has_key?(record, :type)
    end

    test "has class field" do
      record = %Record{}
      assert Map.has_key?(record, :class)
    end

    test "has ttl field" do
      record = %Record{}
      assert Map.has_key?(record, :ttl)
    end

    test "has rdlength field" do
      record = %Record{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has data field" do
      record = %Record{}
      assert Map.has_key?(record, :data)
    end

    test "default name is root domain" do
      record = %Record{}
      assert record.name.value == "."
    end

    test "default type is A (1)" do
      record = %Record{}
      assert record.type.value == <<1::16>>
    end

    test "default class is IN (1)" do
      record = %Record{}
      assert record.class.value == <<1::16>>
    end

    test "default ttl is 0" do
      record = %Record{}
      assert record.ttl == 0
    end
  end

  describe "new/5" do
    test "creates A record" do
      record = Record.new("example.com", 1, 1, 3600, {1, 2, 3, 4})
      assert %Record{} = record
    end

    test "sets domain name correctly" do
      record = Record.new("www.example.com", 1, 1, 3600, {1, 1, 1, 1})
      assert record.name.value == "www.example.com."
    end

    test "sets type correctly" do
      record = Record.new("example.com", 1, 1, 3600, {1, 1, 1, 1})
      assert record.type.value == <<1::16>>
    end

    test "sets class correctly" do
      record = Record.new("example.com", 1, 1, 3600, {1, 1, 1, 1})
      assert record.class.value == <<1::16>>
    end

    test "sets TTL correctly" do
      record = Record.new("example.com", 1, 1, 3600, {1, 1, 1, 1})
      assert record.ttl == 3600
    end

    test "stores A record data" do
      record = Record.new("example.com", 1, 1, 3600, {1, 2, 3, 4})
      assert record.data.data == {1, 2, 3, 4}
    end

    test "creates record with atom type" do
      record = Record.new("example.com", :a, 1, 3600, {1, 2, 3, 4})
      assert record.type.value == <<1::16>>
    end

    test "creates record with atom class" do
      record = Record.new("example.com", 1, :in, 3600, {1, 2, 3, 4})
      assert record.class.value == <<1::16>>
    end

    test "creates record with zero TTL" do
      record = Record.new("example.com", 1, 1, 0, {1, 2, 3, 4})
      assert record.ttl == 0
    end

    test "creates record with max TTL" do
      max_ttl = 0xFFFFFFFF
      record = Record.new("example.com", 1, 1, max_ttl, {1, 2, 3, 4})
      assert record.ttl == max_ttl
    end

    test "calculates rdlength for A record" do
      record = Record.new("example.com", 1, 1, 3600, {1, 2, 3, 4})
      assert record.rdlength == 4
    end

    test "creates AAAA record" do
      ipv6 = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      record = Record.new("example.com", 28, 1, 3600, ipv6)
      assert record.type.value == <<28::16>>
    end

    test "calculates rdlength for AAAA record" do
      ipv6 = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      record = Record.new("example.com", 28, 1, 3600, ipv6)
      assert record.rdlength == 16
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format for A record" do
      record = Record.new("example.com", 1, 1, 3600, {1, 2, 3, 4})
      iodata = DNS.to_iodata(record)
      assert is_binary(iodata)
    end

    test "wire format starts with domain name" do
      record = Record.new("test.com", 1, 1, 3600, {1, 2, 3, 4})
      iodata = DNS.to_iodata(record)
      # Domain "test.com" should be at the start
      <<4, "test", 3, "com", 0, _rest::binary>> = iodata
    end

    test "wire format includes type after name" do
      record = Record.new("test.com", 1, 1, 3600, {1, 2, 3, 4})
      iodata = DNS.to_iodata(record)
      domain_size = 10
      <<_domain::binary-size(domain_size), type::16, _rest::binary>> = iodata
      assert type == 1
    end

    test "wire format includes class" do
      record = Record.new("test.com", 1, 1, 3600, {1, 2, 3, 4})
      iodata = DNS.to_iodata(record)
      domain_size = 10
      <<_domain::binary-size(domain_size), _type::16, class::16, _rest::binary>> = iodata
      assert class == 1
    end

    test "wire format includes TTL as 32-bit value" do
      record = Record.new("test.com", 1, 1, 3600, {1, 2, 3, 4})
      iodata = DNS.to_iodata(record)
      domain_size = 10
      <<_domain::binary-size(domain_size), _type::16, _class::16, ttl::32, _rest::binary>> = iodata
      assert ttl == 3600
    end

    test "wire format includes rdlength and rdata" do
      record = Record.new("test.com", 1, 1, 3600, {1, 2, 3, 4})
      iodata = DNS.to_iodata(record)
      domain_size = 10

      <<_domain::binary-size(domain_size), _type::16, _class::16, _ttl::32, rdlength::16,
        rdata::binary-size(rdlength)>> = iodata

      assert rdlength == 4
      assert rdata == <<1, 2, 3, 4>>
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats A record correctly" do
      record = Record.new("example.com", 1, 1, 3600, {1, 1, 1, 1})
      str = to_string(record)
      assert str == "example.com. A IN 3600 1.1.1.1"
    end

    test "includes domain name" do
      record = Record.new("www.example.com", 1, 1, 3600, {1, 2, 3, 4})
      str = to_string(record)
      assert str =~ "www.example.com."
    end

    test "includes type" do
      record = Record.new("example.com", 1, 1, 3600, {1, 2, 3, 4})
      str = to_string(record)
      assert str =~ "A"
    end

    test "includes class" do
      record = Record.new("example.com", 1, 1, 3600, {1, 2, 3, 4})
      str = to_string(record)
      assert str =~ "IN"
    end

    test "includes TTL" do
      record = Record.new("example.com", 1, 1, 3600, {1, 2, 3, 4})
      str = to_string(record)
      assert str =~ "3600"
    end

    test "includes IP address for A record" do
      record = Record.new("example.com", 1, 1, 3600, {192, 168, 1, 1})
      str = to_string(record)
      assert str =~ "192.168.1.1"
    end

    test "string interpolation works" do
      record = Record.new("example.com", 1, 1, 3600, {1, 2, 3, 4})
      result = "Record: #{record}"
      assert result =~ "example.com."
    end
  end

  describe "A record specifics" do
    test "creates A record with common IPs" do
      ips = [
        {127, 0, 0, 1},
        {192, 168, 1, 1},
        {10, 0, 0, 1},
        {8, 8, 8, 8},
        {1, 1, 1, 1}
      ]

      for ip <- ips do
        record = Record.new("test.com", 1, 1, 3600, ip)
        assert record.data.data == ip
      end
    end

    test "A record rdlength is always 4" do
      record = Record.new("example.com", 1, 1, 3600, {255, 255, 255, 255})
      assert record.rdlength == 4
    end
  end

  describe "AAAA record specifics" do
    test "creates AAAA record" do
      ipv6 = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      record = Record.new("example.com", 28, 1, 3600, ipv6)
      assert record.data.data == ipv6
    end

    test "AAAA record rdlength is always 16" do
      ipv6 = {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      record = Record.new("example.com", 28, 1, 3600, ipv6)
      assert record.rdlength == 16
    end

    test "creates AAAA with loopback" do
      loopback = {0, 0, 0, 0, 0, 0, 0, 1}
      record = Record.new("localhost", 28, 1, 3600, loopback)
      assert record.data.data == loopback
    end
  end

  describe "TTL handling" do
    test "zero TTL (no caching)" do
      record = Record.new("example.com", 1, 1, 0, {1, 2, 3, 4})
      assert record.ttl == 0
    end

    test "short TTL (5 minutes)" do
      record = Record.new("example.com", 1, 1, 300, {1, 2, 3, 4})
      assert record.ttl == 300
    end

    test "common TTL (1 hour)" do
      record = Record.new("example.com", 1, 1, 3600, {1, 2, 3, 4})
      assert record.ttl == 3600
    end

    test "long TTL (1 day)" do
      record = Record.new("example.com", 1, 1, 86400, {1, 2, 3, 4})
      assert record.ttl == 86400
    end

    test "max TTL (136 years)" do
      max_ttl = 0xFFFFFFFF
      record = Record.new("example.com", 1, 1, max_ttl, {1, 2, 3, 4})
      assert record.ttl == max_ttl
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = Record.new("example.com", 1, 1, 3600, {1, 2, 3, 4})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "handles root domain record" do
      # Use A record type (1) with proper IPv4 data
      record = Record.new(".", 1, 1, 3600, {1, 2, 3, 4})
      assert record.name.value == "."
    end

    test "handles single-label domain" do
      record = Record.new("localhost", 1, 1, 3600, {127, 0, 0, 1})
      assert record.name.value == "localhost."
    end

    test "handles subdomain" do
      record = Record.new("api.v2.example.com", 1, 1, 3600, {1, 2, 3, 4})
      assert record.name.value == "api.v2.example.com."
    end
  end

  describe "DNS protocol compliance" do
    test "record format follows RFC 1035" do
      record = Record.new("test.com", 1, 1, 3600, {1, 2, 3, 4})
      iodata = DNS.to_iodata(record)
      # Verify structure: NAME + TYPE(2) + CLASS(2) + TTL(4) + RDLENGTH(2) + RDATA
      # Total: 10 + 2 + 2 + 4 + 2 + 4 = 24 bytes
      assert byte_size(iodata) == 24
    end

    test "type is 16-bit value" do
      # Use binary data for unknown type 65535 (reserved)
      record = Record.new("test.com", 65535, 1, 3600, <<1, 2, 3, 4>>)
      iodata = DNS.to_iodata(record)
      domain_size = 10
      <<_domain::binary-size(domain_size), type::16, _rest::binary>> = iodata
      assert type == 65535
    end

    test "class is 16-bit value" do
      record = Record.new("test.com", 1, 65535, 3600, {1, 2, 3, 4})
      iodata = DNS.to_iodata(record)
      domain_size = 10
      <<_domain::binary-size(domain_size), _type::16, class::16, _rest::binary>> = iodata
      assert class == 65535
    end

    test "TTL is 32-bit unsigned" do
      record = Record.new("test.com", 1, 1, 0xFFFFFFFF, {1, 2, 3, 4})
      iodata = DNS.to_iodata(record)
      domain_size = 10
      <<_domain::binary-size(domain_size), _type::16, _class::16, ttl::32, _rest::binary>> = iodata
      assert ttl == 0xFFFFFFFF
    end
  end
end
