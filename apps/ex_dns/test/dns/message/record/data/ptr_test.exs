defmodule DNS.Message.Record.Data.PTRTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Message.Record.Data.PTR.

  Tests cover:
  - Module structure and exports
  - Struct fields and defaults
  - new/1 with reverse DNS domain strings
  - from_iodata/1, from_iodata/2 for parsing
  - Protocol implementations (DNS.Parameter, String.Chars)
  - Wire format encoding (RFC 1035)
  - Edge cases (reverse DNS, mDNS service discovery)
  """
  use ExUnit.Case, async: true

  alias DNS.Message.Record.Data.PTR
  alias DNS.Message.Domain

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(PTR)
    end

    test "exports new/1" do
      Code.ensure_loaded!(PTR)
      assert Kernel.function_exported?(PTR, :new, 1)
    end

    test "exports from_iodata/1" do
      Code.ensure_loaded!(PTR)
      assert Kernel.function_exported?(PTR, :from_iodata, 1)
    end

    test "exports from_iodata/2" do
      Code.ensure_loaded!(PTR)
      assert Kernel.function_exported?(PTR, :from_iodata, 2)
    end

    test "defines a struct" do
      Code.ensure_loaded!(PTR)
      assert is_struct(PTR.__struct__())
    end
  end

  describe "struct fields" do
    test "has type field" do
      record = %PTR{}
      assert Map.has_key?(record, :type)
    end

    test "has rdlength field" do
      record = %PTR{}
      assert Map.has_key?(record, :rdlength)
    end

    test "has raw field" do
      record = %PTR{}
      assert Map.has_key?(record, :raw)
    end

    test "has data field" do
      record = %PTR{}
      assert Map.has_key?(record, :data)
    end

    test "default type is PTR (12)" do
      type = %PTR{}.type
      assert type == DNS.ResourceRecordType.new(12)
    end

    test "default raw is nil" do
      assert %PTR{}.raw == nil
    end

    test "default data is nil" do
      assert %PTR{}.data == nil
    end
  end

  describe "new/1" do
    test "creates PTR record from domain string" do
      record = PTR.new("host.example.com")
      assert %PTR{} = record
      assert %Domain{} = record.data
    end

    test "stores pointed domain" do
      record = PTR.new("host.example.com")
      assert record.data.value == "host.example.com."
    end

    test "handles domain with trailing dot" do
      record = PTR.new("host.example.com.")
      assert record.data.value == "host.example.com."
    end

    test "creates record for reverse IPv4 lookup" do
      # 1.168.192.in-addr.arpa points to hostname
      record = PTR.new("router.local")
      assert record.data.value == "router.local."
    end

    test "creates record for mDNS service discovery" do
      record = PTR.new("_http._tcp.local")
      assert record.data.value == "_http._tcp.local."
    end

    test "creates record for mDNS service instance" do
      record = PTR.new("My Web Server._http._tcp.local")
      assert record.data.value == "My Web Server._http._tcp.local."
    end

    test "creates record for IoT service discovery" do
      record = PTR.new("_ewelink._tcp.local")
      assert record.data.value == "_ewelink._tcp.local."
    end

    test "raw field contains binary data" do
      record = PTR.new("host.example.com")
      assert is_binary(record.raw)
    end

    test "rdlength matches domain size" do
      domain = Domain.new("host.example.com")
      record = PTR.new("host.example.com")
      assert record.rdlength == domain.size
    end

    test "handles single-label hostname" do
      record = PTR.new("localhost")
      assert record.data.value == "localhost."
    end
  end

  describe "from_iodata/1" do
    test "parses domain from binary" do
      raw = DNS.to_iodata(Domain.new("host.example.com"))
      record = PTR.from_iodata(raw)
      assert %PTR{} = record
      assert record.data.value == "host.example.com."
    end

    test "stores raw binary" do
      raw = DNS.to_iodata(Domain.new("server.local"))
      record = PTR.from_iodata(raw)
      assert record.raw == raw
    end

    test "parses reverse DNS domain" do
      raw = DNS.to_iodata(Domain.new("1.0.168.192.in-addr.arpa"))
      record = PTR.from_iodata(raw)
      assert record.data.value == "1.0.168.192.in-addr.arpa."
    end

    test "parses mDNS service type" do
      raw = DNS.to_iodata(Domain.new("_http._tcp.local"))
      record = PTR.from_iodata(raw)
      assert record.data.value == "_http._tcp.local."
    end

    test "sets rdlength from domain" do
      raw = DNS.to_iodata(Domain.new("host.example.com"))
      record = PTR.from_iodata(raw)
      assert record.rdlength == record.data.size
    end
  end

  describe "from_iodata/2" do
    test "accepts message parameter for compression" do
      raw = DNS.to_iodata(Domain.new("host.example.com"))
      record = PTR.from_iodata(raw, <<>>)
      assert %PTR{} = record
    end

    test "message can be nil" do
      raw = DNS.to_iodata(Domain.new("host.example.com"))
      record = PTR.from_iodata(raw, nil)
      assert record.data.value == "host.example.com."
    end
  end

  describe "String.Chars protocol (to_string)" do
    test "formats as pointed domain" do
      record = PTR.new("host.example.com")
      assert to_string(record) == "host.example.com."
    end

    test "includes trailing dot" do
      record = PTR.new("server.local")
      str = to_string(record)
      assert String.ends_with?(str, ".")
    end

    test "string interpolation works" do
      record = PTR.new("host.example.com")
      result = "PTR: #{record}"
      assert result == "PTR: host.example.com."
    end

    test "formats mDNS service type" do
      record = PTR.new("_http._tcp.local")
      str = to_string(record)
      assert str == "_http._tcp.local."
    end

    test "formats reverse DNS domain" do
      record = PTR.new("1.0.168.192.in-addr.arpa")
      str = to_string(record)
      assert str == "1.0.168.192.in-addr.arpa."
    end
  end

  describe "DNS.Parameter protocol (to_iodata)" do
    test "produces correct wire format" do
      record = PTR.new("host.example.com")
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, domain_bytes::binary>> = iodata
      assert length == byte_size(domain_bytes)
    end

    test "length prefix matches domain size" do
      record = PTR.new("server.local")
      iodata = DNS.Parameter.to_iodata(record)
      <<length::16, _rest::binary>> = iodata
      domain = Domain.new("server.local")
      assert length == byte_size(DNS.to_iodata(domain))
    end

    test "domain is encoded after length" do
      record = PTR.new("host.com")
      iodata = DNS.Parameter.to_iodata(record)
      <<_length::16, first_label_len, _rest::binary>> = iodata
      # First label is "host" = 4 bytes
      assert first_label_len == 4
    end

    test "wire format byte size includes length prefix" do
      record = PTR.new("host.example.com")
      iodata = DNS.Parameter.to_iodata(record)
      domain = Domain.new("host.example.com")
      assert byte_size(iodata) == byte_size(DNS.to_iodata(domain)) + 2
    end
  end

  describe "round-trip" do
    test "new/1 -> to_iodata -> parse back" do
      original = "host.example.com"
      record = PTR.new(original)
      <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
      parsed = PTR.from_iodata(raw)
      assert parsed.data.value == "host.example.com."
    end

    test "round-trip preserves domain" do
      domains = ["host.local", "_http._tcp.local", "1.0.168.192.in-addr.arpa", "server.example.com"]

      for domain <- domains do
        record = PTR.new(domain)
        <<_length::16, raw::binary>> = DNS.Parameter.to_iodata(record)
        parsed = PTR.from_iodata(raw)
        assert parsed.data.value == "#{domain}."
      end
    end
  end

  describe "reverse DNS (in-addr.arpa)" do
    test "creates IPv4 reverse lookup domain" do
      # For IP 192.168.0.1, the PTR domain is 1.0.168.192.in-addr.arpa
      record = PTR.new("1.0.168.192.in-addr.arpa")
      assert record.data.value == "1.0.168.192.in-addr.arpa."
    end

    test "creates localhost reverse lookup" do
      record = PTR.new("1.0.0.127.in-addr.arpa")
      assert record.data.value == "1.0.0.127.in-addr.arpa."
    end

    test "creates class C network reverse" do
      record = PTR.new("0.168.192.in-addr.arpa")
      assert record.data.value == "0.168.192.in-addr.arpa."
    end
  end

  describe "IPv6 reverse DNS (ip6.arpa)" do
    test "creates IPv6 reverse lookup domain" do
      # Partial representation
      record = PTR.new("8.b.d.0.1.0.0.2.ip6.arpa")
      assert record.data.value == "8.b.d.0.1.0.0.2.ip6.arpa."
    end
  end

  describe "mDNS service discovery" do
    test "HTTP service type" do
      record = PTR.new("_http._tcp.local")
      assert record.data.value == "_http._tcp.local."
    end

    test "HTTPS service type" do
      record = PTR.new("_https._tcp.local")
      assert record.data.value == "_https._tcp.local."
    end

    test "printer service type" do
      record = PTR.new("_ipp._tcp.local")
      assert record.data.value == "_ipp._tcp.local."
    end

    test "AirPlay service type" do
      record = PTR.new("_airplay._tcp.local")
      assert record.data.value == "_airplay._tcp.local."
    end

    test "service instance name" do
      record = PTR.new("My Printer._ipp._tcp.local")
      assert record.data.value == "My Printer._ipp._tcp.local."
    end

    test "services meta-query" do
      record = PTR.new("_services._dns-sd._udp.local")
      assert record.data.value == "_services._dns-sd._udp.local."
    end
  end

  describe "edge cases" do
    test "struct is inspectable" do
      record = PTR.new("host.example.com")
      inspect_output = inspect(record)
      assert is_binary(inspect_output)
    end

    test "handles spaces in mDNS service names" do
      record = PTR.new("My Web Server._http._tcp.local")
      assert record.data.value == "My Web Server._http._tcp.local."
    end

    test "handles hyphenated hostnames" do
      record = PTR.new("web-server-01.example.com")
      assert record.data.value == "web-server-01.example.com."
    end

    test "handles underscore prefixed service types" do
      record = PTR.new("_custom-service._tcp.local")
      assert record.data.value == "_custom-service._tcp.local."
    end
  end
end
