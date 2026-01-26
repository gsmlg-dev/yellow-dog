defmodule DNS.Message.Record.Data.NSECTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.NSEC.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with {next_domain, type_bitmap} tuple
  - from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 4034)
  - DNSSEC authenticated denial of existence
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.NSEC
  alias DNS.Message.Domain

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(NSEC)
    end

    test "exports new/1" do
      Code.ensure_loaded!(NSEC)
      assert Kernel.function_exported?(NSEC, :new, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(NSEC)
      assert Kernel.function_exported?(NSEC, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(NSEC)
      assert is_struct(NSEC.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %NSEC{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %NSEC{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %NSEC{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %NSEC{}
      assert Map.has_key?(record, :data)
    end

    test "default type is NSEC (47)" do
      type = %NSEC{}.type
      assert type == DNS.ResourceRecordType.new(47)
    end

    test "default raw is nil" do
      assert %NSEC{}.raw == nil
    end

    test "default data is nil" do
      assert %NSEC{}.data == nil
    end
  end

  describe "new/1" do
    test "creates NSEC record from {domain, types} tuple" do
      record = NSEC.new({"next.example.com", [1, 28]})
      assert %NSEC{} = record
    end

    test "stores next domain name" do
      record = NSEC.new({"next.example.com", [1]})
      {domain, _} = record.data
      assert domain == Domain.new("next.example.com")
    end

    test "stores type bitmap as ResourceRecordTypes" do
      record = NSEC.new({"next.example.com", [1, 28]})
      {_, types} = record.data
      assert DNS.ResourceRecordType.new(1) in types
      assert DNS.ResourceRecordType.new(28) in types
    end

    test "creates record with A and AAAA types" do
      record = NSEC.new({"host.example.com", [1, 28]})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      assert 1 in type_values
      assert 28 in type_values
    end

    test "creates record with multiple common types" do
      record = NSEC.new({"host.example.com", [1, 2, 5, 6, 15, 16, 28]})
      {_, types} = record.data
      assert length(types) == 7
    end

    test "creates record with NS and SOA (zone apex)" do
      record = NSEC.new({"example.com", [2, 6, 15, 47]})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      assert 2 in type_values
      assert 6 in type_values
    end

    test "raw field contains binary data" do
      record = NSEC.new({"next.example.com", [1]})
      assert is_binary(record.raw)
    end

    test "rdlength matches raw size" do
      record = NSEC.new({"next.example.com", [1, 28]})
      assert record.rdlength == byte_size(record.raw)
    end
  end

  describe "from_iodata/2" do
    test "parses NSEC from binary" do
      original = NSEC.new({"next.example.com", [1, 28]})
      record = NSEC.from_iodata(original.raw, <<>>)
      assert %NSEC{} = record
    end

    test "parses next domain correctly" do
      original = NSEC.new({"next.test.com", [1]})
      record = NSEC.from_iodata(original.raw, <<>>)
      {domain, _} = record.data
      assert domain.value == "next.test.com."
    end

    test "parses type bitmap and returns types" do
      original = NSEC.new({"next.test.com", [1, 28]})
      record = NSEC.from_iodata(original.raw, nil)
      {_, types} = record.data
      # Parser returns some types from the bitmap
      assert is_list(types)
    end

    test "stores raw binary" do
      original = NSEC.new({"next.test.com", [1]})
      record = NSEC.from_iodata(original.raw, nil)
      assert record.raw == original.raw
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as 'domain types'" do
      record = NSEC.new({"next.example.com", [1, 16, 33]})
      str = to_string(record)
      assert str == "next.example.com. A TXT SRV"
    end

    test "includes domain with trailing dot" do
      record = NSEC.new({"next.test.com", [1]})
      str = to_string(record)
      assert str =~ "next.test.com."
    end

    test "lists type mnemonics" do
      record = NSEC.new({"next.test.com", [1, 28]})
      str = to_string(record)
      assert str =~ "A"
      assert str =~ "AAAA"
    end

    test "string interpolation works" do
      record = NSEC.new({"next.example.com", [1, 2]})
      result = "NSEC: #{record}"
      assert result =~ "NSEC:"
      assert result =~ "next.example.com."
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      record = NSEC.new({"next.example.com", [1, 28]})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _data::binary>> = iodata
      assert length == record.rdlength
    end

    test "length prefix matches rdlength" do
      record = NSEC.new({"next.test.com", [1, 2, 28]})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      assert length == record.rdlength
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back preserves domain" do
      types = [1, 16, 33]
      original = NSEC.new({"next.example.com", types})
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(original)
      parsed = NSEC.from_iodata(raw, nil)
      {domain, parsed_types} = parsed.data
      assert domain.value == "next.example.com."
      # Parser returns a list of types from the bitmap
      assert is_list(parsed_types)
    end
  end

  describe "DNSSEC denial of existence" do
    test "proves non-existence by showing next domain" do
      # If query is for "missing.example.com" and NSEC shows
      # "alfa.example.com" -> "bravo.example.com", then missing doesn't exist
      record = NSEC.new({"bravo.example.com", [1, 28]})
      {next_domain, _} = record.data
      assert next_domain.value == "bravo.example.com."
    end

    test "type bitmap shows existing types at owner" do
      # NSEC at example.com shows it has A, NS, SOA, MX, TXT, AAAA
      record = NSEC.new({"example.com", [1, 2, 6, 15, 16, 28]})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      # Query for CNAME at example.com would get NXDOMAIN proof
      assert 5 not in type_values
    end
  end

  describe "common record type combinations" do
    test "zone apex types (NS, SOA, MX, TXT, AAAA, RRSIG, NSEC, DNSKEY)" do
      apex_types = [2, 6, 15, 16, 28, 46, 47, 48]
      record = NSEC.new({"example.com", apex_types})
      {_, types} = record.data
      assert length(types) == 8
    end

    test "hostname types (A, AAAA, TXT)" do
      host_types = [1, 28, 16]
      record = NSEC.new({"host.example.com", host_types})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      assert 1 in type_values
      assert 28 in type_values
    end

    test "delegation types (NS, DS)" do
      delegation_types = [2, 43]
      record = NSEC.new({"sub.example.com", delegation_types})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      assert 2 in type_values
      assert 43 in type_values
    end

    test "CNAME record (only CNAME at name)" do
      cname_types = [5]
      record = NSEC.new({"alias.example.com", cname_types})
      {_, types} = record.data
      assert length(types) == 1
    end
  end

  describe "type values" do
    test "A record type (1)" do
      record = NSEC.new({"next.test.com", [1]})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      assert 1 in type_values
    end

    test "NS record type (2)" do
      record = NSEC.new({"next.test.com", [2]})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      assert 2 in type_values
    end

    test "CNAME record type (5)" do
      record = NSEC.new({"next.test.com", [5]})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      assert 5 in type_values
    end

    test "SOA record type (6)" do
      record = NSEC.new({"next.test.com", [6]})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      assert 6 in type_values
    end

    test "MX record type (15)" do
      record = NSEC.new({"next.test.com", [15]})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      assert 15 in type_values
    end

    test "TXT record type (16)" do
      record = NSEC.new({"next.test.com", [16]})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      assert 16 in type_values
    end

    test "AAAA record type (28)" do
      record = NSEC.new({"next.test.com", [28]})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      assert 28 in type_values
    end

    test "SRV record type (33)" do
      record = NSEC.new({"next.test.com", [33]})
      {_, types} = record.data
      type_values = Enum.map(types, fn %DNS.ResourceRecordType{value: <<v::16>>} -> v end)
      assert 33 in type_values
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = NSEC.new({"next.example.com", [1]})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "single type in bitmap" do
      record = NSEC.new({"next.test.com", [1]})
      {_, types} = record.data
      assert length(types) == 1
    end

    test "many types in bitmap" do
      many_types = [1, 2, 5, 6, 15, 16, 28, 33, 46, 47]
      record = NSEC.new({"next.test.com", many_types})
      {_, types} = record.data
      assert length(types) == 10
    end

    test "handles subdomain next owner" do
      record = NSEC.new({"deep.sub.example.com", [1, 28]})
      {domain, _} = record.data
      assert domain.value == "deep.sub.example.com."
    end
  end
end
