defmodule YellowDog.ServerAgent.ConfigApplyStoreTest do
  use ExUnit.Case, async: false

  Code.require_file("../../support/config_apply_store_support.ex", __DIR__)

  alias YellowDog.ServerAgent.ConfigApplyStore
  alias YellowDog.ServerAgent.ConfigApplyStoreTestClock
  alias YellowDog.ServerAgent.ConfigApplyStoreTestFileOps
  alias YellowDog.ServerAgent.ConfigStore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.ConfigState

  @server_id "server-east-1"
  @profile "dns_only"
  @operation "server.settings.update"
  @time_1 ~U[2026-07-17 09:00:00Z]
  @time_2 ~U[2026-07-17 09:01:00Z]
  @time_3 ~U[2026-07-17 09:02:00Z]
  @time_4 ~U[2026-07-17 09:03:00Z]
  @time_5 ~U[2026-07-17 09:04:00Z]
  @revision_a String.duplicate("a", 64)
  @revision_b String.duplicate("b", 64)

  setup do
    previous_trap_exit = Process.flag(:trap_exit, true)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-config-apply-store-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(data_dir)

    on_exit(fn ->
      Process.flag(:trap_exit, previous_trap_exit)
      ConfigApplyStoreTestFileOps.clear()
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "starts with the exact options and initial snapshot", %{data_dir: data_dir} do
    config_store = start_config_store(data_dir)
    store = start_apply_store(data_dir, config_store)

    assert {:ok,
            %{
              schema_version: 1,
              target_type: :server,
              target_id: @server_id,
              known_good: nil,
              runtime_status: :unconfigured,
              attempt: nil,
              observed_at: nil,
              published_through: 0,
              next_publication_sequence: 1,
              outbox: []
            }} = ConfigApplyStore.snapshot(store)

    refute File.exists?(apply_state_path(data_dir))

    invalid_options = [
      [data_dir: "relative", server_id: @server_id, profile: @profile],
      [data_dir: Path.join(data_dir, "../unsafe"), server_id: @server_id, profile: @profile],
      [data_dir: data_dir, server_id: "", profile: @profile],
      [data_dir: data_dir, server_id: "../server", profile: @profile],
      [data_dir: data_dir, server_id: "server\u0000", profile: @profile],
      [data_dir: data_dir, server_id: @server_id, profile: ""],
      [data_dir: data_dir, server_id: @server_id, profile: @profile, clock: :invalid],
      [data_dir: data_dir, server_id: @server_id, profile: @profile, max_bytes: 0],
      [
        data_dir: data_dir,
        server_id: @server_id,
        profile: @profile,
        config_store: :missing_store
      ],
      [data_dir: data_dir, server_id: @server_id, profile: @profile, unknown: true]
    ]

    for opts <- invalid_options do
      assert {:error, :invalid_options} =
               ConfigApplyStore.start_link([name: nil] ++ opts)
    end
  end

  test "preflight is non-mutating and enforces admit, resume, replay, and block gates", %{
    data_dir: data_dir
  } do
    config_store = start_config_store(data_dir)
    store = start_apply_store(data_dir, config_store, clock_values: clock_values())
    first = envelope(1)

    assert {:admit, :new} = ConfigApplyStore.preflight(first, store)
    assert {:error, %Error{code: :not_found}} = ConfigStore.current(config_store)
    refute File.exists?(apply_state_path(data_dir))

    candidate = stage(first, config_store)
    assert {:ok, _} = ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)
    assert {:resume, :staged} = ConfigApplyStore.preflight(first, store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 1}, store)
    assert {:resume, :before_validate} = ConfigApplyStore.preflight(first, store)

    other = envelope(2)
    assert_conflict(ConfigApplyStore.preflight(other, store))
    assert {:ok, ^candidate} = ConfigStore.current(config_store)

    assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 1}, store)
    assert_conflict(ConfigApplyStore.preflight(first, store))

    assert {:ok, _} =
             ConfigApplyStore.transition(
               :uncertain_after_side_effect,
               %{version: 1},
               store
             )

    assert {:replay, %{attempt: %{checkpoint: :unknown}}} =
             ConfigApplyStore.preflight(first, store)

    assert_conflict(ConfigApplyStore.preflight(other, store))
  end

  test "delivered requires the exact current immutable ConfigStore document", %{
    data_dir: data_dir
  } do
    for mutation <- [:mismatch, :missing, :corrupt] do
      test_dir = Path.join(data_dir, Atom.to_string(mutation))
      config_store = start_config_store(test_dir)
      store = start_apply_store(test_dir, config_store)
      delivery = envelope(1)
      candidate = stage(delivery, config_store)

      case mutation do
        :mismatch ->
          assert_invalid(
            ConfigApplyStore.transition(
              :delivered,
              %{candidate: %{candidate | "published_at" => "2026-07-17T07:00:00Z"}},
              store
            )
          )

        :missing ->
          File.rm!(version_path(test_dir, delivery))
          assert_invalid(ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store))

        :corrupt ->
          File.write!(version_path(test_dir, delivery), "{")
          assert_invalid(ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store))
      end

      assert {:ok, %{attempt: nil, outbox: []}} = ConfigApplyStore.snapshot(store)
    end
  end

  test "publishes exact delivered applying and applied messages with one timestamp each", %{
    data_dir: data_dir
  } do
    config_store = start_config_store(data_dir)

    store =
      start_apply_store(data_dir, config_store,
        clock_values: [@time_1, @time_2, @time_3, @time_4, @time_5]
      )

    delivery = envelope(1)
    candidate = stage(delivery, config_store)

    assert {:ok, delivered} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)

    assert delivered.observed_at == @time_1
    assert [%{message: delivered_message}] = delivered.outbox
    assert delivered_message == config_state(:delivered, delivery, @time_1)

    assert {:ok, _} =
             ConfigApplyStore.transition(:before_validate, %{version: 1}, store)

    assert {:ok, applying} =
             ConfigApplyStore.transition(:before_install, %{version: 1}, store)

    assert applying.observed_at == @time_3
    assert [%{}, %{message: applying_message}] = applying.outbox
    assert applying_message == config_state(:applying, delivery, @time_3)

    assert {:ok, _} =
             ConfigApplyStore.transition(
               :before_activate,
               %{version: 1, installed_revision: @revision_a},
               store
             )

    assert {:ok, applied} = ConfigApplyStore.transition(:applied, %{version: 1}, store)
    assert applied.observed_at == @time_5
    assert applied.runtime_status == :known
    assert applied.known_good == known_good(1, delivery.payload_digest, @revision_a)

    assert [%{}, %{}, %{message: applied_message}] = applied.outbox

    assert applied_message ==
             config_state(:applied, delivery, @time_5, applied_revision: @revision_a)

    assert_round_trip(applied.outbox)
    assert exact_document_keys(read_document(data_dir)) == top_level_keys()
  end

  test "validation failure retains known-good but publishes nil previous fields", %{
    data_dir: data_dir
  } do
    {store, config_store, first} = applied_store(data_dir)
    drain(store)
    second = envelope(2, expected_revision: @revision_a)
    candidate = stage(second, config_store)

    assert {:ok, _} = ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 2}, store)

    assert {:ok, failed} =
             ConfigApplyStore.transition(
               :validation_failed,
               %{version: 2, reason: "invalid runtime config"},
               store
             )

    assert failed.runtime_status == :known
    assert failed.known_good == known_good(1, first.payload_digest, @revision_a)
    assert failed.attempt.previous == nil
    assert failed.attempt.failure == %{phase: :validation, reason: "invalid runtime config"}
    assert failed.attempt.rollback == nil

    assert [%{}, %{message: message}] = failed.outbox

    assert message ==
             config_state(:failed, second, failed.observed_at,
               failure: %{"phase" => "validation", "reason" => "invalid runtime config"}
             )
  end

  test "apply failure without known-good latches unknown and publishes nil rollback", %{
    data_dir: data_dir
  } do
    {store, _config_store, delivery} = delivered_store(data_dir)
    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 1}, store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 1}, store)

    assert {:ok, failed} =
             ConfigApplyStore.transition(
               :apply_failed,
               %{version: 1, reason: "install failed"},
               store
             )

    assert failed.runtime_status == :unknown
    assert failed.known_good == nil
    assert failed.attempt.failure == %{phase: :apply, reason: "install failed"}
    assert failed.attempt.rollback == nil

    assert [%{}, %{}, %{message: message}] = failed.outbox

    assert message ==
             config_state(:failed, delivery, failed.observed_at,
               failure: %{"phase" => "apply", "reason" => "install failed"}
             )
  end

  test "rollback success and rollback failure preserve exact runtime evidence", %{
    data_dir: data_dir
  } do
    for outcome <- [:succeeded, :failed] do
      test_dir = Path.join(data_dir, Atom.to_string(outcome))
      {store, config_store, first} = applied_store(test_dir)
      drain(store)
      second = envelope(2, expected_revision: @revision_a)
      candidate = stage(second, config_store)

      assert {:ok, _} = ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)
      assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 2}, store)
      assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 2}, store)

      assert {:ok, _} =
               ConfigApplyStore.transition(
                 :before_activate,
                 %{version: 2, installed_revision: @revision_b},
                 store
               )

      assert {:ok, restoring} =
               ConfigApplyStore.transition(
                 :before_restore,
                 %{version: 2, trigger_reason: "activation failed"},
                 store
               )

      assert restoring.runtime_status == :unknown
      assert restoring.attempt.failure == %{phase: :apply, reason: "activation failed"}
      assert restoring.attempt.rollback.status == :before_restore

      if outcome == :succeeded do
        assert {:ok, _} =
                 ConfigApplyStore.transition(:before_reactivate, %{version: 2}, store)

        assert {:ok, terminal} =
                 ConfigApplyStore.transition(:rollback_succeeded, %{version: 2}, store)

        assert terminal.runtime_status == :known
        assert terminal.known_good == known_good(1, first.payload_digest, @revision_a)
        assert terminal.attempt.rollback.succeeded

        assert List.last(terminal.outbox).message ==
                 config_state(:failed, second, terminal.observed_at,
                   previous_version: 1,
                   previous_revision: @revision_a,
                   failure: %{"phase" => "apply", "reason" => "activation failed"},
                   rollback: %{
                     "succeeded" => true,
                     "restored_version" => 1,
                     "restored_revision" => @revision_a,
                     "reason" => nil
                   }
                 )
      else
        assert {:ok, terminal} =
                 ConfigApplyStore.transition(
                   :rollback_failed,
                   %{version: 2, reason: "restore failed"},
                   store
                 )

        assert terminal.runtime_status == :unknown
        assert terminal.attempt.failure == %{phase: :rollback, reason: "restore failed"}
        refute terminal.attempt.rollback.succeeded

        assert List.last(terminal.outbox).message ==
                 config_state(:failed, second, terminal.observed_at,
                   previous_version: 1,
                   previous_revision: @revision_a,
                   failure: %{"phase" => "rollback", "reason" => "restore failed"},
                   rollback: %{
                     "succeeded" => false,
                     "restored_version" => nil,
                     "restored_revision" => nil,
                     "reason" => "restore failed"
                   }
                 )
      end
    end
  end

  test "alternate apply and rollback predecessors retain installed and rollback evidence", %{
    data_dir: data_dir
  } do
    {apply_store, _config_store, _delivery} = delivered_store(Path.join(data_dir, "apply"))
    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 1}, apply_store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 1}, apply_store)

    assert {:ok, _} =
             ConfigApplyStore.transition(
               :before_activate,
               %{version: 1, installed_revision: @revision_a},
               apply_store
             )

    assert {:ok, apply_failed} =
             ConfigApplyStore.transition(
               :apply_failed,
               %{version: 1, reason: "activation failed"},
               apply_store
             )

    assert apply_failed.attempt.installed_revision == @revision_a

    {rollback_store, config_store, _first} = applied_store(Path.join(data_dir, "rollback"))
    drain(rollback_store)
    second = envelope(2, expected_revision: @revision_a)
    candidate = stage(second, config_store)

    assert {:ok, _} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, rollback_store)

    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 2}, rollback_store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 2}, rollback_store)

    assert {:ok, _} =
             ConfigApplyStore.transition(
               :before_restore,
               %{version: 2, trigger_reason: "install failed"},
               rollback_store
             )

    assert {:ok, _} =
             ConfigApplyStore.transition(:before_reactivate, %{version: 2}, rollback_store)

    assert {:ok, rollback_failed} =
             ConfigApplyStore.transition(
               :rollback_failed,
               %{version: 2, reason: "reactivation failed"},
               rollback_store
             )

    assert rollback_failed.attempt.rollback.trigger_reason == "install failed"
    assert rollback_failed.attempt.rollback.status == :failed
  end

  test "enforces every predecessor and exact attrs map", %{data_dir: data_dir} do
    {store, _config_store, _delivery} = delivered_store(data_dir)

    illegal = [
      {:delivered, %{version: 1}},
      {:before_validate, %{"version" => 1}},
      {:before_validate, %{version: 1, extra: true}},
      {:validation_failed, %{version: 2, reason: "bad"}},
      {:before_activate, %{version: 1, installed_revision: @revision_a}},
      {:apply_failed, %{version: 1, reason: "too early"}},
      {:before_restore, %{version: 1, trigger_reason: "too early"}},
      {:before_reactivate, %{version: 1}},
      {:rollback_succeeded, %{version: 1}},
      {:rollback_failed, %{version: 1, reason: "too early"}},
      {:applied, %{version: 1}},
      {:uncertain_after_side_effect, %{version: 1}}
    ]

    for {event, attrs} <- illegal do
      assert_error(ConfigApplyStore.transition(event, attrs, store))
    end

    assert_error(ConfigApplyStore.transition(:unknown_event, %{}, store))

    assert {:ok, %{attempt: %{status: :delivered, checkpoint: :staged}}} =
             ConfigApplyStore.snapshot(store)
  end

  test "exact duplicate transitions are idempotent and conflicts do not consume the clock", %{
    data_dir: data_dir
  } do
    config_store = start_config_store(data_dir)
    {:ok, clock} = ConfigApplyStoreTestClock.start_link([@time_1, @time_2, @time_3])

    store =
      start_apply_store(data_dir, config_store,
        clock: fn -> ConfigApplyStoreTestClock.now(clock) end
      )

    delivery = envelope(1)
    candidate = stage(delivery, config_store)

    assert {:ok, first} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)

    assert {:ok, ^first} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)

    assert_invalid(
      ConfigApplyStore.transition(
        :delivered,
        %{candidate: %{candidate | "published_at" => "2026-07-17T07:00:00Z"}},
        store
      )
    )

    assert {:ok, before_validate} =
             ConfigApplyStore.transition(:before_validate, %{version: 1}, store)

    assert before_validate.observed_at == @time_2

    assert {:ok, ^before_validate} =
             ConfigApplyStore.transition(:before_validate, %{version: 1}, store)
  end

  test "known-good expected revision and fresh-agent replacement gates fail closed", %{
    data_dir: data_dir
  } do
    config_store = start_config_store(data_dir)
    store = start_apply_store(data_dir, config_store)

    assert_conflict(
      ConfigApplyStore.preflight(envelope(1, expected_revision: @revision_a), store)
    )

    {known_store, known_config_store, _first} = applied_store(Path.join(data_dir, "known"))
    drain(known_store)

    assert_conflict(ConfigApplyStore.preflight(envelope(2), known_store))

    second = envelope(2, expected_revision: @revision_a)
    assert {:admit, :new} = ConfigApplyStore.preflight(second, known_store)
    candidate = stage(second, known_config_store)

    assert {:ok, _} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, known_store)
  end

  test "outbox sequences stay contiguous and ack is head-only and idempotent", %{
    data_dir: data_dir
  } do
    {store, _config_store, _delivery} = applied_store(data_dir)

    assert {:ok, publications} = ConfigApplyStore.pending_publications(store)
    assert Enum.map(publications, & &1.sequence) == [1, 2, 3]
    assert_round_trip(publications)

    assert_conflict(ConfigApplyStore.acknowledge_publication(2, store))
    assert_conflict(ConfigApplyStore.acknowledge_publication(4, store))

    assert {:ok, after_one} = ConfigApplyStore.acknowledge_publication(1, store)
    assert after_one.published_through == 1
    assert Enum.map(after_one.outbox, & &1.sequence) == [2, 3]
    assert after_one.runtime_status == :known
    assert after_one.attempt.status == :applied

    assert {:ok, ^after_one} = ConfigApplyStore.acknowledge_publication(1, store)
    assert {:ok, _} = ConfigApplyStore.acknowledge_publication(2, store)
    assert {:ok, empty} = ConfigApplyStore.acknowledge_publication(3, store)
    assert empty.outbox == []
    assert empty.published_through == 3
    assert empty.next_publication_sequence == 4
    assert {:ok, []} = ConfigApplyStore.pending_publications(store)
  end

  test "terminal replacement continues publication sequence and capacity never exceeds three", %{
    data_dir: data_dir
  } do
    {store, config_store, _first} = applied_store(data_dir)
    drain(store)
    second = envelope(2, expected_revision: @revision_a)
    candidate = stage(second, config_store)

    assert {:ok, delivered} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)

    assert Enum.map(delivered.outbox, & &1.sequence) == [4]
    assert delivered.next_publication_sequence == 5

    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 2}, store)

    assert {:ok, failed} =
             ConfigApplyStore.transition(
               :validation_failed,
               %{version: 2, reason: "invalid candidate"},
               store
             )

    assert Enum.map(failed.outbox, & &1.sequence) == [4, 5]
    assert length(failed.outbox) <= 3
  end

  test "startup preserves pure checkpoints and converts every side-effect checkpoint to unknown",
       %{
         data_dir: data_dir
       } do
    for checkpoint <- [
          :staged,
          :before_validate,
          :before_install,
          :before_activate,
          :before_restore,
          :before_reactivate
        ] do
      test_dir = Path.join(data_dir, Atom.to_string(checkpoint))
      {store, config_store, _delivery} = store_at_checkpoint(test_dir, checkpoint)
      stop(store)

      restarted = start_apply_store(test_dir, config_store)
      assert {:ok, snapshot} = ConfigApplyStore.snapshot(restarted)

      if checkpoint in [:staged, :before_validate] do
        assert snapshot.attempt.checkpoint == checkpoint
        refute snapshot.runtime_status == :unknown
      else
        assert snapshot.attempt.checkpoint == :unknown
        assert snapshot.attempt.status == :applying
        assert snapshot.runtime_status == :unknown
      end
    end
  end

  test "startup rejects current staging mismatch, missing, and corrupt content", %{
    data_dir: data_dir
  } do
    for mutation <- [:mismatch, :missing, :corrupt] do
      test_dir = Path.join(data_dir, Atom.to_string(mutation))
      {store, config_store, delivery} = delivered_store(test_dir)
      stop(store)
      path = version_path(test_dir, delivery)

      case mutation do
        :mismatch ->
          rewrite(path, &Map.put(&1, "profile", "other"))

        :missing ->
          File.rm!(path)

        :corrupt ->
          File.write!(path, "{")
      end

      assert {:error, {:config_apply_recovery_failed, :staging}} =
               ConfigApplyStore.start_link(base_apply_opts(test_dir, config_store, name: nil))
    end
  end

  test "startup preserves every terminal state and preflight replays it without mutation", %{
    data_dir: data_dir
  } do
    for terminal <- [
          :applied,
          :validation_failed,
          :apply_failed,
          :rollback_succeeded,
          :rollback_failed
        ] do
      test_dir = Path.join(data_dir, Atom.to_string(terminal))
      {store, config_store, delivery} = terminal_store(test_dir, terminal)
      assert {:ok, before_restart} = ConfigApplyStore.snapshot(store)
      stop(store)

      restarted = start_apply_store(test_dir, config_store)
      assert {:ok, ^before_restart} = ConfigApplyStore.snapshot(restarted)
      assert {:replay, ^before_restart} = ConfigApplyStore.preflight(delivery, restarted)
    end
  end

  test "startup rejects impossible observed-at and previous-version relationships", %{
    data_dir: data_dir
  } do
    for mutation <- [:observed_at, :previous_version] do
      test_dir = Path.join(data_dir, Atom.to_string(mutation))
      {store, config_store, _delivery} = terminal_store(test_dir, :rollback_succeeded)
      stop(store)
      path = apply_state_path(test_dir)

      case mutation do
        :observed_at -> rewrite(path, &Map.put(&1, "observed_at", nil))
        :previous_version -> rewrite(path, &put_in(&1, ["attempt", "previous", "version"], 2))
      end

      assert {:error, {:config_apply_recovery_failed, :corrupt}} =
               ConfigApplyStore.start_link(base_apply_opts(test_dir, config_store, name: nil))
    end
  end

  test "typed replace errors reconcile intended, prior, and inconsistent content", %{
    data_dir: data_dir
  } do
    for outcome <- [:intended, :prior, :other, :missing, :corrupt] do
      test_dir = Path.join(data_dir, Atom.to_string(outcome))
      config_store = start_config_store(test_dir)

      store =
        start_apply_store(test_dir, config_store,
          storage_opts: [file_ops: ConfigApplyStoreTestFileOps]
        )

      delivery = envelope(1)
      candidate = stage(delivery, config_store)

      if outcome == :intended do
        ConfigApplyStoreTestFileOps.fail_after(:rename, fn -> :ok end, :timeout)

        assert {:ok, %{attempt: %{status: :delivered}}} =
                 ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)
      else
        assert {:ok, prior} =
                 ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)

        ConfigApplyStoreTestFileOps.fail_after(:rename, fn ->
          case outcome do
            :prior ->
              File.write!(apply_state_path(test_dir), Jason.encode!(durable(prior)))

            :other ->
              rewrite(apply_state_path(test_dir), &Map.put(&1, "runtime_status", "unknown"))

            :missing ->
              File.rm!(apply_state_path(test_dir))

            :corrupt ->
              File.write!(apply_state_path(test_dir), "{")
          end
        end)

        result = ConfigApplyStore.transition(:before_validate, %{version: 1}, store)

        if outcome == :prior do
          assert {:error, %Error{code: :internal}} = result
          assert {:ok, ^prior} = ConfigApplyStore.snapshot(store)
        else
          assert {:error, %Error{code: :internal}} = result

          assert_receive {:EXIT, ^store,
                          {:config_apply_inconsistent_persistence, :before_validate}}

          refute Process.alive?(store)
        end
      end
    end
  end

  test "initial replace error with missing final fail-stops", %{data_dir: data_dir} do
    config_store = start_config_store(data_dir)

    store =
      start_apply_store(data_dir, config_store,
        storage_opts: [file_ops: ConfigApplyStoreTestFileOps]
      )

    candidate = stage(envelope(1), config_store)
    ConfigApplyStoreTestFileOps.fail_next(:rename)

    assert {:error, %Error{code: :internal}} =
             ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)

    assert_receive {:EXIT, ^store, {:config_apply_inconsistent_persistence, :delivered}}
  end

  test "rejects path-chain and final-file symlinks without outside writes", %{data_dir: data_dir} do
    outside = "#{data_dir}-outside"
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    for component <- [:data_dir, :server] do
      test_dir = Path.join(data_dir, Atom.to_string(component))
      File.mkdir_p!(test_dir)
      path = if component == :data_dir, do: test_dir, else: Path.join(test_dir, "server")

      if component == :data_dir, do: File.rm_rf!(test_dir)
      File.ln_s!(outside, path)
      config_store = start_config_store(Path.join(data_dir, "safe-#{component}"))

      assert {:error, {:config_apply_recovery_failed, :path}} =
               ConfigApplyStore.start_link(base_apply_opts(test_dir, config_store, name: nil))
    end

    safe_dir = Path.join(data_dir, "final")
    config_store = start_config_store(safe_dir)
    File.mkdir_p!(Path.dirname(apply_state_path(safe_dir)))
    outside_file = Path.join(outside, "apply_state.json")
    File.write!(outside_file, Jason.encode!(initial_document()))
    File.ln_s!(outside_file, apply_state_path(safe_dir))

    assert {:error, {:config_apply_recovery_failed, :path}} =
             ConfigApplyStore.start_link(base_apply_opts(safe_dir, config_store, name: nil))

    assert Jason.decode!(File.read!(outside_file)) == initial_document()
  end

  test "rejects non-directories and read identity swaps", %{data_dir: data_dir} do
    non_directory = Path.join(data_dir, "non-directory")
    File.mkdir_p!(non_directory)
    File.write!(Path.join(non_directory, "server"), "not a directory")
    config_store = start_config_store(Path.join(data_dir, "safe-non-directory"))

    assert {:error, {:config_apply_recovery_failed, :path}} =
             ConfigApplyStore.start_link(base_apply_opts(non_directory, config_store, name: nil))

    swap_dir = Path.join(data_dir, "identity-swap")
    {store, swap_config_store, _delivery} = delivered_store(swap_dir)
    stop(store)
    path = apply_state_path(swap_dir)
    replacement = "#{path}.replacement"
    File.write!(replacement, File.read!(path))

    ConfigApplyStoreTestFileOps.run_after_return(:read, fn ->
      File.rename!(replacement, path)
    end)

    assert {:error, {:config_apply_recovery_failed, :corrupt}} =
             ConfigApplyStore.start_link(
               base_apply_opts(swap_dir, swap_config_store,
                 name: nil,
                 storage_opts: [file_ops: ConfigApplyStoreTestFileOps]
               )
             )
  end

  test "rejects corrupt unknown-key invalid-nullability and incoherent state documents", %{
    data_dir: data_dir
  } do
    for mutation <- [:json, :unknown_key, :nullability, :state, :outbox, :message] do
      test_dir = Path.join(data_dir, Atom.to_string(mutation))
      {store, config_store, _delivery} = delivered_store(test_dir)
      stop(store)
      path = apply_state_path(test_dir)

      case mutation do
        :json -> File.write!(path, "{")
        :unknown_key -> rewrite(path, &Map.put(&1, "extra", true))
        :nullability -> rewrite(path, &put_in(&1, ["attempt", "previous"], %{"version" => 1}))
        :state -> rewrite(path, &put_in(&1, ["attempt", "checkpoint"], "complete"))
        :outbox -> rewrite(path, &put_in(&1, ["outbox", Access.at(0), "sequence"], 2))
        :message -> rewrite(path, &put_in(&1, ["outbox", Access.at(0), "encoded_message"], "{}"))
      end

      assert {:error, {:config_apply_recovery_failed, :corrupt}} =
               ConfigApplyStore.start_link(base_apply_opts(test_dir, config_store, name: nil))
    end
  end

  defp applied_store(data_dir) do
    config_store = start_config_store(data_dir)

    store =
      start_apply_store(data_dir, config_store, clock_values: clock_values())

    delivery = envelope(1)
    candidate = stage(delivery, config_store)
    assert {:ok, _} = ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 1}, store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 1}, store)

    assert {:ok, _} =
             ConfigApplyStore.transition(
               :before_activate,
               %{version: 1, installed_revision: @revision_a},
               store
             )

    assert {:ok, _} = ConfigApplyStore.transition(:applied, %{version: 1}, store)
    {store, config_store, delivery}
  end

  defp delivered_store(data_dir) do
    config_store = start_config_store(data_dir)
    store = start_apply_store(data_dir, config_store, clock_values: clock_values())
    delivery = envelope(1)
    candidate = stage(delivery, config_store)
    assert {:ok, _} = ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)
    {store, config_store, delivery}
  end

  defp store_at_checkpoint(data_dir, checkpoint) do
    {store, config_store, delivery} = delivered_store(data_dir)

    if checkpoint != :staged do
      assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 1}, store)
    end

    if checkpoint in [:before_install, :before_activate, :before_restore, :before_reactivate] do
      assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 1}, store)
    end

    if checkpoint in [:before_activate, :before_restore, :before_reactivate] do
      assert {:ok, _} =
               ConfigApplyStore.transition(
                 :before_activate,
                 %{version: 1, installed_revision: @revision_a},
                 store
               )
    end

    if checkpoint in [:before_restore, :before_reactivate] do
      # A rollback checkpoint requires prior known-good evidence, so rebuild this case.
      stop(store)
      File.rm_rf!(data_dir)
      {known_store, known_config_store, _first} = applied_store(data_dir)
      drain(known_store)
      second = envelope(2, expected_revision: @revision_a)
      candidate = stage(second, known_config_store)

      assert {:ok, _} =
               ConfigApplyStore.transition(:delivered, %{candidate: candidate}, known_store)

      assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 2}, known_store)
      assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 2}, known_store)

      assert {:ok, _} =
               ConfigApplyStore.transition(
                 :before_restore,
                 %{version: 2, trigger_reason: "install failed"},
                 known_store
               )

      if checkpoint == :before_reactivate do
        assert {:ok, _} =
                 ConfigApplyStore.transition(:before_reactivate, %{version: 2}, known_store)
      end

      {known_store, known_config_store, second}
    else
      {store, config_store, delivery}
    end
  end

  defp terminal_store(data_dir, :applied), do: applied_store(data_dir)

  defp terminal_store(data_dir, :validation_failed) do
    {store, config_store, delivery} = delivered_store(data_dir)
    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 1}, store)

    assert {:ok, _} =
             ConfigApplyStore.transition(
               :validation_failed,
               %{version: 1, reason: "invalid candidate"},
               store
             )

    {store, config_store, delivery}
  end

  defp terminal_store(data_dir, :apply_failed) do
    {store, config_store, delivery} = delivered_store(data_dir)
    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 1}, store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 1}, store)

    assert {:ok, _} =
             ConfigApplyStore.transition(
               :apply_failed,
               %{version: 1, reason: "install failed"},
               store
             )

    {store, config_store, delivery}
  end

  defp terminal_store(data_dir, terminal)
       when terminal in [:rollback_succeeded, :rollback_failed] do
    {store, config_store, _first} = applied_store(data_dir)
    drain(store)
    delivery = envelope(2, expected_revision: @revision_a)
    candidate = stage(delivery, config_store)
    assert {:ok, _} = ConfigApplyStore.transition(:delivered, %{candidate: candidate}, store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_validate, %{version: 2}, store)
    assert {:ok, _} = ConfigApplyStore.transition(:before_install, %{version: 2}, store)

    assert {:ok, _} =
             ConfigApplyStore.transition(
               :before_restore,
               %{version: 2, trigger_reason: "install failed"},
               store
             )

    if terminal == :rollback_succeeded do
      assert {:ok, _} = ConfigApplyStore.transition(:before_reactivate, %{version: 2}, store)
      assert {:ok, _} = ConfigApplyStore.transition(:rollback_succeeded, %{version: 2}, store)
    else
      assert {:ok, _} =
               ConfigApplyStore.transition(
                 :rollback_failed,
                 %{version: 2, reason: "restore failed"},
                 store
               )
    end

    {store, config_store, delivery}
  end

  defp start_config_store(data_dir) do
    name = unique_name(:config_store)

    {:ok, pid} =
      ConfigStore.start_link(
        name: name,
        data_dir: data_dir,
        server_id: @server_id,
        profile: @profile
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    name
  end

  defp start_apply_store(data_dir, config_store, opts \\ []) do
    clock_values = Keyword.get(opts, :clock_values, clock_values())

    opts =
      if Keyword.has_key?(opts, :clock) do
        Keyword.delete(opts, :clock_values)
      else
        {:ok, clock} = ConfigApplyStoreTestClock.start_link(clock_values)

        opts
        |> Keyword.delete(:clock_values)
        |> Keyword.put(:clock, fn -> ConfigApplyStoreTestClock.now(clock) end)
      end

    {:ok, pid} = ConfigApplyStore.start_link(base_apply_opts(data_dir, config_store, opts))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  defp base_apply_opts(data_dir, config_store, opts) do
    defaults = [
      name: nil,
      data_dir: data_dir,
      server_id: @server_id,
      profile: @profile,
      config_store: config_store
    ]

    Keyword.merge(defaults, opts)
  end

  defp stage(delivery, config_store) do
    assert {:ok, candidate} = ConfigStore.stage(delivery, config_store)
    candidate
  end

  defp drain(store) do
    assert {:ok, publications} = ConfigApplyStore.pending_publications(store)

    for publication <- publications do
      assert {:ok, _} =
               ConfigApplyStore.acknowledge_publication(publication.sequence, store)
    end
  end

  defp stop(store) do
    if Process.alive?(store), do: GenServer.stop(store, :normal)
  end

  defp envelope(version, opts \\ []) do
    payload =
      Keyword.get(opts, :payload, %{
        "service" => "dns",
        "entries" => [
          %{"key" => "timeout", "value" => %{"type" => "integer", "value" => version}}
        ]
      })

    {:ok, digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: uuid(version),
      target_type: Keyword.get(opts, :target_type, :server),
      target_id: Keyword.get(opts, :target_id, @server_id),
      operation: Keyword.get(opts, :operation, @operation),
      idempotency_key: uuid(version + 100),
      payload: payload,
      payload_digest: Keyword.get(opts, :payload_digest, digest),
      expected_revision: Keyword.get(opts, :expected_revision),
      config_version: Keyword.get(opts, :config_version, version),
      sent_at: Keyword.get(opts, :sent_at, ~U[2026-07-17 08:00:00Z])
    }
  end

  defp config_state(state, delivery, observed_at, opts \\ []) do
    %ConfigState{
      target_type: :server,
      target_id: @server_id,
      operation: @operation,
      state: state,
      version: delivery.config_version,
      digest: delivery.payload_digest,
      applied_revision: Keyword.get(opts, :applied_revision),
      previous_version: Keyword.get(opts, :previous_version),
      previous_revision: Keyword.get(opts, :previous_revision),
      failure: Keyword.get(opts, :failure),
      rollback: Keyword.get(opts, :rollback),
      observed_at: observed_at
    }
  end

  defp assert_round_trip(publications) do
    for publication <- publications do
      assert {:ok, publication.message} == Message.decode(publication.encoded_message)
      assert {:ok, publication.encoded_message} == Message.encode(publication.message)
    end
  end

  defp known_good(version, digest, revision),
    do: %{version: version, digest: digest, revision: revision}

  defp durable(snapshot) do
    %{
      "schema_version" => snapshot.schema_version,
      "target_type" => Atom.to_string(snapshot.target_type),
      "target_id" => snapshot.target_id,
      "known_good" => durable_known_good(snapshot.known_good),
      "runtime_status" => Atom.to_string(snapshot.runtime_status),
      "attempt" => durable_attempt(snapshot.attempt),
      "observed_at" => encode_time(snapshot.observed_at),
      "published_through" => snapshot.published_through,
      "next_publication_sequence" => snapshot.next_publication_sequence,
      "outbox" =>
        Enum.map(snapshot.outbox, fn entry ->
          %{"sequence" => entry.sequence, "encoded_message" => entry.encoded_message}
        end)
    }
  end

  defp durable_known_good(nil), do: nil

  defp durable_known_good(value) do
    %{
      "version" => value.version,
      "digest" => value.digest,
      "revision" => value.revision
    }
  end

  defp durable_attempt(nil), do: nil

  defp durable_attempt(value) do
    %{
      "version" => value.version,
      "digest" => value.digest,
      "operation" => value.operation,
      "profile" => value.profile,
      "expected_revision" => value.expected_revision,
      "status" => Atom.to_string(value.status),
      "checkpoint" => Atom.to_string(value.checkpoint),
      "previous" => durable_known_good(value.previous),
      "installed_revision" => value.installed_revision,
      "failure" => durable_failure(value.failure),
      "rollback" => durable_rollback(value.rollback)
    }
  end

  defp durable_failure(nil), do: nil

  defp durable_failure(value),
    do: %{"phase" => Atom.to_string(value.phase), "reason" => value.reason}

  defp durable_rollback(nil), do: nil

  defp durable_rollback(value) do
    %{
      "trigger_reason" => value.trigger_reason,
      "status" => Atom.to_string(value.status),
      "succeeded" => value.succeeded,
      "restored_version" => value.restored_version,
      "restored_revision" => value.restored_revision,
      "reason" => value.reason
    }
  end

  defp initial_document do
    %{
      "schema_version" => 1,
      "target_type" => "server",
      "target_id" => @server_id,
      "known_good" => nil,
      "runtime_status" => "unconfigured",
      "attempt" => nil,
      "observed_at" => nil,
      "published_through" => 0,
      "next_publication_sequence" => 1,
      "outbox" => []
    }
  end

  defp read_document(data_dir) do
    data_dir
    |> apply_state_path()
    |> File.read!()
    |> Jason.decode!()
  end

  defp rewrite(path, mutation) do
    path
    |> File.read!()
    |> Jason.decode!()
    |> mutation.()
    |> then(&File.write!(path, Jason.encode!(&1)))
  end

  defp exact_document_keys(document), do: Map.keys(document) |> Enum.sort()

  defp top_level_keys do
    ~w(
      attempt known_good next_publication_sequence observed_at outbox
      published_through runtime_status schema_version target_id target_type
    )
    |> Enum.sort()
  end

  defp apply_state_path(data_dir), do: Path.join([data_dir, "server", "apply_state.json"])

  defp version_path(data_dir, delivery) do
    Path.join([
      data_dir,
      "server",
      "versions",
      "#{delivery.config_version}-#{delivery.payload_digest}.json"
    ])
  end

  defp uuid(value) do
    leading = value |> Integer.to_string(16) |> String.pad_leading(8, "0")
    "#{leading}-1111-4111-8111-111111111111"
  end

  defp unique_name(kind),
    do: {:global, {__MODULE__, kind, System.unique_integer([:positive])}}

  defp clock_values do
    [@time_1, @time_2, @time_3, @time_4, @time_5] ++
      List.duplicate(~U[2026-07-17 09:10:00Z], 20)
  end

  defp encode_time(nil), do: nil
  defp encode_time(value), do: DateTime.to_iso8601(value)

  defp assert_error(result) do
    assert {:error, %Error{code: code, details: %{}}} = result
    assert code in [:invalid, :conflict]
  end

  defp assert_invalid(result),
    do: assert({:error, %Error{code: :invalid, details: %{}}} = result)

  defp assert_conflict(result),
    do: assert({:error, %Error{code: :conflict, details: %{}}} = result)
end
