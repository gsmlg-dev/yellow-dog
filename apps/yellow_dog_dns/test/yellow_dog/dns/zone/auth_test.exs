defmodule YellowDog.Dns.Zone.AuthTest do
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Zone.Auth

  setup_all do
    # Start the ZoneRegistry once for all tests
    {:ok, _registry_pid} = Registry.start_link(keys: :unique, name: YellowDog.Dns.ZoneRegistry)
    :ok
  end

  setup do
    # Start an auth zone for testing with a unique name to avoid conflicts
    zone_name = "example-#{System.unique_integer([:positive])}.com"
    {:ok, pid} = Auth.start_link(name: zone_name, records: [])

    on_exit(fn ->
      # Gracefully stop the zone process, catching any errors from already-stopped processes
      try do
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal, 1000)
        end
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, zone: pid, zone_name: zone_name}
  end

  describe "add_record/2 with atom types" do
    test "adds A record with string name and atom type", %{zone: pid} do
      record = %{
        name: "www.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      }

      assert :ok = Auth.add_record(pid, record)

      records = Auth.get_all_records(pid)
      assert length(records) == 1

      [added] = records
      assert added.name == "www.example.com"
      assert added.type == :a
    end

    test "adds AAAA record", %{zone: pid} do
      record = %{
        name: "ipv6.example.com",
        type: :aaaa,
        class: :in,
        ttl: 3600,
        rdata: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      }

      assert :ok = Auth.add_record(pid, record)

      records = Auth.get_all_records(pid)
      assert length(records) == 1
    end

    test "adds multiple records", %{zone: pid} do
      records = [
        %{name: "www.example.com", type: :a, class: :in, ttl: 3600, rdata: {192, 0, 2, 1}},
        %{name: "mail.example.com", type: :a, class: :in, ttl: 3600, rdata: {192, 0, 2, 2}},
        %{name: "example.com", type: :mx, class: :in, ttl: 3600, rdata: {10, "mail.example.com"}}
      ]

      for record <- records do
        assert :ok = Auth.add_record(pid, record)
      end

      all_records = Auth.get_all_records(pid)
      assert length(all_records) == 3
    end
  end

  describe "add_record/2 with DNS.Message.Record struct" do
    test "adds record using DNS.Message.Record.new/5", %{zone: pid} do
      record = DNS.Message.Record.new("test.example.com", :a, :in, 3600, {10, 0, 0, 1})

      assert :ok = Auth.add_record(pid, record)

      records = Auth.get_all_records(pid)
      assert length(records) == 1
    end

    test "adds record with Domain struct name", %{zone: pid} do
      domain = DNS.Message.Domain.new("api.example.com")

      record = %{
        name: domain,
        type: :a,
        class: :in,
        ttl: 300,
        rdata: {10, 0, 0, 2}
      }

      assert :ok = Auth.add_record(pid, record)

      records = Auth.get_all_records(pid)
      assert length(records) == 1
    end

    test "adds record with RRType struct", %{zone: pid} do
      rtype = DNS.ResourceRecordType.new(:a)

      record = %{
        name: "rtype.example.com",
        type: rtype,
        class: :in,
        ttl: 300,
        rdata: {10, 0, 0, 3}
      }

      assert :ok = Auth.add_record(pid, record)

      records = Auth.get_all_records(pid)
      assert length(records) == 1
    end

    test "adds record with both Domain and RRType structs", %{zone: pid} do
      domain = DNS.Message.Domain.new("full.example.com")
      rtype = DNS.ResourceRecordType.new(:aaaa)

      record = %{
        name: domain,
        type: rtype,
        class: :in,
        ttl: 600,
        rdata: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 0x100}
      }

      assert :ok = Auth.add_record(pid, record)

      records = Auth.get_all_records(pid)
      assert length(records) == 1
    end
  end

  describe "get_records/3" do
    test "retrieves specific record by name and type", %{zone: pid} do
      Auth.add_record(pid, %{
        name: "www.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      Auth.add_record(pid, %{
        name: "www.example.com",
        type: :aaaa,
        class: :in,
        ttl: 3600,
        rdata: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
      })

      a_records = Auth.get_records(pid, "www.example.com", :a)
      assert length(a_records) == 1

      aaaa_records = Auth.get_records(pid, "www.example.com", :aaaa)
      assert length(aaaa_records) == 1
    end

    test "retrieves all records for a name with :any type", %{zone: pid} do
      Auth.add_record(pid, %{
        name: "multi.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      Auth.add_record(pid, %{
        name: "multi.example.com",
        type: :txt,
        class: :in,
        ttl: 3600,
        rdata: "test record"
      })

      all_records = Auth.get_records(pid, "multi.example.com", :any)
      assert length(all_records) == 2
    end

    test "returns empty list for non-existent name", %{zone: pid} do
      records = Auth.get_records(pid, "nonexistent.example.com", :a)
      assert records == []
    end
  end

  describe "remove_record/3" do
    test "removes a record by name and type", %{zone: pid} do
      Auth.add_record(pid, %{
        name: "temp.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      assert length(Auth.get_all_records(pid)) == 1

      :ok = Auth.remove_record(pid, "temp.example.com", :a)

      assert length(Auth.get_all_records(pid)) == 0
    end

    test "only removes matching type", %{zone: pid} do
      Auth.add_record(pid, %{
        name: "mixed.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      Auth.add_record(pid, %{
        name: "mixed.example.com",
        type: :txt,
        class: :in,
        ttl: 3600,
        rdata: "keep me"
      })

      :ok = Auth.remove_record(pid, "mixed.example.com", :a)

      records = Auth.get_all_records(pid)
      assert length(records) == 1
      assert hd(records).type == :txt
    end
  end

  describe "name normalization" do
    test "normalizes names with trailing dots", %{zone: pid} do
      Auth.add_record(pid, %{
        name: "trailing.example.com.",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      # Should be able to retrieve without trailing dot
      records = Auth.get_records(pid, "trailing.example.com", :a)
      assert length(records) == 1
    end

    test "normalizes case-insensitive names", %{zone: pid} do
      Auth.add_record(pid, %{
        name: "UPPERCASE.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      # Should be able to retrieve with lowercase
      records = Auth.get_records(pid, "uppercase.example.com", :a)
      assert length(records) == 1
    end
  end

  describe "stats/1" do
    test "returns zone statistics", %{zone: pid, zone_name: zone_name} do
      Auth.add_record(pid, %{
        name: "stat.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      stats = Auth.stats(pid)

      assert stats.name == zone_name
      assert stats.record_count >= 1
      assert is_integer(stats.query_count)
      assert is_integer(stats.hit_count)
      assert is_integer(stats.miss_count)
    end
  end

  describe "dirty?/1" do
    test "marks zone as dirty after adding record", %{zone: pid} do
      refute Auth.dirty?(pid)

      Auth.add_record(pid, %{
        name: "dirty.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      assert Auth.dirty?(pid)
    end
  end

  describe "version metadata" do
    test "get_version/1 returns initial version", %{zone: pid} do
      assert Auth.get_version(pid) == 1
    end

    test "version increments on add_record", %{zone: pid} do
      initial_version = Auth.get_version(pid)

      Auth.add_record(pid, %{
        name: "v1.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      assert Auth.get_version(pid) == initial_version + 1
    end

    test "version increments on remove_record", %{zone: pid} do
      Auth.add_record(pid, %{
        name: "removeme.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      version_after_add = Auth.get_version(pid)

      Auth.remove_record(pid, "removeme.example.com", :a)

      assert Auth.get_version(pid) == version_after_add + 1
    end

    test "get_metadata/1 returns version info", %{zone: pid} do
      metadata = Auth.get_metadata(pid)

      assert metadata.version == 1
      assert metadata.updated_at == nil
      assert %DateTime{} = metadata.created_at
      assert metadata.dirty == false
    end

    test "updated_at is set after modification", %{zone: pid} do
      assert Auth.get_metadata(pid).updated_at == nil

      Auth.add_record(pid, %{
        name: "update.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      metadata = Auth.get_metadata(pid)
      assert %DateTime{} = metadata.updated_at
    end

    test "stats includes version info", %{zone: pid, zone_name: zone_name} do
      Auth.add_record(pid, %{
        name: "stat.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      stats = Auth.stats(pid)

      assert stats.version == 2
      assert %DateTime{} = stats.updated_at
    end
  end

  describe "versioned operations" do
    test "add_record_versioned succeeds with correct version", %{zone: pid} do
      current_version = Auth.get_version(pid)

      assert {:ok, new_version} =
               Auth.add_record_versioned(
                 pid,
                 %{
                   name: "versioned.example.com",
                   type: :a,
                   class: :in,
                   ttl: 3600,
                   rdata: {192, 0, 2, 1}
                 },
                 current_version
               )

      assert new_version == current_version + 1
      assert Auth.get_version(pid) == new_version
    end

    test "add_record_versioned fails with stale version", %{zone: pid} do
      stale_version = Auth.get_version(pid) - 1

      assert {:error, :version_conflict} =
               Auth.add_record_versioned(
                 pid,
                 %{
                   name: "stale.example.com",
                   type: :a,
                   class: :in,
                   ttl: 3600,
                   rdata: {192, 0, 2, 1}
                 },
                 stale_version
               )

      # Version should not have changed
      assert Auth.get_version(pid) == 1
    end

    test "add_record_versioned fails after concurrent modification", %{zone: pid} do
      version_before = Auth.get_version(pid)

      # Simulate concurrent modification
      Auth.add_record(pid, %{
        name: "concurrent.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      # Now try versioned add with old version
      assert {:error, :version_conflict} =
               Auth.add_record_versioned(
                 pid,
                 %{
                   name: "delayed.example.com",
                   type: :a,
                   class: :in,
                   ttl: 3600,
                   rdata: {192, 0, 2, 2}
                 },
                 version_before
               )
    end

    test "remove_record_versioned succeeds with correct version", %{zone: pid} do
      Auth.add_record(pid, %{
        name: "toremove.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      current_version = Auth.get_version(pid)

      assert {:ok, new_version} =
               Auth.remove_record_versioned(pid, "toremove.example.com", :a, current_version)

      assert new_version == current_version + 1
    end

    test "remove_record_versioned fails with stale version", %{zone: pid} do
      Auth.add_record(pid, %{
        name: "keepme.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 0, 2, 1}
      })

      stale_version = Auth.get_version(pid) - 1

      assert {:error, :version_conflict} =
               Auth.remove_record_versioned(pid, "keepme.example.com", :a, stale_version)

      # Record should still exist
      assert length(Auth.get_records(pid, "keepme.example.com", :a)) == 1
    end
  end
end
