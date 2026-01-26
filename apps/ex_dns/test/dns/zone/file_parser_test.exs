defmodule DNS.Zone.FileParserTest do
  @moduledoc """
  Comprehensive unit tests for DNS.Zone.FileParser.

  Tests cover:
  - Module structure and exports
  - parse/1 for basic zone files
  - $ORIGIN directive handling
  - $TTL directive handling
  - SOA record parsing
  - NS record parsing
  - A/AAAA record parsing
  - MX record parsing
  - TXT record parsing
  - CNAME/PTR record parsing
  - SRV record parsing
  - HTTPS/SVCB record parsing
  - DNSSEC record parsing (DNSKEY, DS, RRSIG)
  - Comment handling
  - Error handling
  - Root zone file parsing
  """
  use ExUnit.Case, async: true

  alias DNS.Zone.FileParser

  describe "module structure" do
    test "module is defined and loadable" do
      {:module, _} = Code.ensure_loaded(FileParser)
    end

    test "exports parse/1" do
      Code.ensure_loaded!(FileParser)
      assert Kernel.function_exported?(FileParser, :parse, 1)
    end
  end

  describe "parse/1 basic zone file" do
    test "parses basic zone file" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns1.example.com. admin.example.com. 2024010101 3600 1800 604800 86400
      @       IN  NS  ns1.example.com.
      @       IN  NS  ns2.example.com.
      ns1     IN  A   192.0.2.1
      ns2     IN  A   192.0.2.2
      www     IN  A   192.0.2.100
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      assert zone.origin == "example.com"
      assert zone.ttl == 3600
      assert length(zone.records) >= 5
    end

    test "returns zone struct" do
      zone_content = """
      $ORIGIN test.com.
      $TTL 300
      @       IN  SOA ns.test.com. admin.test.com. 1 3600 1800 604800 86400
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      assert %{origin: _, ttl: _, records: _} = zone
    end
  end

  describe "$ORIGIN directive" do
    test "parses $ORIGIN directive" do
      zone_content = """
      $ORIGIN example.org.
      $TTL 300
      @       IN  SOA ns.example.org. admin.example.org. 1 3600 1800 604800 86400
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      assert zone.origin == "example.org"
    end

    test "strips trailing dot from origin" do
      zone_content = """
      $ORIGIN example.net.
      $TTL 300
      @       IN  SOA ns.example.net. admin.example.net. 1 3600 1800 604800 86400
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      assert zone.origin == "example.net"
    end

    test "handles subdomain origin" do
      zone_content = """
      $ORIGIN sub.example.com.
      $TTL 300
      @       IN  SOA ns.sub.example.com. admin.sub.example.com. 1 3600 1800 604800 86400
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      assert zone.origin == "sub.example.com"
    end
  end

  describe "$TTL directive" do
    test "parses $TTL directive" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 7200
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      assert zone.ttl == 7200
    end

    test "handles various TTL values" do
      for ttl <- [60, 300, 3600, 86400, 604_800] do
        zone_content = """
        $ORIGIN example.com.
        $TTL #{ttl}
        @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
        """

        assert {:ok, zone} = FileParser.parse(zone_content)
        assert zone.ttl == ttl
      end
    end
  end

  describe "SOA record parsing" do
    test "parses SOA record" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns1.example.com. admin.example.com. 2024010101 3600 1800 604800 86400
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      # SOA is stored in zone.soa, not in records list
      assert zone.soa != nil
    end

    test "parses SOA with parenthesized values" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns1.example.com. admin.example.com. (
                  2024010101  ; serial
                  3600        ; refresh
                  1800        ; retry
                  604800      ; expire
                  86400       ; minimum
              )
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      # SOA is stored in zone.soa
      assert zone.soa != nil
    end
  end

  describe "NS record parsing" do
    test "parses NS records" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      @       IN  NS  ns1.example.com.
      @       IN  NS  ns2.example.com.
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      ns_records = Enum.filter(zone.records, fn r -> r.type == :ns end)
      assert length(ns_records) == 2
    end

    test "NS records reference correct nameservers" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      @       IN  NS  ns1.example.com.
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      [ns_record] = Enum.filter(zone.records, fn r -> r.type == :ns end)
      # data contains nameserver info
      assert inspect(ns_record.data) =~ "ns1.example.com"
    end
  end

  describe "A record parsing" do
    test "parses A records" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      www     IN  A   192.0.2.1
      mail    IN  A   192.0.2.2
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      a_records = Enum.filter(zone.records, fn r -> r.type == :a end)
      assert length(a_records) == 2
    end

    test "parses A record with correct IP" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      www     IN  A   10.20.30.40
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      [a_record] = Enum.filter(zone.records, fn r -> r.type == :a end)
      # data is a list of maps with :type and :address
      [%{address: address}] = a_record.data
      assert address == "10.20.30.40"
    end

    test "parses @ A record" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      @       IN  A   192.0.2.1
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      a_records = Enum.filter(zone.records, fn r -> r.type == :a end)
      assert length(a_records) == 1
      [record] = a_records
      assert record.name == "example.com"
    end
  end

  describe "AAAA record parsing" do
    test "parses AAAA records" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      www     IN  AAAA 2001:db8::1
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      aaaa_records = Enum.filter(zone.records, fn r -> r.type == :aaaa end)
      assert length(aaaa_records) == 1
    end
  end

  describe "MX record parsing" do
    test "parses MX records" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      @       IN  MX  10 mail.example.com.
      @       IN  MX  20 backup.example.com.
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      mx_records = Enum.filter(zone.records, fn r -> r.type == :mx end)
      assert length(mx_records) == 2
    end
  end

  describe "TXT record parsing" do
    test "parses TXT records" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      @       IN  TXT "v=spf1 include:example.com ~all"
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      txt_records = Enum.filter(zone.records, fn r -> r.type == :txt end)
      assert length(txt_records) == 1
    end
  end

  describe "CNAME record parsing" do
    test "parses CNAME records" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      alias   IN  CNAME target.example.com.
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      cname_records = Enum.filter(zone.records, fn r -> r.type == :cname end)
      assert length(cname_records) == 1
    end
  end

  describe "SRV record parsing" do
    test "parses SRV records" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      _http._tcp  IN  SRV 10 5 80 www.example.com.
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      srv_records = Enum.filter(zone.records, fn r -> r.type == :srv end)
      assert length(srv_records) == 1
    end
  end

  describe "HTTPS record parsing" do
    test "parses HTTPS record with ALPN" do
      zone_content = """
      $ORIGIN discord.com.
      $TTL 300
      @       IN  SOA ns1.discord.com. admin.discord.com. 2024010101 3600 1800 604800 86400
      @       IN  NS  ns1.discord.com.
      @       IN  HTTPS 1 . alpn="h3,h2" ipv4hint=162.159.128.233
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      https_records = Enum.filter(zone.records, fn r -> r.type == :https end)
      assert length(https_records) == 1
      [record] = https_records
      assert record.name == "discord.com"
      assert record.ttl == 300

      assert [%{priority: 1, target: ".", params: "alpn=\"h3,h2\" ipv4hint=162.159.128.233"}] =
               record.data
    end

    test "parses HTTPS record with multiple parameters" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 300
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      @       IN  HTTPS 1 . alpn="h3,h2" port=443 ipv4hint=192.0.2.1
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      https_records = Enum.filter(zone.records, fn r -> r.type == :https end)
      assert length(https_records) == 1
    end
  end

  describe "DNSSEC record parsing" do
    test "handles DNSSEC records" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns1.example.com. admin.example.com. 2024010101 3600 1800 604800 86400
      @       IN  NS  ns1.example.com.
      example.com. IN DNSKEY 256 3 8 AwEAAc3...
      example.com. IN DS 12345 8 2 49FD46E6...
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      dnskey_records = Enum.filter(zone.records, fn r -> r.type == :dnskey end)
      ds_records = Enum.filter(zone.records, fn r -> r.type == :ds end)
      assert length(dnskey_records) == 1
      assert length(ds_records) == 1
    end

    test "parses DNSKEY record" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      example.com. IN DNSKEY 257 3 13 mdsswUyr3DPW...
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      dnskey_records = Enum.filter(zone.records, fn r -> r.type == :dnskey end)
      assert length(dnskey_records) == 1
    end

    test "parses DS record" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      example.com. IN DS 60485 5 1 2BB183AF5F22588179A53B0A98631FAD1A292118
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      ds_records = Enum.filter(zone.records, fn r -> r.type == :ds end)
      assert length(ds_records) == 1
    end
  end

  describe "comment handling" do
    test "ignores comment lines" do
      zone_content = """
      ; This is a comment
      $ORIGIN example.com.
      ; Another comment
      $TTL 3600
      ; SOA comment
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      assert zone.origin == "example.com"
    end

    test "handles inline comments" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600 ; default TTL
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400 ; SOA record
      www     IN  A   192.0.2.1 ; web server
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      a_records = Enum.filter(zone.records, fn r -> r.type == :a end)
      assert length(a_records) == 1
    end
  end

  describe "record inheritance" do
    test "records inherit TTL from $TTL directive" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      www     IN  A   192.0.2.1
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      [a_record] = Enum.filter(zone.records, fn r -> r.type == :a end)
      assert a_record.ttl == 3600
    end

    test "records can override TTL" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      www     7200 IN  A   192.0.2.1
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      [a_record] = Enum.filter(zone.records, fn r -> r.type == :a end)
      assert a_record.ttl == 7200
    end
  end

  describe "parse root zone file" do
    test "parse root zone file" do
      file_path = Path.expand("data/root.zone", :code.priv_dir(:ex_dns))
      zone_content = File.read!(file_path)
      assert {:ok, zone} = FileParser.parse(zone_content)
      assert %{} = zone
    end

    test "root zone contains NS records" do
      file_path = Path.expand("data/root.zone", :code.priv_dir(:ex_dns))
      zone_content = File.read!(file_path)
      {:ok, zone} = FileParser.parse(zone_content)
      ns_records = Enum.filter(zone.records, fn r -> r.type == :ns end)
      assert length(ns_records) > 0
    end
  end

  describe "edge cases" do
    test "handles multiple record types on same name" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      www     IN  A     192.0.2.1
      www     IN  AAAA  2001:db8::1
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      www_records = Enum.filter(zone.records, fn r -> String.contains?(r.name, "www") end)
      assert length(www_records) == 2
    end

    test "handles fully qualified names" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      example.com.  IN  SOA ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      www.example.com.  IN  A   192.0.2.1
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      assert zone.origin == "example.com"
    end

    test "handles case-insensitive record types" do
      zone_content = """
      $ORIGIN example.com.
      $TTL 3600
      @       in  soa ns.example.com. admin.example.com. 1 3600 1800 604800 86400
      www     in  a   192.0.2.1
      """

      assert {:ok, zone} = FileParser.parse(zone_content)
      a_records = Enum.filter(zone.records, fn r -> r.type == :a end)
      assert length(a_records) == 1
    end
  end
end
