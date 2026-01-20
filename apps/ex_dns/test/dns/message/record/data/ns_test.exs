defmodule DNS.Message.Record.Data.NSTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.NS.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with nameserver domain strings
  - from_iodata/1, from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 1035)
  - Edge cases and common nameserver patterns
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.NS
  alias DNS.Message.Domain

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(NS)
    end

    test "exports new/1" do
      Code.ensure_loaded!(NS)
      assert Kernel.function_exported?(NS, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(NS)
      assert Kernel.function_exported?(NS, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(NS)
      assert Kernel.function_exported?(NS, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(NS)
      assert is_struct(NS.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %NS{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %NS{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %NS{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %NS{}
      assert Map.has_key?(record, :data)
    end

    test "default type is NS (2)" do
      type = %NS{}.type
      assert type == DNS.ResourceRecordType.new(2)
    end

    test "default raw is nil" do
      assert %NS{}.raw == nil
    end

    test "default data is nil" do
      assert %NS{}.data == nil
    end
  end

  describe "new/1" do
    test "creates NS record from domain string" do
      record = NS.new("ns1.example.com")
      assert %NS{} = record
      assert %Domain{} = record.data
    end

    test "stores nameserver domain" do
      record = NS.new("ns1.example.com")
      assert record.data.value == "ns1.example.com."
    end

    test "handles domain with trailing dot" do
      record = NS.new("ns1.example.com.")
      assert record.data.value == "ns1.example.com."
    end

    test "creates record for typical ns1 naming" do
      record = NS.new("ns1.example.com")
      assert record.data.value == "ns1.example.com."
    end

    test "creates record for typical ns2 naming" do
      record = NS.new("ns2.example.com")
      assert record.data.value == "ns2.example.com."
    end

    test "creates record for cloud provider nameserver" do
      record = NS.new("ns-1234.awsdns-12.org")
      assert record.data.value == "ns-1234.awsdns-12.org."
    end

    test "creates record for registrar nameserver" do
      record = NS.new("dns1.registrar-servers.com")
      assert record.data.value == "dns1.registrar-servers.com."
    end

    test "raw field contains binary data" do
      record = NS.new("ns1.example.com")
      assert is_binary(record.raw)
    end

    test "rdlength matches domain size" do
      domain = Domain.new("ns1.example.com")
      record = NS.new("ns1.example.com")
      assert record.rdlength == domain.size
    end

    test "handles single-label nameserver" do
      record = NS.new("localhost")
      assert record.data.value == "localhost."
    end
  end

  describe "from_iodata/1" do
    test "parses nameserver from binary" do
      raw = DNS.to_iodata(Domain.new("ns1.example.com"))
      record = NS.from_iodata(raw)
      assert %NS{} = record
      assert record.data.value == "ns1.example.com."
    end

    test "stores raw binary" do
      raw = DNS.to_iodata(Domain.new("ns2.example.com"))
      record = NS.from_iodata(raw)
      assert record.raw == raw
    end

    test "parses short nameserver domain" do
      raw = DNS.to_iodata(Domain.new("ns.co"))
      record = NS.from_iodata(raw)
      assert record.data.value == "ns.co."
    end

    test "parses long nameserver domain" do
      raw = DNS.to_iodata(Domain.new("ns1.primary.dns.provider.example.com"))
      record = NS.from_iodata(raw)
      assert record.data.value == "ns1.primary.dns.provider.example.com."
    end
  end

  describe "from_iodata/2" do
    test "accepts message parameter for compression" do
      raw = DNS.to_iodata(Domain.new("ns1.example.com"))
      record = NS.from_iodata(raw, <<>>)
      assert %NS{} = record
    end

    test "message can be nil" do
      raw = DNS.to_iodata(Domain.new("ns1.example.com"))
      record = NS.from_iodata(raw, nil)
      assert record.data.value == "ns1.example.com."
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as nameserver domain" do
      record = NS.new("ns1.example.com")
      assert to_string(record) == "ns1.example.com."
    end

    test "includes trailing dot" do
      record = NS.new("ns2.example.com")
      str = to_string(record)
      assert String.ends_with?(str, ".")
    end

    test "string interpolation works" do
      record = NS.new("ns1.example.com")
      result = "NS: #{record}"
      assert result == "NS: ns1.example.com."
    end

    test "formats cloud provider nameserver" do
      record = NS.new("ns-1234.awsdns-12.org")
      str = to_string(record)
      assert str == "ns-1234.awsdns-12.org."
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      record = NS.new("ns1.example.com")
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, domain_bytes::binary>> = iodata
      assert length == byte_size(domain_bytes)
    end

    test "length prefix matches domain size" do
      record = NS.new("ns2.example.com")
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      domain = Domain.new("ns2.example.com")
      assert length == byte_size(DNS.to_iodata(domain))
    end

    test "domain is encoded after length" do
      record = NS.new("ns.com")
      iodata = DNS.Parameter.to_iodata(record)
      <<_length::16, first_label_len, _rest::binary>> = iodata
      # First label is "ns" = 2 bytes
      assert first_label_len == 2
    end

    test "wire format byte size includes length prefix" do
      record = NS.new("ns1.example.com")
      iodata = DNS.Parameter.to_iodata(record)
      domain = Domain.new("ns1.example.com")
      assert byte_size(iodata) == byte_size(DNS.to_iodata(domain)) + 2
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      original = "ns1.example.com"
      record = NS.new(original)
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      parsed = NS.from_iodata(raw)
      assert parsed.data.value == "ns1.example.com."
    end

    test "round-trip preserves nameserver domain" do
      nameservers = ["ns1.example.com", "ns-1234.awsdns-12.org", "dns1.p01.nsone.net", "ns.cloudflare.com"]

      for ns <- nameservers do
        record = NS.new(ns)
        <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
        parsed = NS.from_iodata(raw)
        assert parsed.data.value == "#{ns}."
      end
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = NS.new("ns1.example.com")
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "handles hyphenated nameserver names" do
      record = NS.new("ns-1234.awsdns-12.co.uk")
      assert record.data.value == "ns-1234.awsdns-12.co.uk."
    end

    test "handles numeric nameserver names" do
      record = NS.new("ns1.dns.google")
      assert record.data.value == "ns1.dns.google."
    end

    test "handles root server naming pattern" do
      record = NS.new("a.root-servers.net")
      assert record.data.value == "a.root-servers.net."
    end

    test "handles TLD nameserver" do
      record = NS.new("a.gtld-servers.net")
      assert record.data.value == "a.gtld-servers.net."
    end
  end
end
