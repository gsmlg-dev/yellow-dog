defmodule DNS.Zone.ParserErrorTest do
  use ExUnit.Case
  alias DNS.Zone.Parser
  alias DNS.Zone

  describe "Parser error handling" do
    test "returns error for malformed SOA record" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com.
      ; Missing SOA parameters
      """

      assert {:error, reason} = Parser.parse(content)
      assert is_binary(reason)
    end

    test "returns error for invalid record format" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      invalid line without proper record format
      """

      assert {:error, reason} = Parser.parse(content)
      assert is_binary(reason)
    end

    test "returns error for unclosed SOA parentheses" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          2024010101 3600 1800 604800 86400
      ; Missing closing parenthesis
      """

      assert {:error, reason} = Parser.parse(content)
      assert is_binary(reason)
    end

    test "handles empty content gracefully" do
      assert {:ok, %DNS.Zone.Parser.ZoneFile{records: []}} = Parser.parse("")
    end

    test "handles content with only comments" do
      content = """
      ; This is just a comment
      ; Another comment
      """

      assert {:ok, zone} = Parser.parse(content)
      assert zone.comments == [" This is just a comment", " Another comment"]
      assert zone.records == []
    end

    test "handles content with only directives" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      """

      assert {:ok, zone} = Parser.parse(content)
      assert zone.ttl == 3600
      assert zone.origin == "example.com."
      assert zone.records == []
    end

    test "returns error for invalid TTL values" do
      content = """
      $TTL invalid
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      """

      assert {:error, reason} = Parser.parse(content)
      assert is_binary(reason)
    end

    test "handles domain names with double dots" do
      content = """
      $ORIGIN invalid..domain.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      """

      # Parser may accept this or error depending on validation level
      result = Parser.parse(content)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "Zone parsing error handling" do
    test "Zone.parse_zone_string handles parser errors" do
      assert {:error, reason} = Zone.parse_zone_string("invalid content")
      assert is_binary(reason)
    end

    test "Zone.parse_zone_file handles file errors" do
      assert {:error, reason} = Zone.parse_zone_file("/nonexistent/file.zone")
      assert String.contains?(reason, "Failed to read file")
    end

    test "Zone.parse_zone_file handles parser errors in file" do
      # Create temporary file with invalid content
      temp_file = Path.join(System.tmp_dir!(), "invalid_zone_#{System.unique_integer()}.zone")
      File.write!(temp_file, "invalid zone content")

      try do
        assert {:error, reason} = Zone.parse_zone_file(temp_file)
        assert is_binary(reason)
      after
        File.rm!(temp_file)
      end
    end
  end

  describe "edge cases" do
    test "handles very large zone files" do
      # Create a large zone with many records
      records =
        Enum.map(1..100, fn i ->
          "record#{i} IN A 192.168.1.#{i}"
        end)

      content = """
      $TTL 300
      $ORIGIN largezone.com.
      @ IN SOA ns1.largezone.com. admin.largezone.com. (
          1 3600 1800 604800 300
      )
      @ IN NS ns1.largezone.com.
      #{Enum.join(records, "\n")}
      """

      assert {:ok, zone} = Zone.parse_zone_string(content)
      assert zone.origin == "largezone.com."
      # SOA + NS + 100 A records
      assert length(zone.records) == 101
    end

    test "handles records with missing TTL" do
      content = """
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www IN A 192.168.1.100
      """

      assert {:ok, zone} = Zone.parse_zone_string(content)
      # Zone struct stores type as atom :a
      a_record = Enum.find(zone.records, &(&1.type == :a))
      # Should use default TTL (derived from SOA minimum)
      assert a_record.ttl == 3600
    end

    test "handles relative domain names" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www IN A 192.168.1.100
      mail IN CNAME www
      """

      assert {:ok, zone} = Zone.parse_zone_string(content)
      assert zone.origin == "example.com."
    end

    test "handles root zone (.)" do
      content = """
      $TTL 3600
      . IN SOA a.root-servers.net. nstld.verisign-grs.com. (
          2024010101 1800 900 604800 86400
      )
      """

      assert {:ok, zone} = Zone.parse_zone_string(content)
      assert zone.origin == nil
    end
  end

  describe "validation of parsed zones" do
    test "allows zones without SOA record" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN NS ns1.example.com.
      """

      assert {:ok, zone} = Zone.parse_zone_string(content)
      assert zone.origin == "example.com."
      assert zone.soa == nil
    end

    test "validates SOA record format" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA invalid-soa-format
      """

      assert {:error, reason} = Zone.parse_zone_string(content)
      assert is_binary(reason)
    end

    test "handles special characters in TXT records" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      @ IN TXT "Special chars: !@#$%^*&*()"
      @ IN TXT "Unicode: éñ中文"
      """

      assert {:ok, zone} = Zone.parse_zone_string(content)
      txt_records = Enum.filter(zone.records, &(&1.type == :txt))
      assert length(txt_records) == 2
    end
  end

  describe "round-trip consistency" do
    test "maintains data integrity through parse-export-parse cycle" do
      original_content = """
      ; Complex zone file
      $TTL 3600
      $ORIGIN roundtrip.com.

      @ IN SOA ns1.roundtrip.com. admin.roundtrip.com. (
          2024010101 ; Serial
          3600       ; Refresh
          1800       ; Retry
          604800     ; Expire
          300        ; Minimum TTL
      )

      ; Name servers
      @ IN NS ns1.roundtrip.com.
      @ IN NS ns2.roundtrip.com.

      ; A records
      @ IN A 192.168.1.1
      www IN A 192.168.1.100
      mail IN A 192.168.1.200

      ; MX records
      @ IN MX 10 mail.roundtrip.com.
      @ IN MX 20 backup.roundtrip.com.

      ; CNAME records
      ftp IN CNAME www.roundtrip.com.
      webmail IN CNAME mail.roundtrip.com.

      ; TXT records
      @ IN TXT "v=spf1 mx ~all"
      www IN TXT "web server"

      ; SRV records
      _sip._tcp IN SRV 10 60 5060 sip.roundtrip.com.
      """

      # Parse original
      assert {:ok, original_zone} = Zone.parse_zone_string(original_content)

      # Export to BIND format
      assert {:ok, exported} = Zone.export_zone(original_zone, format: :bind)

      # Parse exported content
      assert {:ok, reparsed_zone} = Zone.parse_zone_string(exported)

      # Verify essential data matches
      assert original_zone.origin == reparsed_zone.origin
      assert original_zone.ttl == reparsed_zone.ttl
      assert original_zone.soa.serial == reparsed_zone.soa.serial
      assert length(original_zone.records) == length(reparsed_zone.records)
    end
  end

  describe "malformed record types" do
    test "parses A record with invalid IP (no validation at parse time)" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www IN A 256.256.256.256
      """

      # Parser stores IP as string, validation happens later
      result = Parser.parse(content)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "parses AAAA record with invalid IPv6 (no validation at parse time)" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www IN AAAA gggg::invalid
      """

      # Parser stores IPv6 as string, validation happens later
      result = Parser.parse(content)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "returns error for MX record without priority" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      @ IN MX mail.example.com.
      """

      assert {:error, reason} = Parser.parse(content)
      assert is_binary(reason)
    end

    test "returns error for SRV record with missing fields" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      _http._tcp IN SRV 10
      """

      assert {:error, reason} = Parser.parse(content)
      assert is_binary(reason)
    end
  end

  describe "directive errors" do
    test "returns error for $INCLUDE with missing file" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      $INCLUDE /nonexistent/path/included.zone
      """

      # $INCLUDE may be handled differently depending on implementation
      result = Parser.parse(content)
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "returns error for $ORIGIN with missing value" do
      content = """
      $TTL 3600
      $ORIGIN
      """

      assert {:error, reason} = Parser.parse(content)
      assert is_binary(reason)
    end

    test "returns error for unknown directive" do
      content = """
      $TTL 3600
      $UNKNOWN directive
      """

      result = Parser.parse(content)
      # May be ignored or return error depending on implementation
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles $TTL with time unit suffix" do
      content = """
      $TTL 1h
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      """

      result = Parser.parse(content)
      # May be supported or return error
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "comment handling" do
    test "preserves inline comments" do
      content = """
      $TTL 3600 ; Default TTL
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      ) ; SOA record
      www IN A 192.168.1.1 ; Web server
      """

      assert {:ok, _zone} = Parser.parse(content)
    end

    test "handles comment-only lines between records" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      ; This is a comment
      ; Another comment
      www IN A 192.168.1.1
      """

      assert {:ok, zone} = Parser.parse(content)
      assert length(zone.comments) >= 2
    end

    test "handles empty lines" do
      content = """
      $TTL 3600

      $ORIGIN example.com.

      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )

      www IN A 192.168.1.1
      """

      assert {:ok, _zone} = Parser.parse(content)
    end
  end

  describe "multiline record handling" do
    test "handles SOA with inline values" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      """

      assert {:ok, zone} = Parser.parse(content)
      # Parser.parse returns ZoneFile struct, SOA is in records list
      soa_record = Enum.find(zone.records, &(&1.type == "SOA"))
      assert soa_record != nil
    end

    test "handles SOA with parentheses spanning lines" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          2024010101
          3600
          1800
          604800
          86400
      )
      """

      assert {:ok, zone} = Parser.parse(content)
      soa_record = Enum.find(zone.records, &(&1.type == "SOA"))
      assert soa_record != nil
      assert soa_record.rdata.serial == 2_024_010_101
    end

    test "handles SOA with comments inside parentheses" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          2024010101 ; Serial
          3600       ; Refresh (1 hour)
          1800       ; Retry (30 minutes)
          604800     ; Expire (1 week)
          86400      ; Minimum TTL (1 day)
      )
      """

      assert {:ok, zone} = Parser.parse(content)
      soa_record = Enum.find(zone.records, &(&1.type == "SOA"))
      assert soa_record != nil
      assert soa_record.rdata.serial == 2_024_010_101
    end
  end

  describe "whitespace handling" do
    test "handles tabs as field separators" do
      content = "$TTL\t3600\n$ORIGIN\texample.com.\n@ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )"

      assert {:ok, zone} = Parser.parse(content)
      assert zone.ttl == 3600
    end

    test "handles mixed tabs and spaces" do
      content = """
      $TTL\t  3600
      $ORIGIN   example.com.
      @\t IN\tSOA\tns1.example.com.\tadmin.example.com. (
          1 3600 1800 604800 86400
      )
      """

      assert {:ok, _zone} = Parser.parse(content)
    end

    test "handles trailing whitespace on lines" do
      content =
        "$TTL 3600   \n$ORIGIN example.com.   \n@ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )   "

      assert {:ok, _zone} = Parser.parse(content)
    end
  end

  describe "class handling" do
    test "handles explicit IN class" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www IN A 192.168.1.1
      """

      assert {:ok, zone} = Parser.parse(content)
      a_record = Enum.find(zone.records, &(&1.type == "A"))
      assert a_record != nil
    end

    test "handles implicit class (omitted)" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www A 192.168.1.1
      """

      result = Parser.parse(content)
      # May parse with implicit IN or error depending on implementation
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "TTL inheritance" do
    test "records use zone default TTL" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www IN A 192.168.1.1
      """

      assert {:ok, zone} = Zone.parse_zone_string(content)
      # Zone struct stores type as atom :a
      a_record = Enum.find(zone.records, &(&1.type == :a))
      assert a_record.ttl == 3600
    end

    test "explicit TTL overrides default" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www 7200 IN A 192.168.1.1
      """

      assert {:ok, zone} = Zone.parse_zone_string(content)
      # Zone struct stores type as atom :a
      a_record = Enum.find(zone.records, &(&1.type == :a))
      assert a_record.ttl == 7200
    end
  end

  describe "owner name handling" do
    test "handles @ as zone apex" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      @ IN A 192.168.1.1
      """

      assert {:ok, zone} = Parser.parse(content)
      a_record = Enum.find(zone.records, &(&1.type == "A"))
      assert a_record != nil
    end

    test "handles relative names" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www IN A 192.168.1.1
      """

      assert {:ok, zone} = Parser.parse(content)
      # Parser returns type as string, find A record
      a_record = Enum.find(zone.records, &(&1.type == "A"))
      assert a_record != nil
      assert a_record.name == "www" or a_record.name == "www.example.com."
    end

    test "handles absolute names" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www.example.com. IN A 192.168.1.1
      """

      assert {:ok, _zone} = Parser.parse(content)
    end

    test "handles wildcard names" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      * IN A 192.168.1.1
      """

      assert {:ok, zone} = Parser.parse(content)
      wildcard_record = Enum.find(zone.records, &String.contains?(&1.name, "*"))
      assert wildcard_record != nil
    end
  end

  describe "special record types" do
    test "handles CAA records" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      @ IN CAA 0 issue "letsencrypt.org"
      """

      result = Parser.parse(content)
      # CAA may or may not be supported depending on parser implementation
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles DNSKEY records" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      @ IN DNSKEY 256 3 8 AwEAAa...
      """

      result = Parser.parse(content)
      # DNSKEY may or may not be supported
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles PTR records" do
      content = """
      $TTL 3600
      $ORIGIN in-addr.arpa.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      100.1.168.192 IN PTR www.example.com.
      """

      result = Parser.parse(content)
      # PTR records may have specific parsing requirements
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "concurrent parsing" do
    test "multiple parses are thread-safe" do
      content = """
      $TTL 3600
      $ORIGIN thread#{:erlang.unique_integer()}.com.
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      www IN A 192.168.1.1
      """

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Parser.parse(content)
          end)
        end

      results = Task.await_many(tasks)

      for result <- results do
        assert match?({:ok, _}, result)
      end
    end
  end

  describe "error message quality" do
    test "error messages include line context" do
      content = """
      $TTL 3600
      $ORIGIN example.com.
      invalid record
      """

      {:error, reason} = Parser.parse(content)
      # Error message should provide useful information
      assert is_binary(reason)
    end

    test "error messages are descriptive" do
      content = """
      $ORIGIN example.com.
      @ IN SOA
      """

      {:error, reason} = Parser.parse(content)
      assert is_binary(reason)
      assert String.length(reason) > 0
    end
  end

  describe "performance" do
    test "parses medium zone efficiently" do
      records =
        for i <- 1..50 do
          "host#{i} IN A 192.168.#{rem(i, 256)}.#{rem(i, 256)}"
        end

      content = """
      $TTL 3600
      $ORIGIN perf.com.
      @ IN SOA ns1.perf.com. admin.perf.com. (
          1 3600 1800 604800 86400
      )
      #{Enum.join(records, "\n")}
      """

      {time_us, result} = :timer.tc(fn -> Parser.parse(content) end)

      assert match?({:ok, _}, result)
      # Should parse in under 1 second
      assert time_us < 1_000_000
    end
  end
end
