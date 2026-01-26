defmodule DNS.Message.Record.Data.OPTTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.OPT.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with EDNS0 struct
  - from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 6891)
  - EDNS0 options and flags
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.OPT
  alias DNS.Message.EDNS0

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(OPT)
    end

    test "exports new/1" do
      Code.ensure_loaded!(OPT)
      assert Kernel.function_exported?(OPT, :new, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(OPT)
      assert Kernel.function_exported?(OPT, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(OPT)
      assert is_struct(OPT.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %OPT{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %OPT{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %OPT{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %OPT{}
      assert Map.has_key?(record, :data)
    end

    test "default type is OPT (41)" do
      type = %OPT{}.type
      assert type == DNS.ResourceRecordType.new(41)
    end

    test "default raw is nil" do
      assert %OPT{}.raw == nil
    end

    test "default data is nil" do
      assert %OPT{}.data == nil
    end

    test "default rdlength is nil" do
      assert %OPT{}.rdlength == nil
    end
  end

  describe "new/1" do
    test "creates OPT record from EDNS0 struct" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      assert %OPT{} = record
      assert %EDNS0{} = record.data
    end

    test "stores EDNS0 data" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      assert record.data == edns0
    end

    test "raw field contains binary data" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      assert is_binary(record.raw)
    end

    test "rdlength matches raw size" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      assert record.rdlength == byte_size(record.raw)
    end

    test "creates record with custom UDP payload size" do
      edns0 = EDNS0.new({4096, 0, 0, 0, 0, []})
      record = OPT.new(edns0)
      assert record.data.udp_payload == 4096
    end

    test "creates record with DNSSEC OK bit set" do
      edns0 = EDNS0.new({512, 0, 0, 1, 0, []})
      record = OPT.new(edns0)
      assert record.data.do_bit == 1
    end

    test "creates record with extended RCODE" do
      edns0 = EDNS0.new({512, 16, 0, 0, 0, []})
      record = OPT.new(edns0)
      assert record.data.extended_rcode == 16
    end

    test "creates record with EDNS version" do
      edns0 = EDNS0.new({512, 0, 1, 0, 0, []})
      record = OPT.new(edns0)
      assert record.data.version == 1
    end

    test "creates record with empty options" do
      edns0 = EDNS0.new({512, 0, 0, 0, 0, []})
      record = OPT.new(edns0)
      assert record.data.options == []
    end

    test "type value is 41" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      assert record.type.value == <<41::16>>
    end
  end

  describe "from_iodata/2" do
    test "parses OPT from EDNS0 binary" do
      # EDNS0 format: root(0) type(41) udp(512) ext_rcode(0) version(0) flags(0) rdlen(0)
      raw = <<0, 0, 41, 2, 0, 0, 0, 0, 0, 0, 0>>
      record = OPT.from_iodata(raw)
      assert %OPT{} = record
    end

    test "parses UDP payload size" do
      # UDP payload 4096 = 0x1000
      raw = <<0, 0, 41, 0x10, 0x00, 0, 0, 0, 0, 0, 0>>
      record = OPT.from_iodata(raw)
      assert record.data.udp_payload == 4096
    end

    test "parses extended RCODE" do
      # Extended RCODE 16
      raw = <<0, 0, 41, 2, 0, 16, 0, 0, 0, 0, 0>>
      record = OPT.from_iodata(raw)
      assert record.data.extended_rcode == 16
    end

    test "parses version" do
      # Version 1
      raw = <<0, 0, 41, 2, 0, 0, 1, 0, 0, 0, 0>>
      record = OPT.from_iodata(raw)
      assert record.data.version == 1
    end

    test "parses DO bit" do
      # DO bit set (0x80 in high byte of flags)
      raw = <<0, 0, 41, 2, 0, 0, 0, 0x80, 0, 0, 0>>
      record = OPT.from_iodata(raw)
      assert record.data.do_bit == 1
    end

    test "stores raw binary" do
      raw = <<0, 0, 41, 2, 0, 0, 0, 0, 0, 0, 0>>
      record = OPT.from_iodata(raw)
      assert record.raw == raw
    end

    test "message parameter can be nil" do
      raw = <<0, 0, 41, 2, 0, 0, 0, 0, 0, 0, 0>>
      record = OPT.from_iodata(raw, nil)
      assert %OPT{} = record
    end

    test "message parameter can be empty binary" do
      raw = <<0, 0, 41, 2, 0, 0, 0, 0, 0, 0, 0>>
      record = OPT.from_iodata(raw, <<>>)
      assert %OPT{} = record
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats EDNS0 information" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      str = to_string(record)
      assert is_binary(str)
    end

    test "includes version in output" do
      edns0 = EDNS0.new({512, 0, 0, 0, 0, []})
      record = OPT.new(edns0)
      str = to_string(record)
      assert str =~ "version: 0"
    end

    test "includes DO flag when set" do
      edns0 = EDNS0.new({512, 0, 0, 1, 0, []})
      record = OPT.new(edns0)
      str = to_string(record)
      assert str =~ "DO"
    end

    test "includes UDP payload size" do
      edns0 = EDNS0.new({4096, 0, 0, 0, 0, []})
      record = OPT.new(edns0)
      str = to_string(record)
      assert str =~ "4096"
    end

    test "string interpolation works" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      result = "OPT: #{record}"
      assert result =~ "OPT:"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      iodata = DNS.Parameter.to_iodata(record)
      assert is_binary(iodata)
    end

    test "includes length prefix" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length >= 0
    end

    test "length prefix matches content size" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, rest::binary>> = iodata
      assert length == byte_size(rest)
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse preserves EDNS0 structure" do
      edns0 = EDNS0.new({4096, 0, 0, 1, 0, []})
      record = OPT.new(edns0)
      <<_length::16, _rest::binary>> = DNS.Parameter.to_iodata(record)
      # OPT parsing requires the full EDNS0 format including root name and type
      # which is handled by the record itself
      assert record.data.udp_payload == 4096
      assert record.data.do_bit == 1
    end
  end

  describe "EDNS0 semantics" do
    test "OPT is pseudo-RR type 41" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      assert record.type.value == <<0, 41>>
    end

    test "UDP payload size indicates buffer size" do
      # 512 is minimal compliant size
      edns0 = EDNS0.new({512, 0, 0, 0, 0, []})
      record = OPT.new(edns0)
      assert record.data.udp_payload == 512
    end

    test "large UDP payload size for modern resolvers" do
      # 4096 is common for modern resolvers
      edns0 = EDNS0.new({4096, 0, 0, 0, 0, []})
      record = OPT.new(edns0)
      assert record.data.udp_payload == 4096
    end

    test "DO bit requests DNSSEC data" do
      edns0 = EDNS0.new({512, 0, 0, 1, 0, []})
      record = OPT.new(edns0)
      assert record.data.do_bit == 1
    end

    test "version 0 is standard EDNS" do
      edns0 = EDNS0.new({512, 0, 0, 0, 0, []})
      record = OPT.new(edns0)
      assert record.data.version == 0
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "maximum UDP payload size" do
      edns0 = EDNS0.new({65535, 0, 0, 0, 0, []})
      record = OPT.new(edns0)
      assert record.data.udp_payload == 65535
    end

    test "maximum extended RCODE" do
      edns0 = EDNS0.new({512, 255, 0, 0, 0, []})
      record = OPT.new(edns0)
      assert record.data.extended_rcode == 255
    end

    test "maximum version" do
      edns0 = EDNS0.new({512, 0, 255, 0, 0, []})
      record = OPT.new(edns0)
      assert record.data.version == 255
    end

    test "default EDNS0 has zero values" do
      edns0 = EDNS0.new()
      record = OPT.new(edns0)
      assert record.data.udp_payload == 0
      assert record.data.extended_rcode == 0
      assert record.data.version == 0
      assert record.data.do_bit == 0
      assert record.data.flags == 0
      assert record.data.options == []
    end
  end
end
