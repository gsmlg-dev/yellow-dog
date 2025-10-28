defmodule YellowDog.Dns.Zone.ParserTest do
  use ExUnit.Case, async: true

  alias YellowDog.Dns.Zone
  alias YellowDog.Dns.Zone.Parser

  @fixtures_dir Path.join([__DIR__, "..", "..", "..", "fixtures", "zones"])

  describe "parse_file/2" do
    test "parses a simple zone file successfully" do
      file_path = Path.join(@fixtures_dir, "simple.zone")

      assert {:ok, zone} = Parser.parse_file(file_path, zone_name: "simple.test")

      assert zone.name == "simple.test"
      assert zone.type == :master
      assert zone.ttl == 300
      assert zone.soa != nil
      assert zone.soa.mname == "ns1.simple.test."
      assert zone.soa.rname == "admin.simple.test."
      assert zone.soa.serial == 2024010101
    end

    test "parses a complex zone file with multiple record types" do
      file_path = Path.join(@fixtures_dir, "example.com.zone")

      assert {:ok, zone} = Parser.parse_file(file_path, zone_name: "example.com")

      assert zone.name == "example.com"
      assert zone.ttl == 3600

      # Check SOA
      assert zone.soa != nil
      assert zone.soa.mname == "ns1.example.com."
      assert zone.soa.rname == "admin.example.com."
      assert zone.soa.serial == 2024102801
      assert zone.soa.refresh == 7200
      assert zone.soa.retry == 3600
      assert zone.soa.expire == 1_209_600
      assert zone.soa.minimum == 3600

      # Check NS records
      ns_records = Zone.find_records(zone, "@", :NS)
      assert length(ns_records) >= 2

      # Check A records (owner is made absolute)
      www_records = Zone.find_records(zone, "www.example.com.", :A)
      assert length(www_records) == 1
      assert hd(www_records).rdata == {192, 168, 1, 100}

      # Check AAAA record
      aaaa_records = Zone.find_records(zone, "www.example.com.", :AAAA)
      assert length(aaaa_records) == 1
      assert hd(aaaa_records).rdata == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

      # Check MX records (@ is kept as @, not made absolute)
      mx_records = Zone.find_records(zone, "@", :MX)
      assert length(mx_records) == 2

      # Check TXT records
      txt_records = Zone.find_records(zone, "@", :TXT)
      assert length(txt_records) >= 1

      # Check CNAME record
      cname_records = Zone.find_records(zone, "ftp.example.com.", :CNAME)
      assert length(cname_records) == 1
      assert hd(cname_records).rdata == "www.example.com."
    end

    test "returns error for non-existent file" do
      assert {:error, {:file_error, :enoent}} =
               Parser.parse_file("/nonexistent/file.zone", zone_name: "test.com")
    end

    test "returns error when zone_name is not provided" do
      file_path = Path.join(@fixtures_dir, "simple.zone")

      assert {:error, :zone_name_required} = Parser.parse_file(file_path, [])
    end
  end

  describe "parse_string/2" do
    test "parses a minimal zone file string" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      @  IN  NS  ns1.test.com.
      ns1  IN  A  10.0.0.1
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      assert zone.name == "test.com"
      assert zone.ttl == 300
      assert zone.soa != nil
      assert zone.soa.serial == 2024010101

      # Check records
      ns_records = Zone.find_records(zone, "@", :NS)
      assert length(ns_records) == 1

      a_records = Zone.find_records(zone, "ns1.test.com.", :A)
      assert length(a_records) == 1
      assert hd(a_records).rdata == {10, 0, 0, 1}
    end

    test "parses zone with comments" do
      content = """
      ; This is a comment
      $ORIGIN test.com.
      $TTL 300
      ; Another comment
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      ; Comment after SOA
      @  IN  NS  ns1.test.com.  ; inline comment
      ns1  IN  A  10.0.0.1
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      assert zone.name == "test.com"
      assert zone.soa != nil
    end

    test "parses multi-line SOA record with parentheses" do
      content = """
      $ORIGIN example.com.
      $TTL 3600
      @  IN  SOA ns1.example.com. admin.example.com. (
                 2024102801  ; Serial
                 7200        ; Refresh
                 3600        ; Retry
                 1209600     ; Expire
                 3600 )      ; Minimum TTL
      @  IN  NS  ns1.example.com.
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "example.com")

      assert zone.soa != nil
      assert zone.soa.serial == 2024102801
      assert zone.soa.refresh == 7200
      assert zone.soa.retry == 3600
      assert zone.soa.expire == 1_209_600
      assert zone.soa.minimum == 3600
    end

    test "parses A record" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      www  IN  A  192.168.1.100
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      records = Zone.find_records(zone, "www.test.com.", :A)
      assert length(records) == 1
      assert hd(records).rdata == {192, 168, 1, 100}
      assert hd(records).ttl == 300
    end

    test "parses AAAA record" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      www  IN  AAAA  2001:db8::1
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      records = Zone.find_records(zone, "www.test.com.", :AAAA)
      assert length(records) == 1
      assert hd(records).rdata == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
    end

    test "parses MX record" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      @  IN  MX  10 mail.test.com.
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      records = Zone.find_records(zone, "@", :MX)
      assert length(records) == 1
      assert hd(records).rdata == {10, "mail.test.com."}
    end

    test "parses TXT record" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      @  IN  TXT  "v=spf1 mx a -all"
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      records = Zone.find_records(zone, "@", :TXT)
      assert length(records) == 1
      assert hd(records).rdata == "v=spf1 mx a -all"
    end

    test "parses CNAME record" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      www  IN  A  192.168.1.100
      ftp  IN  CNAME  www.test.com.
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      records = Zone.find_records(zone, "ftp.test.com.", :CNAME)
      assert length(records) == 1
      assert hd(records).rdata == "www.test.com."
    end

    test "parses SRV record" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      _http._tcp  IN  SRV  10 60 80 www.test.com.
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      records = Zone.find_records(zone, "_http._tcp.test.com.", :SRV)
      assert length(records) == 1
      assert hd(records).rdata == {10, 60, 80, "www.test.com."}
    end

    test "parses CAA record" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      @  IN  CAA  0 issue "letsencrypt.org"
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      records = Zone.find_records(zone, "@", :CAA)
      assert length(records) == 1
      assert hd(records).rdata == {0, "issue", "letsencrypt.org"}
    end
  end

  describe "relative domain names" do
    test "makes relative names absolute with $ORIGIN" do
      file_path = Path.join(@fixtures_dir, "relative-names.zone")

      assert {:ok, zone} = Parser.parse_file(file_path, zone_name: "test.local")

      # Check that relative names were made absolute
      records = Zone.find_records(zone, "host1.test.local.", :A)
      assert length(records) == 1

      # Check CNAME with relative target
      cname_records = Zone.find_records(zone, "alias.test.local.", :CNAME)
      assert length(cname_records) == 1
      # Target should be made absolute
      assert hd(cname_records).rdata == "host1.test.local."
    end

    test "handles @ symbol as zone apex" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      @  IN  A  192.168.1.1
      @  IN  NS  ns1.test.com.
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      # @ should represent the zone apex
      a_records = Zone.find_records(zone, "@", :A)
      assert length(a_records) == 1
      assert hd(a_records).rdata == {192, 168, 1, 1}
    end
  end

  describe "$ORIGIN directive" do
    test "updates origin when $ORIGIN is encountered" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300

      $ORIGIN sub.test.com.
      www  IN  A  192.168.1.100
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      # Record should be under new origin
      records = Zone.find_records(zone, "www.sub.test.com.", :A)
      assert length(records) == 1
    end
  end

  describe "$TTL directive" do
    test "uses default TTL for records" do
      content = """
      $ORIGIN test.com.
      $TTL 1800
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      www  IN  A  192.168.1.100
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      records = Zone.find_records(zone, "www.test.com.", :A)
      assert length(records) == 1
      assert hd(records).ttl == 1800
    end

    test "updates default TTL when $TTL is encountered" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      www  IN  A  192.168.1.100

      $TTL 600
      mail  IN  A  192.168.1.20
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      www_records = Zone.find_records(zone, "www.test.com.", :A)
      assert hd(www_records).ttl == 300

      mail_records = Zone.find_records(zone, "mail.test.com.", :A)
      assert hd(mail_records).ttl == 600
    end

    test "allows explicit TTL to override default" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      www  900  IN  A  192.168.1.100
      """

      assert {:ok, zone} = Parser.parse_string(content, zone_name: "test.com")

      records = Zone.find_records(zone, "www.test.com.", :A)
      assert length(records) == 1
      assert hd(records).ttl == 900
    end
  end

  describe "error handling" do
    test "returns error for invalid IPv4 address" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      www  IN  A  999.999.999.999
      """

      assert {:error, {:parse_error, _, _}} =
               Parser.parse_string(content, zone_name: "test.com")
    end

    test "returns error for invalid IPv6 address" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      www  IN  AAAA  gggg::1
      """

      assert {:error, {:parse_error, _, _}} =
               Parser.parse_string(content, zone_name: "test.com")
    end

    test "returns error for invalid MX priority" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      @  IN  MX  invalid mail.test.com.
      """

      assert {:error, {:parse_error, _, _}} =
               Parser.parse_string(content, zone_name: "test.com")
    end

    test "returns error for unclosed parentheses" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. (
                 2024010101
                 3600
                 1800
                 604800
                 300
      @  IN  NS  ns1.test.com.
      """

      assert {:error, {:unclosed_parentheses, _}} =
               Parser.parse_string(content, zone_name: "test.com")
    end

    test "returns error for SOA with insufficient fields" do
      content = """
      $ORIGIN test.com.
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101
      """

      assert {:error, {:parse_error, _, _}} =
               Parser.parse_string(content, zone_name: "test.com")
    end

    test "returns error when zone_name is not provided" do
      content = """
      $TTL 300
      @  IN  SOA ns1.test.com. admin.test.com. 2024010101 3600 1800 604800 300
      """

      assert {:error, :zone_name_required} = Parser.parse_string(content, [])
    end
  end
end
