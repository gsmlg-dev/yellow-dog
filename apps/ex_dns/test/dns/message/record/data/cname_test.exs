defmodule DNS.Message.Record.Data.CNAMETest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.CNAME.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with domain name strings
  - from_iodata/1, from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 1035)
  - Edge cases and canonical names
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.CNAME
  alias DNS.Message.Domain

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(CNAME)
    end

    test "exports new/1" do
      Code.ensure_loaded!(CNAME)
      assert Kernel.function_exported?(CNAME, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(CNAME)
      assert Kernel.function_exported?(CNAME, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(CNAME)
      assert Kernel.function_exported?(CNAME, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(CNAME)
      assert is_struct(CNAME.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %CNAME{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %CNAME{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %CNAME{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %CNAME{}
      assert Map.has_key?(record, :data)
    end

    test "default type is CNAME (5)" do
      type = %CNAME{}.type
      assert type == DNS.ResourceRecordType.new(5)
    end

    test "default raw is nil" do
      assert %CNAME{}.raw == nil
    end

    test "default data is nil" do
      assert %CNAME{}.data == nil
    end
  end

  describe "new/1" do
    test "creates CNAME record from domain string" do
      record = CNAME.new("www.example.com")
      assert %CNAME{} = record
      assert %Domain{} = record.data
    end

    test "stores domain value" do
      record = CNAME.new("www.example.com")
      assert record.data.value == "www.example.com."
    end

    test "handles domain with trailing dot" do
      record = CNAME.new("www.example.com.")
      assert record.data.value == "www.example.com."
    end

    test "creates record for CDN alias" do
      record = CNAME.new("cdn.cloudfront.net")
      assert record.data.value == "cdn.cloudfront.net."
    end

    test "creates record for subdomain alias" do
      record = CNAME.new("www.example.com")
      assert record.data.value == "www.example.com."
    end

    test "creates record for deep subdomain" do
      record = CNAME.new("api.v2.prod.example.com")
      assert record.data.value == "api.v2.prod.example.com."
    end

    test "raw field contains binary data" do
      record = CNAME.new("www.example.com")
      assert is_binary(record.raw)
    end

    test "rdlength matches domain size" do
      domain = Domain.new("www.example.com")
      record = CNAME.new("www.example.com")
      assert record.rdlength == domain.size
    end

    test "handles single-label canonical name" do
      record = CNAME.new("localhost")
      assert record.data.value == "localhost."
    end
  end

  describe "from_iodata/1" do
    test "parses domain from binary" do
      raw = DNS.to_iodata(Domain.new("www.example.com"))
      record = CNAME.from_iodata(raw)
      assert %CNAME{} = record
      assert record.data.value == "www.example.com."
    end

    test "stores raw binary" do
      raw = DNS.to_iodata(Domain.new("alias.example.com"))
      record = CNAME.from_iodata(raw)
      assert record.raw == raw
    end

    test "parses short domain" do
      raw = DNS.to_iodata(Domain.new("a.co"))
      record = CNAME.from_iodata(raw)
      assert record.data.value == "a.co."
    end

    test "parses long domain" do
      raw = DNS.to_iodata(Domain.new("very.long.subdomain.chain.example.com"))
      record = CNAME.from_iodata(raw)
      assert record.data.value == "very.long.subdomain.chain.example.com."
    end

    test "sets rdlength from domain" do
      raw = DNS.to_iodata(Domain.new("test.example.com"))
      record = CNAME.from_iodata(raw)
      assert record.rdlength == record.data.size
    end
  end

  describe "from_iodata/2" do
    test "accepts message parameter for compression" do
      raw = DNS.to_iodata(Domain.new("www.example.com"))
      record = CNAME.from_iodata(raw, <<>>)
      assert %CNAME{} = record
    end

    test "message can be nil" do
      raw = DNS.to_iodata(Domain.new("www.example.com"))
      record = CNAME.from_iodata(raw, nil)
      assert record.data.value == "www.example.com."
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as domain name" do
      record = CNAME.new("www.example.com")
      assert to_string(record) == "www.example.com."
    end

    test "includes trailing dot" do
      record = CNAME.new("alias.example.com")
      str = to_string(record)
      assert String.ends_with?(str, ".")
    end

    test "string interpolation works" do
      record = CNAME.new("cdn.example.com")
      result = "CNAME: #{record}"
      assert result == "CNAME: cdn.example.com."
    end

    test "formats deep subdomain" do
      record = CNAME.new("api.v1.prod.example.com")
      str = to_string(record)
      assert str == "api.v1.prod.example.com."
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      record = CNAME.new("www.example.com")
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, domain_bytes::binary>> = iodata
      assert length == byte_size(domain_bytes)
    end

    test "length prefix matches domain size" do
      record = CNAME.new("alias.example.com")
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      domain = Domain.new("alias.example.com")
      assert length == byte_size(DNS.to_iodata(domain))
    end

    test "domain is encoded after length" do
      record = CNAME.new("test.com")
      iodata = DNS.Parameter.to_iodata(record)
      <<_length::16, first_label_len, _rest::binary>> = iodata
      # First label is "test" = 4 bytes
      assert first_label_len == 4
    end

    test "wire format byte size includes length prefix" do
      record = CNAME.new("www.example.com")
      iodata = DNS.Parameter.to_iodata(record)
      domain = Domain.new("www.example.com")
      assert byte_size(iodata) == byte_size(DNS.to_iodata(domain)) + 2
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      original = "www.example.com"
      record = CNAME.new(original)
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      parsed = CNAME.from_iodata(raw)
      assert parsed.data.value == "www.example.com."
    end

    test "round-trip preserves domain" do
      domains = ["a.com", "www.example.com", "cdn.cloudfront.net", "api.v2.example.com"]

      for domain <- domains do
        record = CNAME.new(domain)
        <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
        parsed = CNAME.from_iodata(raw)
        assert parsed.data.value == "#{domain}."
      end
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = CNAME.new("www.example.com")
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "handles hyphenated domains" do
      record = CNAME.new("my-service.example-domain.com")
      assert record.data.value == "my-service.example-domain.com."
    end

    test "handles numeric subdomains" do
      record = CNAME.new("123.456.example.com")
      assert record.data.value == "123.456.example.com."
    end

    test "handles internationalized domain (ASCII)" do
      record = CNAME.new("xn--nxasmq5b.com")
      assert record.data.value == "xn--nxasmq5b.com."
    end

    test "handles TLD-only domain" do
      record = CNAME.new("com")
      assert record.data.value == "com."
    end
  end
end
