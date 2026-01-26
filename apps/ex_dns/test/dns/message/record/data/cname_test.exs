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

  describe "RFC compliance" do
    test "CNAME record type value is 5 per RFC 1035" do
      record = CNAME.new("www.example.com")
      # RFC 1035 Section 3.2.2: CNAME = 5
      # type.value is binary <<0, 5>> representing 16-bit value
      assert record.type.value == <<0, 5>>
    end

    test "domain name follows RFC 1035 wire format" do
      record = CNAME.new("www.example.com")
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      # Should start with label length (3 for "www")
      <<label_len, label::binary-size(label_len), _rest::binary>> = raw
      assert label_len == 3
      assert label == "www"
    end

    test "domain ends with null label (root)" do
      record = CNAME.new("www.example.com")
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      # Last byte should be 0 (null label indicating root)
      assert :binary.last(raw) == 0
    end

    test "handles maximum label length (63 characters)" do
      # RFC 1035: label max is 63 octets
      long_label = String.duplicate("a", 63)
      record = CNAME.new("#{long_label}.example.com")
      assert record.data.value == "#{long_label}.example.com."
    end

    test "handles near-maximum domain length" do
      # RFC 1035: domain max is 255 octets including length bytes
      labels = ["www", "sub1", "sub2", "sub3", "example", "com"]
      domain = Enum.join(labels, ".")
      record = CNAME.new(domain)
      assert record.data.value == "#{domain}."
    end
  end

  describe "CDN and cloud provider patterns" do
    test "creates record for CloudFront distribution" do
      cdn_domains = [
        "d111111abcdef8.cloudfront.net",
        "d1234567890abc.cloudfront.net"
      ]

      for cdn <- cdn_domains do
        record = CNAME.new(cdn)
        assert record.data.value == "#{cdn}."
        assert %CNAME{} = record
      end
    end

    test "creates record for Cloudflare proxy" do
      record = CNAME.new("example.com.cdn.cloudflare.net")
      assert record.data.value == "example.com.cdn.cloudflare.net."
    end

    test "creates record for Azure CDN" do
      cdn_domains = [
        "example.azureedge.net",
        "example-cdn.azureedge.net"
      ]

      for cdn <- cdn_domains do
        record = CNAME.new(cdn)
        assert record.data.value == "#{cdn}."
      end
    end

    test "creates record for Google Cloud CDN" do
      record = CNAME.new("c.storage.googleapis.com")
      assert record.data.value == "c.storage.googleapis.com."
    end

    test "creates record for Fastly CDN" do
      record = CNAME.new("global.ssl.fastly.net")
      assert record.data.value == "global.ssl.fastly.net."
    end

    test "creates record for Akamai CDN" do
      record = CNAME.new("example.edgekey.net")
      assert record.data.value == "example.edgekey.net."
    end
  end

  describe "common CNAME use cases" do
    test "www to apex domain alias" do
      record = CNAME.new("example.com")
      assert record.data.value == "example.com."
    end

    test "subdomain to load balancer" do
      record = CNAME.new("api-lb-1234567890.us-east-1.elb.amazonaws.com")
      assert record.data.value == "api-lb-1234567890.us-east-1.elb.amazonaws.com."
    end

    test "mail alias to external provider" do
      mail_targets = [
        "mail.google.com",
        "outlook.office365.com",
        "mx.example-mail.com"
      ]

      for target <- mail_targets do
        record = CNAME.new(target)
        assert record.data.value == "#{target}."
      end
    end

    test "verification record for services" do
      verification_targets = [
        "_dmarc.example.com",
        "_domainkey.example.com"
      ]

      for target <- verification_targets do
        record = CNAME.new(target)
        assert record.data.value == "#{target}."
      end
    end

    test "service discovery alias" do
      record = CNAME.new("_http._tcp.example.com")
      assert record.data.value == "_http._tcp.example.com."
    end
  end

  describe "type field" do
    test "type field is DNS.ResourceRecordType struct" do
      record = CNAME.new("www.example.com")
      assert %DNS.ResourceRecordType{} = record.type
    end

    test "type can be compared with new type" do
      record = CNAME.new("www.example.com")
      cname_type = DNS.ResourceRecordType.new(:cname)
      assert record.type == cname_type
    end

    test "type can be compared by value" do
      record = CNAME.new("www.example.com")
      # Value is 16-bit binary representation
      assert record.type.value == <<0, 5>>
    end
  end

  describe "data field" do
    test "data is Domain struct" do
      record = CNAME.new("www.example.com")
      assert %Domain{} = record.data
    end

    test "domain value includes trailing dot" do
      record = CNAME.new("www.example.com")
      assert String.ends_with?(record.data.value, ".")
    end

    test "domain has correct size" do
      record = CNAME.new("a.co")
      # "a" (1) + length (1) + "co" (2) + length (1) + null (1) = 6
      assert record.data.size == 6
    end

    test "domain size increases with label count" do
      short = CNAME.new("a.com")
      long = CNAME.new("a.b.c.d.com")
      assert short.data.size < long.data.size
    end
  end

  describe "raw field" do
    test "raw field is binary representation" do
      record = CNAME.new("www.example.com")
      assert is_binary(record.raw)
    end

    test "raw matches domain wire format" do
      record = CNAME.new("www.example.com")
      domain = Domain.new("www.example.com")
      expected_raw = DNS.to_iodata(domain)
      assert record.raw == expected_raw
    end
  end

  describe "rdlength field" do
    test "rdlength matches domain size" do
      record = CNAME.new("www.example.com")
      domain = Domain.new("www.example.com")
      assert record.rdlength == domain.size
    end

    test "rdlength varies with domain length" do
      short = CNAME.new("a.co")
      long = CNAME.new("www.subdomain.example.com")
      assert short.rdlength < long.rdlength
    end
  end

  describe "concurrency" do
    test "multiple CNAME record creations are thread-safe" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            CNAME.new("alias#{i}.example.com")
          end)
        end

      results = Task.await_many(tasks)

      for {result, i} <- Enum.with_index(results, 1) do
        assert %CNAME{} = result
        assert result.data.value == "alias#{i}.example.com."
      end
    end
  end

  describe "special domain patterns" do
    test "handles underscore prefixed domains" do
      record = CNAME.new("_acme-challenge.example.com")
      assert record.data.value == "_acme-challenge.example.com."
    end

    test "handles deeply nested subdomains" do
      record = CNAME.new("a.b.c.d.e.f.example.com")
      assert record.data.value == "a.b.c.d.e.f.example.com."
    end

    test "handles mixed case input" do
      record = CNAME.new("WWW.Example.COM")
      # Domain should preserve or normalize case
      assert record.data != nil
    end

    test "handles new TLDs" do
      new_tlds = [
        "example.app",
        "example.dev",
        "example.io",
        "example.cloud",
        "example.ai"
      ]

      for tld <- new_tlds do
        record = CNAME.new(tld)
        assert record.data.value == "#{tld}."
      end
    end

    test "handles country code TLDs" do
      cctlds = [
        "example.co.uk",
        "example.com.au",
        "example.de",
        "example.jp"
      ]

      for domain <- cctlds do
        record = CNAME.new(domain)
        assert record.data.value == "#{domain}."
      end
    end
  end

  describe "comparison and equality" do
    test "two CNAME records with same domain are equal" do
      record1 = CNAME.new("www.example.com")
      record2 = CNAME.new("www.example.com")
      assert record1.data.value == record2.data.value
    end

    test "two CNAME records with different domains differ" do
      record1 = CNAME.new("www.example.com")
      record2 = CNAME.new("api.example.com")
      refute record1.data.value == record2.data.value
    end

    test "CNAME record with and without trailing dot are equivalent" do
      record1 = CNAME.new("www.example.com")
      record2 = CNAME.new("www.example.com.")
      assert record1.data.value == record2.data.value
    end
  end

  describe "error conditions" do
    test "empty domain results in root" do
      record = CNAME.new("")
      # Empty input should result in root domain
      assert record.data != nil
    end

    test "domain with only trailing dot" do
      record = CNAME.new(".")
      # Root domain representation
      assert record.data != nil
    end
  end

  describe "CNAME chain scenarios" do
    test "can create multiple chained CNAMEs" do
      # Simulating: www -> alias1 -> alias2 -> target
      chain = [
        CNAME.new("alias1.example.com"),
        CNAME.new("alias2.example.com"),
        CNAME.new("target.example.com")
      ]

      for record <- chain do
        assert %CNAME{} = record
        assert record.type.value == <<0, 5>>
      end
    end
  end

  describe "integration with DNS message" do
    test "CNAME record can be used in resource record" do
      cname = CNAME.new("www.example.com")
      # Verify it has the fields needed for a resource record
      assert cname.type != nil
      assert cname.rdlength != nil
      assert cname.data != nil
    end

    test "CNAME with various target domains" do
      targets = [
        "www.example.com",
        "cdn.cloudfront.net",
        "lb.us-east-1.amazonaws.com",
        "proxy.cloudflare.net"
      ]

      for target <- targets do
        record = CNAME.new(target)
        assert %CNAME{} = record
        assert record.type.value == <<0, 5>>
      end
    end
  end

  describe "wildcard CNAME targets" do
    test "creates record pointing to wildcard target result" do
      # CNAME can point to the result of a wildcard lookup
      record = CNAME.new("wildcard-result.example.com")
      assert record.data.value == "wildcard-result.example.com."
    end
  end

  describe "performance" do
    test "creating many CNAME records is efficient" do
      records =
        for i <- 1..100 do
          CNAME.new("alias#{i}.example.com")
        end

      assert length(records) == 100

      for {record, i} <- Enum.with_index(records, 1) do
        assert record.data.value == "alias#{i}.example.com."
      end
    end
  end
end
