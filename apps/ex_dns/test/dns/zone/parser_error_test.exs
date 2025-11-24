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
      @ IN SOA ns1.example.com. admin.example.com. 1 3600 1800 604800 86400
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
      @ IN SOA ns1.example.com. admin.example.com. 1 3600 1800 604800 86400
      """

      assert {:error, reason} = Parser.parse(content)
      assert is_binary(reason)
    end

    test "returns error for invalid domain names" do
      content = """
      $ORIGIN invalid..domain.
      @ IN SOA ns1.example.com. admin.example.com. 1 3600 1800 604800 86400
      """

      assert {:error, reason} = Parser.parse(content)
      assert is_binary(reason)
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
      a_record = Enum.find(zone.records, &(&1.type == :a))
      # Should use default TTL
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
end
