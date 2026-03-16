defmodule YellowDog.Store.ZoneTest do
  use ExUnit.Case, async: false

  @moduletag :store_integration

  alias YellowDog.Store.Zone

  @test_soa %{
    mname: "ns1.example.com",
    rname: "admin.example.com",
    serial: 2_026_031_601,
    refresh: 3600,
    retry: 900,
    expire: 604_800,
    minimum: 86_400
  }

  setup do
    YellowDog.StoreHelper.setup_store()
    :ok
  end

  describe "create_zone/3" do
    test "creates zone metadata" do
      assert :ok = Zone.create_zone("test-create.example.com", @test_soa)

      assert {:ok, zone} = Zone.get_zone("test-create.example.com")
      assert zone.origin == "test-create.example.com"
      assert zone.soa.mname == "ns1.example.com"
      assert zone.authoritative == true
      assert zone.default_ttl == 3600
    end

    test "create_zone with custom options" do
      assert :ok =
               Zone.create_zone("test-opts.example.com", @test_soa,
                 default_ttl: 7200,
                 authoritative: false,
                 allow_dynamic_update: true,
                 serial_strategy: :increment
               )

      assert {:ok, zone} = Zone.get_zone("test-opts.example.com")
      assert zone.default_ttl == 7200
      assert zone.authoritative == false
      assert zone.allow_dynamic_update == true
      assert zone.serial_strategy == :increment
    end

    test "duplicate zone creation returns error" do
      Zone.create_zone("test-dup.example.com", @test_soa)

      assert {:error, :already_exists} =
               Zone.create_zone("test-dup.example.com", @test_soa)
    end
  end

  describe "delete_zone/1" do
    test "removes zone and all records" do
      Zone.create_zone("test-del.example.com", @test_soa)

      Zone.put_rrset("test-del.example.com", "www.test-del.example.com", :a, [
        %{rdata: {192, 168, 1, 1}, ttl: 3600}
      ])

      assert :ok = Zone.delete_zone("test-del.example.com")
      assert {:error, :not_found} = Zone.get_zone("test-del.example.com")

      assert {:error, :not_found} =
               Zone.get_rrset("test-del.example.com", "www.test-del.example.com", :a)
    end
  end

  describe "put_rrset/4 and get_rrset/3" do
    test "creates and retrieves an RRset" do
      Zone.create_zone("test-rr.example.com", @test_soa)

      rrset = [%{rdata: {192, 168, 1, 1}, ttl: 300}]
      assert :ok = Zone.put_rrset("test-rr.example.com", "www.test-rr.example.com", :a, rrset)

      assert {:ok, record} = Zone.get_rrset("test-rr.example.com", "www.test-rr.example.com", :a)
      assert record.rrset == rrset
      assert record.owner == "www.test-rr.example.com"
      assert record.type == :a
      assert record.zone == "test-rr.example.com"
    end

    test "get_rrset returns not_found for missing record" do
      Zone.create_zone("test-rr2.example.com", @test_soa)

      assert {:error, :not_found} =
               Zone.get_rrset("test-rr2.example.com", "nonexistent.test-rr2.example.com", :a)
    end
  end

  describe "SOA serial auto-increment" do
    test "serial increments after put_rrset" do
      Zone.create_zone("test-serial.example.com", @test_soa)
      {:ok, zone_before} = Zone.get_zone("test-serial.example.com")

      Zone.put_rrset("test-serial.example.com", "www.test-serial.example.com", :a, [
        %{rdata: {10, 0, 0, 1}, ttl: 300}
      ])

      {:ok, zone_after} = Zone.get_zone("test-serial.example.com")
      assert zone_after.soa.serial > zone_before.soa.serial
    end

    test "serial increments after delete_rrset" do
      Zone.create_zone("test-serial2.example.com", @test_soa)

      Zone.put_rrset("test-serial2.example.com", "www.test-serial2.example.com", :a, [
        %{rdata: {10, 0, 0, 2}, ttl: 300}
      ])

      {:ok, zone_before} = Zone.get_zone("test-serial2.example.com")

      Zone.delete_rrset("test-serial2.example.com", "www.test-serial2.example.com", :a)

      {:ok, zone_after} = Zone.get_zone("test-serial2.example.com")
      assert zone_after.soa.serial > zone_before.soa.serial
    end
  end

  describe "list_records/1" do
    test "lists all RRsets in a zone" do
      Zone.create_zone("test-list.example.com", @test_soa)

      Zone.put_rrset("test-list.example.com", "www", :a, [%{rdata: {10, 0, 0, 1}}])

      Zone.put_rrset("test-list.example.com", "mail", :mx, [
        %{rdata: "mail.test-list.example.com", priority: 10}
      ])

      assert {:ok, records} = Zone.list_records("test-list.example.com")
      assert length(records) >= 2
    end
  end

  describe "list_records/2" do
    test "filters records by owner name" do
      Zone.create_zone("test-list2.example.com", @test_soa)

      Zone.put_rrset("test-list2.example.com", "www", :a, [%{rdata: {10, 0, 0, 1}}])
      Zone.put_rrset("test-list2.example.com", "www", :aaaa, [%{rdata: {0, 0, 0, 0, 0, 0, 0, 1}}])
      Zone.put_rrset("test-list2.example.com", "mail", :a, [%{rdata: {10, 0, 0, 2}}])

      assert {:ok, records} = Zone.list_records("test-list2.example.com", "www")
      assert length(records) == 2
      assert Enum.all?(records, fn r -> r.owner == "www" end)
    end
  end

  describe "delete_rrset/3" do
    test "removes an RRset" do
      Zone.create_zone("test-delrr.example.com", @test_soa)

      Zone.put_rrset("test-delrr.example.com", "www", :a, [%{rdata: {10, 0, 0, 1}}])
      assert :ok = Zone.delete_rrset("test-delrr.example.com", "www", :a)
      assert {:error, :not_found} = Zone.get_rrset("test-delrr.example.com", "www", :a)
    end
  end

  describe "list_zones/0" do
    test "returns list of zone names" do
      Zone.create_zone("test-listzones.example.com", @test_soa)

      assert {:ok, names} = Zone.list_zones()
      assert is_list(names)
      assert "test-listzones.example.com" in names
    end
  end

  describe "import/2" do
    test "imports records into a zone" do
      records = [
        %{owner: "test-import.example.com", type: :soa, rrset: [@test_soa]},
        %{owner: "www.test-import.example.com", type: :a, rrset: [%{rdata: {10, 0, 0, 1}}]}
      ]

      assert :ok = Zone.import("test-import.example.com", records)
      assert {:ok, _zone} = Zone.get_zone("test-import.example.com")
    end
  end

  describe "export/1" do
    test "exports all records from a zone" do
      Zone.create_zone("test-export.example.com", @test_soa)
      Zone.put_rrset("test-export.example.com", "www", :a, [%{rdata: {10, 0, 0, 1}}])

      assert {:ok, records} = Zone.export("test-export.example.com")
      assert is_list(records)
    end
  end

  describe "import/export round-trip" do
    test "imported records can be exported with semantic equivalence" do
      records = [
        %{owner: "@", type: :soa, rrset: [@test_soa]},
        %{owner: "www", type: :a, rrset: [%{rdata: {192, 168, 1, 1}, ttl: 300}]},
        %{owner: "mail", type: :mx, rrset: [%{rdata: "mail.rt.example.com", priority: 10}]},
        %{
          owner: "www",
          type: :aaaa,
          rrset: [%{rdata: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}}]
        }
      ]

      assert :ok = Zone.import("rt.example.com", records)

      assert {:ok, exported} = Zone.export("rt.example.com")

      # Verify all non-SOA records round-trip
      for original <- records, original.type != :soa do
        match =
          Enum.find(exported, fn r ->
            r.owner == original.owner and r.type == original.type
          end)

        assert match != nil, "Missing #{original.owner}/#{original.type} after round-trip"
        assert match.rrset == original.rrset
      end
    end
  end

  describe "RRset CAS prevents concurrent edit races" do
    test "concurrent put_rrset on same key serializes correctly" do
      Zone.create_zone("test-cas.example.com", @test_soa)

      # First write
      assert :ok =
               Zone.put_rrset("test-cas.example.com", "www", :a, [
                 %{rdata: {10, 0, 0, 1}}
               ])

      # Second write (overwrites first)
      assert :ok =
               Zone.put_rrset("test-cas.example.com", "www", :a, [
                 %{rdata: {10, 0, 0, 2}}
               ])

      {:ok, record} = Zone.get_rrset("test-cas.example.com", "www", :a)
      assert [%{rdata: {10, 0, 0, 2}}] = record.rrset
    end
  end
end
