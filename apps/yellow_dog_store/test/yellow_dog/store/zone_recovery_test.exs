Code.require_file(Path.expand("../../support/failure_backend.ex", __DIR__))

defmodule YellowDog.Store.ZoneRecoveryTest do
  use ExUnit.Case, async: false

  alias YellowDog.Store.{Backend, EventBridge, Key, Zone}
  alias YellowDog.Store.Backend.{Cluster, Ets}
  alias YellowDog.Store.Test.FailureBackend

  defmodule LegacyBackend do
    defdelegate put(key, value, opts), to: FailureBackend
    defdelegate get(key, opts), to: FailureBackend
    defdelegate delete(key), to: FailureBackend
    defdelegate put_if(key, value, opts), to: FailureBackend
    defdelegate prefix_scan(prefix, opts), to: FailureBackend
    defdelegate put_many(operations), to: FailureBackend
  end

  defmodule TrapBackend do
    def get(_key, _opts), do: {:error, :wrong_backend}
    def put_if(_key, _value, _opts), do: {:error, :wrong_backend}
  end

  @view "recovery"
  @soa %{
    mname: "ns1.example.com",
    rname: "hostmaster.example.com",
    serial: 100,
    refresh: 3600,
    retry: 1800,
    expire: 604_800,
    minimum: 300
  }

  setup do
    YellowDog.StoreHelper.setup_store()

    on_exit(fn ->
      Backend.set_active(Ets)
      FailureBackend.reset()
    end)

    :ok
  end

  test "replacement recovery keys stay outside observable DNS view keys" do
    header = Key.zone_replacement_header(@view, "example.com")
    chunk = Key.zone_replacement_plan("operation-id", 0)

    refute String.starts_with?(header, Key.all_views_prefix())
    refute String.starts_with?(chunk, Key.all_views_prefix())
    assert String.starts_with?(header, Key.zone_replacement_header_prefix())
    assert String.starts_with?(chunk, Key.zone_replacement_plan_prefix("operation-id"))
  end

  test "ETS transaction compares the durable cursor and applies mixed mutations atomically" do
    header_key = "zone-replacement:header:test"
    old_header = %{phase: :applying, next_chunk: 0, generation: 1}
    next_header = %{old_header | next_chunk: 1}
    :ok = Ets.put(header_key, old_header)
    :ok = Ets.put("old", :value)

    spec = %{
      compare: [{:value, header_key, :==, old_header}],
      success: [
        {:put, "new", :value, %{}},
        {:delete, {:key, "old"}, %{}},
        {:put, header_key, next_header, %{}}
      ],
      failure: []
    }

    assert {:ok, %{succeeded: true}} = Ets.txn(spec)
    assert {:ok, :value} = Ets.get("new")
    assert {:error, :not_found} = Ets.get("old")
    assert {:ok, ^next_header} = Ets.get(header_key)

    assert {:ok, %{succeeded: false}} = Ets.txn(spec)
  end

  test "ETS transaction fully prevalidates compares, both branches, counts, and bytes" do
    invalid_success = %{
      compare: [],
      success: [{:put, "must-not-exist", :written, %{}}, {:unsupported, :operation}],
      failure: []
    }

    assert {:error, {:invalid_txn, :unsupported_op}} = Ets.txn(invalid_success)
    assert {:error, :not_found} = Ets.get("must-not-exist")

    invalid_failure = %{
      compare: [],
      success: [{:put, "unselected-invalid-branch", :written, %{}}],
      failure: [{:unsupported, :operation}]
    }

    assert {:error, {:invalid_txn, :unsupported_op}} = Ets.txn(invalid_failure)
    assert {:error, :not_found} = Ets.get("unselected-invalid-branch")

    invalid_compare = %{
      compare: [
        {:value, "absent", :==, :present},
        {:unsupported, "key", :==, true}
      ],
      success: [],
      failure: [{:put, "invalid-compare-branch", :written, %{}}]
    }

    assert {:error, {:invalid_txn, :unsupported_compare}} = Ets.txn(invalid_compare)
    assert {:error, :not_found} = Ets.get("invalid-compare-branch")

    too_many = %{
      compare: [],
      success: for(index <- 1..129, do: {:put, "count-#{index}", index, %{}}),
      failure: []
    }

    assert {:error, {:invalid_txn, :too_many_success_ops}} = Ets.txn(too_many)
    assert {:error, :not_found} = Ets.get("count-1")

    too_large = %{
      compare: [],
      success: [{:put, "large", String.duplicate("x", 1_000_000), %{}}],
      failure: []
    }

    assert {:error, {:invalid_txn, :spec_too_large}} = Ets.txn(too_large)
    assert {:error, :not_found} = Ets.get("large")
  end

  test "ETS transaction rejects invalid operation options before any mutation" do
    Enum.each([0, -1, 1.5, :infinity], fn invalid_ttl ->
      valid_key = "valid-before-#{inspect(invalid_ttl)}"
      invalid_key = "invalid-ttl-#{inspect(invalid_ttl)}"

      spec = %{
        compare: [],
        success: [
          {:put, valid_key, :written, %{}},
          {:put, invalid_key, :written, %{ttl: invalid_ttl}}
        ],
        failure: []
      }

      assert {:error, {:invalid_txn, :invalid_ttl}} = Ets.txn(spec)
      assert {:error, :not_found} = Ets.get(valid_key)
      assert {:error, :not_found} = Ets.get(invalid_key)
    end)

    assert {:error, {:invalid_txn, :unsupported_put_option}} =
             Ets.txn(%{
               compare: [],
               success: [{:put, "leased", :value, %{lease: "lease-id"}}],
               failure: []
             })

    assert {:error, {:invalid_txn, :unsupported_delete_option}} =
             Ets.txn(%{
               compare: [],
               success: [{:delete, {:key, "delete"}, %{ttl: 60}}],
               failure: []
             })

    assert {:ok, %{succeeded: true}} =
             Ets.txn(%{
               compare: [],
               success: [{:put, "valid-ttl", :value, %{ttl: 60}}],
               failure: []
             })

    assert {:ok, :value} = Ets.get("valid-ttl")
  end

  test "backends state their exact recovery durability" do
    assert Ets.recovery_durability() == :caller_process_while_table_survives
    assert Cluster.recovery_durability() == :restart_durable
  end

  test "501 records use multiple durable apply chunks and increment serial once" do
    zone = "many.example.com"
    records = records(501)
    :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)

    assert {:ok, %{changed_count: 501}} = Zone.replace_records(@view, zone, records)
    assert {:ok, stored} = Zone.list_records(@view, zone)
    assert length(stored) == 501
    assert {:ok, metadata} = Zone.get_zone(@view, zone)
    assert metadata.soa.serial == 101

    assert {:ok, []} = Ets.prefix_scan(Key.zone_replacement_header_prefix())
  end

  test "one record larger than the conservative transaction bound is rejected before intent" do
    zone = "oversized.example.com"
    :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)

    oversized =
      desired_record("large", %{
        text: String.duplicate("x", Zone.max_replacement_transaction_bytes())
      })

    assert {:error, {:replace_failed, {:record_too_large, _bytes}}} =
             Zone.replace_records(@view, zone, [oversized])

    assert {:ok, []} = Ets.prefix_scan(Key.zone_replacement_header_prefix())
    assert {:ok, metadata} = Zone.get_zone(@view, zone)
    assert metadata.soa.serial == 100
  end

  test "caller exits after intent creation and plan persistence recover without partial state" do
    checkpoints = [
      {:txn, :intent, {:delegate_then_exit, :intent_crash}},
      {:put_if_prefix, "store:zone-replacement:plan:", {:write_then_exit, :plan_crash}}
    ]

    Enum.each(Enum.with_index(checkpoints), fn {checkpoint, index} ->
      zone = "prepare-crash-#{index}.example.com"
      :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)
      crash_replacement(zone, records(2), [checkpoint])

      assert {:ok, stored} = Zone.list_records(@view, zone)

      if index == 0 do
        assert stored == []
        assert {:ok, metadata} = Zone.get_zone(@view, zone)
        assert metadata.soa.serial == 100
      else
        assert length(stored) == 2
        assert {:ok, metadata} = Zone.get_zone(@view, zone)
        assert metadata.soa.serial == 101
      end

      assert_no_recovery_state()
      Backend.set_active(Ets)
    end)
  end

  test "transient preparing plan reads preserve intent and execute does not report success" do
    zone = "prepare-timeout.example.com"
    plan_prefix = "store:zone-replacement:plan:"
    :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)

    use_failure_backend([
      {:get_prefix, plan_prefix, :pass},
      {:get_prefix, plan_prefix, {:error, :timeout}}
    ])

    assert {:error, {:replace_failed, {:recovery_failed, {:plan_read_failed, 0, :timeout}}}} =
             Zone.replace_records(@view, zone, records(1))

    {header_key, %{phase: :preparing} = header} = replacement_header(zone)

    assert {:ok, [_chunk]} =
             Ets.prefix_scan(Key.zone_replacement_plan_prefix(header.operation_id))

    assert {:ok, ^header} = Ets.get(header_key)

    Backend.set_active(Ets)
    assert {:ok, [_record]} = Zone.list_records(@view, zone)
    assert_no_recovery_state()
  end

  test "execute strongly verifies the exact target metadata after cleanup" do
    zone = "target-verification.example.com"
    zone_key = Key.zone(@view, zone)
    :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)

    use_failure_backend([
      {:txn, :header_cleanup, {:delegate_then_tamper_key, zone_key, %{tampered: true}}}
    ])

    assert {:error, {:replace_failed, {:target_verification_failed, :mismatch}}} =
             Zone.replace_records(@view, zone, records(1))

    assert {:ok, %{tampered: true}} = Ets.get(zone_key, consistency: :strong)
    assert_no_recovery_state()
  end

  test "caller exits after every apply chunk recover the immutable plan idempotently" do
    records = records(260)

    for cursor <- 1..3 do
      zone = "apply-crash-#{cursor}.example.com"
      :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)
      phase = if cursor == 3, do: :finalizing, else: :applying

      crash_replacement(zone, records, [
        {:txn, {:apply, cursor, phase}, {:delegate_then_exit, {:apply_crash, cursor}}}
      ])

      assert {:ok, stored} = Zone.list_records(@view, zone)
      assert length(stored) == 260
      assert {:ok, metadata} = Zone.get_zone(@view, zone)
      assert metadata.soa.serial == 101
      assert_no_recovery_state()
      Backend.set_active(Ets)
    end
  end

  test "caller exits after final serial commit, event delivery, and cleanup recover idempotently" do
    checkpoints = [
      {:txn, :finalize, {:delegate_then_exit, :finalize_crash}},
      {:txn, {:event, 2, :events}, {:exit, :event_crash}},
      {:txn, :header_cleanup, {:delegate_then_exit, :cleanup_crash}}
    ]

    Enum.each(Enum.with_index(checkpoints), fn {checkpoint, index} ->
      zone = "late-crash-#{index}.example.com"
      :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)
      crash_replacement(zone, records(2), [checkpoint])

      assert {:ok, stored} = Zone.list_records(@view, zone)
      assert length(stored) == 2
      assert {:ok, metadata} = Zone.get_zone(@view, zone)
      assert metadata.soa.serial == 101
      assert_no_recovery_state()
      Backend.set_active(Ets)
    end)
  end

  test "replacement events persist synchronously by operation cursor before advancement" do
    start_event_bridge()
    zone = "durable-event.example.com"
    event_prefix = "event_log:zone-replacement:"
    :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)
    {:ok, subscription} = EventBridge.subscribe(Key.zone_rr_prefix(@view, zone) <> "*")

    use_failure_backend([
      {:put_if_prefix, event_prefix, :pass},
      {:put_if_prefix, event_prefix, {:write_then_exit, :event_persisted}}
    ])

    {pid, monitor} = spawn_replacement(zone, records(1))
    assert_receive {:DOWN, ^monitor, :process, ^pid, :event_persisted}, 5_000

    {_header_key, header} = replacement_header(zone)
    assert header.phase == :events
    assert header.event_state.cursor == 1
    assert {:ok, persisted_before_recovery} = Ets.prefix_scan(event_prefix)
    assert length(persisted_before_recovery) == 2

    assert {:ok, [_record]} = Zone.list_records(@view, zone)
    assert_receive {:store_event, %{operation_id: operation_id, cursor: 1}}, 5_000
    assert operation_id == header.operation_id
    assert_no_recovery_state()

    assert {:ok, persisted_after_cleanup} = Ets.prefix_scan(event_prefix)
    assert length(persisted_after_cleanup) == 2
    assert {:ok, [replayed]} = EventBridge.replay(Key.zone_rr_prefix(@view, zone) <> "*", 0)
    assert replayed.operation_id == header.operation_id
    assert replayed.cursor == 1
    EventBridge.unsubscribe(subscription)
  end

  test "unknown event persistence outcomes resolve by strong durable event reread" do
    event_prefix = "event_log:zone-replacement:"

    before_zone = "event-timeout-before.example.com"
    :ok = Zone.create_zone(@view, before_zone, @soa, serial_strategy: :increment)
    use_failure_backend([{:put_if_prefix, event_prefix, {:error, :timeout}}])

    assert {:error, {:replace_failed, {:recovery_failed, {:event_persist_failed, :timeout}}}} =
             Zone.replace_records(@view, before_zone, records(1))

    {_key, before_header} = replacement_header(before_zone)
    assert before_header.phase == :events
    assert before_header.event_state.cursor == 0

    FailureBackend.reset()
    assert {:ok, [_record]} = Zone.list_records(@view, before_zone)

    after_zone = "event-timeout-after.example.com"
    Backend.set_active(Ets)
    :ok = Zone.create_zone(@view, after_zone, @soa, serial_strategy: :increment)
    use_failure_backend([{:put_if_prefix, event_prefix, {:write_then_error, :timeout}}])

    assert {:ok, %{changed_count: 1}} = Zone.replace_records(@view, after_zone, records(1))
    assert {:ok, [_record]} = Zone.list_records(@view, after_zone)
  end

  test "unknown apply outcomes before and after commit resolve from the strong durable cursor" do
    outcomes = [{:error, :timeout}, {:delegate_then, {:error, :timeout}}]

    Enum.each(Enum.with_index(outcomes), fn {outcome, index} ->
      zone = "unknown-#{index}.example.com"
      :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)
      use_failure_backend([{:txn, {:apply, 1, :finalizing}, outcome}])

      assert {:ok, %{changed_count: 2}} = Zone.replace_records(@view, zone, records(2))
      assert {:ok, stored} = Zone.list_records(@view, zone)
      assert length(stored) == 2
      assert {:ok, metadata} = Zone.get_zone(@view, zone)
      assert metadata.soa.serial == 101
      assert_no_recovery_state()
      Backend.set_active(Ets)
    end)
  end

  test "missing and corrupt applying chunks fail closed and remain for repair" do
    Enum.each([:missing, :corrupt], fn fault ->
      zone = "#{fault}-plan.example.com"
      :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)

      crash_replacement(zone, records(260), [
        {:txn, {:apply, 2, :applying}, {:exit, {:before_second_chunk, fault}}}
      ])

      {header_key, header} = replacement_header(zone)
      chunk_key = Key.zone_replacement_plan(header.operation_id, header.next_chunk)

      case fault do
        :missing -> Ets.delete(chunk_key)
        :corrupt -> Ets.put(chunk_key, [:corrupt])
      end

      assert {:error, {:recovery_failed, {:corrupt_applying_plan, _reason}}} =
               Zone.list_records(@view, zone)

      assert {:error,
              {:replace_failed, {:recovery_failed, {:corrupt_applying_plan, _replace_reason}}}} =
               Zone.replace_records(@view, zone, records(1))

      assert {:ok, ^header} = Ets.get(header_key)
      Backend.set_active(Ets)
      YellowDog.StoreHelper.clear_store()
    end)
  end

  test "1001 records recover after a caller exit and use bounded transaction specs" do
    zone = "thousand.example.com"
    :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)
    use_failure_backend([{:txn, :finalize, {:delegate_then_exit, :after_finalize}}])
    {_pid, monitor} = spawn_replacement(zone, records(1001))
    assert_receive {:DOWN, ^monitor, :process, _pid, :after_finalize}, 10_000

    apply_specs = apply_specs(FailureBackend.calls())
    assert length(apply_specs) == 8

    Enum.each(apply_specs, fn spec ->
      assert data_operation_count(spec) <= 127
      assert :erlang.external_size(spec) <= Zone.max_replacement_transaction_bytes()
    end)

    {_header_key, header} = replacement_header(zone)
    assert header.phase == :events
    FailureBackend.reset()

    assert {:ok, stored} = Zone.list_records(@view, zone)
    assert length(stored) == 1001

    plan_reads =
      Enum.count(FailureBackend.calls(), fn
        {:get, key, [consistency: :strong]} ->
          String.starts_with?(key, Key.zone_replacement_plan_prefix(header.operation_id))

        _call ->
          false
      end)

    assert plan_reads == header.plan_count
  end

  test "byte-size chunking stays below the conservative transaction bound" do
    zone = "byte-bounded.example.com"
    payload = String.duplicate("x", 310_000)
    records = for index <- 1..3, do: desired_record("txt-#{index}", %{text: payload})
    :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)
    use_failure_backend()

    assert {:ok, %{changed_count: 3}} = Zone.replace_records(@view, zone, records)
    specs = apply_specs(FailureBackend.calls())
    assert length(specs) >= 2

    assert Enum.all?(
             specs,
             &(:erlang.external_size(&1) <= Zone.max_replacement_transaction_bytes())
           )
  end

  test "concurrent facade reads wait and observe only the complete new state" do
    zone = "observable.example.com"
    old = desired_record("old", %{address: {192, 0, 2, 1}})
    desired = records(130)
    :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)
    :ok = Zone.put_rrset(@view, zone, old.owner, old.type, old.rrset)
    {:ok, before} = Zone.get_zone(@view, zone)
    parent = self()
    barrier = make_ref()

    use_failure_backend([
      {:txn, {:apply, 1, :applying}, {:barrier_after, parent, barrier, :pass}}
    ])

    {replace_pid, replace_monitor} = spawn_replacement(zone, desired)
    assert_receive {:backend_barrier, ^barrier, ^replace_pid}, 5_000

    reader = Task.async(fn -> Zone.list_records(@view, zone) end)
    refute Task.yield(reader, 100)
    send(replace_pid, {:release_backend, barrier})

    assert {:ok, records} = Task.await(reader, 10_000)
    assert length(records) == 130
    assert_receive {:DOWN, ^replace_monitor, :process, ^replace_pid, :normal}, 10_000
    assert {:ok, after_zone} = Zone.get_zone(@view, zone)
    assert after_zone.soa.serial == before.soa.serial + 1
  end

  test "all public zone reads use strong consistency after recovery" do
    zone = "strong-reads.example.com"
    record = desired_record("www", %{address: {192, 0, 2, 10}})
    :ok = Zone.create_zone(@view, zone, @soa)
    :ok = Zone.put_rrset(@view, zone, record.owner, record.type, record.rrset)
    use_failure_backend()

    assert {:ok, _zone} = Zone.get_zone(@view, zone)
    assert {:ok, _record} = Zone.get_rrset(@view, zone, record.owner, record.type)
    assert {:ok, [_record]} = Zone.list_records(@view, zone)
    assert {:ok, [_record]} = Zone.list_records(@view, zone, record.owner)
    assert {:ok, _zones} = Zone.list_zones()
    assert {:ok, _zones} = Zone.list_zones_for_view(@view)

    observable_reads =
      Enum.filter(FailureBackend.calls(), fn
        {:get, key, _opts} -> String.starts_with?(key, "dns:view:")
        {:prefix_scan, key, _opts} -> String.starts_with?(key, "dns:view:")
        _call -> false
      end)

    assert observable_reads != []

    assert Enum.all?(observable_reads, fn {_operation, _key, opts} ->
             opts[:consistency] == :strong
           end)
  end

  test "lazy zone ID persistence recovers under one captured backend immediately before CAS" do
    zone = "legacy-id-recovery.example.com"
    zone_key = Key.zone(@view, zone)
    header_key = Key.zone_replacement_header(@view, zone)
    :ok = Zone.create_zone(@view, zone, @soa)
    {:ok, persisted} = Ets.get(zone_key)
    :ok = Ets.put(zone_key, Map.delete(persisted, :id))

    use_failure_backend([
      {:prefix_scan, Key.zone_prefix(@view), {:delegate_then_set_active, TrapBackend}}
    ])

    assert {:ok, zones} = Zone.list_zones_for_view(@view)
    assert Enum.any?(zones, &(&1.origin == zone and is_binary(&1.id)))
    assert {:ok, %{id: id}} = Ets.get(zone_key)
    assert is_binary(id)

    calls = FailureBackend.calls()

    recovery_index =
      Enum.find_index(calls, &match?({:get, ^header_key, [consistency: :strong]}, &1))

    cas_index = Enum.find_index(calls, &match?({:put_if, ^zone_key, _opts}, &1))
    assert is_integer(recovery_index)
    assert is_integer(cas_index)
    assert recovery_index < cas_index
  end

  test "legacy ID backfill rejects key and payload scope mismatch without taking payload lock" do
    key_zone = "keyed-a.example.com"
    payload_zone = "payload-b.example.com"
    key = Key.zone(@view, key_zone)
    :ok = Zone.create_zone(@view, payload_zone, @soa)
    {:ok, payload} = Ets.get(Key.zone(@view, payload_zone))
    malformed = Map.delete(payload, :id)
    :ok = Ets.put(key, malformed)
    use_failure_backend()

    parent = self()

    holder =
      spawn(fn ->
        :global.trans({{Zone, :zone, @view, payload_zone}, self()}, fn ->
          send(parent, {:payload_lock_held, self()})

          receive do
            :release_payload_lock -> :ok
          end
        end)
      end)

    assert_receive {:payload_lock_held, ^holder}, 1_000
    list_task = Task.async(fn -> Zone.list_zones_for_view(@view) end)
    yielded = Task.yield(list_task, 500)
    send(holder, :release_payload_lock)
    completed = yielded || {:ok, Task.await(list_task, 2_000)}

    assert completed == {:ok, {:error, {:invalid_zone_metadata_scope, key}}}
    assert {:ok, ^malformed} = Ets.get(key, consistency: :strong)
    assert FailureBackend.writes() == []
  end

  test "no events are published before finalization and recovery publishes committed changes" do
    start_event_bridge()
    zone = "event-order.example.com"
    :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)
    {:ok, subscription} = EventBridge.subscribe("dns:view:#{@view}:zone:#{zone}:rr:*")

    use_failure_backend([
      {:txn, {:apply, 1, :finalizing}, {:delegate_then_exit, :after_apply}}
    ])

    {_pid, monitor} = spawn_replacement(zone, records(2))
    assert_receive {:DOWN, ^monitor, :process, _pid, :after_apply}, 5_000
    refute_receive {:store_event, _event}, 100

    assert {:ok, records} = Zone.list_records(@view, zone)
    assert length(records) == 2
    assert_receive {:store_event, %{type: :put}}, 5_000
    EventBridge.unsubscribe(subscription)
  end

  test "legacy mutation, replacement, and delete recover first and cannot bypass fencing" do
    mutation_zone = "legacy-put.example.com"
    :ok = Zone.create_zone(@view, mutation_zone, @soa, serial_strategy: :increment)

    crash_replacement(mutation_zone, records(130), [
      {:txn, {:apply, 1, :applying}, {:delegate_then_exit, :legacy_put}}
    ])

    Backend.set_active(FailureBackend)
    assert :ok = Zone.put_rrset(@view, mutation_zone, "legacy", :a, [%{ttl: 60, rdata: :legacy}])
    assert {:ok, mutation_meta} = Zone.get_zone(@view, mutation_zone)
    assert mutation_meta.soa.serial == 102

    replacement_zone = "legacy-replace.example.com"
    Backend.set_active(Ets)
    :ok = Zone.create_zone(@view, replacement_zone, @soa, serial_strategy: :increment)

    crash_replacement(replacement_zone, records(130), [
      {:txn, {:apply, 1, :applying}, {:delegate_then_exit, :legacy_replace}}
    ])

    Backend.set_active(FailureBackend)

    assert {:ok, %{changed_count: 131}} =
             Zone.replace_records(@view, replacement_zone, [desired_record("final", %{value: 1})])

    assert {:ok, replacement_meta} = Zone.get_zone(@view, replacement_zone)
    assert replacement_meta.soa.serial == 102

    delete_zone = "legacy-delete.example.com"
    Backend.set_active(Ets)
    :ok = Zone.create_zone(@view, delete_zone, @soa, serial_strategy: :increment)

    crash_replacement(delete_zone, records(130), [
      {:txn, {:apply, 1, :applying}, {:delegate_then_exit, :legacy_delete}}
    ])

    Backend.set_active(FailureBackend)
    assert :ok = Zone.delete_zone(@view, delete_zone)
    assert {:error, :not_found} = Zone.get_zone(@view, delete_zone)
  end

  test "stale transaction generation cannot mutate or delete a later intent" do
    key = Key.zone_replacement_header(@view, "fenced.example.com")
    stale = %{operation_id: "old", generation: 1}
    current = %{operation_id: "new", generation: 2}
    :ok = Ets.put(key, current)

    spec = %{
      compare: [{:value, key, :==, stale}],
      success: [{:delete, {:key, key}, %{}}],
      failure: []
    }

    assert {:ok, %{succeeded: false}} = Ets.txn(spec)
    assert {:ok, ^current} = Ets.get(key)
  end

  test "scanned replacement header keys must match their payload scope" do
    payload = %{view_name: @view, zone: "payload.example.com"}
    actual_key = Key.zone_replacement_header(@view, "different.example.com")
    expected_key = Key.zone_replacement_header(@view, payload.zone)
    :ok = Ets.put(actual_key, payload)

    assert {:error, {:recovery_failed, {:header_key_mismatch, ^actual_key, ^expected_key}}} =
             Zone.recover_pending_replacements()

    assert {:ok, ^payload} = Ets.get(actual_key)
  end

  test "unknown transitions fence immutable changes and non-monotonic progress" do
    cases = [
      {"immutable", %{base_zone: %{tampered: true}}},
      {"regression", %{phase: :preparing, next_chunk: 1}}
    ]

    Enum.each(cases, fn {name, updates} ->
      zone = "transition-#{name}.example.com"
      :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)

      use_failure_backend([
        {:txn, :begin_applying, {:delegate_then_tamper_header, updates, {:error, :timeout}}}
      ])

      assert {:error, {:replace_failed, {:recovery_failed, :fenced}}} =
               Zone.replace_records(@view, zone, records(1))

      assert {:ok, []} = Ets.prefix_scan(Key.zone_rr_prefix(@view, zone))
      Backend.set_active(Ets)
      YellowDog.StoreHelper.clear_store()
    end)
  end

  test "legacy backends retain Phase 3B1 compensation and public errors" do
    zone = "legacy-compensation.example.com"
    old = desired_record("old", %{value: 1})
    updated = desired_record("old", %{value: 2})
    added = desired_record("new", %{value: 3})
    :ok = Zone.create_zone(@view, zone, @soa, serial_strategy: :increment)
    :ok = Zone.put_rrset(@view, zone, old.owner, old.type, old.rrset)
    {:ok, previous} = Zone.list_records(@view, zone)
    FailureBackend.configure([{:put_many, {:partial, 1, {:error, :batch_failed}}}])
    Backend.set_active(LegacyBackend)

    assert {:error, {:replace_failed, {:put_many_failed, :batch_failed}}} =
             Zone.replace_records(@view, zone, [updated, added])

    assert {:ok, ^previous} = Zone.list_records(@view, zone)
  end

  defp records(count) do
    for index <- 1..count do
      desired_record("host-#{index}", %{address: {192, 0, div(index, 256), rem(index, 256)}})
    end
  end

  defp desired_record(owner, rdata) do
    %{owner: owner, type: :a, rrset: [%{ttl: 300, rdata: rdata}]}
  end

  defp use_failure_backend(actions \\ []) do
    Backend.set_active(FailureBackend)
    FailureBackend.configure(actions)
  end

  defp crash_replacement(zone, records, actions) do
    use_failure_backend(actions)
    {pid, monitor} = spawn_replacement(zone, records)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 10_000
  end

  defp spawn_replacement(zone, records) do
    parent = self()

    spawn_monitor(fn ->
      result = Zone.replace_records(@view, zone, records)
      send(parent, {:replacement_result, self(), result})
    end)
  end

  defp replacement_header(zone) do
    key = Key.zone_replacement_header(@view, zone)
    {:ok, header} = Ets.get(key)
    {key, header}
  end

  defp assert_no_recovery_state do
    assert {:ok, []} = Ets.prefix_scan(Key.zone_replacement_header_prefix())
    assert {:ok, []} = Ets.prefix_scan("store:zone-replacement:plan:")
  end

  defp apply_specs(calls) do
    calls
    |> Enum.flat_map(fn
      {:txn, %{success: operations} = spec} ->
        if Enum.any?(operations, fn
             {:put, key, _value, _opts} -> String.contains?(key, ":rr:")
             {:delete, {:key, key}, _opts} -> String.contains?(key, ":rr:")
             _other -> false
           end),
           do: [spec],
           else: []

      _call ->
        []
    end)
  end

  defp data_operation_count(%{success: operations}) do
    Enum.count(operations, fn
      {:put, key, _value, _opts} -> String.contains?(key, ":rr:")
      {:delete, {:key, key}, _opts} -> String.contains?(key, ":rr:")
      _other -> false
    end)
  end

  defp start_event_bridge do
    case Process.whereis(EventBridge) do
      nil -> start_supervised!(EventBridge)
      _pid -> :ok
    end
  end
end
