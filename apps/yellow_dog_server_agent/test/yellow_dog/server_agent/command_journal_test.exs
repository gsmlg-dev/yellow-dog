defmodule YellowDog.ServerAgent.CommandJournalTest do
  use ExUnit.Case, async: false

  Code.require_file("../../support/command_journal_support.ex", __DIR__)

  alias YellowDog.ServerAgent.CommandJournal
  alias YellowDog.ServerAgent.CommandJournalFailingScanner
  alias YellowDog.ServerAgent.CommandJournalTestClock
  alias YellowDog.ServerAgent.CommandJournalTestFileOps
  alias YellowDog.ServerAgent.CommandJournalTraversalScanner
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message
  alias YellowDog.Sync.Message.Journal

  @server_id "server-east-1"
  @capability "runtime.services"
  @request_id "11111111-1111-4111-8111-111111111111"
  @other_request_id "22222222-2222-4222-8222-222222222222"
  @third_request_id "33333333-3333-4333-8333-333333333333"
  @idempotency_key "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @other_idempotency_key "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @third_idempotency_key "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
  @sent_at ~U[2026-07-17 01:00:00Z]
  @inserted_at ~U[2026-07-17 02:00:00Z]
  @running_at ~U[2026-07-17 02:01:00Z]
  @resolved_at ~U[2026-07-17 02:02:00Z]
  @recovered_at ~U[2026-07-17 02:03:00Z]

  setup do
    previous_trap_exit = Process.flag(:trap_exit, true)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-command-journal-#{System.unique_integer([:positive])}"
      )
      |> Path.expand()

    File.mkdir_p!(data_dir)

    on_exit(fn ->
      Process.flag(:trap_exit, previous_trap_exit)
      CommandJournalTestFileOps.clear()
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "requires an absolute canonical root and validated concrete configuration", %{
    data_dir: data_dir
  } do
    invalid_options = [
      [data_dir: "relative", server_id: @server_id, capabilities: [@capability]],
      [
        data_dir: Path.join(data_dir, "../not-canonical"),
        server_id: @server_id,
        capabilities: [@capability]
      ],
      [data_dir: data_dir, server_id: "", capabilities: [@capability]],
      [data_dir: data_dir, server_id: @server_id, capabilities: [@capability, @capability]],
      [data_dir: data_dir, server_id: @server_id, capabilities: [:runtime_services]],
      [data_dir: data_dir, server_id: @server_id, capabilities: [@capability], max_records: 0],
      [
        data_dir: data_dir,
        server_id: @server_id,
        capabilities: [@capability],
        max_records: 1_001
      ],
      [data_dir: data_dir, server_id: @server_id, capabilities: [@capability], clock: :bad]
    ]

    for opts <- invalid_options do
      assert {:error, :invalid_configuration} = CommandJournal.start_link([name: nil] ++ opts)
    end
  end

  test "validates command kind, Server identity, and capability before reserving", %{
    data_dir: data_dir
  } do
    {:ok, journal} = start_journal(data_dir, capabilities: [])

    assert_invalid(CommandJournal.reserve(envelope(), journal))
    refute File.exists?(journal_path(data_dir, @request_id))

    {:ok, capable_journal} = start_journal(data_dir, capabilities: [@capability])

    assert_invalid(CommandJournal.reserve(envelope(target_type: :netman), capable_journal))

    assert_invalid(CommandJournal.reserve(envelope(target_id: "server-west-1"), capable_journal))

    assert_invalid(
      CommandJournal.reserve(
        envelope(operation: "server.runtime.services.list", payload: %{}),
        capable_journal
      )
    )

    refute File.exists?(journal_path(data_dir, @request_id))
  end

  test "reserve durably creates the exact received document before returning", %{
    data_dir: data_dir
  } do
    {:ok, clock} = CommandJournalTestClock.start_link([@inserted_at])
    {:ok, journal} = start_journal(data_dir, clock: fn -> CommandJournalTestClock.now(clock) end)
    envelope = envelope()

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope, journal)

    assert %{
             "schema_version" => 1,
             "request_id" => @request_id,
             "envelope" => stored_envelope,
             "state" => "received",
             "result" => nil,
             "error" => nil,
             "idempotency_fingerprint" => %{
               "target_type" => "server",
               "target_id" => @server_id,
               "operation" => "server.runtime.services.start",
               "idempotency_key" => @idempotency_key,
               "expected_revision" => nil,
               "payload_digest" => payload_digest,
               "config_version" => nil
             },
             "inserted_at" => "2026-07-17T02:00:00Z",
             "updated_at" => "2026-07-17T02:00:00Z",
             "resolved_at" => nil
           } = document = read_document(data_dir, @request_id)

    assert Map.keys(document) |> Enum.sort() ==
             ~w(
               envelope error idempotency_fingerprint inserted_at request_id
               resolved_at result schema_version state updated_at
             )
             |> Enum.sort()

    assert stored_envelope == Envelope.to_wire(envelope)
    assert payload_digest == envelope.payload_digest
    refute Map.has_key?(stored_envelope, "config_version")
  end

  test "running and successful completion persist before their replies", %{data_dir: data_dir} do
    {:ok, clock} =
      CommandJournalTestClock.start_link([@inserted_at, @running_at, @resolved_at])

    {:ok, journal} = start_journal(data_dir, clock: fn -> CommandJournalTestClock.now(clock) end)
    result = success_result()

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    assert :ok = CommandJournal.mark_running(@request_id, journal)

    assert %{
             "state" => "running",
             "updated_at" => "2026-07-17T02:01:00Z",
             "resolved_at" => nil
           } = read_document(data_dir, @request_id)

    assert {:ok, ^result} = CommandJournal.complete_success(@request_id, result, journal)

    assert %{
             "state" => "succeeded",
             "result" => ^result,
             "error" => nil,
             "updated_at" => "2026-07-17T02:02:00Z",
             "resolved_at" => "2026-07-17T02:02:00Z"
           } = read_document(data_dir, @request_id)
  end

  test "rejects invalid success and failure outcomes without changing running evidence", %{
    data_dir: data_dir
  } do
    {:ok, journal} = start_journal(data_dir)
    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    assert :ok = CommandJournal.mark_running(@request_id, journal)

    assert_invalid(CommandJournal.complete_success(@request_id, %{}, journal))

    unsafe_error = %Error{
      code: :internal,
      message: "runtime failed",
      details: %{"path" => "/srv/secret"}
    }

    assert_invalid(CommandJournal.complete_failure(@request_id, unsafe_error, journal))

    assert %{"state" => "running", "result" => nil, "error" => nil} =
             read_document(data_dir, @request_id)
  end

  test "persists a validated sanitized failure and replays it exactly after restart", %{
    data_dir: data_dir
  } do
    {:ok, journal} = start_journal(data_dir)
    error = Error.new(:apply_failed, "service start failed", %{"service" => "dns"})

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    assert :ok = CommandJournal.mark_running(@request_id, journal)
    assert {:error, ^error} = CommandJournal.complete_failure(@request_id, error, journal)

    assert %{
             "state" => "failed",
             "result" => nil,
             "error" => %{
               "code" => "apply_failed",
               "message" => "service start failed",
               "details" => %{"service" => "dns"}
             },
             "resolved_at" => resolved_at
           } = read_document(data_dir, @request_id)

    assert is_binary(resolved_at)
    GenServer.stop(journal)

    {:ok, restarted} = start_journal(data_dir)
    assert {:replay, {:error, ^error}} = CommandJournal.reserve(envelope(), restarted)
    assert {:replay, {:error, ^error}} = CommandJournal.replay(envelope(), restarted)
  end

  test "replays exact success after restart and rejects changed request fingerprints", %{
    data_dir: data_dir
  } do
    {:ok, journal} = start_journal(data_dir)
    result = success_result()

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    assert :ok = CommandJournal.mark_running(@request_id, journal)
    assert {:ok, ^result} = CommandJournal.complete_success(@request_id, result, journal)
    persisted = read_document(data_dir, @request_id)
    GenServer.stop(journal)

    {:ok, restarted} = start_journal(data_dir)
    assert {:replay, {:ok, ^result}} = CommandJournal.reserve(envelope(), restarted)
    assert persisted == read_document(data_dir, @request_id)

    changed =
      envelope(
        payload: %{"service" => "dhcpv4"},
        idempotency_key: @other_idempotency_key
      )

    assert_conflict(CommandJournal.reserve(changed, restarted))
    assert persisted == read_document(data_dir, @request_id)
  end

  test "same idempotency key under another request ID conflicts regardless of intent", %{
    data_dir: data_dir
  } do
    {:ok, journal} = start_journal(data_dir)

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)

    duplicate_key =
      envelope(
        request_id: @other_request_id,
        idempotency_key: @idempotency_key
      )

    assert_conflict(CommandJournal.reserve(duplicate_key, journal))
    refute File.exists?(journal_path(data_dir, @other_request_id))
  end

  test "duplicates of received and running requests conflict", %{data_dir: data_dir} do
    {:ok, journal} = start_journal(data_dir)

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    assert_conflict(CommandJournal.reserve(envelope(), journal))

    assert :ok = CommandJournal.mark_running(@request_id, journal)
    assert_conflict(CommandJournal.replay(envelope(), journal))
  end

  test "restart converts running evidence to durable unknown without retry", %{
    data_dir: data_dir
  } do
    {:ok, first_clock} = CommandJournalTestClock.start_link([@inserted_at, @running_at])

    {:ok, journal} =
      start_journal(data_dir, clock: fn -> CommandJournalTestClock.now(first_clock) end)

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    assert :ok = CommandJournal.mark_running(@request_id, journal)
    GenServer.stop(journal)

    {:ok, recovery_clock} = CommandJournalTestClock.start_link([@recovered_at])

    {:ok, restarted} =
      start_journal(data_dir, clock: fn -> CommandJournalTestClock.now(recovery_clock) end)

    assert %{
             "state" => "unknown",
             "result" => nil,
             "error" => nil,
             "updated_at" => "2026-07-17T02:03:00Z",
             "resolved_at" => "2026-07-17T02:03:00Z"
           } = read_document(data_dir, @request_id)

    assert {:replay, {:unknown, @request_id}} =
             CommandJournal.reserve(envelope(), restarted)
  end

  test "hard capacity rejects new records and startup overflow", %{data_dir: data_dir} do
    {:ok, journal} = start_journal(data_dir, max_records: 1)
    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)

    assert_conflict(
      CommandJournal.reserve(
        envelope(
          request_id: @other_request_id,
          idempotency_key: @other_idempotency_key
        ),
        journal
      )
    )

    GenServer.stop(journal)

    File.cp!(
      journal_path(data_dir, @request_id),
      journal_path(data_dir, @other_request_id)
    )

    second_path = journal_path(data_dir, @other_request_id)

    second_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("request_id", @other_request_id)
    |> put_in(["envelope", "request_id"], @other_request_id)
    |> put_in(["envelope", "idempotency_key"], @other_idempotency_key)
    |> put_in(["idempotency_fingerprint", "idempotency_key"], @other_idempotency_key)
    |> then(&File.write!(second_path, Jason.encode!(&1)))

    assert {:error, {:journal_recovery_failed, :capacity}} =
             CommandJournal.start_link(base_opts(data_dir, max_records: 1, name: nil))
  end

  test "the fixed 1000-record maximum remains wire-projectable", %{data_dir: data_dir} do
    {:ok, journal} = start_journal(data_dir, max_records: 1_000)

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    assert :ok = CommandJournal.mark_running(@request_id, journal)

    assert {:ok, _result} =
             CommandJournal.complete_success(@request_id, success_result(), journal)

    GenServer.stop(journal)
    original = read_document(data_dir, @request_id)

    for index <- 1..999 do
      request_id = generated_request_id(index)
      idempotency_key = generated_idempotency_key(index)

      original
      |> Map.put("request_id", request_id)
      |> put_in(["envelope", "request_id"], request_id)
      |> put_in(["envelope", "idempotency_key"], idempotency_key)
      |> put_in(["idempotency_fingerprint", "idempotency_key"], idempotency_key)
      |> then(&File.write!(journal_path(data_dir, request_id), Jason.encode!(&1)))
    end

    {:ok, restarted} = start_journal(data_dir, max_records: 1_000)
    assert {:ok, %Journal{entries: entries}} = CommandJournal.wire_projection(restarted)
    assert length(entries) == 1_000
  end

  test "terminal replay and idempotency conflict precede full-capacity rejection", %{
    data_dir: data_dir
  } do
    {:ok, journal} = start_journal(data_dir, max_records: 1)
    result = success_result()

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    assert :ok = CommandJournal.mark_running(@request_id, journal)
    assert {:ok, ^result} = CommandJournal.complete_success(@request_id, result, journal)
    assert {:replay, {:ok, ^result}} = CommandJournal.reserve(envelope(), journal)

    assert {:error,
            %Error{
              code: :conflict,
              message: "command idempotency key conflicts",
              details: %{}
            }} =
             CommandJournal.reserve(
               envelope(request_id: @other_request_id, idempotency_key: @idempotency_key),
               journal
             )
  end

  test "startup rejects corrupt JSON, exact-key changes, identity swaps, and fingerprints", %{
    data_dir: data_dir
  } do
    for mutation <- [:json, :keys, :identity, :fingerprint] do
      case File.rm_rf(journal_directory(data_dir)) do
        {:ok, _files} -> :ok
        {:error, _reason, _file} -> flunk("failed to reset journal fixture")
      end

      {:ok, journal} = start_journal(data_dir)
      assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
      assert :ok = CommandJournal.mark_running(@request_id, journal)

      assert {:ok, _result} =
               CommandJournal.complete_success(@request_id, success_result(), journal)

      GenServer.stop(journal)
      path = journal_path(data_dir, @request_id)

      case mutation do
        :json ->
          File.write!(path, "{")

        :keys ->
          rewrite(path, &Map.put(&1, "unexpected", true))

        :identity ->
          rewrite(path, &put_in(&1, ["envelope", "target_id"], "server-west-1"))

        :fingerprint ->
          rewrite(
            path,
            &put_in(&1, ["idempotency_fingerprint", "payload_digest"], String.duplicate("f", 64))
          )
      end

      assert {:error, {:journal_recovery_failed, :corrupt}} =
               CommandJournal.start_link(base_opts(data_dir, name: nil))
    end
  end

  test "startup rejects invalid persisted success and error outcomes", %{data_dir: data_dir} do
    for mutation <- [:result, :error] do
      File.rm_rf!(journal_directory(data_dir))
      {:ok, journal} = start_journal(data_dir)
      assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
      assert :ok = CommandJournal.mark_running(@request_id, journal)

      case mutation do
        :result ->
          assert {:ok, _result} =
                   CommandJournal.complete_success(@request_id, success_result(), journal)

        :error ->
          assert {:error, %Error{}} =
                   CommandJournal.complete_failure(
                     @request_id,
                     Error.new(:apply_failed, "service start failed", %{}),
                     journal
                   )
      end

      GenServer.stop(journal)
      path = journal_path(data_dir, @request_id)

      case mutation do
        :result -> rewrite(path, &Map.put(&1, "result", %{}))
        :error -> rewrite(path, &put_in(&1, ["error", "details"], %{"path" => "/srv/secret"}))
      end

      assert {:error, {:journal_recovery_failed, :corrupt}} =
               CommandJournal.start_link(base_opts(data_dir, name: nil))
    end
  end

  test "startup rejects invalid names, stage files, directories, symlinks, and scanner failure",
       %{
         data_dir: data_dir
       } do
    directory = journal_directory(data_dir)
    File.mkdir_p!(directory)

    invalid_entries = [
      {"../escape.json", fn -> File.write!(Path.join(directory, "escape.JSON"), "{}") end},
      {"stage", fn -> File.write!(Path.join(directory, ".request.json.token.stage"), "{}") end},
      {"directory", fn -> File.mkdir_p!(Path.join(directory, "#{@request_id}.json")) end},
      {"symlink", fn -> File.ln_s!("/tmp", Path.join(directory, "#{@request_id}.json")) end}
    ]

    for {_case, create_entry} <- invalid_entries do
      File.rm_rf!(directory)
      File.mkdir_p!(directory)
      create_entry.()

      assert {:error, {:journal_recovery_failed, :corrupt}} =
               CommandJournal.start_link(base_opts(data_dir, name: nil))
    end

    assert {:error, {:journal_recovery_failed, :scan}} =
             CommandJournal.start_link(
               base_opts(data_dir, name: nil, directory_scanner: CommandJournalFailingScanner)
             )

    assert {:error, {:journal_recovery_failed, :corrupt}} =
             CommandJournal.start_link(
               base_opts(data_dir, name: nil, directory_scanner: CommandJournalTraversalScanner)
             )
  end

  test "startup rejects a symlinked journals directory", %{data_dir: data_dir} do
    File.mkdir_p!(Path.join(data_dir, "server"))
    File.ln_s!("/tmp", journal_directory(data_dir))

    assert {:error, {:journal_recovery_failed, :corrupt}} =
             CommandJournal.start_link(base_opts(data_dir, name: nil))
  end

  test "startup rejects symlinked data_dir without writing outside", %{data_dir: data_dir} do
    outside = "#{data_dir}-outside"
    File.mkdir_p!(outside)
    File.rm_rf!(data_dir)
    File.ln_s!(outside, data_dir)

    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, {:journal_recovery_failed, :corrupt}} =
             CommandJournal.start_link(base_opts(data_dir, name: nil))

    refute File.exists?(Path.join(outside, "server"))
  end

  test "startup rejects a symlinked server ancestor without writing outside", %{
    data_dir: data_dir
  } do
    outside = "#{data_dir}-outside"
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(data_dir, "server"))

    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, {:journal_recovery_failed, :corrupt}} =
             CommandJournal.start_link(base_opts(data_dir, name: nil))

    refute File.exists?(Path.join(outside, "journals"))
  end

  test "reserve rejects a final symlink to an exact outside document", %{data_dir: data_dir} do
    outside_data_dir = "#{data_dir}-outside"
    {:ok, outside_clock} = CommandJournalTestClock.start_link([@inserted_at])

    {:ok, outside_journal} =
      start_journal(outside_data_dir,
        clock: fn -> CommandJournalTestClock.now(outside_clock) end
      )

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), outside_journal)
    GenServer.stop(outside_journal)

    outside_path = journal_path(outside_data_dir, @request_id)
    outside_document = File.read!(outside_path)
    on_exit(fn -> File.rm_rf(outside_data_dir) end)

    {:ok, clock} = CommandJournalTestClock.start_link([@inserted_at])
    {:ok, journal} = start_journal(data_dir, clock: fn -> CommandJournalTestClock.now(clock) end)
    path = journal_path(data_dir, @request_id)
    File.ln_s!(outside_path, path)

    assert_conflict(CommandJournal.reserve(envelope(), journal))
    assert :miss = CommandJournal.replay(envelope(), journal)
    assert File.read!(outside_path) == outside_document
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(path)
  end

  test "a final symlink swapped before transition fail-stops without modifying outside", %{
    data_dir: data_dir
  } do
    {:ok, journal} = start_journal(data_dir)
    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)

    path = journal_path(data_dir, @request_id)
    outside_path = "#{data_dir}-outside.json"
    outside_document = File.read!(path)
    File.write!(outside_path, outside_document)
    File.rm!(path)
    File.ln_s!(outside_path, path)

    on_exit(fn -> File.rm(outside_path) end)

    assert_internal(CommandJournal.mark_running(@request_id, journal))
    assert_receive {:EXIT, ^journal, :command_journal_inconsistent_persistence}
    refute Process.alive?(journal)
    assert File.read!(outside_path) == outside_document
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(path)
  end

  test "reserve does not claim a record swapped to a symlink after durable creation", %{
    data_dir: data_dir
  } do
    {:ok, journal} =
      start_journal(data_dir, storage_opts: [file_ops: CommandJournalTestFileOps])

    path = journal_path(data_dir, @request_id)
    outside_path = "#{data_dir}-outside.json"
    File.write!(outside_path, "outside")

    CommandJournalTestFileOps.run_after(:sync_dir, fn ->
      File.rm!(path)
      File.ln_s!(outside_path, path)
    end)

    assert_internal(CommandJournal.reserve(envelope(), journal))
    assert :miss = CommandJournal.replay(envelope(), journal)
    assert File.read!(outside_path) == "outside"
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(path)
  end

  test "a post-transition symlink swap fail-stops without claiming the transition", %{
    data_dir: data_dir
  } do
    {:ok, journal} =
      start_journal(data_dir, storage_opts: [file_ops: CommandJournalTestFileOps])

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    path = journal_path(data_dir, @request_id)
    outside_path = "#{data_dir}-outside.json"
    File.write!(outside_path, "outside")

    CommandJournalTestFileOps.run_after(:sync_dir, fn ->
      File.rm!(path)
      File.ln_s!(outside_path, path)
    end)

    assert_internal(CommandJournal.mark_running(@request_id, journal))
    assert_receive {:EXIT, ^journal, :command_journal_inconsistent_persistence}
    refute Process.alive?(journal)
    assert File.read!(outside_path) == "outside"
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(path)
  end

  test "startup validates every record before recovering earlier pending evidence", %{
    data_dir: data_dir
  } do
    {:ok, journal} = start_journal(data_dir, max_records: 2)
    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)

    assert {:reserved, @other_request_id} =
             CommandJournal.reserve(
               envelope(
                 request_id: @other_request_id,
                 idempotency_key: @other_idempotency_key
               ),
               journal
             )

    pending = read_document(data_dir, @request_id)
    GenServer.stop(journal)
    File.write!(journal_path(data_dir, @other_request_id), "{")

    assert {:error, {:journal_recovery_failed, :corrupt}} =
             CommandJournal.start_link(base_opts(data_dir, max_records: 2, name: nil))

    assert pending == read_document(data_dir, @request_id)
  end

  test "persistence failures never advance in-memory journal state", %{data_dir: data_dir} do
    {:ok, journal} =
      start_journal(data_dir,
        storage_opts: [file_ops: CommandJournalTestFileOps]
      )

    CommandJournalTestFileOps.fail_next(:link)
    assert_internal(CommandJournal.reserve(envelope(), journal))
    assert :miss = CommandJournal.replay(envelope(), journal)

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)

    CommandJournalTestFileOps.fail_next(:rename)
    assert_internal(CommandJournal.mark_running(@request_id, journal))
    assert_conflict(CommandJournal.replay(envelope(), journal))

    assert :ok = CommandJournal.mark_running(@request_id, journal)
    CommandJournalTestFileOps.fail_next(:rename)
    assert_internal(CommandJournal.complete_success(@request_id, success_result(), journal))
    assert_conflict(CommandJournal.replay(envelope(), journal))
  end

  test "a post-rename error reconciles committed success and prevents later failure", %{
    data_dir: data_dir
  } do
    {:ok, journal} =
      start_journal(data_dir, storage_opts: [file_ops: CommandJournalTestFileOps])

    result = success_result()
    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    assert :ok = CommandJournal.mark_running(@request_id, journal)

    CommandJournalTestFileOps.fail_after(:rename, fn -> :ok end)
    assert {:ok, ^result} = CommandJournal.complete_success(@request_id, result, journal)
    assert %{"state" => "succeeded"} = read_document(data_dir, @request_id)

    assert_conflict(
      CommandJournal.complete_failure(
        @request_id,
        Error.new(:apply_failed, "late failure", %{}),
        journal
      )
    )

    assert %{"state" => "succeeded"} = read_document(data_dir, @request_id)
  end

  test "a directory-sync error reconciles committed success and prevents later failure", %{
    data_dir: data_dir
  } do
    {:ok, journal} =
      start_journal(data_dir, storage_opts: [file_ops: CommandJournalTestFileOps])

    result = success_result()
    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    assert :ok = CommandJournal.mark_running(@request_id, journal)

    CommandJournalTestFileOps.fail_next(:sync_dir)
    assert {:ok, ^result} = CommandJournal.complete_success(@request_id, result, journal)
    assert %{"state" => "succeeded"} = read_document(data_dir, @request_id)

    assert_conflict(
      CommandJournal.complete_failure(
        @request_id,
        Error.new(:apply_failed, "late failure", %{}),
        journal
      )
    )
  end

  test "a repeated directory-sync timeout reconciles committed success", %{
    data_dir: data_dir
  } do
    {:ok, journal} =
      start_journal(data_dir, storage_opts: [file_ops: CommandJournalTestFileOps])

    result = success_result()
    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    assert :ok = CommandJournal.mark_running(@request_id, journal)

    CommandJournalTestFileOps.fail_times(:sync_dir, :timeout, 2)
    assert {:ok, ^result} = CommandJournal.complete_success(@request_id, result, journal)
    assert {:replay, {:ok, ^result}} = CommandJournal.replay(envelope(), journal)
  end

  test "inconsistent durable evidence after replace fail-stops the journal", %{
    data_dir: data_dir
  } do
    for mutation <- [:other_terminal, :malformed, :missing] do
      File.rm_rf!(journal_directory(data_dir))

      {:ok, journal} =
        start_journal(data_dir, storage_opts: [file_ops: CommandJournalTestFileOps])

      assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
      assert :ok = CommandJournal.mark_running(@request_id, journal)
      path = journal_path(data_dir, @request_id)

      CommandJournalTestFileOps.fail_after(:rename, fn ->
        case mutation do
          :other_terminal ->
            rewrite(path, fn document ->
              document
              |> Map.put("state", "failed")
              |> Map.put("result", nil)
              |> Map.put("error", %{
                "code" => "apply_failed",
                "message" => "conflicting durable outcome",
                "details" => %{}
              })
            end)

          :malformed ->
            File.write!(path, "{")

          :missing ->
            File.rm!(path)
        end
      end)

      assert_internal(CommandJournal.complete_success(@request_id, success_result(), journal))
      assert_receive {:EXIT, ^journal, :command_journal_inconsistent_persistence}
      refute Process.alive?(journal)
    end
  end

  test "wire projection is validated, terminal-only, and sorted by request ID", %{
    data_dir: data_dir
  } do
    {:ok, journal} = start_journal(data_dir, max_records: 3)

    pending =
      envelope(
        request_id: @third_request_id,
        idempotency_key: @third_idempotency_key
      )

    failed =
      envelope(
        request_id: @other_request_id,
        idempotency_key: @other_idempotency_key
      )

    assert {:reserved, @third_request_id} = CommandJournal.reserve(pending, journal)
    assert {:reserved, @other_request_id} = CommandJournal.reserve(failed, journal)
    assert :ok = CommandJournal.mark_running(@other_request_id, journal)
    error = Error.new(:apply_failed, "service start failed", %{})
    assert {:error, ^error} = CommandJournal.complete_failure(@other_request_id, error, journal)

    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    assert :ok = CommandJournal.mark_running(@request_id, journal)

    assert {:ok, _result} =
             CommandJournal.complete_success(@request_id, success_result(), journal)

    assert {:ok,
            %Journal{
              target_type: :server,
              target_id: @server_id,
              entries: [
                %{
                  "request_id" => @request_id,
                  "operation" => "server.runtime.services.start",
                  "status" => "completed",
                  "result" => %{"service" => "dns", "state" => "running"},
                  "error" => nil
                },
                %{
                  "request_id" => @other_request_id,
                  "operation" => "server.runtime.services.start",
                  "status" => "failed",
                  "result" => nil,
                  "error" => %Error{
                    code: :apply_failed,
                    message: "service start failed",
                    details: %{}
                  }
                }
              ]
            } = projection} = CommandJournal.wire_projection(journal)

    assert {:ok, encoded} = Message.encode(projection)
    assert {:ok, ^projection} = Message.decode(encoded)
  end

  test "wire projection exposes recovered unknown with nil result and error", %{
    data_dir: data_dir
  } do
    {:ok, journal} = start_journal(data_dir)
    assert {:reserved, @request_id} = CommandJournal.reserve(envelope(), journal)
    GenServer.stop(journal)

    {:ok, restarted} = start_journal(data_dir)

    assert {:ok,
            %Journal{
              entries: [
                %{
                  "request_id" => @request_id,
                  "status" => "unknown",
                  "result" => nil,
                  "error" => nil
                }
              ]
            }} = CommandJournal.wire_projection(restarted)
  end

  defp start_journal(data_dir, opts \\ []) do
    CommandJournal.start_link(base_opts(data_dir, opts))
  end

  defp base_opts(data_dir, opts) do
    defaults = [
      name: nil,
      data_dir: data_dir,
      server_id: @server_id,
      capabilities: [@capability],
      max_records: 100
    ]

    Keyword.merge(defaults, opts)
  end

  defp envelope(opts \\ []) do
    payload = Keyword.get(opts, :payload, %{"service" => "dns"})
    {:ok, payload_digest} = Digest.calculate(payload)

    struct!(
      Envelope,
      Keyword.merge(
        [
          protocol_version: 1,
          request_id: @request_id,
          target_type: :server,
          target_id: @server_id,
          operation: "server.runtime.services.start",
          idempotency_key: @idempotency_key,
          payload: payload,
          payload_digest: payload_digest,
          expected_revision: nil,
          config_version: nil,
          sent_at: @sent_at
        ],
        opts
      )
    )
  end

  defp success_result, do: %{"service" => "dns", "state" => "running"}

  defp generated_request_id(index) do
    leading = index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(8, "0")
    "#{leading}-1111-4111-8111-111111111111"
  end

  defp generated_idempotency_key(index) do
    leading = index |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(8, "0")
    "#{leading}-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  end

  defp journal_directory(data_dir), do: Path.join([data_dir, "server", "journals"])

  defp journal_path(data_dir, request_id),
    do: Path.join(journal_directory(data_dir), "#{request_id}.json")

  defp read_document(data_dir, request_id) do
    data_dir
    |> journal_path(request_id)
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

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid, details: %{}}} = result
  end

  defp assert_conflict(result) do
    assert {:error, %Error{code: :conflict, details: %{}}} = result
  end

  defp assert_internal(result) do
    assert {:error, %Error{code: :internal, details: %{}}} = result
  end
end
