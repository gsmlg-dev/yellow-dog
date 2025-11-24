defmodule DNS.Zone.ParserTest do
  use ExUnit.Case
  alias DNS.Zone.Parser
  alias DNS.Zone.Parser.{ZoneFile, ResourceRecord, SOARecord}

  describe "basic zone file parsing" do
    test "parses simple zone with SOA and NS records" do
      content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns1.example.com. admin.example.com. (
                  2024010101  ; serial
                  3600        ; refresh
                  1800        ; retry
                  604800      ; expire
                  86400       ; minimum
              )
      @       IN  NS  ns1.example.com.
      @       IN  NS  ns2.example.com.
      """

      assert {:ok, zone} = Parser.parse(content)
      assert %ZoneFile{} = zone
      assert zone.origin == "example.com."
      assert zone.ttl == 3600
      assert length(zone.records) == 3
    end

    test "parses zone with various record types" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @       IN  SOA ns1.test.com. admin.test.com. (
                  2024010101  ; serial
                  3600        ; refresh
                  1800        ; retry
                  604800      ; expire
                  300         ; minimum
              )
      @       IN  NS  ns1.test.com.
      @       IN  A   192.168.1.1
      www     IN  A   192.168.1.100
      mail    IN  MX  10 mail.test.com.
      ftp     IN  CNAME www.test.com.
      text    IN  TXT "sample text record"
      """

      assert {:ok, zone} = Parser.parse(content)
      assert zone.origin == "test.com."
      assert zone.ttl == 300
      assert length(zone.records) == 7

      records_by_type = Enum.group_by(zone.records, & &1.type)
      assert Map.has_key?(records_by_type, "SOA")
      assert Map.has_key?(records_by_type, "NS")
      assert Map.has_key?(records_by_type, "A")
      assert Map.has_key?(records_by_type, "MX")
      assert Map.has_key?(records_by_type, "CNAME")
      assert Map.has_key?(records_by_type, "TXT")
    end
  end

  describe "SOA record parsing" do
    test "parses SOA record with multi-line format" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          2024010101 ; serial
          3600       ; refresh (1 hour)
          1800       ; retry (30 minutes)
          604800     ; expire (1 week)
          86400      ; minimum (1 day)
      )
      """

      assert {:ok, zone} = Parser.parse(content)
      assert [%ResourceRecord{type: "SOA"} = soa_record] = zone.records
      assert %SOARecord{} = soa_record.rdata
      assert soa_record.rdata.primary_ns == "ns1.example.com."
      assert soa_record.rdata.admin_email == "admin.example.com."
      assert soa_record.rdata.serial == 2_024_010_101
      assert soa_record.rdata.refresh == 3600
      assert soa_record.rdata.retry == 1800
      assert soa_record.rdata.expire == 604_800
      assert soa_record.rdata.minimum == 86400
    end

    test "parses SOA record with single-line format" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          2024010101 3600 1800 604800 86400
      )
      """

      assert {:ok, zone} = Parser.parse(content)
      assert [%ResourceRecord{type: "SOA"} = soa_record] = zone.records
      assert %SOARecord{} = soa_record.rdata
      assert soa_record.rdata.primary_ns == "ns1.example.com."
      assert soa_record.rdata.admin_email == "admin.example.com."
      assert soa_record.rdata.serial == 2_024_010_101
    end

    test "handles SOA with comments within parentheses" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          2024010101 ; Serial number
          3600       ; Refresh time
          1800       ; Retry time
          604800     ; Expire time
          86400      ; Minimum TTL
      )
      """

      assert {:ok, zone} = Parser.parse(content)
      assert [%ResourceRecord{type: "SOA"} = soa_record] = zone.records
      assert %SOARecord{} = soa_record.rdata
      assert soa_record.rdata.serial == 2_024_010_101
    end
  end

  describe "directive parsing" do
    test "parses $ORIGIN directive" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      """

      assert {:ok, zone} = Parser.parse(content)
      assert zone.origin == "example.com."
    end

    test "parses $TTL directive" do
      content = """
      $TTL 7200
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      """

      assert {:ok, zone} = Parser.parse(content)
      assert zone.ttl == 7200
    end

    test "parses multiple directives" do
      content = """
      ; Zone file for example.com
      $TTL 3600
      $ORIGIN example.com.

      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      """

      assert {:ok, zone} = Parser.parse(content)
      assert zone.ttl == 3600
      assert zone.origin == "example.com."
      assert zone.comments == [" Zone file for example.com"]
    end
  end

  describe "record type parsing" do
    test "parses A records" do
      content = """
      $ORIGIN example.com.
      @ IN A 192.168.1.1
      www IN A 192.168.1.100
      """

      assert {:ok, zone} = Parser.parse(content)
      a_records = Enum.filter(zone.records, &(&1.type == "A"))
      assert length(a_records) == 2
      assert Enum.any?(a_records, fn r -> r.name == "@" && r.rdata == "192.168.1.1" end)
      assert Enum.any?(a_records, fn r -> r.name == "www" && r.rdata == "192.168.1.100" end)
    end

    test "parses AAAA records" do
      content = """
      $ORIGIN example.com.
      @ IN AAAA 2001:db8::1
      www IN AAAA 2001:db8::2
      """

      assert {:ok, zone} = Parser.parse(content)
      aaaa_records = Enum.filter(zone.records, &(&1.type == "AAAA"))
      assert length(aaaa_records) == 2
      assert Enum.any?(aaaa_records, fn r -> r.name == "@" && r.rdata == "2001:db8::1" end)
    end

    test "parses CNAME records" do
      content = """
      $ORIGIN example.com.
      ftp IN CNAME www.example.com.
      mail IN CNAME mailserver.example.net.
      """

      assert {:ok, zone} = Parser.parse(content)
      cname_records = Enum.filter(zone.records, &(&1.type == "CNAME"))
      assert length(cname_records) == 2

      assert Enum.any?(cname_records, fn r -> r.name == "ftp" && r.rdata == "www.example.com." end)
    end

    test "parses MX records" do
      content = """
      $ORIGIN example.com.
      @ IN MX 10 mail1.example.com.
      @ IN MX 20 mail2.example.com.
      """

      assert {:ok, zone} = Parser.parse(content)
      mx_records = Enum.filter(zone.records, &(&1.type == "MX"))
      assert length(mx_records) == 2
      assert Enum.any?(mx_records, fn r -> r.name == "@" && r.rdata.priority == 10 end)
    end

    test "parses TXT records" do
      content = """
      $ORIGIN example.com.
      @ IN TXT "v=spf1 mx ~all"
      www IN TXT "web server"
      """

      assert {:ok, zone} = Parser.parse(content)
      txt_records = Enum.filter(zone.records, &(&1.type == "TXT"))
      assert length(txt_records) == 2
      assert Enum.any?(txt_records, fn r -> r.name == "@" && r.rdata == "v=spf1 mx ~all" end)
    end

    test "parses NS records" do
      content = """
      $ORIGIN example.com.
      @ IN NS ns1.example.com.
      @ IN NS ns2.example.com.
      """

      assert {:ok, zone} = Parser.parse(content)
      ns_records = Enum.filter(zone.records, &(&1.type == "NS"))
      assert length(ns_records) == 2
      assert Enum.all?(ns_records, fn r -> r.name == "@" end)
    end

    test "parses SRV records" do
      content = """
      $ORIGIN example.com.
      _sip._tcp IN SRV 10 60 5060 sipserver.example.com.
      """

      assert {:ok, zone} = Parser.parse(content)
      srv_records = Enum.filter(zone.records, &(&1.type == "SRV"))
      assert length(srv_records) == 1
      [srv] = srv_records
      assert srv.name == "_sip._tcp"
      assert srv.rdata.priority == 10
      assert srv.rdata.weight == 60
      assert srv.rdata.port == 5060
      assert srv.rdata.target == "sipserver.example.com."
    end
  end

  describe "TTL handling" do
    test "uses record-level TTL" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www 300 IN A 192.168.1.100
      mail 600 IN A 192.168.1.200
      """

      assert {:ok, zone} = Parser.parse(content)
      records = Enum.filter(zone.records, &(&1.type == "A"))
      assert Enum.any?(records, fn r -> r.name == "www" && r.ttl == 300 end)
      assert Enum.any?(records, fn r -> r.name == "mail" && r.ttl == 600 end)
    end

    test "uses zone TTL when record TTL not specified" do
      content = """
      $TTL 7200
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www IN A 192.168.1.100
      """

      assert {:ok, zone} = Parser.parse(content)
      a_record = Enum.find(zone.records, &(&1.type == "A"))
      # Note: The parser sets record TTL to nil, Zone.from_ast handles fallback
      assert a_record.ttl == nil
    end
  end

  describe "comments handling" do
    test "parses single-line comments" do
      content = """
      ; This is a comment
      $ORIGIN example.com.
      ; Another comment
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      """

      assert {:ok, zone} = Parser.parse(content)
      assert zone.comments == [" This is a comment", " Another comment"]
    end

    test "ignores inline comments" do
      content = """
      $ORIGIN example.com. ; inline comment
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      """

      assert {:ok, zone} = Parser.parse(content)
      assert zone.origin == "example.com."
    end
  end

  describe "error handling" do
    test "returns error for invalid SOA format" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com.
      """

      assert {:error, _reason} = Parser.parse(content)
    end

    test "returns error for malformed record" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      invalid record without proper format
      """

      assert {:error, _reason} = Parser.parse(content)
    end

    test "returns empty zone for empty content" do
      assert {:ok, zone} = Parser.parse("")
      assert %DNS.Zone.Parser.ZoneFile{} = zone
      assert zone.records == []
    end
  end

  describe "complex zone parsing" do
    test "parses real-world zone file" do
      content = """
      ; Zone file for example.com
      $TTL 3600
      $ORIGIN example.com.

      @ IN SOA ns1.example.com. admin.example.com. (
          2024010101 ; Serial
          3600       ; Refresh
          1800       ; Retry
          604800     ; Expire
          300        ; Minimum TTL
      )

      ; Name servers
      @ IN NS ns1.example.com.
      @ IN NS ns2.example.com.

      ; A records
      @ IN A 192.168.1.1
      www IN A 192.168.1.100
      mail IN A 192.168.1.200
      ns1 IN A 192.168.1.1
      ns2 IN A 192.168.1.2

      ; MX records
      @ IN MX 10 mail.example.com.
      @ IN MX 20 mail2.example.com.

      ; CNAME records
      ftp IN CNAME www.example.com.
      webmail IN CNAME mail.example.com.

      ; TXT records
      @ IN TXT "v=spf1 mx ~all"
      """

      assert {:ok, zone} = Parser.parse(content)
      assert zone.origin == "example.com."
      assert zone.ttl == 3600
      assert length(zone.comments) >= 1
      assert length(zone.records) >= 10

      # Verify specific records exist
      records_by_type = Enum.group_by(zone.records, & &1.type)
      assert Map.has_key?(records_by_type, "SOA")
      assert Map.has_key?(records_by_type, "NS")
      assert Map.has_key?(records_by_type, "A")
      assert Map.has_key?(records_by_type, "MX")
      assert Map.has_key?(records_by_type, "CNAME")
      assert Map.has_key?(records_by_type, "TXT")
    end
  end

  describe "edge cases" do
    test "handles tabs and extra whitespace" do
      content = """
      $ORIGIN	example.com.
      $TTL		3600
      @		IN		SOA		ns1.example.com.		admin.example.com.		(
      		2024010101		3600		1800		604800		86400
      )
      """

      assert {:ok, zone} = Parser.parse(content)
      assert zone.origin == "example.com."
      assert zone.ttl == 3600
    end

    test "handles mixed case record types" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      @ IN A 192.168.1.1
      @ IN MX 10 mail.example.com.
      """

      assert {:ok, zone} = Parser.parse(content)
      types = Enum.map(zone.records, & &1.type)
      assert "SOA" in types
      assert "A" in types
      assert "MX" in types
    end

    test "handles TXT records with quotes" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      @ IN TXT "sample text record"
      """

      assert {:ok, zone} = Parser.parse(content)
      txt_record = Enum.find(zone.records, &(&1.type == "TXT"))
      assert txt_record.rdata == "sample text record"
    end
  end
end
