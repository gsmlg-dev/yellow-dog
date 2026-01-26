defmodule DNS.Message.Record.DataTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data module.

  Tests cover:
  - Module structure and exports
  - struct fields
  - new/2 - record data creation with registry lookup
  - from_iodata/3 - binary parsing with registry lookup
  - DNS.Parameter protocol implementation
  - String.Chars protocol implementation
  - Fallback for unknown record types
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data
  alias DNS.ResourceRecordType, as: RRType

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(Data)
    end

    test "exports new/2" do
      Code.ensure_loaded!(Data)
      assert Kernel.function_exported?(Data, :new, 2)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(Data)
      assert Kernel.function_exported?(Data, :from_iodata, 2)
    end

    test "exports from_iodata/3" do
      Code.ensure_loaded!(Data)
      assert Kernel.function_exported?(Data, :from_iodata, 3)
    end
  end

  describe "struct" do
    test "has raw field" do
      data = %Data{}
      assert Map.has_key?(data, :raw)
    end

    test "has type field" do
      data = %Data{}
      assert Map.has_key?(data, :type)
    end

    test "has rdlength field" do
      data = %Data{}
      assert Map.has_key?(data, :rdlength)
    end

    test "raw defaults to empty binary" do
      data = %Data{}
      assert data.raw == <<>>
    end

    test "type defaults to nil" do
      data = %Data{}
      assert data.type == nil
    end

    test "rdlength defaults to nil" do
      data = %Data{}
      assert data.rdlength == nil
    end
  end

  describe "new/2 - known record types" do
    test "creates A record for type 1" do
      rtype = RRType.new(1)
      data = Data.new(rtype, {192, 168, 1, 1})

      assert %DNS.Message.Record.Data.A{} = data
      assert data.data == {192, 168, 1, 1}
    end

    test "creates AAAA record for type 28" do
      rtype = RRType.new(28)
      data = Data.new(rtype, {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})

      assert %DNS.Message.Record.Data.AAAA{} = data
      assert data.data == {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
    end

    test "creates CNAME record for type 5" do
      rtype = RRType.new(5)
      data = Data.new(rtype, "www.example.com.")

      assert %DNS.Message.Record.Data.CNAME{} = data
    end

    test "creates NS record for type 2" do
      rtype = RRType.new(2)
      data = Data.new(rtype, "ns1.example.com.")

      assert %DNS.Message.Record.Data.NS{} = data
    end

    test "creates MX record for type 15" do
      rtype = RRType.new(15)
      data = Data.new(rtype, {10, "mail.example.com."})

      assert %DNS.Message.Record.Data.MX{} = data
    end

    test "creates TXT record for type 16" do
      rtype = RRType.new(16)
      data = Data.new(rtype, ["Hello World"])

      assert %DNS.Message.Record.Data.TXT{} = data
      assert data.data == ["Hello World"]
    end

    test "creates PTR record for type 12" do
      rtype = RRType.new(12)
      data = Data.new(rtype, "host.example.com.")

      assert %DNS.Message.Record.Data.PTR{} = data
    end

    test "creates SRV record for type 33" do
      rtype = RRType.new(33)
      data = Data.new(rtype, {10, 5, 443, "server.example.com."})

      assert %DNS.Message.Record.Data.SRV{} = data
    end

    test "creates SOA record for type 6" do
      rtype = RRType.new(6)
      # SOA parameters: ns, rp, serial, refresh, retry, expire, negative
      ns = DNS.Message.Domain.new("ns1.example.com.")
      rp = DNS.Message.Domain.new("admin.example.com.")
      data = Data.new(rtype, {ns, rp, 2_024_010_101, 3600, 600, 604_800, 86400})

      assert %DNS.Message.Record.Data.SOA{} = data
    end

    test "creates CAA record for type 257" do
      rtype = RRType.new(257)
      data = Data.new(rtype, {0, "issue", "letsencrypt.org"})

      assert %DNS.Message.Record.Data.CAA{} = data
    end

    test "creates TLSA record for type 52" do
      rtype = RRType.new(52)
      data = Data.new(rtype, {3, 1, 1, <<0xAB, 0xCD, 0xEF>>})

      assert %DNS.Message.Record.Data.TLSA{} = data
    end
  end

  describe "new/2 - unknown record types (fallback)" do
    test "creates generic Data for unknown type" do
      rtype = RRType.new(9999)
      data = Data.new(rtype, "custom_data")

      assert %Data{} = data
    end

    test "generic data contains raw value" do
      rtype = RRType.new(9999)
      data = Data.new(rtype, "custom_data")

      assert data.raw == "custom_data"
    end

    test "generic data has correct rdlength" do
      rtype = RRType.new(9999)
      raw_data = <<1, 2, 3, 4, 5>>
      data = Data.new(rtype, raw_data)

      assert data.rdlength == 5
    end

    test "generic data has type set" do
      rtype = RRType.new(9999)
      data = Data.new(rtype, "test")

      assert data.type == rtype
    end
  end

  describe "from_iodata/2 and from_iodata/3 - known types" do
    test "parses A record binary" do
      binary = <<192, 168, 1, 1>>
      data = Data.from_iodata(1, binary)

      assert %DNS.Message.Record.Data.A{} = data
      assert data.data == {192, 168, 1, 1}
    end

    test "parses AAAA record binary" do
      binary = <<0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      data = Data.from_iodata(28, binary)

      assert %DNS.Message.Record.Data.AAAA{} = data
    end

    test "parses TXT record binary" do
      binary = <<4, "test">>
      data = Data.from_iodata(16, binary)

      assert %DNS.Message.Record.Data.TXT{} = data
    end

    test "parses with message context" do
      binary = <<192, 168, 1, 1>>
      message = <<>>
      data = Data.from_iodata(1, binary, message)

      assert %DNS.Message.Record.Data.A{} = data
    end
  end

  describe "from_iodata/2 and from_iodata/3 - unknown types" do
    test "creates generic Data for unknown type" do
      binary = <<1, 2, 3, 4>>
      data = Data.from_iodata(9999, binary)

      assert %Data{} = data
    end

    test "generic data stores raw binary" do
      binary = <<0xDE, 0xAD, 0xBE, 0xEF>>
      data = Data.from_iodata(9999, binary)

      assert data.raw == binary
    end

    test "generic data has correct rdlength" do
      binary = <<1, 2, 3, 4, 5, 6>>
      data = Data.from_iodata(9999, binary)

      assert data.rdlength == 6
    end

    test "generic data has type set from integer" do
      binary = <<1, 2>>
      data = Data.from_iodata(9999, binary)

      assert %RRType{} = data.type
      # 9999 in big-endian
      assert data.type.value == <<0x27, 0x0F>>
    end
  end

  describe "DNS.Parameter protocol implementation" do
    test "generic Data implements to_iodata" do
      data = %Data{rdlength: 4, raw: <<1, 2, 3, 4>>}
      result = DNS.Parameter.to_iodata(data)

      assert is_binary(result)
    end

    test "to_iodata includes rdlength prefix" do
      data = %Data{rdlength: 3, raw: <<0xAA, 0xBB, 0xCC>>}
      result = DNS.Parameter.to_iodata(data)

      <<rdlen::16, rest::binary>> = result
      assert rdlen == 3
      assert rest == <<0xAA, 0xBB, 0xCC>>
    end

    test "to_iodata for zero-length data" do
      data = %Data{rdlength: 0, raw: <<>>}
      result = DNS.Parameter.to_iodata(data)

      assert result == <<0, 0>>
    end
  end

  describe "String.Chars protocol implementation" do
    test "generic Data implements to_string" do
      data = %Data{raw: <<1, 2, 3>>}
      result = to_string(data)

      assert is_binary(result)
    end

    test "to_string inspects raw binary" do
      data = %Data{raw: <<192, 168, 1, 1>>}
      result = to_string(data)

      # Should contain the inspect output of the raw binary
      assert String.contains?(result, "192")
    end

    test "to_string for empty raw" do
      data = %Data{raw: <<>>}
      result = to_string(data)

      # Empty binary inspects as "" (empty string)
      assert result == "\"\""
    end

    test "to_string for printable string" do
      data = %Data{raw: "hello"}
      result = to_string(data)

      assert String.contains?(result, "hello")
    end
  end

  describe "round-trip compatibility" do
    test "generic data survives serialization round-trip" do
      original_raw = <<0xDE, 0xAD, 0xBE, 0xEF>>
      rtype = RRType.new(9999)
      data = Data.new(rtype, original_raw)

      # Serialize
      binary = DNS.Parameter.to_iodata(data)

      # Parse the rdlen and raw
      <<rdlen::16, raw::binary>> = binary

      assert rdlen == 4
      assert raw == original_raw
    end
  end

  describe "edge cases" do
    test "handles empty raw data for unknown type" do
      rtype = RRType.new(9999)
      data = Data.new(rtype, <<>>)

      assert data.raw == <<>>
      assert data.rdlength == 0
    end

    test "handles large raw data" do
      rtype = RRType.new(9999)
      large_data = :binary.copy(<<0xFF>>, 1000)
      data = Data.new(rtype, large_data)

      assert data.raw == large_data
      assert data.rdlength == 1000
    end

    test "from_iodata with empty binary" do
      data = Data.from_iodata(9999, <<>>)

      assert data.raw == <<>>
      assert data.rdlength == 0
    end
  end

  describe "known record types - DNS.Parameter serialization" do
    test "A record serializes correctly" do
      rtype = RRType.new(1)
      data = Data.new(rtype, {192, 168, 1, 100})

      result = DNS.Parameter.to_iodata(data)

      # A record: 2 bytes rdlen + 4 bytes IP
      <<rdlen::16, ip::binary>> = result
      assert rdlen == 4
      assert ip == <<192, 168, 1, 100>>
    end

    test "AAAA record serializes correctly" do
      rtype = RRType.new(28)
      data = Data.new(rtype, {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})

      result = DNS.Parameter.to_iodata(data)

      # AAAA record: 2 bytes rdlen + 16 bytes IP
      <<rdlen::16, _ip::binary-size(16)>> = result
      assert rdlen == 16
    end

    test "TXT record serializes correctly" do
      rtype = RRType.new(16)
      data = Data.new(rtype, ["test"])

      result = DNS.Parameter.to_iodata(data)

      # TXT record: 2 bytes rdlen + 1 byte string len + string
      <<rdlen::16, str_len::8, text::binary>> = result
      # 1 byte len + 4 bytes "test"
      assert rdlen == 5
      assert str_len == 4
      assert text == "test"
    end
  end
end
