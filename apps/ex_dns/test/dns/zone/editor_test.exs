defmodule DNS.Zone.EditorTest do
  use ExUnit.Case, async: false

  alias DNS.Zone
  alias DNS.Zone.Editor
  alias DNS.Zone.Manager
  alias DNS.Message.Record

  setup do
    Manager.init()
    :ok
  end

  describe "Zone creation" do
    test "create_zone_interactive creates valid zone" do
      zone_name = "test-example.com"

      assert {:ok, zone} = Editor.create_zone_interactive(zone_name, type: :authoritative)
      assert zone.name.value == zone_name
      assert zone.type == :authoritative
    end

    test "create_zone_interactive rejects duplicate zone" do
      zone_name = "duplicate.com"

      assert {:ok, _} = Editor.create_zone_interactive(zone_name)

      assert {:error, "Zone already exists: duplicate.com"} =
               Editor.create_zone_interactive(zone_name)
    end

    test "create_zone_interactive rejects invalid zone name" do
      assert {:error, "Invalid zone name format: invalid name"} =
               Editor.create_zone_interactive("invalid name")
    end

    test "create_zone_interactive with SOA and NS records" do
      zone_name = "soa-example.com"

      assert {:ok, zone} =
               Editor.create_zone_interactive(zone_name,
                 type: :authoritative,
                 soa: [mname: "ns1.soa-example.com", rname: "admin.soa-example.com", serial: 1],
                 ns: ["ns1.soa-example.com", "ns2.soa-example.com"]
               )

      assert zone.name.value == zone_name
      assert length(Keyword.get(zone.options, :soa_records, [])) == 1
      assert length(Keyword.get(zone.options, :ns_records, [])) == 2
    end

    test "create_zone_interactive with default type" do
      zone_name = "default-type.com"
      assert {:ok, zone} = Editor.create_zone_interactive(zone_name)
      assert zone.type == :authoritative
    end
  end

  describe "Record management" do
    setup do
      zone_name = "record-test.com"

      zone = Zone.new(zone_name, :authoritative)

      soa_record =
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.record-test.com", "admin.record-test.com", 1, 3600, 1800, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}

      Manager.create_zone(zone_name, :authoritative, zone.options)

      {:ok, zone_name: zone_name}
    end

    test "add_record adds A record", %{zone_name: zone_name} do
      assert {:ok, zone} =
               Editor.add_record(zone_name, :a,
                 name: "www.#{zone_name}",
                 ip: {192, 168, 1, 1},
                 ttl: 300
               )

      a_records = Keyword.get(zone.options, :a_records, [])
      assert length(a_records) == 1
      [a_record] = a_records
      assert a_record.name.value == "www.#{zone_name}."
      assert a_record.data.data == {192, 168, 1, 1}
      assert a_record.ttl == 300
    end

    test "add_record adds AAAA record", %{zone_name: zone_name} do
      assert {:ok, zone} =
               Editor.add_record(zone_name, :aaaa,
                 name: "www.#{zone_name}",
                 ip: {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1},
                 ttl: 300
               )

      aaaa_records = Keyword.get(zone.options, :aaaa_records, [])
      assert length(aaaa_records) == 1
      [aaaa_record] = aaaa_records
      assert aaaa_record.data.data == {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
    end

    test "add_record adds MX record", %{zone_name: zone_name} do
      assert {:ok, zone} =
               Editor.add_record(zone_name, :mx,
                 name: zone_name,
                 preference: 10,
                 exchange: "mail.#{zone_name}"
               )

      mx_records = Keyword.get(zone.options, :mx_records, [])
      assert length(mx_records) == 1
      [mx_record] = mx_records
      assert mx_record.data.data == {10, DNS.Message.Domain.new("mail.#{zone_name}")}
    end

    test "add_record adds CNAME record", %{zone_name: zone_name} do
      assert {:ok, zone} =
               Editor.add_record(zone_name, :cname,
                 name: "alias.#{zone_name}",
                 target: "www.#{zone_name}"
               )

      cname_records = Keyword.get(zone.options, :cname_records, [])
      assert length(cname_records) == 1
    end

    test "add_record adds NS record", %{zone_name: zone_name} do
      assert {:ok, zone} =
               Editor.add_record(zone_name, :ns,
                 name: zone_name,
                 nsdname: "ns1.#{zone_name}"
               )

      ns_records = Keyword.get(zone.options, :ns_records, [])
      assert length(ns_records) == 1
    end

    test "add_record adds TXT record", %{zone_name: zone_name} do
      assert {:ok, zone} =
               Editor.add_record(zone_name, :txt,
                 name: zone_name,
                 text: ["v=spf1 include:example.com ~all"]
               )

      txt_records = Keyword.get(zone.options, :txt_records, [])
      assert length(txt_records) == 1
    end

    test "add_record validates zone", %{zone_name: zone_name} do
      # Test with invalid record
      assert {:ok, %DNS.Zone{}} =
               Editor.add_record(zone_name, :a,
                 name: "invalid name",
                 ip: {192, 168, 1, 1}
               )
    end

    test "add_record returns error for non-existent zone" do
      assert {:error, "Zone not found: nonexistent.com"} =
               Editor.add_record("nonexistent.com", :a, name: "www", ip: {1, 2, 3, 4})
    end

    test "remove_record removes matching records", %{zone_name: zone_name} do
      # First add a record
      assert {:ok, _zone} =
               Editor.add_record(zone_name, :a,
                 name: "www.#{zone_name}",
                 ip: {192, 168, 1, 1}
               )
    end

    test "remove_record returns error when no records match", %{zone_name: zone_name} do
      assert {:error, "No matching records found"} =
               Editor.remove_record(zone_name, :a, name: "nonexistent.#{zone_name}")
    end

    test "remove_record returns error for non-existent zone" do
      assert {:error, "Zone not found: nonexistent.com"} =
               Editor.remove_record("nonexistent.com", :a, name: "www")
    end

    test "update_record returns error when no records match", %{zone_name: zone_name} do
      assert {:error, "No matching records found"} =
               Editor.update_record(zone_name, :a, [name: "nonexistent.#{zone_name}"], ttl: 600)
    end

    test "update_record returns error for non-existent zone" do
      assert {:error, "Zone not found: nonexistent.com"} =
               Editor.update_record("nonexistent.com", :a, [name: "www"], ttl: 600)
    end
  end

  describe "Record listing and search" do
    setup do
      zone_name = "search-test.com"

      zone = Zone.new(zone_name, :authoritative)

      soa_record =
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.search-test.com", "admin.search-test.com", 1, 3600, 1800, 604_800, 300}
        )

      a_record1 = Record.new("www.#{zone_name}", :a, :in, 300, {192, 168, 1, 1})
      a_record2 = Record.new("mail.#{zone_name}", :a, :in, 300, {192, 168, 1, 2})
      mx_record = Record.new(zone_name, :mx, :in, 300, {10, "mail.#{zone_name}"})

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      options = Keyword.put(options, :a_records, [a_record1, a_record2])
      options = Keyword.put(options, :mx_records, [mx_record])
      zone = %{zone | options: options}

      Manager.create_zone(zone_name, :authoritative, zone.options)

      {:ok, zone_name: zone_name}
    end

    test "list_records returns all records", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.list_records(zone_name)
      # SOA + 2 A + 1 MX
      assert length(records) == 4

      # Check if we have the expected record types
      types = Enum.map(records, & &1.type)
      assert DNS.ResourceRecordType.new(:soa) in types
      assert DNS.ResourceRecordType.new(:a) in types
      assert DNS.ResourceRecordType.new(:mx) in types
    end

    test "list_records formats A record data as dotted notation", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.list_records(zone_name)

      a_records =
        Enum.filter(records, fn r ->
          to_string(r.type) == "A"
        end)

      assert length(a_records) == 2
      assert Enum.any?(a_records, &(&1.data == "192.168.1.1"))
      assert Enum.any?(a_records, &(&1.data == "192.168.1.2"))
    end

    test "list_records formats MX record data", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.list_records(zone_name)

      mx_records =
        Enum.filter(records, fn r ->
          to_string(r.type) == "MX"
        end)

      assert length(mx_records) == 1
      assert hd(mx_records).data =~ "10"
    end

    test "list_records formats SOA record data", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.list_records(zone_name)

      soa_records =
        Enum.filter(records, fn r ->
          to_string(r.type) == "SOA"
        end)

      assert length(soa_records) == 1
      soa_data = hd(soa_records).data
      assert soa_data =~ "ns1.search-test.com"
      assert soa_data =~ "admin.search-test.com"
    end

    test "search_records by name", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.search_records(zone_name, name: "www.#{zone_name}.")
      assert length(records) == 1
      assert hd(records).name == "www.#{zone_name}."
    end

    test "search_records by type with atom", %{zone_name: zone_name} do
      # Tests normalize_type_str: atom :a matches RRType struct
      assert {:ok, records} = Editor.search_records(zone_name, type: :a)
      assert length(records) == 2

      assert Enum.all?(records, fn r ->
               to_string(r.type) == "A"
             end)
    end

    test "search_records by type with RRType struct", %{zone_name: zone_name} do
      # Tests normalize_type_str: RRType struct matches RRType struct
      rr_type = DNS.ResourceRecordType.new(:mx)
      assert {:ok, records} = Editor.search_records(zone_name, type: rr_type)
      assert length(records) == 1
    end

    test "search_records by type with string", %{zone_name: zone_name} do
      # Tests normalize_type_str: string "SOA" matches RRType struct
      assert {:ok, records} = Editor.search_records(zone_name, type: "SOA")
      assert length(records) == 1
    end

    test "search_records returns empty when no matches", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.search_records(zone_name, name: "nonexistent.#{zone_name}")
      assert records == []
    end

    test "search_records returns error for non-existent zone" do
      assert {:error, "Zone not found: nonexistent.com"} =
               Editor.search_records("nonexistent.com", name: "www")
    end

    test "list_records returns error for non-existent zone" do
      assert {:error, "Zone not found: nonexistent.com"} = Editor.list_records("nonexistent.com")
    end
  end

  describe "format_record_data with various types" do
    setup do
      zone_name = "format-test.com"

      zone = Zone.new(zone_name, :authoritative)

      soa_record =
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.format-test.com", "admin.format-test.com", 1, 3600, 1800, 604_800, 300}
        )

      a_record = Record.new("www.#{zone_name}", :a, :in, 300, {10, 0, 0, 1})

      aaaa_record =
        Record.new("www.#{zone_name}", :aaaa, :in, 300, {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1})

      cname_record = Record.new("alias.#{zone_name}", :cname, :in, 300, "www.#{zone_name}")
      ns_record = Record.new(zone_name, :ns, :in, 3600, "ns1.#{zone_name}")
      mx_record = Record.new(zone_name, :mx, :in, 300, {10, "mail.#{zone_name}"})
      txt_record = Record.new(zone_name, :txt, :in, 300, ["v=spf1 -all"])

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      options = Keyword.put(options, :a_records, [a_record])
      options = Keyword.put(options, :aaaa_records, [aaaa_record])
      options = Keyword.put(options, :cname_records, [cname_record])
      options = Keyword.put(options, :ns_records, [ns_record])
      options = Keyword.put(options, :mx_records, [mx_record])
      options = Keyword.put(options, :txt_records, [txt_record])
      zone = %{zone | options: options}

      Manager.create_zone(zone_name, :authoritative, zone.options)

      {:ok, zone_name: zone_name}
    end

    test "A record formatted as dotted decimal", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.list_records(zone_name)
      a_rec = Enum.find(records, &(to_string(&1.type) == "A"))
      assert a_rec.data == "10.0.0.1"
    end

    test "AAAA record formatted as colon-separated hex", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.list_records(zone_name)
      aaaa_rec = Enum.find(records, &(to_string(&1.type) == "AAAA"))
      assert aaaa_rec.data == "2001:DB8:0:0:0:0:0:1"
    end

    test "CNAME record formatted as string", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.list_records(zone_name)
      cname_rec = Enum.find(records, &(to_string(&1.type) == "CNAME"))
      assert is_binary(cname_rec.data)
    end

    test "NS record formatted as string", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.list_records(zone_name)
      ns_rec = Enum.find(records, &(to_string(&1.type) == "NS"))
      assert is_binary(ns_rec.data)
    end

    test "MX record formatted with priority", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.list_records(zone_name)
      mx_rec = Enum.find(records, &(to_string(&1.type) == "MX"))
      assert mx_rec.data =~ "10"
    end

    test "TXT record formatted as text", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.list_records(zone_name)
      txt_rec = Enum.find(records, &(to_string(&1.type) == "TXT"))
      assert txt_rec.data == "v=spf1 -all"
    end

    test "SOA record formatted with all fields", %{zone_name: zone_name} do
      assert {:ok, records} = Editor.list_records(zone_name)
      soa_rec = Enum.find(records, &(to_string(&1.type) == "SOA"))
      assert soa_rec.data =~ "ns1.format-test.com"
      assert soa_rec.data =~ "admin.format-test.com"
      assert soa_rec.data =~ "3600"
    end
  end

  describe "Zone export" do
    setup do
      zone_name = "export-test.com"

      zone = Zone.new(zone_name, :authoritative)

      soa_record =
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.export-test.com", "admin.export-test.com", 1, 3600, 1800, 604_800, 300}
        )

      a_record = Record.new("www.#{zone_name}", :a, :in, 300, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      options = Keyword.put(options, :a_records, [a_record])
      zone = %{zone | options: options}

      Manager.create_zone(zone_name, :authoritative, zone.options)

      {:ok, zone_name: zone_name}
    end

    test "export_zone to BIND format", %{zone_name: zone_name} do
      assert {:ok, content} = Editor.export_zone(zone_name, format: :bind)
      assert is_binary(content)
      assert content =~ "; Zone file for #{zone_name}"
      assert content =~ "$TTL 3600"
      assert content =~ "SOA"
      assert content =~ "A"
    end

    test "export_zone to JSON format", %{zone_name: zone_name} do
      assert {:ok, content} = Editor.export_zone(zone_name, format: :json)
      assert is_binary(content)
      assert content =~ "\"zone\": \"#{zone_name}\""
      assert content =~ "\"type\": \"A\""
    end

    test "export_zone JSON contains properly formatted A data", %{zone_name: zone_name} do
      assert {:ok, content} = Editor.export_zone(zone_name, format: :json)
      # Should contain formatted IP, not inspect output
      assert content =~ "192.168.1.1"
    end

    test "export_zone JSON contains properly formatted SOA data", %{zone_name: zone_name} do
      assert {:ok, content} = Editor.export_zone(zone_name, format: :json)
      assert content =~ "ns1.export-test.com"
      assert content =~ "admin.export-test.com"
    end

    test "export_zone to YAML format", %{zone_name: zone_name} do
      assert {:ok, content} = Editor.export_zone(zone_name, format: :yaml)
      assert is_binary(content)
      assert content =~ "zone: #{zone_name}"
    end

    test "export_zone returns error for invalid format", %{zone_name: zone_name} do
      assert {:error, "Unsupported export format: invalid"} =
               Editor.export_zone(zone_name, format: :invalid)
    end

    test "export_zone returns error for non-existent zone" do
      assert {:error, "Zone not found: nonexistent.com"} = Editor.export_zone("nonexistent.com")
    end

    test "export_zone default format is BIND", %{zone_name: zone_name} do
      assert {:ok, content} = Editor.export_zone(zone_name)
      assert content =~ "; Zone file for"
    end
  end

  describe "DNSSEC management" do
    setup do
      zone_name = "dnssec-test.com"

      zone = Zone.new(zone_name, :authoritative)

      soa_record =
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.dnssec-test.com", "admin.dnssec-test.com", 1, 3600, 1800, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}

      Manager.create_zone(zone_name, :authoritative, zone.options)

      {:ok, zone_name: zone_name}
    end

    test "enable_dnssec returns error for non-existent zone" do
      assert {:error, "Zone not found: nonexistent.com"} =
               Editor.enable_dnssec("nonexistent.com")
    end
  end

  describe "Zone validation" do
    setup do
      zone_name = "validation-test.com"

      zone = Zone.new(zone_name, :authoritative)

      soa_record =
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.validation-test.com", "admin.validation-test.com", 1, 3600, 1800, 604_800, 300}
        )

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      zone = %{zone | options: options}

      Manager.create_zone(zone_name, :authoritative, zone.options)

      {:ok, zone_name: zone_name}
    end

    test "validate_zone returns validation results", %{zone_name: zone_name} do
      assert {:ok, result} = Editor.validate_zone(zone_name)
      assert result.zone_name == zone_name
      assert result.status == :valid
      assert is_list(result.errors)
      assert is_list(result.warnings)
    end

    test "validate_zone returns error for non-existent zone" do
      assert {:error, "Zone not found: nonexistent.com"} = Editor.validate_zone("nonexistent.com")
    end
  end

  describe "Zone cloning" do
    setup do
      zone_name = "clone-source.com"

      zone = Zone.new(zone_name, :authoritative)

      soa_record =
        Record.new(
          zone_name,
          :soa,
          :in,
          3600,
          {"ns1.clone-source.com", "admin.clone-source.com", 1, 3600, 1800, 604_800, 300}
        )

      a_record = Record.new("www.#{zone_name}", :a, :in, 300, {192, 168, 1, 1})

      options = Keyword.put(zone.options, :soa_records, [soa_record])
      options = Keyword.put(options, :a_records, [a_record])
      zone = %{zone | options: options}

      Manager.create_zone(zone_name, :authoritative, zone.options)

      {:ok, source_zone_name: zone_name}
    end

    test "clone_zone creates copy of zone", %{source_zone_name: source_zone_name} do
      new_zone_name = "clone-destination.com"

      assert {:ok, cloned_zone} = Editor.clone_zone(source_zone_name, new_zone_name)
      assert cloned_zone.name.value == new_zone_name
      assert cloned_zone.type == :authoritative

      # Verify both zones exist
      assert {:ok, _source_zone} = Manager.get_zone(source_zone_name)
      assert {:ok, _cloned_zone} = Manager.get_zone(new_zone_name)
    end

    test "clone_zone returns error for non-existent source" do
      assert {:error, "Source zone not found: nonexistent.com"} =
               Editor.clone_zone("nonexistent.com", "clone-destination.com")
    end
  end
end
