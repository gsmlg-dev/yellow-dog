defmodule YellowDog.Dns.Zone.StorageTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Zone.Storage

  setup do
    # Clean up any existing tables (only if they exist)
    tables = [:dns_zone_data, :dns_zone_metadata, :dns_zone_index]

    Enum.each(tables, fn table ->
      case :ets.whereis(table) do
        :undefined -> :ok
        _tid -> :ets.delete_all_objects(table)
      end
    end)

    :ok
  end

  describe "init/0" do
    test "initializes ETS tables successfully" do
      assert :ok = Storage.init()

      # Verify tables exist
      assert :ets.whereis(:dns_zone_data) != :undefined
      assert :ets.whereis(:dns_zone_metadata) != :undefined
      assert :ets.whereis(:dns_zone_index) != :undefined
    end

    test "returns error if tables already exist" do
      assert :ok = Storage.init()
      assert {:error, :already_exists} = Storage.init()
    end
  end

  describe "insert_record/6" do
    setup do
      Storage.init()
      :ok
    end

    test "inserts A record successfully" do
      assert :ok =
               Storage.insert_record(
                 "example.com",
                 "www",
                 :A,
                 {192, 168, 1, 10},
                 300,
                 :IN
               )

      assert {:ok, [record]} = Storage.lookup_record("example.com", "www", :A)
      assert record.rdata == {192, 168, 1, 10}
      assert record.ttl == 300
      assert record.class == :IN
    end

    test "inserts MX record successfully" do
      assert :ok =
               Storage.insert_record(
                 "example.com",
                 "@",
                 :MX,
                 {10, "mail.example.com"},
                 600,
                 :IN
               )

      assert {:ok, [record]} = Storage.lookup_record("example.com", "@", :MX)
      assert record.rdata == {10, "mail.example.com"}
      assert record.ttl == 600
    end

    test "normalizes zone names" do
      Storage.insert_record("Example.COM", "www", :A, {192, 168, 1, 10})

      assert {:ok, _} = Storage.lookup_record("example.com", "www", :A)
      assert {:ok, _} = Storage.lookup_record("EXAMPLE.COM", "www", :A)
    end

    test "uses default TTL when not specified" do
      Storage.insert_record("example.com", "test", :A, {10, 0, 0, 1})

      assert {:ok, [record]} = Storage.lookup_record("example.com", "test", :A)
      assert record.ttl == 3600
    end
  end

  describe "lookup_record/3" do
    setup do
      Storage.init()
      Storage.insert_record("example.com", "www", :A, {192, 168, 1, 10}, 300)
      :ok
    end

    test "finds existing record" do
      assert {:ok, [record]} = Storage.lookup_record("example.com", "www", :A)
      assert record.rdata == {192, 168, 1, 10}
    end

    test "returns error for non-existent record" do
      assert {:error, :not_found} = Storage.lookup_record("example.com", "notexist", :A)
    end

    test "returns error for non-existent zone" do
      assert {:error, :not_found} = Storage.lookup_record("notexist.com", "www", :A)
    end

    test "case-insensitive lookup" do
      assert {:ok, _} = Storage.lookup_record("EXAMPLE.COM", "WWW", :A)
      assert {:ok, _} = Storage.lookup_record("Example.Com", "Www", :A)
    end
  end

  describe "delete_record/3" do
    setup do
      Storage.init()
      Storage.insert_record("example.com", "www", :A, {192, 168, 1, 10})
      Storage.insert_record("example.com", "mail", :A, {192, 168, 1, 20})
      :ok
    end

    test "deletes existing record" do
      assert :ok = Storage.delete_record("example.com", "www", :A)
      assert {:error, :not_found} = Storage.lookup_record("example.com", "www", :A)

      # Other records remain
      assert {:ok, _} = Storage.lookup_record("example.com", "mail", :A)
    end

    test "deleting non-existent record succeeds" do
      assert :ok = Storage.delete_record("example.com", "notexist", :A)
    end
  end

  describe "zone metadata" do
    setup do
      Storage.init()
      :ok
    end

    test "stores and retrieves zone metadata" do
      metadata = %{
        type: :master,
        file: "zones/example.com.zone",
        serial: 2024102801,
        loaded_at: System.system_time(:second)
      }

      assert :ok = Storage.put_zone_metadata("example.com", metadata)
      assert {:ok, ^metadata} = Storage.get_zone_metadata("example.com")
    end

    test "returns error for non-existent zone metadata" do
      assert {:error, :not_found} = Storage.get_zone_metadata("notexist.com")
    end

    test "updates existing metadata" do
      metadata1 = %{type: :master, serial: 1}
      metadata2 = %{type: :slave, serial: 2}

      Storage.put_zone_metadata("example.com", metadata1)
      Storage.put_zone_metadata("example.com", metadata2)

      assert {:ok, ^metadata2} = Storage.get_zone_metadata("example.com")
    end
  end

  describe "list_zones/0" do
    setup do
      Storage.init()
      :ok
    end

    test "returns empty list when no zones loaded" do
      assert {:ok, []} = Storage.list_zones()
    end

    test "lists all loaded zones" do
      Storage.put_zone_metadata("example.com", %{type: :master})
      Storage.put_zone_metadata("test.com", %{type: :slave})

      assert {:ok, zones} = Storage.list_zones()
      assert length(zones) == 2
      assert "example.com" in zones
      assert "test.com" in zones
    end
  end

  describe "list_zone_records/1" do
    setup do
      Storage.init()

      Storage.insert_record("example.com", "www", :A, {192, 168, 1, 10})
      Storage.insert_record("example.com", "mail", :A, {192, 168, 1, 20})
      Storage.insert_record("example.com", "@", :MX, {10, "mail.example.com"})

      :ok
    end

    test "lists all records for a zone" do
      assert {:ok, records} = Storage.list_zone_records("example.com")
      assert length(records) == 3

      owners = Enum.map(records, & &1.owner)
      assert "www" in owners
      assert "mail" in owners
      assert "@" in owners
    end

    test "returns empty list for zone with no records" do
      assert {:ok, []} = Storage.list_zone_records("empty.com")
    end
  end

  describe "delete_zone/1" do
    setup do
      Storage.init()

      Storage.insert_record("example.com", "www", :A, {192, 168, 1, 10})
      Storage.insert_record("example.com", "mail", :A, {192, 168, 1, 20})
      Storage.put_zone_metadata("example.com", %{type: :master})

      Storage.insert_record("test.com", "www", :A, {10, 0, 0, 1})
      Storage.put_zone_metadata("test.com", %{type: :master})

      :ok
    end

    test "deletes all records and metadata for zone" do
      assert :ok = Storage.delete_zone("example.com")

      assert {:ok, []} = Storage.list_zone_records("example.com")
      assert {:error, :not_found} = Storage.get_zone_metadata("example.com")

      # Other zones remain
      assert {:ok, [_]} = Storage.list_zone_records("test.com")
      assert {:ok, _} = Storage.get_zone_metadata("test.com")
    end

    test "deleting non-existent zone succeeds" do
      assert :ok = Storage.delete_zone("notexist.com")
    end
  end

  describe "zone_exists?/1" do
    setup do
      Storage.init()
      Storage.put_zone_metadata("example.com", %{type: :master})
      :ok
    end

    test "returns true for existing zone" do
      assert Storage.zone_exists?("example.com")
    end

    test "returns false for non-existent zone" do
      refute Storage.zone_exists?("notexist.com")
    end
  end

  describe "get_zone_stats/1" do
    setup do
      Storage.init()

      Storage.put_zone_metadata("example.com", %{
        type: :master,
        serial: 2024102801,
        loaded_at: 1_234_567_890
      })

      Storage.insert_record("example.com", "www", :A, {192, 168, 1, 10})
      Storage.insert_record("example.com", "mail", :A, {192, 168, 1, 20})

      :ok
    end

    test "returns zone statistics" do
      assert {:ok, stats} = Storage.get_zone_stats("example.com")

      assert stats.zone == "example.com"
      assert stats.type == :master
      assert stats.serial == 2024102801
      assert stats.record_count == 2
      assert stats.loaded_at == 1_234_567_890
    end

    test "returns error for non-existent zone" do
      assert {:error, :not_found} = Storage.get_zone_stats("notexist.com")
    end
  end

  describe "stats/0" do
    setup do
      Storage.init()

      Storage.put_zone_metadata("example.com", %{type: :master})
      Storage.put_zone_metadata("test.com", %{type: :master})

      Storage.insert_record("example.com", "www", :A, {192, 168, 1, 10})
      Storage.insert_record("example.com", "mail", :A, {192, 168, 1, 20})
      Storage.insert_record("test.com", "www", :A, {10, 0, 0, 1})

      :ok
    end

    test "returns global storage statistics" do
      stats = Storage.stats()

      assert stats.total_zones == 2
      assert stats.total_records == 3
      assert stats.memory_bytes > 0
      assert stats.memory_mb >= 0
    end
  end
end
