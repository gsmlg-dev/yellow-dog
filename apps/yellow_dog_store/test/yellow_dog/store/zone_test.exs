Code.require_file(Path.expand("../../support/failure_backend.ex", __DIR__))

defmodule YellowDog.Store.ZoneTest do
  use ExUnit.Case, async: false

  @moduletag :store_integration

  alias YellowDog.Store.{Backend, EventBridge, Key, Zone}
  alias YellowDog.Store.Backend.Ets, as: EtsBackend
  alias YellowDog.Store.Test.FailureBackend

  @view "default"

  @test_soa %{
    mname: "ns1.example.com",
    rname: "admin.example.com",
    serial: 2_026_031_601,
    refresh: 3600,
    retry: 900,
    expire: 604_800,
    minimum: 86_400
  }

  defp assert_uuid(value) do
    assert is_binary(value)
    assert value =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    value
  end

  setup do
    YellowDog.StoreHelper.setup_store()

    on_exit(fn ->
      Backend.set_active(EtsBackend)
      FailureBackend.reset()
    end)

    :ok
  end

  defp desired_record(owner, address) do
    %{owner: owner, type: :a, rrset: [%{rdata: address, ttl: 300}]}
  end

  defp strong_record_snapshot(view_name, zone_name) do
    {:ok, entries} =
      EtsBackend.prefix_scan(Key.zone_rr_prefix(view_name, zone_name), consistency: :strong)

    Enum.map(entries, fn {_key, value} -> value end)
  end

  defp use_failure_backend(actions \\ []) do
    Backend.set_active(FailureBackend)
    FailureBackend.configure(actions)
  end

  defp start_event_bridge do
    case Process.whereis(EventBridge) do
      nil -> start_supervised!(EventBridge)
      _pid -> :ok
    end
  end

  # -------------------------------------------------------------------
  # Auth zone metadata
  # -------------------------------------------------------------------

  describe "create_zone/4 (auth)" do
    test "creates zone metadata with zone_type" do
      assert :ok = Zone.create_zone(@view, "test-create.example.com", @test_soa)

      assert {:ok, zone} = Zone.get_zone(@view, "test-create.example.com")
      assert zone.zone_type == :auth
      assert zone.origin == "test-create.example.com"
      assert zone.soa.mname == "ns1.example.com"
      assert zone.authoritative == true
      assert zone.default_ttl == 3600
    end

    test "creates auth zone with generated UUID" do
      assert :ok = Zone.create_zone(@view, "test-id-auth.example.com", @test_soa)

      assert {:ok, zone} = Zone.get_zone(@view, "test-id-auth.example.com")
      assert_uuid(zone.id)
    end

    test "create_zone with custom options" do
      assert :ok =
               Zone.create_zone(@view, "test-opts.example.com", @test_soa,
                 default_ttl: 7200,
                 authoritative: false,
                 allow_dynamic_update: true,
                 serial_strategy: :increment
               )

      assert {:ok, zone} = Zone.get_zone(@view, "test-opts.example.com")
      assert zone.default_ttl == 7200
      assert zone.authoritative == false
      assert zone.allow_dynamic_update == true
      assert zone.serial_strategy == :increment
    end

    test "create_zone persists cloud mirror metadata" do
      cloud_mirror = %{
        enabled: true,
        connector_name: "cf-main",
        provider: :cloudflare,
        zone_id: "cloudflare-zone-123",
        direction: :bidirectional,
        conflict_strategy: :local_wins
      }

      assert :ok =
               Zone.create_zone(@view, "test-mirror.example.com", @test_soa,
                 cloud_mirror: cloud_mirror
               )

      assert {:ok, zone} = Zone.get_zone(@view, "test-mirror.example.com")
      assert zone.cloud_mirror == cloud_mirror
    end

    test "duplicate zone creation returns error" do
      Zone.create_zone(@view, "test-dup.example.com", @test_soa)

      assert {:error, :already_exists} =
               Zone.create_zone(@view, "test-dup.example.com", @test_soa)
    end
  end

  describe "delete_zone/2" do
    test "removes zone and all records" do
      Zone.create_zone(@view, "test-del.example.com", @test_soa)

      Zone.put_rrset(@view, "test-del.example.com", "www.test-del.example.com", :a, [
        %{rdata: {192, 168, 1, 1}, ttl: 3600}
      ])

      assert :ok = Zone.delete_zone(@view, "test-del.example.com")
      assert {:error, :not_found} = Zone.get_zone(@view, "test-del.example.com")

      assert {:error, :not_found} =
               Zone.get_rrset(@view, "test-del.example.com", "www.test-del.example.com", :a)
    end
  end

  # -------------------------------------------------------------------
  # Forward zone
  # -------------------------------------------------------------------

  describe "create_forward_zone/4" do
    test "creates forward zone with forwarders" do
      forwarders = [%{ip: "8.8.8.8", port: 53}, %{ip: "8.8.4.4", port: 53}]

      assert :ok =
               Zone.create_forward_zone(@view, "corp.internal", forwarders,
                 forward_mode: :first,
                 timeout_ms: 3000
               )

      assert {:ok, zone} = Zone.get_zone(@view, "corp.internal")
      assert zone.zone_type == :forward
      assert zone.origin == "corp.internal"
      assert zone.forwarders == forwarders
      assert zone.forward_mode == :first
      assert zone.timeout_ms == 3000
      assert zone.max_retries == 2
    end

    test "creates forward zone with generated UUID" do
      assert :ok =
               Zone.create_forward_zone(@view, "test-id-forward.example.com", [
                 %{ip: "10.0.0.1", port: 53}
               ])

      assert {:ok, zone} = Zone.get_zone(@view, "test-id-forward.example.com")
      assert_uuid(zone.id)
    end

    test "duplicate forward zone returns error" do
      Zone.create_forward_zone(@view, "dup.internal", [%{ip: "10.0.0.1", port: 53}])

      assert {:error, :already_exists} =
               Zone.create_forward_zone(@view, "dup.internal", [%{ip: "10.0.0.2", port: 53}])
    end

    test "defaults forward_mode to :only" do
      Zone.create_forward_zone(@view, "default-mode.internal", [%{ip: "10.0.0.1", port: 53}])

      assert {:ok, zone} = Zone.get_zone(@view, "default-mode.internal")
      assert zone.forward_mode == :only
    end
  end

  describe "update_forward_zone/3" do
    test "updates forwarders list" do
      Zone.create_forward_zone(@view, "upd-fwd.internal", [%{ip: "10.0.0.1", port: 53}])

      new_forwarders = [%{ip: "10.0.0.2", port: 53}, %{ip: "10.0.0.3", port: 53}]

      assert :ok =
               Zone.update_forward_zone(@view, "upd-fwd.internal", %{forwarders: new_forwarders})

      assert {:ok, zone} = Zone.get_zone(@view, "upd-fwd.internal")
      assert zone.forwarders == new_forwarders
    end

    test "updates forward_mode" do
      Zone.create_forward_zone(@view, "mode-fwd.internal", [%{ip: "10.0.0.1", port: 53}])

      assert :ok = Zone.update_forward_zone(@view, "mode-fwd.internal", %{forward_mode: :first})

      assert {:ok, zone} = Zone.get_zone(@view, "mode-fwd.internal")
      assert zone.forward_mode == :first
    end
  end

  # -------------------------------------------------------------------
  # Stub zone
  # -------------------------------------------------------------------

  describe "create_stub_zone/4" do
    test "creates stub zone with primaries" do
      primaries = [%{ip: "10.2.0.1", port: 53}, %{ip: "10.2.0.2", port: 53}]

      assert :ok =
               Zone.create_stub_zone(@view, "subsidiary.example.com", primaries,
                 refresh_interval: 1800
               )

      assert {:ok, zone} = Zone.get_zone(@view, "subsidiary.example.com")
      assert zone.zone_type == :stub
      assert zone.origin == "subsidiary.example.com"
      assert zone.primaries == primaries
      assert zone.refresh_interval == 1800
    end

    test "creates stub zone with generated UUID" do
      assert :ok =
               Zone.create_stub_zone(@view, "test-id-stub.example.com", [
                 %{ip: "10.0.0.2", port: 53}
               ])

      assert {:ok, zone} = Zone.get_zone(@view, "test-id-stub.example.com")
      assert_uuid(zone.id)
    end

    test "duplicate stub zone returns error" do
      Zone.create_stub_zone(@view, "dup-stub.example.com", [%{ip: "10.0.0.1", port: 53}])

      assert {:error, :already_exists} =
               Zone.create_stub_zone(@view, "dup-stub.example.com", [%{ip: "10.0.0.2", port: 53}])
    end

    test "defaults refresh_interval to 3600" do
      Zone.create_stub_zone(@view, "default-stub.example.com", [%{ip: "10.0.0.1", port: 53}])

      assert {:ok, zone} = Zone.get_zone(@view, "default-stub.example.com")
      assert zone.refresh_interval == 3600
    end
  end

  describe "update_stub_zone/3" do
    test "updates primaries" do
      Zone.create_stub_zone(@view, "upd-stub.example.com", [%{ip: "10.0.0.1", port: 53}])

      new_primaries = [%{ip: "10.0.0.5", port: 53}]

      assert :ok =
               Zone.update_stub_zone(@view, "upd-stub.example.com", %{primaries: new_primaries})

      assert {:ok, zone} = Zone.get_zone(@view, "upd-stub.example.com")
      assert zone.primaries == new_primaries
    end

    test "updates refresh_interval" do
      Zone.create_stub_zone(@view, "ri-stub.example.com", [%{ip: "10.0.0.1", port: 53}])

      assert :ok = Zone.update_stub_zone(@view, "ri-stub.example.com", %{refresh_interval: 7200})

      assert {:ok, zone} = Zone.get_zone(@view, "ri-stub.example.com")
      assert zone.refresh_interval == 7200
    end
  end

  describe "zone UUID lookup and backfill" do
    test "get_zone_by_id/1 returns zone metadata with view_name" do
      assert :ok = Zone.create_zone(@view, "lookup-id.example.com", @test_soa)
      assert {:ok, created} = Zone.get_zone(@view, "lookup-id.example.com")

      assert {:ok, found} = Zone.get_zone_by_id(created.id)
      assert found.id == created.id
      assert found.view_name == @view
      assert found.origin == "lookup-id.example.com"
      assert found.zone_type == :auth
    end

    test "get_zone_by_id/1 returns not_found for missing id" do
      assert {:error, :not_found} =
               Zone.get_zone_by_id("00000000-0000-4000-8000-000000000000")
    end

    test "list_zones_for_view/1 lazily backfills missing id" do
      key = YellowDog.Store.Key.zone(@view, "legacy-no-id.example.com")
      now = System.system_time(:second)

      legacy_zone = %{
        zone_type: :auth,
        origin: "legacy-no-id.example.com",
        soa: @test_soa,
        default_ttl: 3600,
        authoritative: true,
        allow_dynamic_update: false,
        serial_strategy: :date_serial,
        cloud_mirror: nil,
        created_at: now,
        updated_at: now
      }

      assert :ok = YellowDog.Store.Backend.active().put_if(key, legacy_zone, expected: nil)

      assert {:ok, zones} = Zone.list_zones_for_view(@view)
      assert zone = Enum.find(zones, &(&1.origin == "legacy-no-id.example.com"))
      assert_uuid(zone.id)

      assert {:ok, persisted} = Zone.get_zone(@view, "legacy-no-id.example.com")
      assert persisted.id == zone.id
    end
  end

  # -------------------------------------------------------------------
  # RRset operations (auth only)
  # -------------------------------------------------------------------

  describe "replace_records/3" do
    test "empty replacement succeeds unchanged without serial or write churn" do
      zone_name = "replace-empty.example.com"
      Zone.create_zone(@view, zone_name, @test_soa, serial_strategy: :increment)
      {:ok, before_zone} = Zone.get_zone(@view, zone_name)
      use_failure_backend()

      assert {:ok, %{previous: [], changed_count: 0}} =
               Zone.replace_records(@view, zone_name, [])

      assert {:ok, after_zone} = Zone.get_zone(@view, zone_name)
      assert after_zone.soa.serial == before_zone.soa.serial
      assert FailureBackend.writes() == []

      assert {:prefix_scan, _, [consistency: :strong]} =
               Enum.find(FailureBackend.calls(), &match?({:prefix_scan, _, _}, &1))
    end

    test "unchanged replacement returns the complete prior snapshot without churn" do
      zone_name = "replace-unchanged.example.com"
      record = desired_record("www", {192, 0, 2, 1})
      Zone.create_zone(@view, zone_name, @test_soa, serial_strategy: :increment)
      Zone.put_rrset(@view, zone_name, record.owner, record.type, record.rrset)
      previous = strong_record_snapshot(@view, zone_name)
      {:ok, before_zone} = Zone.get_zone(@view, zone_name)
      use_failure_backend()

      assert {:ok, %{previous: ^previous, changed_count: 0}} =
               Zone.replace_records(@view, zone_name, [record])

      assert {:ok, after_zone} = Zone.get_zone(@view, zone_name)
      assert after_zone.soa.serial == before_zone.soa.serial
      assert FailureBackend.writes() == []
    end

    test "counts added RRsets deterministically and increments the serial once" do
      zone_name = "replace-add.example.com"
      records = [desired_record("a", {192, 0, 2, 1}), desired_record("b", {192, 0, 2, 2})]
      Zone.create_zone(@view, zone_name, @test_soa, serial_strategy: :increment)
      {:ok, before_zone} = Zone.get_zone(@view, zone_name)
      use_failure_backend()

      assert {:ok, %{previous: [], changed_count: 2}} =
               Zone.replace_records(@view, zone_name, records)

      assert {:ok, after_zone} = Zone.get_zone(@view, zone_name)
      assert after_zone.soa.serial == before_zone.soa.serial + 1

      zone_key = Key.zone(@view, zone_name)

      assert 1 ==
               Enum.count(FailureBackend.writes(), fn
                 {:put_if, ^zone_key, _opts} -> true
                 _ -> false
               end)
    end

    test "counts one updated RRset" do
      zone_name = "replace-update.example.com"
      old = desired_record("www", {192, 0, 2, 1})
      updated = desired_record("www", {192, 0, 2, 2})
      Zone.create_zone(@view, zone_name, @test_soa, serial_strategy: :increment)
      Zone.put_rrset(@view, zone_name, old.owner, old.type, old.rrset)
      previous = strong_record_snapshot(@view, zone_name)

      assert {:ok, %{previous: ^previous, changed_count: 1}} =
               Zone.replace_records(@view, zone_name, [updated])

      assert {:ok, stored} = Zone.get_rrset(@view, zone_name, updated.owner, updated.type)
      assert stored.rrset == updated.rrset
    end

    test "counts one deleted RRset" do
      zone_name = "replace-delete.example.com"
      kept = desired_record("keep", {192, 0, 2, 1})
      removed = desired_record("remove", {192, 0, 2, 2})
      Zone.create_zone(@view, zone_name, @test_soa, serial_strategy: :increment)
      Zone.put_rrset(@view, zone_name, kept.owner, kept.type, kept.rrset)
      Zone.put_rrset(@view, zone_name, removed.owner, removed.type, removed.rrset)

      assert {:ok, %{changed_count: 1}} = Zone.replace_records(@view, zone_name, [kept])
      assert {:error, :not_found} = Zone.get_rrset(@view, zone_name, removed.owner, removed.type)
    end

    test "counts mixed add, update, and delete changes" do
      zone_name = "replace-mixed.example.com"
      kept = desired_record("keep", {192, 0, 2, 1})
      old = desired_record("update", {192, 0, 2, 2})
      removed = desired_record("remove", {192, 0, 2, 3})
      updated = desired_record("update", {192, 0, 2, 20})
      added = desired_record("add", {192, 0, 2, 4})
      Zone.create_zone(@view, zone_name, @test_soa, serial_strategy: :increment)

      for record <- [kept, old, removed] do
        Zone.put_rrset(@view, zone_name, record.owner, record.type, record.rrset)
      end

      assert {:ok, %{changed_count: 3}} =
               Zone.replace_records(@view, zone_name, [kept, updated, added])

      assert Enum.map(strong_record_snapshot(@view, zone_name), & &1.owner) ==
               ["add", "keep", "update"]
    end

    test "rejects duplicate and invalid records before any write" do
      zone_name = "replace-invalid.example.com"
      record = desired_record("www", {192, 0, 2, 1})
      Zone.create_zone(@view, zone_name, @test_soa)
      use_failure_backend()

      assert {:error, {:replace_failed, :duplicate_record}} =
               Zone.replace_records(@view, zone_name, [record, record])

      assert FailureBackend.writes() == []
      FailureBackend.reset()

      assert {:error, {:replace_failed, :invalid_record}} =
               Zone.replace_records(@view, zone_name, [%{owner: "www", type: "A", rrset: []}])

      assert FailureBackend.writes() == []
    end

    test "rejects missing and non-authoritative zones before RR writes" do
      use_failure_backend()

      assert {:error, {:replace_failed, :zone_not_found}} =
               Zone.replace_records(@view, "missing.example.com", [])

      assert FailureBackend.writes() == []

      Backend.set_active(EtsBackend)
      Zone.create_forward_zone(@view, "forward.example.com", [%{ip: "192.0.2.53", port: 53}])
      use_failure_backend()

      assert {:error, {:replace_failed, :not_authoritative}} =
               Zone.replace_records(@view, "forward.example.com", [])

      assert FailureBackend.writes() == []
    end

    test "restores exact content and removes new keys after a partial batch put failure" do
      zone_name = "replace-put-failure.example.com"
      old = desired_record("old", {192, 0, 2, 1})
      updated = desired_record("old", {192, 0, 2, 10})
      added = desired_record("new", {192, 0, 2, 2})
      Zone.create_zone(@view, zone_name, @test_soa, serial_strategy: :increment)
      Zone.put_rrset(@view, zone_name, old.owner, old.type, old.rrset)
      previous = strong_record_snapshot(@view, zone_name)
      use_failure_backend([{:put_many, {:partial, 2}, :batch_failed}])

      assert {:error, {:replace_failed, {:put_many_failed, :batch_failed}}} =
               Zone.replace_records(@view, zone_name, [updated, added])

      assert strong_record_snapshot(@view, zone_name) == previous
    end

    test "restores exact content after a stale delete failure" do
      zone_name = "replace-delete-failure.example.com"
      kept = desired_record("keep", {192, 0, 2, 1})
      stale = desired_record("stale", {192, 0, 2, 2})
      Zone.create_zone(@view, zone_name, @test_soa, serial_strategy: :increment)
      Zone.put_rrset(@view, zone_name, kept.owner, kept.type, kept.rrset)
      Zone.put_rrset(@view, zone_name, stale.owner, stale.type, stale.rrset)
      previous = strong_record_snapshot(@view, zone_name)
      stale_key = Key.zone_rr(@view, zone_name, stale.owner, stale.type)
      use_failure_backend([{:delete, stale_key, :delete_failed}])

      assert {:error, {:replace_failed, {:delete_failed, ^stale_key, :delete_failed}}} =
               Zone.replace_records(@view, zone_name, [kept])

      assert strong_record_snapshot(@view, zone_name) == previous
    end

    test "restores exact content, preserves an advanced serial, and emits no premature events" do
      zone_name = "replace-serial-failure.example.com"
      old = desired_record("www", {192, 0, 2, 1})
      updated = desired_record("www", {192, 0, 2, 2})
      Zone.create_zone(@view, zone_name, @test_soa, serial_strategy: :increment)
      Zone.put_rrset(@view, zone_name, old.owner, old.type, old.rrset)
      previous = strong_record_snapshot(@view, zone_name)
      {:ok, before_zone} = Zone.get_zone(@view, zone_name)
      start_event_bridge()
      {:ok, _ref} = EventBridge.subscribe(Key.zone_rr_prefix(@view, zone_name) <> "*")
      zone_key = Key.zone(@view, zone_name)
      use_failure_backend([{:put_if, zone_key, :write_then_fail, :serial_failed}])

      assert {:error, {:replace_failed, {:serial_failed, :serial_failed}}} =
               Zone.replace_records(@view, zone_name, [updated])

      assert strong_record_snapshot(@view, zone_name) == previous
      assert {:ok, after_zone} = Zone.get_zone(@view, zone_name)
      assert after_zone.soa.serial == before_zone.soa.serial + 1
      refute_receive {:store_event, _}, 100
    end

    test "returns rollback_failed when compensation cannot restore prior content" do
      zone_name = "replace-rollback-failure.example.com"
      old = desired_record("www", {192, 0, 2, 1})
      updated = desired_record("www", {192, 0, 2, 2})
      Zone.create_zone(@view, zone_name, @test_soa, serial_strategy: :increment)
      Zone.put_rrset(@view, zone_name, old.owner, old.type, old.rrset)

      use_failure_backend([
        {:put_many, {:partial, 1}, :batch_failed},
        {:put_many, :fail, :restore_failed}
      ])

      assert {:error,
              {:rollback_failed, {:put_many_failed, :batch_failed},
               {:restore_failed, :restore_failed}}} =
               Zone.replace_records(@view, zone_name, [updated])
    end

    test "emits committed put and delete events only after successful replacement" do
      zone_name = "replace-events.example.com"
      stale = desired_record("stale", {192, 0, 2, 1})
      added = desired_record("added", {192, 0, 2, 2})
      Zone.create_zone(@view, zone_name, @test_soa, serial_strategy: :increment)
      Zone.put_rrset(@view, zone_name, stale.owner, stale.type, stale.rrset)
      start_event_bridge()
      {:ok, _ref} = EventBridge.subscribe(Key.zone_rr_prefix(@view, zone_name) <> "*")

      assert {:ok, %{changed_count: 2}} = Zone.replace_records(@view, zone_name, [added])

      added_key = Key.zone_rr(@view, zone_name, added.owner, added.type)
      stale_key = Key.zone_rr(@view, zone_name, stale.owner, stale.type)
      assert_receive {:store_event, %{type: :put, key: ^added_key}}, 1_000
      assert_receive {:store_event, %{type: :delete, key: ^stale_key}}, 1_000
    end
  end

  describe "put_rrset/5 and get_rrset/4" do
    test "creates and retrieves an RRset" do
      Zone.create_zone(@view, "test-rr.example.com", @test_soa)

      rrset = [%{rdata: {192, 168, 1, 1}, ttl: 300}]

      assert :ok =
               Zone.put_rrset(@view, "test-rr.example.com", "www.test-rr.example.com", :a, rrset)

      assert {:ok, record} =
               Zone.get_rrset(@view, "test-rr.example.com", "www.test-rr.example.com", :a)

      assert record.rrset == rrset
      assert record.owner == "www.test-rr.example.com"
      assert record.type == :a
      assert record.zone == "test-rr.example.com"
    end

    test "get_rrset returns not_found for missing record" do
      Zone.create_zone(@view, "test-rr2.example.com", @test_soa)

      assert {:error, :not_found} =
               Zone.get_rrset(
                 @view,
                 "test-rr2.example.com",
                 "nonexistent.test-rr2.example.com",
                 :a
               )
    end
  end

  describe "SOA serial auto-increment" do
    test "serial increments after put_rrset" do
      Zone.create_zone(@view, "test-serial.example.com", @test_soa)
      {:ok, zone_before} = Zone.get_zone(@view, "test-serial.example.com")

      Zone.put_rrset(@view, "test-serial.example.com", "www.test-serial.example.com", :a, [
        %{rdata: {10, 0, 0, 1}, ttl: 300}
      ])

      {:ok, zone_after} = Zone.get_zone(@view, "test-serial.example.com")
      assert zone_after.soa.serial > zone_before.soa.serial
    end

    test "serial increments after delete_rrset" do
      Zone.create_zone(@view, "test-serial2.example.com", @test_soa)

      Zone.put_rrset(@view, "test-serial2.example.com", "www.test-serial2.example.com", :a, [
        %{rdata: {10, 0, 0, 2}, ttl: 300}
      ])

      {:ok, zone_before} = Zone.get_zone(@view, "test-serial2.example.com")

      Zone.delete_rrset(@view, "test-serial2.example.com", "www.test-serial2.example.com", :a)

      {:ok, zone_after} = Zone.get_zone(@view, "test-serial2.example.com")
      assert zone_after.soa.serial > zone_before.soa.serial
    end

    test "increment_serial is no-op for non-auth zones" do
      Zone.create_forward_zone(@view, "fwd-serial.internal", [%{ip: "10.0.0.1", port: 53}])
      assert :ok = Zone.increment_serial(@view, "fwd-serial.internal")
    end
  end

  describe "list_records/2" do
    test "lists all RRsets in a zone" do
      Zone.create_zone(@view, "test-list.example.com", @test_soa)

      Zone.put_rrset(@view, "test-list.example.com", "www", :a, [%{rdata: {10, 0, 0, 1}}])

      Zone.put_rrset(@view, "test-list.example.com", "mail", :mx, [
        %{rdata: "mail.test-list.example.com", priority: 10}
      ])

      assert {:ok, records} = Zone.list_records(@view, "test-list.example.com")
      assert length(records) >= 2
    end
  end

  describe "list_records/3" do
    test "filters records by owner name" do
      Zone.create_zone(@view, "test-list2.example.com", @test_soa)

      Zone.put_rrset(@view, "test-list2.example.com", "www", :a, [%{rdata: {10, 0, 0, 1}}])

      Zone.put_rrset(@view, "test-list2.example.com", "www", :aaaa, [
        %{rdata: {0, 0, 0, 0, 0, 0, 0, 1}}
      ])

      Zone.put_rrset(@view, "test-list2.example.com", "mail", :a, [%{rdata: {10, 0, 0, 2}}])

      assert {:ok, records} = Zone.list_records(@view, "test-list2.example.com", "www")
      assert length(records) == 2
      assert Enum.all?(records, fn r -> r.owner == "www" end)
    end
  end

  describe "delete_rrset/4" do
    test "removes an RRset" do
      Zone.create_zone(@view, "test-delrr.example.com", @test_soa)

      Zone.put_rrset(@view, "test-delrr.example.com", "www", :a, [%{rdata: {10, 0, 0, 1}}])
      assert :ok = Zone.delete_rrset(@view, "test-delrr.example.com", "www", :a)
      assert {:error, :not_found} = Zone.get_rrset(@view, "test-delrr.example.com", "www", :a)
    end
  end

  # -------------------------------------------------------------------
  # Listing (cross-type)
  # -------------------------------------------------------------------

  describe "list_zones/0" do
    test "returns all zones across all views" do
      Zone.create_zone(@view, "auth.example.com", @test_soa)
      Zone.create_forward_zone(@view, "fwd.example.com", [%{ip: "10.0.0.1", port: 53}])
      Zone.create_stub_zone(@view, "stub.example.com", [%{ip: "10.0.0.2", port: 53}])

      assert {:ok, zones} = Zone.list_zones()
      assert is_list(zones)
      origins = Enum.map(zones, & &1.origin)
      assert "auth.example.com" in origins
      assert "fwd.example.com" in origins
      assert "stub.example.com" in origins
    end
  end

  describe "list_zones_for_view/1" do
    test "returns zones only for the specified view" do
      Zone.create_zone("view-a", "a.example.com", @test_soa)
      Zone.create_zone("view-b", "b.example.com", @test_soa)

      assert {:ok, zones} = Zone.list_zones_for_view("view-a")
      origins = Enum.map(zones, & &1.origin)
      assert "a.example.com" in origins
      refute "b.example.com" in origins
    end
  end

  describe "list_zones_by_type/1" do
    test "filters by zone type" do
      Zone.create_zone(@view, "auth-filter.example.com", @test_soa)
      Zone.create_forward_zone(@view, "fwd-filter.example.com", [%{ip: "10.0.0.1", port: 53}])
      Zone.create_stub_zone(@view, "stub-filter.example.com", [%{ip: "10.0.0.2", port: 53}])

      assert {:ok, auth_zones} = Zone.list_zones_by_type(:auth)
      assert Enum.all?(auth_zones, fn z -> z.zone_type == :auth end)
      assert Enum.any?(auth_zones, fn z -> z.origin == "auth-filter.example.com" end)

      assert {:ok, fwd_zones} = Zone.list_zones_by_type(:forward)
      assert Enum.all?(fwd_zones, fn z -> z.zone_type == :forward end)

      assert {:ok, stub_zones} = Zone.list_zones_by_type(:stub)
      assert Enum.all?(stub_zones, fn z -> z.zone_type == :stub end)
    end
  end

  describe "delete_zone/2 works for all types" do
    test "deletes forward zone" do
      Zone.create_forward_zone(@view, "del-fwd.internal", [%{ip: "10.0.0.1", port: 53}])
      assert :ok = Zone.delete_zone(@view, "del-fwd.internal")
      assert {:error, :not_found} = Zone.get_zone(@view, "del-fwd.internal")
    end

    test "deletes stub zone" do
      Zone.create_stub_zone(@view, "del-stub.example.com", [%{ip: "10.0.0.1", port: 53}])
      assert :ok = Zone.delete_zone(@view, "del-stub.example.com")
      assert {:error, :not_found} = Zone.get_zone(@view, "del-stub.example.com")
    end
  end

  # -------------------------------------------------------------------
  # Import / Export
  # -------------------------------------------------------------------

  describe "import_zone/3" do
    test "imports records into a zone" do
      records = [
        %{owner: "test-import.example.com", type: :soa, rrset: [@test_soa]},
        %{owner: "www.test-import.example.com", type: :a, rrset: [%{rdata: {10, 0, 0, 1}}]}
      ]

      assert :ok = Zone.import_zone(@view, "test-import.example.com", records)
      assert {:ok, _zone} = Zone.get_zone(@view, "test-import.example.com")
    end
  end

  describe "export_zone/2" do
    test "exports all records from a zone" do
      Zone.create_zone(@view, "test-export.example.com", @test_soa)
      Zone.put_rrset(@view, "test-export.example.com", "www", :a, [%{rdata: {10, 0, 0, 1}}])

      assert {:ok, records} = Zone.export_zone(@view, "test-export.example.com")
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

      assert :ok = Zone.import_zone(@view, "rt.example.com", records)

      assert {:ok, exported} = Zone.export_zone(@view, "rt.example.com")

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

  describe "update_zone/3 (generic)" do
    test "updates auth zone metadata" do
      Zone.create_zone(@view, "upd-auth.example.com", @test_soa)
      assert :ok = Zone.update_zone(@view, "upd-auth.example.com", %{default_ttl: 7200})

      assert {:ok, zone} = Zone.get_zone(@view, "upd-auth.example.com")
      assert zone.default_ttl == 7200
    end
  end

  # -------------------------------------------------------------------
  # View scoping
  # -------------------------------------------------------------------

  describe "view scoping" do
    test "same zone name in different views are independent" do
      Zone.create_zone("internal", "example.com", @test_soa)

      Zone.create_forward_zone("external", "example.com", [%{ip: "8.8.8.8", port: 53}])

      assert {:ok, internal} = Zone.get_zone("internal", "example.com")
      assert internal.zone_type == :auth

      assert {:ok, external} = Zone.get_zone("external", "example.com")
      assert external.zone_type == :forward
    end
  end
end
