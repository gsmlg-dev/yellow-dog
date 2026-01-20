defmodule DNS.Message.Record.Data.SOATest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.SOA.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with 7-element tuple
  - from_iodata/1, from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 1035)
  - SOA field semantics (serial, refresh, retry, expire, minimum)
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.SOA
  alias DNS.Message.Domain

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(SOA)
    end

    test "exports new/1" do
      Code.ensure_loaded!(SOA)
      assert Kernel.function_exported?(SOA, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(SOA)
      assert Kernel.function_exported?(SOA, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(SOA)
      assert Kernel.function_exported?(SOA, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(SOA)
      assert is_struct(SOA.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %SOA{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %SOA{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %SOA{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %SOA{}
      assert Map.has_key?(record, :data)
    end

    test "default type is SOA (6)" do
      type = %SOA{}.type
      assert type == DNS.ResourceRecordType.new(6)
    end

    test "default raw is nil" do
      assert %SOA{}.raw == nil
    end

    test "default data is nil" do
      assert %SOA{}.data == nil
    end
  end

  describe "new/1" do
    test "creates SOA record from 7-element tuple" do
      ns = Domain.new("ns1.example.com")
      rp = Domain.new("admin.example.com")
      soa = {ns, rp, 2024012101, 3600, 600, 604800, 86400}
      record = SOA.new(soa)
      assert %SOA{} = record
      assert record.data == soa
    end

    test "stores nameserver (MNAME)" do
      ns = Domain.new("ns1.example.com")
      rp = Domain.new("admin.example.com")
      record = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      {mname, _, _, _, _, _, _} = record.data
      assert mname == ns
    end

    test "stores responsible person (RNAME)" do
      ns = Domain.new("ns1.example.com")
      rp = Domain.new("hostmaster.example.com")
      record = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      {_, rname, _, _, _, _, _} = record.data
      assert rname == rp
    end

    test "stores serial number" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      serial = 2024012101
      record = SOA.new({ns, rp, serial, 3600, 600, 604800, 86400})
      {_, _, s, _, _, _, _} = record.data
      assert s == serial
    end

    test "stores refresh interval" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      refresh = 7200
      record = SOA.new({ns, rp, 1, refresh, 600, 604800, 86400})
      {_, _, _, r, _, _, _} = record.data
      assert r == refresh
    end

    test "stores retry interval" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      retry_val = 900
      record = SOA.new({ns, rp, 1, 3600, retry_val, 604800, 86400})
      {_, _, _, _, r, _, _} = record.data
      assert r == retry_val
    end

    test "stores expire time" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      expire = 1209600
      record = SOA.new({ns, rp, 1, 3600, 600, expire, 86400})
      {_, _, _, _, _, e, _} = record.data
      assert e == expire
    end

    test "stores negative TTL (minimum)" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      minimum = 3600
      record = SOA.new({ns, rp, 1, 3600, 600, 604800, minimum})
      {_, _, _, _, _, _, m} = record.data
      assert m == minimum
    end

    test "raw field contains binary data" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      record = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      assert is_binary(record.raw)
    end

    test "rdlength matches raw size" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      record = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      assert record.rdlength == byte_size(record.raw)
    end

    test "handles typical zone configuration" do
      ns = Domain.new("ns1.example.com")
      rp = Domain.new("hostmaster.example.com")
      # Typical values: serial YYYYMMDDNN, refresh 3h, retry 15m, expire 1w, minimum 1d
      record = SOA.new({ns, rp, 2024012101, 10800, 900, 604800, 86400})
      assert %SOA{} = record
    end
  end

  describe "from_iodata/1" do
    test "parses SOA from binary" do
      ns = Domain.new("ns.example.com")
      rp = Domain.new("admin.example.com")
      original = SOA.new({ns, rp, 123, 456, 789, 1000, 2000})
      record = SOA.from_iodata(original.raw)
      assert %SOA{} = record
    end

    test "parses nameserver correctly" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      original = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      record = SOA.from_iodata(original.raw)
      {mname, _, _, _, _, _, _} = record.data
      assert mname.value == "ns.test.com."
    end

    test "parses responsible person correctly" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("hostmaster.test.com")
      original = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      record = SOA.from_iodata(original.raw)
      {_, rname, _, _, _, _, _} = record.data
      assert rname.value == "hostmaster.test.com."
    end

    test "parses all numeric fields" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      original = SOA.new({ns, rp, 100, 200, 300, 400, 500})
      record = SOA.from_iodata(original.raw)
      {_, _, serial, refresh, retry_val, expire, minimum} = record.data
      assert serial == 100
      assert refresh == 200
      assert retry_val == 300
      assert expire == 400
      assert minimum == 500
    end

    test "stores raw binary" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      original = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      record = SOA.from_iodata(original.raw)
      assert record.raw == original.raw
    end
  end

  describe "from_iodata/2" do
    test "accepts message parameter for compression" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      original = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      record = SOA.from_iodata(original.raw, <<>>)
      assert %SOA{} = record
    end

    test "message can be nil" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      original = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      record = SOA.from_iodata(original.raw, nil)
      {_, _, serial, _, _, _, _} = record.data
      assert serial == 1
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats all SOA fields" do
      ns = Domain.new("ns.example.com")
      rp = Domain.new("admin.example.com")
      record = SOA.new({ns, rp, 2024012101, 10800, 900, 604800, 86400})
      str = to_string(record)
      assert str == "ns.example.com. admin.example.com. 2024012101 10800 900 604800 86400"
    end

    test "includes nameserver with trailing dot" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      record = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      str = to_string(record)
      assert str =~ "ns.test.com."
    end

    test "includes responsible person with trailing dot" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("hostmaster.test.com")
      record = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      str = to_string(record)
      assert str =~ "hostmaster.test.com."
    end

    test "string interpolation works" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      record = SOA.new({ns, rp, 12345, 1, 1, 1, 1})
      result = "SOA: #{record}"
      assert result =~ "SOA:"
      assert result =~ "12345"
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      ns = Domain.new("ns.example.com")
      rp = Domain.new("admin.example.com")
      record = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _data::binary>> = iodata
      assert length > 0
    end

    test "length includes domains and 20 bytes for numeric fields" do
      ns = Domain.new("ns.example.com")
      rp = Domain.new("admin.example.com")
      record = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      ns_size = byte_size(DNS.to_iodata(ns))
      rp_size = byte_size(DNS.to_iodata(rp))
      assert length == ns_size + rp_size + 20
    end

    test "numeric fields are 32-bit each (5 fields = 20 bytes)" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("rp.test.com")
      record = SOA.new({ns, rp, 1, 2, 3, 4, 5})
      iodata = DNS.Parameter.to_iodata(record)
      <<_length::16, rest::binary>> = iodata
      ns_size = byte_size(DNS.to_iodata(ns))
      rp_size = byte_size(DNS.to_iodata(rp))
      <<_ns::binary-size(ns_size), _rp::binary-size(rp_size), s::32, re::32, rt::32, e::32, m::32>> =
        rest

      assert {s, re, rt, e, m} == {1, 2, 3, 4, 5}
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      ns = Domain.new("ns.example.com")
      rp = Domain.new("admin.example.com")
      original = {ns, rp, 2024012101, 3600, 600, 604800, 86400}
      record = SOA.new(original)
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      parsed = SOA.from_iodata(raw)
      {mname, rname, serial, refresh, retry_val, expire, minimum} = parsed.data
      assert mname.value == "ns.example.com."
      assert rname.value == "admin.example.com."
      assert serial == 2024012101
      assert refresh == 3600
      assert retry_val == 600
      assert expire == 604800
      assert minimum == 86400
    end
  end

  describe "SOA field semantics" do
    test "serial number typical format YYYYMMDDNN" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      serial = 2024012101
      record = SOA.new({ns, rp, serial, 3600, 600, 604800, 86400})
      {_, _, s, _, _, _, _} = record.data
      assert s == serial
    end

    test "refresh interval in seconds" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      # 3 hours = 10800 seconds
      record = SOA.new({ns, rp, 1, 10800, 600, 604800, 86400})
      {_, _, _, refresh, _, _, _} = record.data
      assert refresh == 10800
    end

    test "retry interval typically shorter than refresh" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      # 15 minutes = 900 seconds
      record = SOA.new({ns, rp, 1, 10800, 900, 604800, 86400})
      {_, _, _, _, retry_val, _, _} = record.data
      assert retry_val == 900
    end

    test "expire time typically 1-2 weeks" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      # 1 week = 604800 seconds
      record = SOA.new({ns, rp, 1, 10800, 900, 604800, 86400})
      {_, _, _, _, _, expire, _} = record.data
      assert expire == 604800
    end

    test "minimum TTL for negative caching" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      # 1 day = 86400 seconds
      record = SOA.new({ns, rp, 1, 10800, 900, 604800, 86400})
      {_, _, _, _, _, _, minimum} = record.data
      assert minimum == 86400
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      record = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "maximum serial number" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      # Max 32-bit unsigned: 4294967295, but typespec says 2_147_483_647
      max_serial = 2_147_483_647
      record = SOA.new({ns, rp, max_serial, 1, 1, 1, 1})
      {_, _, s, _, _, _, _} = record.data
      assert s == max_serial
    end

    test "zero values" do
      ns = Domain.new("ns.test.com")
      rp = Domain.new("admin.test.com")
      record = SOA.new({ns, rp, 0, 0, 0, 0, 0})
      {_, _, serial, refresh, retry_val, expire, minimum} = record.data
      assert {serial, refresh, retry_val, expire, minimum} == {0, 0, 0, 0, 0}
    end

    test "responsible person email format" do
      # admin@example.com becomes admin.example.com in DNS
      ns = Domain.new("ns.example.com")
      rp = Domain.new("admin.example.com")
      record = SOA.new({ns, rp, 1, 1, 1, 1, 1})
      str = to_string(record)
      assert str =~ "admin.example.com."
    end
  end
end
