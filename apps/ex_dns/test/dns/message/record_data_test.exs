defmodule DNS.Message.RecordDataTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/2 with various record types (delegation to Registry)
  - from_iodata/3 for parsing binary data
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Generic fallback for unknown types
  - Registry integration
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data
  alias DNS.ResourceRecordType

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

    test "defines a struct" do
      Code.ensure_loaded!(Data)
      assert is_struct(Data.__struct__())
    end
  end

  describe "struct fields" do
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

    test "default raw is empty binary" do
      data = %Data{}
      assert data.raw == <<>>
    end

    test "default type is nil" do
      data = %Data{}
      assert data.type == nil
    end

    test "default rdlength is nil" do
      data = %Data{}
      assert data.rdlength == nil
    end
  end

  describe "new/2 delegation to Registry" do
    test "creates A record via Registry" do
      rtype = ResourceRecordType.new(1)
      data = Data.new(rtype, {192, 168, 1, 1})
      assert %DNS.Message.Record.Data.A{} = data
    end

    test "creates AAAA record via Registry" do
      rtype = ResourceRecordType.new(28)
      data = Data.new(rtype, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      assert %DNS.Message.Record.Data.AAAA{} = data
    end

    test "creates NS record via Registry" do
      rtype = ResourceRecordType.new(2)
      data = Data.new(rtype, "ns1.example.com")
      assert %DNS.Message.Record.Data.NS{} = data
    end

    test "creates CNAME record via Registry" do
      rtype = ResourceRecordType.new(5)
      data = Data.new(rtype, "alias.example.com")
      assert %DNS.Message.Record.Data.CNAME{} = data
    end

    test "creates MX record via Registry" do
      rtype = ResourceRecordType.new(15)
      data = Data.new(rtype, {10, "mail.example.com"})
      assert %DNS.Message.Record.Data.MX{} = data
    end

    test "creates TXT record via Registry" do
      rtype = ResourceRecordType.new(16)
      # TXT records expect a list of strings
      data = Data.new(rtype, ["v=spf1 include:example.com ~all"])
      assert %DNS.Message.Record.Data.TXT{} = data
    end

    test "creates SOA record via Registry" do
      rtype = ResourceRecordType.new(6)
      soa_data = {"ns1.example.com", "admin.example.com", 2024010101, 3600, 1800, 604800, 86400}
      data = Data.new(rtype, soa_data)
      assert %DNS.Message.Record.Data.SOA{} = data
    end

    test "creates PTR record via Registry" do
      rtype = ResourceRecordType.new(12)
      data = Data.new(rtype, "host.example.com")
      assert %DNS.Message.Record.Data.PTR{} = data
    end
  end

  describe "new/2 fallback for unknown types" do
    test "falls back to generic Data for unknown type" do
      # Type 9999 is not registered
      rtype = ResourceRecordType.new(9999)
      raw_data = <<1, 2, 3, 4, 5>>
      data = Data.new(rtype, raw_data)
      assert %Data{} = data
    end

    test "stores raw data for unknown type" do
      rtype = ResourceRecordType.new(9999)
      raw_data = <<1, 2, 3, 4, 5>>
      data = Data.new(rtype, raw_data)
      assert data.raw == raw_data
    end

    test "stores type for unknown type" do
      rtype = ResourceRecordType.new(9999)
      data = Data.new(rtype, <<1, 2, 3, 4>>)
      assert data.type == rtype
    end

    test "calculates rdlength for unknown type" do
      rtype = ResourceRecordType.new(9999)
      raw_data = <<1, 2, 3, 4, 5>>
      data = Data.new(rtype, raw_data)
      assert data.rdlength == 5
    end

    test "handles empty data for unknown type" do
      rtype = ResourceRecordType.new(9999)
      data = Data.new(rtype, <<>>)
      assert data.rdlength == 0
      assert data.raw == <<>>
    end
  end

  describe "from_iodata/2 delegation to Registry" do
    test "parses A record via Registry" do
      data = Data.from_iodata(1, <<192, 168, 1, 1>>)
      assert %DNS.Message.Record.Data.A{} = data
    end

    test "parses AAAA record via Registry" do
      ipv6_binary = <<0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
      data = Data.from_iodata(28, ipv6_binary)
      assert %DNS.Message.Record.Data.AAAA{} = data
    end

    test "parses NS record via Registry" do
      # Wire format: length-prefixed labels
      wire_data = <<3, "ns1", 7, "example", 3, "com", 0>>
      data = Data.from_iodata(2, wire_data)
      assert %DNS.Message.Record.Data.NS{} = data
    end

    test "parses TXT record via Registry" do
      # TXT format: length byte + text
      wire_data = <<5, "hello">>
      data = Data.from_iodata(16, wire_data)
      assert %DNS.Message.Record.Data.TXT{} = data
    end
  end

  describe "from_iodata/3 with message context" do
    test "passes message context to implementation" do
      # A record doesn't use message context, but the call should work
      message = <<>>
      data = Data.from_iodata(1, <<192, 168, 1, 1>>, message)
      assert %DNS.Message.Record.Data.A{} = data
    end

    test "allows empty message context" do
      data = Data.from_iodata(1, <<10, 0, 0, 1>>, <<>>)
      assert %DNS.Message.Record.Data.A{} = data
    end
  end

  describe "from_iodata fallback for unknown types" do
    test "falls back to generic Data for unknown type" do
      data = Data.from_iodata(9999, <<1, 2, 3, 4>>)
      assert %Data{} = data
    end

    test "stores raw data for unknown type" do
      raw = <<1, 2, 3, 4, 5>>
      data = Data.from_iodata(9999, raw)
      assert data.raw == raw
    end

    test "calculates rdlength for unknown type" do
      data = Data.from_iodata(9999, <<1, 2, 3, 4, 5>>)
      assert data.rdlength == 5
    end

    test "creates type from integer for unknown type" do
      data = Data.from_iodata(9999, <<1, 2, 3, 4>>)
      assert data.type == ResourceRecordType.new(9999)
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces wire format with rdlength prefix" do
      data = %Data{rdlength: 4, raw: <<192, 168, 1, 1>>}
      iodata = DNS.Parameter.to_iodata(data)
      assert iodata == <<0, 4, 192, 168, 1, 1>>
    end

    test "rdlength is 16-bit big-endian" do
      data = %Data{rdlength: 256, raw: :binary.copy(<<0>>, 256)}
      <<length::16, _rest::binary>> = DNS.Parameter.to_iodata(data)
      assert length == 256
    end

    test "handles empty raw data" do
      data = %Data{rdlength: 0, raw: <<>>}
      iodata = DNS.Parameter.to_iodata(data)
      assert iodata == <<0, 0>>
    end

    test "handles large raw data" do
      raw = :binary.copy(<<0xFF>>, 1000)
      data = %Data{rdlength: 1000, raw: raw}
      <<length::16, rest::binary>> = DNS.Parameter.to_iodata(data)
      assert length == 1000
      assert rest == raw
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "inspects raw data" do
      data = %Data{raw: <<192, 168, 1, 1>>}
      str = to_string(data)
      assert str =~ "192"
      assert str =~ "168"
    end

    test "handles empty raw data" do
      data = %Data{raw: <<>>}
      str = to_string(data)
      # Empty binary inspects as empty string in Elixir
      assert str == "\"\""
    end

    test "handles binary raw data" do
      data = %Data{raw: <<1, 2, 3>>}
      str = to_string(data)
      assert is_binary(str)
    end

    test "string interpolation works" do
      data = %Data{raw: <<1, 2, 3, 4>>}
      result = "Data: #{data}"
      assert is_binary(result)
    end
  end

  describe "round-trip for unknown types" do
    test "new -> to_iodata -> from_iodata preserves data" do
      rtype = ResourceRecordType.new(9999)
      raw = <<1, 2, 3, 4, 5>>
      original = Data.new(rtype, raw)
      iodata = DNS.Parameter.to_iodata(original)

      # Skip the rdlength prefix for from_iodata
      <<_length::16, raw_data::binary>> = iodata
      parsed = Data.from_iodata(9999, raw_data)

      assert parsed.raw == original.raw
      assert parsed.rdlength == original.rdlength
    end

    test "preserves various binary data" do
      rtype = ResourceRecordType.new(9999)

      for raw <- [<<>>, <<1>>, <<1, 2, 3, 4, 5, 6, 7, 8>>, :binary.copy(<<0xFF>>, 100)] do
        original = Data.new(rtype, raw)
        parsed = Data.from_iodata(9999, raw)
        assert parsed.raw == original.raw
      end
    end
  end

  describe "protocol definition (DNS.Message.RecordData)" do
    test "DNS.Message.RecordData protocol is defined" do
      assert Code.ensure_loaded?(DNS.Message.RecordData)
    end

    test "defines to_iodata/1 callback" do
      Code.ensure_loaded!(DNS.Message.RecordData)
      assert function_exported?(DNS.Message.RecordData, :to_iodata, 1)
    end

    test "protocol has impl_for/1 function" do
      Code.ensure_loaded!(DNS.Message.RecordData)
      assert function_exported?(DNS.Message.RecordData, :impl_for, 1)
    end

    test "protocol is properly defined" do
      Code.ensure_loaded!(DNS.Message.RecordData)
      assert :erlang.function_exported(DNS.Message.RecordData, :__protocol__, 1)
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      data = %Data{raw: <<1, 2, 3>>, rdlength: 3}
      inspect_output = inspect(data)
      assert is_binary(inspect_output)
    end

    test "handles max rdlength (65535)" do
      raw = :binary.copy(<<0>>, 65535)
      data = %Data{rdlength: 65535, raw: raw}
      assert data.rdlength == 65535
    end

    test "handles various type numbers" do
      for type_num <- [1, 2, 5, 6, 12, 15, 16, 28, 33, 41, 43, 46, 47, 48, 52, 99, 256, 257] do
        rtype = ResourceRecordType.new(type_num)
        # Just verify it doesn't crash
        assert %{} = rtype
      end
    end

    test "handles binary with all zeros" do
      data = Data.from_iodata(9999, <<0, 0, 0, 0>>)
      assert data.raw == <<0, 0, 0, 0>>
    end

    test "handles binary with all ones" do
      data = Data.from_iodata(9999, <<255, 255, 255, 255>>)
      assert data.raw == <<255, 255, 255, 255>>
    end
  end
end
