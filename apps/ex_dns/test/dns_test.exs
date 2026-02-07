defmodule DNSTest do
  @moduledoc """
  Comprehensive unit tests for DNS module.

  Tests cover:
  - Module structure and exports
  - to_iodata/1 convenience function
  - Protocol integration with all DNS types
  - Domain encoding edge cases
  - Record data serialization
  - EDNS0 option serialization
  - Documentation examples
  - Error handling and validation
  """
  use ExUnit.Case, async: true
  import Bitwise

  doctest DNS

  # ============================================================================
  # Module Structure Tests
  # ============================================================================

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(DNS)
    end

    test "exports to_iodata/1" do
      Code.ensure_loaded!(DNS)
      assert Kernel.function_exported?(DNS, :to_iodata, 1)
    end

    test "has module documentation" do
      {:docs_v1, _, _, _, module_doc, _, _} = Code.fetch_docs(DNS)
      assert module_doc != :hidden
      assert module_doc != :none
    end

    test "to_iodata/1 has function documentation" do
      {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(DNS)

      to_iodata_doc =
        Enum.find(docs, fn
          {{:function, :to_iodata, 1}, _, _, _, _} -> true
          _ -> false
        end)

      assert to_iodata_doc != nil
    end
  end

  # ============================================================================
  # to_iodata/1 Basic Tests
  # ============================================================================

  describe "to_iodata/1" do
    test "delegates to DNS.Parameter.to_iodata/1" do
      # String implements DNS.Parameter
      result = DNS.to_iodata("test.com")
      expected = DNS.Parameter.to_iodata("test.com")
      assert result == expected
    end

    test "converts domain string to wire format" do
      result = DNS.to_iodata("example.com")
      # Domain: 7 + "example" + 3 + "com" + 0
      assert result == <<7, "example", 3, "com", 0>>
    end

    test "converts single-label domain" do
      result = DNS.to_iodata("localhost")
      # Domain: 9 + "localhost" + 0
      assert result == <<9, "localhost", 0>>
    end

    test "converts root domain" do
      result = DNS.to_iodata(".")
      # Root domain is just null byte
      assert result == <<0>>
    end

    test "returns iodata type" do
      result = DNS.to_iodata("example.com")
      assert is_binary(result) or is_list(result)
    end
  end

  # ============================================================================
  # Domain Encoding Tests
  # ============================================================================

  describe "to_iodata/1 with domain strings" do
    test "encodes two-label domain" do
      result = DNS.to_iodata("example.com")
      assert result == <<7, "example", 3, "com", 0>>
    end

    test "encodes three-label domain" do
      result = DNS.to_iodata("www.example.com")
      assert result == <<3, "www", 7, "example", 3, "com", 0>>
    end

    test "encodes four-label domain" do
      result = DNS.to_iodata("mail.sub.example.com")
      assert result == <<4, "mail", 3, "sub", 7, "example", 3, "com", 0>>
    end

    test "encodes single character labels" do
      result = DNS.to_iodata("a.b.c")
      assert result == <<1, "a", 1, "b", 1, "c", 0>>
    end

    test "encodes numeric labels" do
      result = DNS.to_iodata("123.example.com")
      assert result == <<3, "123", 7, "example", 3, "com", 0>>
    end

    test "encodes hyphenated labels" do
      result = DNS.to_iodata("test-server.example.com")
      assert result == <<11, "test-server", 7, "example", 3, "com", 0>>
    end

    test "encodes maximum label length (63 characters)" do
      long_label = String.duplicate("a", 63)
      result = DNS.to_iodata("#{long_label}.com")
      assert result == <<63, long_label::binary, 3, "com", 0>>
    end

    test "encodes TLD-only domain" do
      result = DNS.to_iodata("com")
      assert result == <<3, "com", 0>>
    end

    test "encodes reverse DNS domain" do
      result = DNS.to_iodata("1.168.192.in-addr.arpa")
      assert result == <<1, "1", 3, "168", 3, "192", 7, "in-addr", 4, "arpa", 0>>
    end

    test "encodes IPv6 reverse DNS domain" do
      result = DNS.to_iodata("8.b.d.0.1.0.0.2.ip6.arpa")
      assert result =~ "ip6"
      assert String.ends_with?(result, <<4, "arpa", 0>>)
    end
  end

  # ============================================================================
  # Record Data Tests
  # ============================================================================

  describe "to_iodata/1 with A record data" do
    test "converts A record data" do
      a_record = DNS.Message.Record.Data.A.new({192, 168, 1, 1})
      result = DNS.to_iodata(a_record)
      # A record: rdlength(2) + IP(4) = <<0, 4, 192, 168, 1, 1>>
      assert result == <<0, 4, 192, 168, 1, 1>>
    end

    test "converts A record with loopback address" do
      a_record = DNS.Message.Record.Data.A.new({127, 0, 0, 1})
      result = DNS.to_iodata(a_record)
      assert result == <<0, 4, 127, 0, 0, 1>>
    end

    test "converts A record with all zeros" do
      a_record = DNS.Message.Record.Data.A.new({0, 0, 0, 0})
      result = DNS.to_iodata(a_record)
      assert result == <<0, 4, 0, 0, 0, 0>>
    end

    test "converts A record with all 255s" do
      a_record = DNS.Message.Record.Data.A.new({255, 255, 255, 255})
      result = DNS.to_iodata(a_record)
      assert result == <<0, 4, 255, 255, 255, 255>>
    end

    test "converts A record private network addresses" do
      addresses = [
        {10, 0, 0, 1},
        {172, 16, 0, 1},
        {192, 168, 0, 1}
      ]

      for addr <- addresses do
        {a, b, c, d} = addr
        a_record = DNS.Message.Record.Data.A.new(addr)
        result = DNS.to_iodata(a_record)
        assert result == <<0, 4, a, b, c, d>>
      end
    end
  end

  describe "to_iodata/1 with AAAA record data" do
    test "converts AAAA record data" do
      aaaa_record = DNS.Message.Record.Data.AAAA.new({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      result = DNS.to_iodata(aaaa_record)
      # AAAA record: rdlength(2) + IPv6(16)
      assert byte_size(result) == 18
    end

    test "converts AAAA record with loopback address" do
      aaaa_record = DNS.Message.Record.Data.AAAA.new({0, 0, 0, 0, 0, 0, 0, 1})
      result = DNS.to_iodata(aaaa_record)
      assert byte_size(result) == 18
      # Check rdlength is 16
      <<rdlength::16, _rest::binary>> = result
      assert rdlength == 16
    end

    test "converts AAAA record with all zeros" do
      aaaa_record = DNS.Message.Record.Data.AAAA.new({0, 0, 0, 0, 0, 0, 0, 0})
      result = DNS.to_iodata(aaaa_record)
      assert result == <<0, 16, 0::128>>
    end

    test "converts AAAA record with all 0xFFFF" do
      aaaa_record =
        DNS.Message.Record.Data.AAAA.new(
          {0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}
        )

      result = DNS.to_iodata(aaaa_record)
      <<rdlength::16, ipv6::128>> = result
      assert rdlength == 16
      assert ipv6 == 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    end

    test "converts AAAA record with link-local address" do
      aaaa_record = DNS.Message.Record.Data.AAAA.new({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      result = DNS.to_iodata(aaaa_record)
      assert byte_size(result) == 18
    end
  end

  describe "to_iodata/1 with other record types" do
    test "converts NS record" do
      ns_record = DNS.Message.Record.Data.NS.new("ns1.example.com")
      result = DNS.to_iodata(ns_record)
      assert is_binary(result)
    end

    test "converts CNAME record" do
      cname_record = DNS.Message.Record.Data.CNAME.new("alias.example.com")
      result = DNS.to_iodata(cname_record)
      assert is_binary(result)
    end

    test "converts MX record" do
      mx_record = DNS.Message.Record.Data.MX.new({10, "mail.example.com"})
      result = DNS.to_iodata(mx_record)
      assert is_binary(result)
      # MX: rdlength(2) + preference(2) + exchange(domain)
    end

    test "converts TXT record with single string" do
      txt_record = DNS.Message.Record.Data.TXT.new(["v=spf1 include:example.com ~all"])
      result = DNS.to_iodata(txt_record)
      assert is_binary(result)
    end

    test "converts TXT record with multiple strings" do
      txt_record = DNS.Message.Record.Data.TXT.new(["first", "second", "third"])
      result = DNS.to_iodata(txt_record)
      assert is_binary(result)
    end

    test "converts PTR record" do
      ptr_record = DNS.Message.Record.Data.PTR.new("host.example.com")
      result = DNS.to_iodata(ptr_record)
      assert is_binary(result)
    end
  end

  # ============================================================================
  # Question and Record Tests
  # ============================================================================

  describe "to_iodata/1 with Question" do
    test "converts Question to wire format" do
      question = DNS.Message.Question.new("example.com", 1, 1)
      result = DNS.to_iodata(question)
      assert is_binary(result)
      # Domain(13) + type(2) + class(2) = 17 bytes
      assert byte_size(result) == 17
    end

    test "converts Question for A record" do
      question = DNS.Message.Question.new("test.com", 1, 1)
      result = DNS.to_iodata(question)
      # test.com = 4 + test + 3 + com + 0 = 10 bytes + type(2) + class(2) = 14 bytes
      assert byte_size(result) == 14
    end

    test "converts Question for AAAA record" do
      question = DNS.Message.Question.new("ipv6.example.com", 28, 1)
      result = DNS.to_iodata(question)
      assert is_binary(result)
    end

    test "converts Question for MX record" do
      question = DNS.Message.Question.new("example.com", 15, 1)
      result = DNS.to_iodata(question)
      assert is_binary(result)
    end

    test "converts Question for ANY type" do
      question = DNS.Message.Question.new("example.com", 255, 1)
      result = DNS.to_iodata(question)
      assert is_binary(result)
    end
  end

  describe "to_iodata/1 with Record" do
    test "converts Record to wire format" do
      record = DNS.Message.Record.new("example.com", 1, 1, 3600, {1, 2, 3, 4})
      result = DNS.to_iodata(record)
      assert is_binary(result)
    end

    test "converts Record with zero TTL" do
      record = DNS.Message.Record.new("example.com", 1, 1, 0, {1, 2, 3, 4})
      result = DNS.to_iodata(record)
      assert is_binary(result)
    end

    test "converts Record with maximum TTL" do
      record = DNS.Message.Record.new("example.com", 1, 1, 2_147_483_647, {1, 2, 3, 4})
      result = DNS.to_iodata(record)
      assert is_binary(result)
    end

    test "converts Record with CH class" do
      record = DNS.Message.Record.new("version.bind", 16, 3, 0, ["9.10.3"])
      result = DNS.to_iodata(record)
      assert is_binary(result)
    end
  end

  # ============================================================================
  # EDNS0 Tests
  # ============================================================================

  describe "to_iodata/1 with EDNS0" do
    test "converts EDNS0 to wire format" do
      edns0 = DNS.Message.EDNS0.new({4096, 0, 0, 1, 0, []})
      result = DNS.to_iodata(edns0)
      assert is_binary(result)
      # OPT RR: name(1) + type(2) + class(2) + ttl(4) + rdlength(2) = 11 bytes
      assert byte_size(result) == 11
    end

    test "converts EDNS0 with different buffer sizes" do
      for size <- [512, 1024, 1232, 4096, 65535] do
        edns0 = DNS.Message.EDNS0.new({size, 0, 0, 1, 0, []})
        result = DNS.to_iodata(edns0)
        assert is_binary(result)
      end
    end

    test "converts EDNS0 with DO bit set" do
      edns0 = DNS.Message.EDNS0.new({4096, 0, 0, 1, 0x8000, []})
      result = DNS.to_iodata(edns0)
      assert is_binary(result)
    end
  end

  describe "to_iodata/1 with EDNS0 options" do
    test "converts NSID option" do
      nsid = DNS.Message.EDNS0.Option.NSID.new("test-nsid")
      result = DNS.to_iodata(nsid)
      assert is_binary(result)
    end

    test "converts NSID option with empty value" do
      nsid = DNS.Message.EDNS0.Option.NSID.new("")
      result = DNS.to_iodata(nsid)
      assert is_binary(result)
    end

    test "converts DAU option" do
      dau = DNS.Message.EDNS0.Option.DAU.new([8, 10, 13])
      result = DNS.to_iodata(dau)
      assert is_binary(result)
    end

    test "converts DAU option with single algorithm" do
      dau = DNS.Message.EDNS0.Option.DAU.new([8])
      result = DNS.to_iodata(dau)
      assert is_binary(result)
    end

    test "converts DAU option with empty list" do
      dau = DNS.Message.EDNS0.Option.DAU.new([])
      result = DNS.to_iodata(dau)
      assert is_binary(result)
    end

    test "converts DHU option" do
      dhu = DNS.Message.EDNS0.Option.DHU.new([1, 2])
      result = DNS.to_iodata(dhu)
      assert is_binary(result)
    end

    test "converts N3U option" do
      n3u = DNS.Message.EDNS0.Option.N3U.new([1])
      result = DNS.to_iodata(n3u)
      assert is_binary(result)
    end

    test "converts Padding option" do
      padding = DNS.Message.EDNS0.Option.Padding.new(16)
      result = DNS.to_iodata(padding)
      assert is_binary(result)
    end

    test "converts Cookie option with client cookie only" do
      client_cookie = :crypto.strong_rand_bytes(8)
      cookie = DNS.Message.EDNS0.Option.Cookie.new({client_cookie, nil})
      result = DNS.to_iodata(cookie)
      assert is_binary(result)
    end

    test "converts TcpKeepalive option" do
      keepalive = DNS.Message.EDNS0.Option.TcpKeepalive.new(120)
      result = DNS.to_iodata(keepalive)
      assert is_binary(result)
    end

    test "converts KeyTag option" do
      keytag = DNS.Message.EDNS0.Option.KeyTag.new([20326, 19036])
      result = DNS.to_iodata(keytag)
      assert is_binary(result)
    end

    test "converts ExtendedDNSError option" do
      ede = DNS.Message.EDNS0.Option.ExtendedDNSError.new({1, "DNSSEC validation failure"})
      result = DNS.to_iodata(ede)
      assert is_binary(result)
    end

    test "converts Expire option" do
      expire = DNS.Message.EDNS0.Option.Expire.new(86400)
      result = DNS.to_iodata(expire)
      assert is_binary(result)
    end
  end

  # ============================================================================
  # Header Tests
  # ============================================================================

  describe "to_iodata/1 with Header" do
    test "converts Header to wire format" do
      header = DNS.Message.Header.new()
      result = DNS.to_iodata(header)
      assert is_binary(result)
      # Header is always 12 bytes
      assert byte_size(result) == 12
    end

    test "converts Header with custom ID" do
      header = %DNS.Message.Header{
        id: 0x1234,
        qr: 0,
        opcode: DNS.Message.OpCode.new(0),
        aa: 0,
        tc: 0,
        rd: 1,
        ra: 0,
        z: 0,
        ad: 0,
        cd: 0,
        rcode: DNS.Message.RCode.new(0),
        qdcount: 1,
        ancount: 0,
        nscount: 0,
        arcount: 0
      }

      result = DNS.to_iodata(header)
      <<id::16, _rest::binary>> = result
      assert id == 0x1234
    end

    test "converts Header with QR flag set (response)" do
      header = %DNS.Message.Header{
        id: 0,
        qr: 1,
        opcode: DNS.Message.OpCode.new(0),
        aa: 0,
        tc: 0,
        rd: 1,
        ra: 1,
        z: 0,
        ad: 0,
        cd: 0,
        rcode: DNS.Message.RCode.new(0),
        qdcount: 1,
        ancount: 1,
        nscount: 0,
        arcount: 0
      }

      result = DNS.to_iodata(header)
      <<_id::16, flags::16, _rest::binary>> = result
      # QR is bit 15
      assert (flags &&& 0x8000) == 0x8000
    end

    test "converts Header with different opcodes" do
      for opcode <- [0, 1, 2, 4, 5] do
        header = %DNS.Message.Header{
          id: 0,
          qr: 0,
          opcode: DNS.Message.OpCode.new(opcode),
          aa: 0,
          tc: 0,
          rd: 1,
          ra: 0,
          z: 0,
          ad: 0,
          cd: 0,
          rcode: DNS.Message.RCode.new(0),
          qdcount: 1,
          ancount: 0,
          nscount: 0,
          arcount: 0
        }

        result = DNS.to_iodata(header)
        assert byte_size(result) == 12
      end
    end

    test "converts Header with RCODE" do
      header = %DNS.Message.Header{
        id: 0,
        qr: 1,
        opcode: DNS.Message.OpCode.new(0),
        aa: 0,
        tc: 0,
        rd: 1,
        ra: 1,
        z: 0,
        ad: 0,
        cd: 0,
        rcode: DNS.Message.RCode.new(3),
        qdcount: 1,
        ancount: 0,
        nscount: 0,
        arcount: 0
      }

      result = DNS.to_iodata(header)
      <<_id::16, flags::16, _rest::binary>> = result
      # RCODE is bits 0-3
      assert (flags &&& 0x000F) == 3
    end
  end

  # ============================================================================
  # Type and Class Tests
  # ============================================================================

  describe "to_iodata/1 with ResourceRecordType" do
    test "converts ResourceRecordType" do
      rtype = DNS.ResourceRecordType.new(1)
      result = DNS.to_iodata(rtype)
      assert result == <<1::16>>
    end

    test "converts various record types" do
      types = [
        {1, "A"},
        {2, "NS"},
        {5, "CNAME"},
        {6, "SOA"},
        {12, "PTR"},
        {15, "MX"},
        {16, "TXT"},
        {28, "AAAA"},
        {33, "SRV"},
        {41, "OPT"},
        {43, "DS"},
        {46, "RRSIG"},
        {47, "NSEC"},
        {48, "DNSKEY"},
        {52, "TLSA"},
        {64, "SVCB"},
        {65, "HTTPS"},
        {255, "ANY"}
      ]

      for {type_num, _name} <- types do
        rtype = DNS.ResourceRecordType.new(type_num)
        result = DNS.to_iodata(rtype)
        assert result == <<type_num::16>>
      end
    end

    test "converts high record type numbers" do
      rtype = DNS.ResourceRecordType.new(65535)
      result = DNS.to_iodata(rtype)
      assert result == <<65535::16>>
    end
  end

  describe "to_iodata/1 with Class" do
    test "converts Class" do
      class = DNS.Class.new(1)
      result = DNS.to_iodata(class)
      assert result == <<1::16>>
    end

    test "converts IN class" do
      class = DNS.Class.new(1)
      result = DNS.to_iodata(class)
      assert result == <<0, 1>>
    end

    test "converts CS class" do
      class = DNS.Class.new(2)
      result = DNS.to_iodata(class)
      assert result == <<0, 2>>
    end

    test "converts CH class" do
      class = DNS.Class.new(3)
      result = DNS.to_iodata(class)
      assert result == <<0, 3>>
    end

    test "converts HS class" do
      class = DNS.Class.new(4)
      result = DNS.to_iodata(class)
      assert result == <<0, 4>>
    end

    test "converts ANY class" do
      class = DNS.Class.new(255)
      result = DNS.to_iodata(class)
      assert result == <<0, 255>>
    end
  end

  # ============================================================================
  # Domain Struct Tests
  # ============================================================================

  describe "to_iodata/1 with Domain struct" do
    test "converts Domain struct" do
      domain = DNS.Message.Domain.new("test.com")
      result = DNS.to_iodata(domain)
      assert result == <<4, "test", 3, "com", 0>>
    end

    test "converts Domain struct for root" do
      domain = DNS.Message.Domain.new(".")
      result = DNS.to_iodata(domain)
      assert result == <<0>>
    end

    test "converts Domain struct for long domain" do
      domain = DNS.Message.Domain.new("very.long.subdomain.example.com")
      result = DNS.to_iodata(domain)
      assert is_binary(result)
      assert String.ends_with?(result, <<0>>)
    end
  end

  # ============================================================================
  # Protocol Integration Tests
  # ============================================================================

  describe "protocol integration" do
    test "DNS.Parameter protocol is defined" do
      assert Code.ensure_loaded?(DNS.Parameter)
    end

    test "String implements DNS.Parameter" do
      # Strings implement DNS.Parameter for domain encoding
      assert DNS.Parameter.impl_for("example.com") != nil
    end

    test "various types implement DNS.Parameter" do
      types = [
        DNS.Message.Domain.new("example.com"),
        DNS.Message.Question.new("example.com", 1, 1),
        DNS.Message.Record.new("example.com", 1, 1, 3600, {1, 2, 3, 4}),
        DNS.ResourceRecordType.new(1),
        DNS.Class.new(1)
      ]

      for type <- types do
        assert DNS.Parameter.impl_for(type) != nil,
               "#{inspect(type)} should implement DNS.Parameter"
      end
    end

    test "DNS.Parameter.to_iodata/1 returns binary or iolist" do
      implementations = [
        "example.com",
        DNS.Message.Domain.new("example.com"),
        DNS.ResourceRecordType.new(1),
        DNS.Class.new(1)
      ]

      for impl <- implementations do
        result = DNS.Parameter.to_iodata(impl)
        assert is_binary(result) or is_list(result)
      end
    end
  end

  # ============================================================================
  # Submodule Tests
  # ============================================================================

  describe "submodules" do
    test "DNS.Message is defined" do
      assert Code.ensure_loaded?(DNS.Message)
    end

    test "DNS.Zone is defined" do
      assert Code.ensure_loaded?(DNS.Zone)
    end

    test "DNS.Parameter is defined" do
      assert Code.ensure_loaded?(DNS.Parameter)
    end

    test "DNS.Class is defined" do
      assert Code.ensure_loaded?(DNS.Class)
    end

    test "DNS.ResourceRecordType is defined" do
      assert Code.ensure_loaded?(DNS.ResourceRecordType)
    end

    test "DNS.Message.Header is defined" do
      assert Code.ensure_loaded?(DNS.Message.Header)
    end

    test "DNS.Message.Question is defined" do
      assert Code.ensure_loaded?(DNS.Message.Question)
    end

    test "DNS.Message.Record is defined" do
      assert Code.ensure_loaded?(DNS.Message.Record)
    end

    test "DNS.Message.Domain is defined" do
      assert Code.ensure_loaded?(DNS.Message.Domain)
    end

    test "DNS.Message.EDNS0 is defined" do
      assert Code.ensure_loaded?(DNS.Message.EDNS0)
    end

    test "DNS.Error is defined" do
      assert Code.ensure_loaded?(DNS.Error)
    end

    test "DNS.Constants is defined" do
      assert Code.ensure_loaded?(DNS.Constants)
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    test "handles consecutive calls with same input" do
      result1 = DNS.to_iodata("example.com")
      result2 = DNS.to_iodata("example.com")
      assert result1 == result2
    end

    test "handles different inputs consistently" do
      result1 = DNS.to_iodata("a.com")
      result2 = DNS.to_iodata("b.com")
      assert result1 != result2
    end

    test "output is deterministic" do
      results =
        for _i <- 1..10 do
          DNS.to_iodata("test.example.com")
        end

      assert Enum.uniq(results) == [hd(results)]
    end

    test "handles domain with trailing dot" do
      result1 = DNS.to_iodata("example.com")
      result2 = DNS.to_iodata("example.com.")
      # Both should produce the same wire format
      assert result1 == result2
    end
  end

  # ============================================================================
  # Integration Tests
  # ============================================================================

  describe "integration with DNS message construction" do
    test "can construct and serialize complete DNS query" do
      # Build a complete DNS query message
      header = DNS.Message.Header.new()
      question = DNS.Message.Question.new("example.com", 1, 1)

      header_binary = DNS.to_iodata(header)
      question_binary = DNS.to_iodata(question)

      assert is_binary(header_binary)
      assert is_binary(question_binary)
      assert byte_size(header_binary) == 12
    end

    test "can construct and serialize DNS response with A record" do
      # Record.new expects raw data tuple, which it passes to RData.new
      record = DNS.Message.Record.new("example.com", 1, 1, 300, {93, 184, 216, 34})

      result = DNS.to_iodata(record)
      assert is_binary(result)
    end

    test "can construct and serialize DNS response with multiple records" do
      records = [
        DNS.Message.Record.new("example.com", 1, 1, 300, {93, 184, 216, 34}),
        DNS.Message.Record.new("example.com", 1, 1, 300, {93, 184, 216, 35})
      ]

      results = Enum.map(records, &DNS.to_iodata/1)
      assert Enum.all?(results, &is_binary/1)
    end
  end
end
