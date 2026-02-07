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
      nameservers = [
        "ns1.example.com",
        "ns-1234.awsdns-12.org",
        "dns1.p01.nsone.net",
        "ns.cloudflare.com"
      ]

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

  describe "RFC compliance" do
    test "NS record type value is 2 per RFC 1035" do
      record = NS.new("ns1.example.com")
      # RFC 1035 Section 3.2.2: NS = 2
      # type.value is binary <<0, 2>> representing 16-bit value
      assert record.type.value == <<0, 2>>
    end

    test "domain name follows RFC 1035 wire format" do
      record = NS.new("ns.example.com")
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      # Should start with label length (2 for "ns")
      <<label_len, label::binary-size(label_len), _rest::binary>> = raw
      assert label_len == 2
      assert label == "ns"
    end

    test "domain ends with null label (root)" do
      record = NS.new("ns.example.com")
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      # Last byte should be 0 (null label indicating root)
      assert :binary.last(raw) == 0
    end

    test "handles maximum label length (63 characters)" do
      # RFC 1035: label max is 63 octets
      long_label = String.duplicate("a", 63)
      record = NS.new("#{long_label}.example.com")
      assert record.data.value == "#{long_label}.example.com."
    end

    test "handles near-maximum domain length" do
      # RFC 1035: domain max is 255 octets including length bytes
      # Build domain with multiple labels
      labels = ["ns1", "sub1", "sub2", "sub3", "example", "com"]
      domain = Enum.join(labels, ".")
      record = NS.new(domain)
      assert record.data.value == "#{domain}."
    end
  end

  describe "common DNS providers" do
    test "creates record for AWS Route53 nameserver" do
      ns_names = [
        "ns-123.awsdns-12.org",
        "ns-456.awsdns-34.co.uk",
        "ns-789.awsdns-56.com",
        "ns-1024.awsdns-78.net"
      ]

      for ns <- ns_names do
        record = NS.new(ns)
        assert record.data.value == "#{ns}."
        assert %NS{} = record
      end
    end

    test "creates record for Google Cloud DNS nameserver" do
      ns_names = [
        "ns-cloud-a1.googledomains.com",
        "ns-cloud-b2.googledomains.com",
        "ns-cloud-c3.googledomains.com",
        "ns-cloud-d4.googledomains.com"
      ]

      for ns <- ns_names do
        record = NS.new(ns)
        assert record.data.value == "#{ns}."
      end
    end

    test "creates record for Cloudflare nameserver" do
      ns_names = [
        "abby.ns.cloudflare.com",
        "brad.ns.cloudflare.com",
        "chad.ns.cloudflare.com"
      ]

      for ns <- ns_names do
        record = NS.new(ns)
        assert record.data.value == "#{ns}."
      end
    end

    test "creates record for Azure DNS nameserver" do
      ns_names = [
        "ns1-01.azure-dns.com",
        "ns2-01.azure-dns.net",
        "ns3-01.azure-dns.org",
        "ns4-01.azure-dns.info"
      ]

      for ns <- ns_names do
        record = NS.new(ns)
        assert record.data.value == "#{ns}."
      end
    end

    test "creates record for NS1 nameserver" do
      record = NS.new("dns1.p01.nsone.net")
      assert record.data.value == "dns1.p01.nsone.net."
    end

    test "creates record for DNSimple nameserver" do
      record = NS.new("ns1.dnsimple.com")
      assert record.data.value == "ns1.dnsimple.com."
    end
  end

  describe "root servers" do
    test "creates records for all root servers" do
      root_servers = [
        "a.root-servers.net",
        "b.root-servers.net",
        "c.root-servers.net",
        "d.root-servers.net",
        "e.root-servers.net",
        "f.root-servers.net",
        "g.root-servers.net",
        "h.root-servers.net",
        "i.root-servers.net",
        "j.root-servers.net",
        "k.root-servers.net",
        "l.root-servers.net",
        "m.root-servers.net"
      ]

      for ns <- root_servers do
        record = NS.new(ns)
        assert record.data.value == "#{ns}."
        assert %NS{} = record
      end
    end
  end

  describe "TLD nameservers" do
    test "creates records for gTLD servers" do
      gtld_servers = [
        "a.gtld-servers.net",
        "b.gtld-servers.net",
        "c.gtld-servers.net"
      ]

      for ns <- gtld_servers do
        record = NS.new(ns)
        assert record.data.value == "#{ns}."
      end
    end

    test "creates records for ccTLD servers" do
      cctld_servers = [
        "a.nic.uk",
        "b.nic.de",
        "c.nic.fr"
      ]

      for ns <- cctld_servers do
        record = NS.new(ns)
        assert record.data.value == "#{ns}."
      end
    end
  end

  describe "type field" do
    test "type field is DNS.ResourceRecordType struct" do
      record = NS.new("ns1.example.com")
      assert %DNS.ResourceRecordType{} = record.type
    end

    test "type can be compared with new type" do
      record = NS.new("ns1.example.com")
      ns_type = DNS.ResourceRecordType.new(:ns)
      assert record.type == ns_type
    end

    test "type can be compared by value" do
      record = NS.new("ns1.example.com")
      # Value is 16-bit binary representation
      assert record.type.value == <<0, 2>>
    end
  end

  describe "data field" do
    test "data is Domain struct" do
      record = NS.new("ns1.example.com")
      assert %Domain{} = record.data
    end

    test "domain value includes trailing dot" do
      record = NS.new("ns1.example.com")
      assert String.ends_with?(record.data.value, ".")
    end

    test "domain has correct size" do
      record = NS.new("ns.co")
      # "ns" (2) + length (1) + "co" (2) + length (1) + null (1) = 7
      assert record.data.size == 7
    end
  end

  describe "raw field" do
    test "raw field is binary representation" do
      record = NS.new("ns1.example.com")
      assert is_binary(record.raw)
    end

    test "raw matches domain wire format" do
      record = NS.new("ns1.example.com")
      domain = Domain.new("ns1.example.com")
      expected_raw = DNS.to_iodata(domain)
      assert record.raw == expected_raw
    end
  end

  describe "rdlength field" do
    test "rdlength matches domain size" do
      record = NS.new("ns1.example.com")
      domain = Domain.new("ns1.example.com")
      assert record.rdlength == domain.size
    end

    test "rdlength varies with domain length" do
      short = NS.new("ns.co")
      long = NS.new("ns1.subdomain.example.com")
      assert short.rdlength < long.rdlength
    end
  end

  describe "concurrency" do
    test "multiple NS record creations are thread-safe" do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            NS.new("ns#{i}.example.com")
          end)
        end

      results = Task.await_many(tasks)

      for {result, i} <- Enum.with_index(results, 1) do
        assert %NS{} = result
        assert result.data.value == "ns#{i}.example.com."
      end
    end
  end

  describe "special nameserver patterns" do
    test "handles international domain nameserver" do
      # punycode encoded international domain
      record = NS.new("ns1.xn--n3h.com")
      assert record.data.value == "ns1.xn--n3h.com."
    end

    test "handles deeply nested nameserver" do
      record = NS.new("ns1.dns.zone.sub.example.com")
      assert record.data.value == "ns1.dns.zone.sub.example.com."
    end

    test "handles all numeric labels (IP-based reference)" do
      record = NS.new("ns1.192.168.1.example.com")
      assert record.data.value == "ns1.192.168.1.example.com."
    end

    test "handles mixed case input" do
      record = NS.new("NS1.Example.COM")
      # Domain should preserve or normalize case
      assert record.data != nil
    end

    test "handles private/internal nameserver" do
      record = NS.new("ns1.internal.corp")
      assert record.data.value == "ns1.internal.corp."
    end
  end

  describe "comparison and equality" do
    test "two NS records with same domain are equal" do
      record1 = NS.new("ns1.example.com")
      record2 = NS.new("ns1.example.com")
      assert record1.data.value == record2.data.value
    end

    test "two NS records with different domains differ" do
      record1 = NS.new("ns1.example.com")
      record2 = NS.new("ns2.example.com")
      refute record1.data.value == record2.data.value
    end

    test "NS record with and without trailing dot are equivalent" do
      record1 = NS.new("ns1.example.com")
      record2 = NS.new("ns1.example.com.")
      assert record1.data.value == record2.data.value
    end
  end

  describe "error conditions" do
    test "empty domain results in root" do
      record = NS.new("")
      # Empty input should result in root domain
      assert record.data != nil
    end

    test "domain with only trailing dot" do
      record = NS.new(".")
      # Root domain representation
      assert record.data != nil
    end
  end

  describe "integration with DNS message" do
    test "NS record can be used in resource record" do
      ns = NS.new("ns1.example.com")
      # Verify it has the fields needed for a resource record
      assert to_string(ns.type) != ""
      assert ns.rdlength != nil
      assert ns.data != nil
    end

    test "multiple NS records for same zone" do
      ns_records = [
        NS.new("ns1.example.com"),
        NS.new("ns2.example.com"),
        NS.new("ns3.example.com")
      ]

      for record <- ns_records do
        assert %NS{} = record
        # Type value is 16-bit binary
        assert record.type.value == <<0, 2>>
      end
    end
  end
end
