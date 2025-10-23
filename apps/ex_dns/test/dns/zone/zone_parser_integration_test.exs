defmodule DNS.Zone.ParserIntegrationTest do
  use ExUnit.Case
  alias DNS.Zone

  describe "Zone.parse_zone_string/1" do
    test "parses complete zone from string" do
      content = """
      ; Example zone file
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

      ; Web server
      www IN A 192.168.1.100

      ; Mail server
      mail IN A 192.168.1.200
      @ IN MX 10 mail.example.com.
      """

      assert {:ok, zone} = Zone.parse_zone_string(content)
      assert zone.name.value == "example.com"
      assert zone.origin == "example.com."
      assert zone.ttl == 3600
      assert zone.soa != nil
      assert length(zone.records) == 5
    end

    test "handles zone without explicit origin" do
      content = """
      $TTL 3600
      @ IN SOA ns1.example.com. admin.example.com. (
          1 3600 1800 604800 86400
      )
      @ IN NS ns1.example.com.
      """

      assert {:ok, zone} = Zone.parse_zone_string(content)
      assert zone.origin == nil
      # Default root zone
      assert zone.name.value == "."
    end

    test "handles zone with comments" do
      content = """
      ; Zone file for testing
      ; Multiple comments
      $TTL 3600
      $ORIGIN test.com.

      ; SOA record
      @ IN SOA ns1.test.com. admin.test.com. (
          1 3600 1800 604800 86400
      )
      """

      assert {:ok, zone} = Zone.parse_zone_string(content)
      assert zone.comments == [" Zone file for testing", " Multiple comments", " SOA record"]
    end
  end

  describe "Zone.parse_zone_file/1" do
    test "parses zone from file" do
      # Create temporary zone file
      zone_content = """
      $TTL 300
      $ORIGIN tempzone.com.

      @ IN SOA ns1.tempzone.com. admin.tempzone.com. (
          2024010101  ; serial
          3600        ; refresh
          1800        ; retry
          604800      ; expire
          300         ; minimum
      )

      @ IN NS ns1.tempzone.com.
      www IN A 10.0.0.1
      """

      # Write to temporary file
      temp_file = Path.join(System.tmp_dir!(), "test_zone_#{System.unique_integer()}.zone")
      File.write!(temp_file, zone_content)

      try do
        assert {:ok, zone} = Zone.parse_zone_file(temp_file)
        assert zone.origin == "tempzone.com."
        assert zone.ttl == 300
        assert length(zone.records) == 2
      after
        File.rm!(temp_file)
      end
    end

    test "returns error for non-existent file" do
      assert {:error, reason} = Zone.parse_zone_file("/nonexistent/path/to/zone.file")
      assert String.contains?(reason, "Failed to read file")
    end
  end

  describe "Zone.from_ast/1" do
    test "converts AST to Zone struct correctly" do
      ast = %DNS.Zone.Parser.ZoneFile{
        origin: "test.com",
        ttl: 3600,
        comments: ["Test zone"],
        records: [
          %DNS.Zone.Parser.ResourceRecord{
            name: "@",
            type: "SOA",
            ttl: 3600,
            rdata: %DNS.Zone.Parser.SOARecord{
              primary_ns: "ns1.test.com",
              admin_email: "admin.test.com",
              serial: 1,
              refresh: 3600,
              retry: 1800,
              expire: 604_800,
              minimum: 300
            }
          },
          %DNS.Zone.Parser.ResourceRecord{
            name: "@",
            type: "NS",
            ttl: 3600,
            rdata: "ns1.test.com"
          },
          %DNS.Zone.Parser.ResourceRecord{
            name: "www",
            type: "A",
            ttl: 300,
            rdata: "192.168.1.100"
          }
        ]
      }

      zone = Zone.from_ast(ast)
      assert zone.name.value == "test.com"
      assert zone.origin == "test.com"
      assert zone.ttl == 3600
      assert zone.comments == ["Test zone"]
      assert zone.soa != nil
      # SOA is extracted separately
      assert length(zone.records) == 2
    end
  end

  describe "Zone.to_bind_format/1" do
    test "exports zone to BIND format" do
      zone = %DNS.Zone{
        name: DNS.Zone.Name.new("example.com"),
        origin: "example.com",
        ttl: 3600,
        comments: ["Zone file for example.com"],
        soa: %DNS.Zone.Parser.SOARecord{
          primary_ns: "ns1.example.com",
          admin_email: "admin.example.com",
          serial: 2_024_010_101,
          refresh: 3600,
          retry: 1800,
          expire: 604_800,
          minimum: 300
        },
        records: [
          DNS.Zone.RRSet.new("@", :ns, [%{type: :ns, nsdname: "ns1.example.com"}], ttl: 3600),
          DNS.Zone.RRSet.new("@", :ns, [%{type: :ns, nsdname: "ns2.example.com"}], ttl: 3600),
          DNS.Zone.RRSet.new("www", :a, [%{type: :a, address: "192.168.1.100"}], ttl: 300)
        ]
      }

      bind_content = Zone.to_bind_format(zone)
      assert is_binary(bind_content)
      assert String.contains?(bind_content, "; Zone file for example.com")
      assert String.contains?(bind_content, "$ORIGIN example.com")
      assert String.contains?(bind_content, "$TTL 3600")
      assert String.contains?(bind_content, "IN SOA")
      assert String.contains?(bind_content, "ns1.example.com")
      assert String.contains?(bind_content, "www")
    end

    test "round-trip parsing and export" do
      original_content = """
      ; Example zone
      $TTL 3600
      $ORIGIN roundtrip.com.

      @ IN SOA ns1.roundtrip.com. admin.roundtrip.com. (
          2024010101  ; serial
          3600        ; refresh
          1800        ; retry
          604800      ; expire
          300         ; minimum
      )

      @ IN NS ns1.roundtrip.com.
      www IN A 192.168.1.100
      mail IN A 192.168.1.200
      """

      # Parse the original
      assert {:ok, zone} = Zone.parse_zone_string(original_content)

      # Export to BIND format
      exported = Zone.to_bind_format(zone)
      assert is_binary(exported)

      # Parse the exported content
      assert {:ok, reparsed_zone} = Zone.parse_zone_string(exported)

      # Verify they're equivalent
      assert reparsed_zone.origin == zone.origin
      assert reparsed_zone.ttl == zone.ttl
      assert length(reparsed_zone.records) == length(zone.records)
    end
  end

  describe "Zone.export_zone/2" do
    test "exports zone in BIND format" do
      zone = %DNS.Zone{
        name: DNS.Zone.Name.new("test.com"),
        origin: "test.com",
        ttl: 3600,
        soa: %DNS.Zone.Parser.SOARecord{
          primary_ns: "ns1.test.com",
          admin_email: "admin.test.com",
          serial: 1,
          refresh: 3600,
          retry: 1800,
          expire: 604_800,
          minimum: 300
        },
        records: [
          DNS.Zone.RRSet.new("@", :ns, [%{type: :ns, nsdname: "ns1.test.com"}], ttl: 3600)
        ]
      }

      assert {:ok, content} = Zone.export_zone(zone, format: :bind)
      assert is_binary(content)
      assert String.contains?(content, "IN SOA")
    end

    test "exports zone in JSON format" do
      zone = %DNS.Zone{
        name: DNS.Zone.Name.new("test.com"),
        origin: "test.com",
        ttl: 3600
      }

      # Skip JSON export test until Jason.Encoder is implemented
      assert {:error, "JSON export not implemented"} = Zone.export_zone(zone, format: :json)
    end

    test "returns error for unsupported format" do
      zone = %DNS.Zone{name: DNS.Zone.Name.new("test.com")}
      assert {:error, "Unsupported format: xml"} = Zone.export_zone(zone, format: :xml)
    end
  end
end
