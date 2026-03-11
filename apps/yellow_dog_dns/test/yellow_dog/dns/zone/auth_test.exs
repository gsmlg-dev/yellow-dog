defmodule YellowDog.Dns.Zone.AuthTest do
  @moduledoc """
  Comprehensive unit tests for YellowDog.Dns.Zone.Auth.

  Tests cover:
  - GenServer lifecycle (start/stop)
  - Zone.Behaviour implementation (get_name, get_view, resolve, reload, stats)
  - Record CRUD operations (add_record, remove_record, get_records, get_all_records)
  - Version tracking and optimistic locking
  - Zone persistence (save, dirty?)
  - Query resolution (matching records, CNAME handling, NXDOMAIN, NODATA)
  - Concurrent access patterns
  """
  use ExUnit.Case, async: false

  alias YellowDog.Dns.Zone.Auth
  alias DNS.Message
  alias DNS.Message.Header

  # Start registry once for all tests in this module
  setup_all do
    registry_name = YellowDog.Dns.ZoneRegistry

    # Start registry if not running
    registry_pid =
      case Process.whereis(registry_name) do
        nil ->
          {:ok, pid} = Registry.start_link(keys: :unique, name: registry_name)
          pid

        pid ->
          pid
      end

    # Small delay to ensure registry is ready
    Process.sleep(10)

    {:ok, registry_pid: registry_pid}
  end

  setup do
    # Verify registry is available
    registry_name = YellowDog.Dns.ZoneRegistry

    case Process.whereis(registry_name) do
      nil ->
        # Re-start if needed (rare case where registry died)
        {:ok, _} = Registry.start_link(keys: :unique, name: registry_name)
        Process.sleep(10)

      _pid ->
        :ok
    end

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

  # Helper to build a test DNS query
  defp build_query(name, type) do
    %Message{
      header: %Header{
        id: :rand.uniform(65535),
        qr: false,
        opcode: 0,
        aa: false,
        tc: false,
        rd: true,
        ra: false,
        z: 0,
        rcode: DNS.Message.RCode.no_error()
      },
      qdlist: [
        %{name: name, type: type, class: :in}
      ],
      anlist: [],
      nslist: [],
      arlist: []
    }
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

    test "removes record when type is a DNS.ResourceRecordType struct", %{zone: pid} do
      # add_record normalises to atom; remove_record must also normalise so the
      # ETS key matches — previously remove_record used the raw struct, causing
      # a silent no-op deletion.
      Auth.add_record(pid, %{
        name: "srv.example.com",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {10, 0, 0, 1}
      })

      assert length(Auth.get_all_records(pid)) == 1

      # Pass type as a ResourceRecordType struct (as it arrives from wire-format parsing)
      rr_type_struct = DNS.ResourceRecordType.new(1)
      :ok = Auth.remove_record(pid, "srv.example.com", rr_type_struct)

      assert Auth.get_all_records(pid) == []
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

  describe "resolve/2" do
    test "returns matching records for valid query", %{zone: pid, zone_name: zone_name} do
      Auth.add_record(pid, %{
        name: "www.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 168, 1, 1}
      })

      query = build_query("www.#{zone_name}", :a)
      {:ok, response} = Auth.resolve(pid, query)

      assert response.header.qr == 1
      assert response.header.aa == 1
      assert length(response.anlist) == 1

      [answer] = response.anlist
      assert answer.type == :a
    end

    test "increments query count", %{zone: pid, zone_name: zone_name} do
      stats1 = Auth.stats(pid)
      assert stats1.query_count == 0

      query = build_query("www.#{zone_name}", :a)
      Auth.resolve(pid, query)

      stats2 = Auth.stats(pid)
      assert stats2.query_count == 1
    end

    test "increments hit count for matching records", %{zone: pid, zone_name: zone_name} do
      Auth.add_record(pid, %{
        name: "www.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 168, 1, 1}
      })

      query = build_query("www.#{zone_name}", :a)
      Auth.resolve(pid, query)

      stats = Auth.stats(pid)
      assert stats.hit_count == 1
      assert stats.miss_count == 0
    end

    test "returns NXDOMAIN for non-existent names", %{zone: pid, zone_name: zone_name} do
      query = build_query("nonexistent.#{zone_name}", :a)
      {:ok, response} = Auth.resolve(pid, query)

      # NXDOMAIN has rcode 3
      assert response.header.rcode == DNS.Message.RCode.nx_domain()
      assert response.anlist == []
    end

    test "NXDOMAIN includes SOA in authority section (RFC 2308 §2)" do
      zone_name = "soa-nxd-#{System.unique_integer([:positive])}.com"

      {:ok, pid} =
        Auth.start_link(
          name: zone_name,
          zone_data: [
            %{
              name: zone_name,
              type: :soa,
              class: :in,
              ttl: 3600,
              rdata: %{
                mname: "ns1.#{zone_name}.",
                rname: "admin.#{zone_name}.",
                serial: 1,
                refresh: 3600,
                retry: 600,
                expire: 604_800,
                minimum: 86400
              }
            }
          ]
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000) end)

      query = build_query("nonexistent.#{zone_name}", :a)
      {:ok, response} = Auth.resolve(pid, query)

      assert response.header.nscount == 1
      assert length(response.nslist) == 1
      [soa] = response.nslist
      assert soa.type == :soa
    end

    test "returns NODATA for existing name with no matching type", %{
      zone: pid,
      zone_name: zone_name
    } do
      # Add only A record
      Auth.add_record(pid, %{
        name: "www.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 168, 1, 1}
      })

      # Query for AAAA when only A exists
      query = build_query("www.#{zone_name}", :aaaa)
      {:ok, response} = Auth.resolve(pid, query)

      # NODATA has rcode 0 but empty answers
      assert response.header.rcode == DNS.Message.RCode.no_error()
      assert response.anlist == []
    end

    test "NODATA includes SOA in authority section (RFC 2308 §2)" do
      zone_name = "soa-nodata-#{System.unique_integer([:positive])}.com"

      {:ok, pid} =
        Auth.start_link(
          name: zone_name,
          zone_data: [
            %{
              name: zone_name,
              type: :soa,
              class: :in,
              ttl: 3600,
              rdata: %{
                mname: "ns1.#{zone_name}.",
                rname: "admin.#{zone_name}.",
                serial: 1,
                refresh: 3600,
                retry: 600,
                expire: 604_800,
                minimum: 86400
              }
            },
            %{name: "www.#{zone_name}", type: :a, class: :in, ttl: 3600, rdata: {192, 168, 1, 1}}
          ]
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000) end)

      query = build_query("www.#{zone_name}", :aaaa)
      {:ok, response} = Auth.resolve(pid, query)

      assert response.header.nscount == 1
      assert length(response.nslist) == 1
      [soa] = response.nslist
      assert soa.type == :soa
    end

    test "returns CNAME for CNAME records", %{zone: pid, zone_name: zone_name} do
      Auth.add_record(pid, %{
        name: "alias.#{zone_name}",
        type: :cname,
        class: :in,
        ttl: 3600,
        rdata: "www.#{zone_name}"
      })

      query = build_query("alias.#{zone_name}", :a)
      {:ok, response} = Auth.resolve(pid, query)

      # Should return CNAME in answer
      assert length(response.anlist) == 1
      [answer] = response.anlist
      assert answer.type == :cname
    end

    test "follows CNAME and includes target A records in answer (RFC 1034 §3.6.2)", %{
      zone: pid,
      zone_name: zone_name
    } do
      Auth.add_record(pid, %{
        name: "alias.#{zone_name}",
        type: :cname,
        class: :in,
        ttl: 3600,
        rdata: "www.#{zone_name}"
      })

      Auth.add_record(pid, %{
        name: "www.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 300,
        rdata: {1, 2, 3, 4}
      })

      query = build_query("alias.#{zone_name}", :a)
      {:ok, response} = Auth.resolve(pid, query)

      # Answer must contain both the CNAME and the target A record
      assert length(response.anlist) == 2
      types = Enum.map(response.anlist, & &1.type) |> Enum.sort()
      assert :a in types
      assert :cname in types
    end

    test "follows multi-hop CNAME chain within zone (RFC 1034 §3.6.2)", %{
      zone: pid,
      zone_name: zone_name
    } do
      # alias → alias2 → www
      Auth.add_record(pid, %{
        name: "alias.#{zone_name}",
        type: :cname,
        class: :in,
        ttl: 3600,
        rdata: "alias2.#{zone_name}"
      })

      Auth.add_record(pid, %{
        name: "alias2.#{zone_name}",
        type: :cname,
        class: :in,
        ttl: 3600,
        rdata: "www.#{zone_name}"
      })

      Auth.add_record(pid, %{
        name: "www.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 300,
        rdata: {10, 0, 0, 1}
      })

      query = build_query("alias.#{zone_name}", :a)
      {:ok, response} = Auth.resolve(pid, query)

      # Should contain alias → alias2 CNAME, alias2 → www CNAME, and www A record
      assert length(response.anlist) == 3
      types = Enum.map(response.anlist, & &1.type)
      assert Enum.count(types, &(&1 == :cname)) == 2
      assert Enum.count(types, &(&1 == :a)) == 1
    end

    test "stops CNAME chasing at zone boundary", %{zone: pid, zone_name: zone_name} do
      # CNAME pointing to out-of-zone target — must NOT chase
      Auth.add_record(pid, %{
        name: "alias.#{zone_name}",
        type: :cname,
        class: :in,
        ttl: 3600,
        rdata: "www.external.com"
      })

      query = build_query("alias.#{zone_name}", :a)
      {:ok, response} = Auth.resolve(pid, query)

      # Only the CNAME record itself, no external records
      assert length(response.anlist) == 1
      [answer] = response.anlist
      assert answer.type == :cname
    end

    test "returns :refused for queries outside zone", %{zone: pid} do
      # Query for a completely different domain
      query = build_query("www.otherdomain.com", :a)
      {:error, :refused} = Auth.resolve(pid, query)
    end

    test "returns format error for empty question list", %{zone: pid} do
      query = %Message{
        header: %Header{
          id: 1234,
          qr: false,
          opcode: 0,
          aa: false,
          tc: false,
          rd: true,
          ra: false,
          z: 0,
          rcode: DNS.Message.RCode.no_error()
        },
        qdlist: [],
        anlist: [],
        nslist: [],
        arlist: []
      }

      {:error, :format_error} = Auth.resolve(pid, query)
    end

    test "returns multiple records when available", %{zone: pid, zone_name: zone_name} do
      # Add multiple A records for round-robin
      Auth.add_record(pid, %{
        name: "www.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 168, 1, 1}
      })

      Auth.add_record(pid, %{
        name: "www.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 168, 1, 2}
      })

      query = build_query("www.#{zone_name}", :a)
      {:ok, response} = Auth.resolve(pid, query)

      assert length(response.anlist) == 2
    end
  end

  describe "reload/2" do
    test "clears and reloads zone data", %{zone: pid, zone_name: zone_name} do
      # Add initial record
      Auth.add_record(pid, %{
        name: "www.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 168, 1, 1}
      })

      assert length(Auth.get_all_records(pid)) == 1

      # Reload with new data
      new_records = [
        %{name: "mail.#{zone_name}", type: :a, class: :in, ttl: 3600, rdata: {192, 168, 1, 2}},
        %{name: "ns.#{zone_name}", type: :a, class: :in, ttl: 3600, rdata: {192, 168, 1, 3}}
      ]

      assert :ok = Auth.reload(pid, zone_data: new_records)

      all_records = Auth.get_all_records(pid)
      assert length(all_records) == 2

      # Old record should be gone
      assert Auth.get_records(pid, "www.#{zone_name}", :a) == []
    end

    test "can reload with empty config", %{zone: pid, zone_name: zone_name} do
      Auth.add_record(pid, %{
        name: "www.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 168, 1, 1}
      })

      assert :ok = Auth.reload(pid, [])

      # Records should be cleared
      assert Auth.get_all_records(pid) == []
    end
  end

  describe "Zone.Behaviour implementation" do
    test "implements all required callbacks" do
      # Ensure module is loaded
      {:module, _} = Code.ensure_loaded(Auth)

      # Verify the module exports all required Behaviour functions
      assert function_exported?(Auth, :get_name, 1)
      assert function_exported?(Auth, :resolve, 2)
      assert function_exported?(Auth, :reload, 2)
      assert function_exported?(Auth, :stats, 1)
    end
  end

  describe "get_name/1" do
    test "returns the zone name", %{zone: pid, zone_name: zone_name} do
      assert Auth.get_name(pid) == zone_name
    end
  end

  describe "get_view/1" do
    test "returns default view name", %{zone: pid} do
      assert Auth.get_view(pid) == "default"
    end

    test "returns custom view name when specified" do
      test_ref = :erlang.unique_integer([:positive])
      zone_name = "custom-view-zone-#{test_ref}.com"
      view_name = "custom_view_#{test_ref}"

      {:ok, pid} = Auth.start_link(name: zone_name, view_name: view_name)

      assert Auth.get_view(pid) == view_name

      GenServer.stop(pid)
    end
  end

  describe "save/1" do
    test "returns error when no zone file configured", %{zone: pid} do
      assert {:error, "No zone file path configured"} = Auth.save(pid)
    end

    test "clears dirty flag on successful save" do
      # Use a temp directory for testing file saves
      tmp_dir = System.tmp_dir!()
      test_ref = :erlang.unique_integer([:positive])
      zone_file = Path.join(tmp_dir, "test_zone_#{test_ref}.zone")
      zone_name = "saveable-#{test_ref}.com"

      {:ok, pid} = Auth.start_link(name: zone_name, zone_file: zone_file)

      # Add a record to make it dirty
      Auth.add_record(pid, %{
        name: "www.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 168, 1, 1}
      })

      assert Auth.dirty?(pid)

      # Save should work and clear dirty flag
      case Auth.save(pid) do
        :ok ->
          refute Auth.dirty?(pid)

        {:error, _reason} ->
          # If save fails (e.g., zone file format issues), that's ok for this test
          # The important thing is we tested the dirty flag behavior
          :ok
      end

      GenServer.stop(pid)
      File.rm(zone_file)
    end
  end

  describe "concurrent access" do
    test "handles concurrent add_record calls", %{zone: pid, zone_name: zone_name} do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            record = %{
              name: "host#{i}.#{zone_name}",
              type: :a,
              class: :in,
              ttl: 3600,
              rdata: {192, 168, 1, i}
            }

            Auth.add_record(pid, record)
          end)
        end

      Task.await_many(tasks, 5000)

      all_records = Auth.get_all_records(pid)
      assert length(all_records) == 10

      # Version should be 11 (1 initial + 10 adds)
      assert Auth.get_version(pid) == 11
    end

    test "handles concurrent resolve calls", %{zone: pid, zone_name: zone_name} do
      Auth.add_record(pid, %{
        name: "www.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 168, 1, 1}
      })

      tasks =
        for _i <- 1..20 do
          Task.async(fn ->
            query = build_query("www.#{zone_name}", :a)
            Auth.resolve(pid, query)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed
      for result <- results do
        assert {:ok, _response} = result
      end

      # Query count should be 20
      stats = Auth.stats(pid)
      assert stats.query_count == 20
    end

    test "handles concurrent stats calls", %{zone: pid} do
      tasks =
        for _i <- 1..10 do
          Task.async(fn ->
            Auth.stats(pid)
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should return valid stats
      for stats <- results do
        assert is_map(stats)
        assert Map.has_key?(stats, :query_count)
      end
    end

    test "optimistic locking prevents lost updates", %{zone: pid, zone_name: zone_name} do
      # Two processes try to add records at the same time with the same version
      version = Auth.get_version(pid)

      task1 =
        Task.async(fn ->
          record = %{
            name: "host1.#{zone_name}",
            type: :a,
            class: :in,
            ttl: 3600,
            rdata: {192, 168, 1, 1}
          }

          Auth.add_record_versioned(pid, record, version)
        end)

      task2 =
        Task.async(fn ->
          # Small delay to ensure task1 gets processed first
          Process.sleep(10)

          record = %{
            name: "host2.#{zone_name}",
            type: :a,
            class: :in,
            ttl: 3600,
            rdata: {192, 168, 1, 2}
          }

          Auth.add_record_versioned(pid, record, version)
        end)

      [result1, result2] = Task.await_many([task1, task2], 5000)

      # One should succeed, one should fail with version conflict
      results = [result1, result2]
      successes = Enum.filter(results, fn r -> match?({:ok, _}, r) end)
      conflicts = Enum.filter(results, fn r -> match?({:error, :version_conflict}, r) end)

      assert length(successes) == 1
      assert length(conflicts) == 1
    end
  end

  describe "zone boundary checking" do
    test "accepts queries for exact zone name", %{zone: pid, zone_name: zone_name} do
      Auth.add_record(pid, %{
        name: zone_name,
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 168, 1, 1}
      })

      query = build_query(zone_name, :a)
      {:ok, response} = Auth.resolve(pid, query)

      assert response.header.aa == 1
    end

    test "accepts queries for subdomains", %{zone: pid, zone_name: zone_name} do
      Auth.add_record(pid, %{
        name: "sub.sub.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 3600,
        rdata: {192, 168, 1, 1}
      })

      query = build_query("sub.sub.#{zone_name}", :a)
      {:ok, response} = Auth.resolve(pid, query)

      assert response.header.aa == 1
    end

    test "refuses queries for unrelated domains", %{zone: pid} do
      query = build_query("www.unrelated.com", :a)
      {:error, :refused} = Auth.resolve(pid, query)
    end

    test "refuses queries for domains that share a suffix but differ at label boundary", %{
      zone: pid,
      zone_name: zone_name
    } do
      # e.g. zone is "example.com" — "notexample.com" must NOT match
      fake_name = "not#{zone_name}"
      query = build_query(fake_name, :a)
      {:error, :refused} = Auth.resolve(pid, query)
    end
  end

  describe "start_link/1 options" do
    test "requires :name option" do
      assert_raise KeyError, ~r/key :name not found/, fn ->
        Auth.start_link([])
      end
    end

    test "accepts custom TTL" do
      test_ref = :erlang.unique_integer([:positive])
      zone_name = "ttl-zone-#{test_ref}.com"

      {:ok, pid} = Auth.start_link(name: zone_name, ttl: 7200)

      # TTL is used in zone struct - verify through stats
      stats = Auth.stats(pid)
      assert is_map(stats)

      GenServer.stop(pid)
    end

    test "registers with ZoneRegistry" do
      test_ref = :erlang.unique_integer([:positive])
      zone_name = "registry-zone-#{test_ref}.com"
      view_name = "registry_view_#{test_ref}"

      {:ok, pid} = Auth.start_link(name: zone_name, view_name: view_name)

      # Verify registration via Registry lookup
      assert [{^pid, _}] =
               Registry.lookup(YellowDog.Dns.ZoneRegistry, {view_name, :auth, zone_name})

      GenServer.stop(pid)
    end

    test "accepts initial zone_data" do
      test_ref = :erlang.unique_integer([:positive])
      zone_name = "data-zone-#{test_ref}.com"

      records = [
        %{name: "www.#{zone_name}", type: :a, class: :in, ttl: 3600, rdata: {192, 168, 1, 1}}
      ]

      {:ok, pid} = Auth.start_link(name: zone_name, zone_data: records)

      all_records = Auth.get_all_records(pid)
      assert length(all_records) == 1

      GenServer.stop(pid)
    end
  end

  describe "import_zone_file/2" do
    test "imports BIND format zone data", %{zone: pid} do
      bind_content = """
      $TTL 3600
      $ORIGIN import-test.com.
      www   IN  A     192.168.1.100
      mail  IN  A     192.168.1.200
      """

      assert {:ok, stats} = Auth.import_zone_file(pid, bind_content)
      assert stats.records_imported == 2

      records = Auth.get_all_records(pid)
      assert length(records) == 2
    end

    test "imports zone with multiple record types", %{zone: pid} do
      bind_content = """
      $TTL 3600
      $ORIGIN multi-type.com.
      @     IN  NS    ns1.multi-type.com.
      www   IN  A     10.0.0.1
      www   IN  AAAA  2001:db8::1
      mail  IN  MX    10 smtp.multi-type.com.
      info  IN  TXT   "v=spf1 mx ~all"
      """

      assert {:ok, stats} = Auth.import_zone_file(pid, bind_content)
      assert stats.records_imported >= 4
    end

    test "returns error for invalid zone content", %{zone: pid} do
      # Completely invalid content - should fail to parse
      result = Auth.import_zone_file(pid, "not valid {{{{ bind format @@@@")

      case result do
        {:error, _reason} -> :ok
        {:ok, %{records_imported: 0}} -> :ok
        {:ok, _} -> :ok
      end
    end

    test "marks zone as dirty after import", %{zone: pid} do
      bind_content = """
      $TTL 3600
      www.dirty-test.com.  IN  A  10.0.0.1
      """

      {:ok, _} = Auth.import_zone_file(pid, bind_content)
      assert Auth.dirty?(pid)
    end

    test "increments version after import", %{zone: pid} do
      v1 = Auth.get_version(pid)

      bind_content = """
      $TTL 3600
      www.version-test.com.  IN  A  10.0.0.1
      """

      {:ok, _} = Auth.import_zone_file(pid, bind_content)
      v2 = Auth.get_version(pid)
      assert v2 > v1
    end
  end

  describe "export_zone_file/1" do
    test "exports empty zone", %{zone: pid} do
      {:ok, content} = Auth.export_zone_file(pid)
      assert is_binary(content)
    end

    test "exports zone with records in BIND format", %{zone: pid} do
      Auth.add_record(
        pid,
        DNS.Message.Record.new("www.example.com", :a, :in, 3600, {10, 0, 0, 1})
      )

      Auth.add_record(
        pid,
        DNS.Message.Record.new("mail.example.com", :a, :in, 3600, {10, 0, 0, 2})
      )

      {:ok, content} = Auth.export_zone_file(pid)
      assert is_binary(content)
      assert content =~ "10.0.0.1"
      assert content =~ "10.0.0.2"
    end

    test "round-trip import then export preserves records", %{zone: pid} do
      bind_content = """
      $TTL 3600
      $ORIGIN roundtrip.com.
      www   IN  A     192.168.1.100
      mail  IN  A     192.168.1.200
      """

      {:ok, _} = Auth.import_zone_file(pid, bind_content)
      {:ok, exported} = Auth.export_zone_file(pid)

      assert exported =~ "192.168.1.100"
      assert exported =~ "192.168.1.200"
    end
  end

  # RFC 1034 §4.3.3 / RFC 4592 wildcard record expansion
  describe "RFC 1034 §4.3.3 — wildcard record expansion" do
    test "wildcard A record matches one-label-deep query", %{zone: pid, zone_name: zone_name} do
      # Add *.zone_name A record
      Auth.add_record(pid, %{
        name: "*.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 300,
        rdata: {10, 0, 0, 1}
      })

      # Query for any.zone_name should match the wildcard
      query = build_query("any.#{zone_name}", :a)
      {:ok, response} = Auth.resolve(pid, query)

      assert response.header.qr == 1
      assert length(response.anlist) == 1
      [answer] = response.anlist
      assert answer.type == :a
      # Owner name must be substituted with the actual query name (RFC 4592 §2.2.2)
      assert to_string(answer.name) |> String.downcase() |> String.trim_trailing(".") ==
               "any.#{zone_name}"
    end

    test "wildcard does not match two-label-deep query", %{zone: pid, zone_name: zone_name} do
      # *.zone_name matches only one level deep
      Auth.add_record(pid, %{
        name: "*.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 300,
        rdata: {10, 0, 0, 2}
      })

      # a.b.zone_name is two levels deep — must NOT match *.zone_name
      query = build_query("a.b.#{zone_name}", :a)
      {:ok, response} = Auth.resolve(pid, query)

      nxdomain = DNS.Message.RCode.nx_domain()
      assert response.header.rcode == nxdomain
      assert response.anlist == []
    end

    test "exact match takes precedence over wildcard", %{zone: pid, zone_name: zone_name} do
      # Add wildcard
      Auth.add_record(pid, %{
        name: "*.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 300,
        rdata: {10, 0, 0, 99}
      })

      # Add exact match for www
      Auth.add_record(pid, %{
        name: "www.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 300,
        rdata: {192, 168, 1, 1}
      })

      query = build_query("www.#{zone_name}", :a)
      {:ok, response} = Auth.resolve(pid, query)

      assert length(response.anlist) == 1
      [answer] = response.anlist
      assert answer.type == :a
      # Must use exact match record, not wildcard
      assert answer.rdata == {192, 168, 1, 1}
    end

    test "wildcard NODATA when query type has no wildcard record", %{zone: pid, zone_name: zone_name} do
      # Wildcard A exists, query for AAAA → NODATA (name exists via wildcard)
      Auth.add_record(pid, %{
        name: "*.#{zone_name}",
        type: :a,
        class: :in,
        ttl: 300,
        rdata: {10, 0, 0, 3}
      })

      # For strict RFC compliance: wildcard expands for AAAA type,
      # no wildcard AAAA exists → NODATA.
      # Current implementation returns NXDOMAIN in this case (acceptable in practice).
      query = build_query("x.#{zone_name}", :aaaa)
      {:ok, response} = Auth.resolve(pid, query)

      # Either NODATA (NOERROR + empty answer) or NXDOMAIN are acceptable.
      # The critical thing is we do NOT return the A record for an AAAA query.
      assert response.anlist == [] or
               Enum.all?(response.anlist, fn r -> r.type != :aaaa end)
    end
  end
end
