defmodule YellowDog.Management.ConfigVersionsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.ConfigVersion
  alias YellowDog.Management.ConfigVersions
  alias YellowDog.Management.Event
  alias YellowDog.Management.EventStore
  alias YellowDog.Management.ManifestStore
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Bounds
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message.ConfigState

  @digest_a String.duplicate("a", 64)
  @digest_b String.duplicate("b", 64)
  @max_version 9_223_372_036_854_775_807

  setup do
    previous_env =
      Map.new(
        [
          :data_dir,
          :atomic_json_file_ops,
          :config_version_file_ops_owner,
          :fail_config_manifest_write
        ],
        fn key ->
          {key, Application.fetch_env(:yellow_dog_management_core, key)}
        end
      )

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-config-versions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops)
    Application.delete_env(:yellow_dog_management_core, :config_version_file_ops_owner)
    Application.delete_env(:yellow_dog_management_core, :fail_config_manifest_write)
    restart_application()

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "publishes immutable monotonic versions independently per concrete target" do
    register_server("srv-a")
    register_server("srv-b")
    register_netman("netman-a")

    versions =
      1..8
      |> Task.async_stream(
        fn index ->
          ManagementCore.publish_server_config("srv-a", server_attrs(index))
        end,
        max_concurrency: 8,
        ordered: false
      )
      |> Enum.map(fn {:ok, {:ok, version}} -> version.version end)
      |> Enum.sort()

    assert versions == Enum.to_list(1..8)

    assert {:ok, %ConfigVersion{version: 1}} =
             ManagementCore.publish_server_config("srv-b", server_attrs(1))

    assert {:ok, %ConfigVersion{version: 1, target_type: :netman}} =
             ManagementCore.publish_netman_config("netman-a", netman_attrs())

    assert {:ok, first} = ManagementCore.get_server_config_version("srv-a", 1)
    assert {:ok, last} = ManagementCore.get_server_config_version("srv-a", 8)
    assert first.payload != last.payload
    refute first.digest == last.digest
  end

  test "validates target registration, concrete config operation, payload, and runtime CAS" do
    register_server("srv-validation")

    assert_error(
      ManagementCore.publish_server_config("missing", server_attrs(1)),
      :not_found
    )

    assert_error(
      ManagementCore.publish_server_config(
        "srv-validation",
        server_attrs(1, operation: "netman.resolved.config.update")
      ),
      :invalid
    )

    assert_error(
      ManagementCore.publish_server_config(
        "srv-validation",
        server_attrs(1, payload: %{"service" => "dns"})
      ),
      :invalid
    )

    assert {:ok, first} =
             ManagementCore.publish_server_config("srv-validation", server_attrs(1))

    first = apply_version(first)

    assert_error(
      ManagementCore.publish_server_config(
        "srv-validation",
        server_attrs(2, expected_revision: @digest_b)
      ),
      :conflict
    )

    assert {:ok, second} =
             ManagementCore.publish_server_config(
               "srv-validation",
               server_attrs(2, expected_revision: first.applied_revision)
             )

    assert second.previous_version == first.version
    assert second.previous_revision == first.applied_revision
  end

  test "accepts the exact lifecycle and increments state revision once per transition" do
    register_server("srv-lifecycle")
    assert {:ok, desired} = publish_server("srv-lifecycle")
    assert desired.state == :desired
    assert desired.state_revision == 0

    assert {:ok, delivered} = transition(desired, :delivered, 0)
    assert delivered.state_revision == 1
    assert %DateTime{} = delivered.delivered_at

    assert {:ok, applying} = transition(delivered, :applying, 1)
    assert applying.state_revision == 2
    assert %DateTime{} = applying.applying_at

    assert {:ok, applied} = transition(applying, :applied, 2, applied_revision: @digest_a)
    assert applied.state_revision == 3
    assert applied.applied_revision == @digest_a
    assert %DateTime{} = applied.applied_at

    assert_error(transition(applied, :applied, 3, applied_revision: @digest_a), :conflict)
    assert_error(transition(applied, :failed, 3, failure_phase: :apply), :conflict)
  end

  test "rejects skipped, repeated, backward, stale, and cross-target transitions" do
    register_server("srv-transition")
    register_server("srv-other")
    assert {:ok, desired} = publish_server("srv-transition")

    assert_error(transition(desired, :desired, 0), :conflict)
    assert_error(transition(desired, :applying, 0), :conflict)
    assert_error(transition(desired, :applied, 0, applied_revision: @digest_a), :conflict)
    assert_error(transition(desired, :delivered, 1), :conflict)

    assert {:ok, delivered} = transition(desired, :delivered, 0)

    for next_state <- [:desired, :delivered, :applied] do
      opts = if next_state == :applied, do: [applied_revision: @digest_a], else: []
      assert_error(transition(delivered, next_state, 1, opts), :conflict)
    end

    wrong_target = acknowledgement(delivered, :applying, target_id: "srv-other")

    assert_error(
      ManagementCore.transition_config(
        :server,
        delivered.target_id,
        delivered.version,
        :applying,
        %{expected_state_revision: 1, acknowledgement: wrong_target}
      ),
      :conflict
    )

    assert {:ok, applying} = transition(delivered, :applying, 1)

    for next_state <- [:desired, :delivered, :applying] do
      assert_error(transition(applying, next_state, 2), :conflict)
    end

    assert {:ok, applied} = transition(applying, :applied, 2, applied_revision: @digest_a)

    assert_terminal_conflicts(applied, 3)

    register_server("srv-terminal-failed")
    assert {:ok, failed_desired} = publish_server("srv-terminal-failed")

    assert {:ok, failed} =
             transition(failed_desired, :failed, 0, failure_phase: :delivery)

    assert_terminal_conflicts(failed, 1)
  end

  test "requires exact acknowledgement identity and applied runtime revision" do
    register_server("srv-ack")
    assert {:ok, first} = publish_server("srv-ack")
    applied = apply_version(first)

    assert {:ok, desired} =
             ManagementCore.publish_server_config(
               "srv-ack",
               server_attrs(2, expected_revision: applied.applied_revision)
             )

    assert {:ok, delivered} = transition(desired, :delivered, 0)
    assert {:ok, applying} = transition(delivered, :applying, 1)

    mismatches = [
      [target_type: :netman],
      [target_id: "other"],
      [operation: "server.settings.apply"],
      [version: applying.version + 1],
      [digest: @digest_b],
      [applied_revision: nil],
      [previous_version: nil],
      [previous_revision: @digest_b]
    ]

    for overrides <- mismatches do
      ack = acknowledgement(applying, :applied, overrides)

      assert_error(
        ManagementCore.transition_config(
          :server,
          applying.target_id,
          applying.version,
          :applied,
          %{expected_state_revision: 2, acknowledgement: ack}
        ),
        :conflict
      )
    end
  end

  test "allows only phase-appropriate failures and persists bounded rollback results" do
    register_server("srv-failure")
    assert {:ok, first} = publish_server("srv-failure")
    applied = apply_version(first)

    assert {:ok, second} =
             ManagementCore.publish_server_config(
               "srv-failure",
               server_attrs(2, expected_revision: applied.applied_revision)
             )

    assert_error(transition(second, :failed, 0, failure_phase: :apply), :conflict)

    assert {:ok, failed_delivery} =
             transition(second, :failed, 0,
               failure_phase: :delivery,
               reason: "transport unavailable"
             )

    assert failed_delivery.failure_phase == :delivery

    assert {:ok, third} =
             ManagementCore.publish_server_config(
               "srv-failure",
               server_attrs(3, expected_revision: applied.applied_revision)
             )

    assert {:ok, delivered} = transition(third, :delivered, 0)
    assert_error(transition(delivered, :failed, 1, failure_phase: :delivery), :conflict)
    assert {:ok, applying} = transition(delivered, :applying, 1)

    assert_error(
      transition(applying, :failed, 2,
        failure_phase: :apply,
        reason: String.duplicate("x", Bounds.max_message_bytes() + 1)
      ),
      :invalid
    )

    assert {:ok, failed_apply} =
             transition(applying, :failed, 2,
               failure_phase: :apply,
               reason: String.duplicate("x", Bounds.max_message_bytes()),
               rollback: %{
                 "succeeded" => true,
                 "restored_version" => applied.version,
                 "restored_revision" => applied.applied_revision,
                 "reason" => nil
               }
             )

    assert failed_apply.state_revision == 3
    assert failed_apply.rollback["succeeded"]
    assert failed_apply.restored_version == applied.version
    assert failed_apply.restored_revision == applied.applied_revision

    assert {:ok, fourth} =
             ManagementCore.publish_server_config(
               "srv-failure",
               server_attrs(4, expected_revision: applied.applied_revision)
             )

    assert {:ok, delivered_validation} = transition(fourth, :delivered, 0)

    assert {:ok, failed_validation} =
             transition(delivered_validation, :failed, 1,
               failure_phase: :validation,
               reason: "config validation failed"
             )

    assert failed_validation.failure_phase == :validation
    assert is_nil(failed_validation.rollback)

    assert {:ok, fifth} =
             ManagementCore.publish_server_config(
               "srv-failure",
               server_attrs(5, expected_revision: applied.applied_revision)
             )

    assert {:ok, delivered_rollback} = transition(fifth, :delivered, 0)
    assert {:ok, applying_rollback} = transition(delivered_rollback, :applying, 1)
    rollback_reason = String.duplicate("r", Bounds.max_message_bytes())

    assert {:ok, failed_rollback} =
             transition(applying_rollback, :failed, 2,
               failure_phase: :rollback,
               reason: "rollback phase failed",
               rollback: %{
                 "succeeded" => false,
                 "restored_version" => nil,
                 "restored_revision" => nil,
                 "reason" => rollback_reason
               }
             )

    assert failed_rollback.failure_phase == :rollback
    refute failed_rollback.rollback["succeeded"]
    assert failed_rollback.rollback["reason"] == rollback_reason
    assert is_nil(failed_rollback.restored_version)
    assert is_nil(failed_rollback.restored_revision)
  end

  test "returns only the latest deliverable desired version while preserving old versions" do
    register_server("srv-offline")
    assert {:ok, first} = publish_server("srv-offline")

    assert {:ok, second} =
             ManagementCore.publish_server_config("srv-offline", server_attrs(2))

    assert_error(transition(first, :delivered, 0), :conflict)

    assert {:ok, %ConfigVersion{version: 2}} =
             ManagementCore.latest_desired_config(:server, "srv-offline")

    assert {:ok, delivered} = transition(second, :delivered, 0)

    assert {:ok, %ConfigVersion{state: :delivered, version: 2}} =
             ManagementCore.latest_desired_config(:server, "srv-offline")

    assert {:ok, applying} = transition(delivered, :applying, 1)

    assert {:ok, %ConfigVersion{state: :applying, version: 2}} =
             ManagementCore.latest_desired_config(:server, "srv-offline")

    assert {:ok, _applied} = transition(applying, :applied, 2, applied_revision: @digest_a)
    assert_error(ManagementCore.latest_desired_config(:server, "srv-offline"), :not_found)

    assert {:ok, %ConfigVersion{version: 1, state: :desired}} =
             ManagementCore.get_server_config_version("srv-offline", first.version)
  end

  test "survives restart with payload, pointers, revisions, failures, and rollback data" do
    register_server("srv-restart")
    assert {:ok, first} = publish_server("srv-restart")
    applied = apply_version(first)

    assert {:ok, second} =
             ManagementCore.publish_server_config(
               "srv-restart",
               server_attrs(2, expected_revision: applied.applied_revision)
             )

    assert {:ok, delivered} = transition(second, :delivered, 0)
    assert {:ok, applying} = transition(delivered, :applying, 1)

    assert {:ok, failed} =
             transition(applying, :failed, 2,
               failure_phase: :apply,
               reason: "apply failed",
               rollback: %{
                 "succeeded" => true,
                 "restored_version" => applied.version,
                 "restored_revision" => applied.applied_revision,
                 "reason" => nil
               }
             )

    restart_application()

    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-restart")
    assert {:ok, manifest} = AtomicJson.read(manifest_path)
    lifecycle = manifest["config_lifecycle"]
    assert lifecycle["desired_version"] == failed.version
    assert lifecycle["applied_version"] == applied.version

    assert {:ok, restored_applied} =
             ManagementCore.get_server_config_version("srv-restart", applied.version)

    assert restored_applied == applied
    assert restored_applied.payload == first.payload
    assert restored_applied.digest == first.digest
    assert restored_applied.applied_revision == applied.applied_revision

    assert {:ok, restored} =
             ManagementCore.get_server_config_version("srv-restart", second.version)

    assert restored == failed
    assert restored.payload == second.payload
    assert restored.digest == second.digest
    assert restored.previous_version == applied.version
    assert restored.previous_revision == applied.applied_revision
    assert restored.failure_phase == :apply
    assert restored.failure_reason == "apply failed"
    assert restored.rollback == failed.rollback
    assert restored.restored_version == applied.version
    assert restored.restored_revision == applied.applied_revision
    assert_error(ManagementCore.latest_desired_config(:server, "srv-restart"), :not_found)
  end

  test "expired queued publications and transitions do not run after ConfigVersions resumes", %{
    data_dir: data_dir
  } do
    register_server("srv-expired-publish")
    register_server("srv-expired-transition")
    assert {:ok, desired} = publish_server("srv-expired-transition")

    assert {:ok, publish_manifest_path} = StoragePath.server_manifest("srv-expired-publish")
    assert {:ok, publish_manifest} = AtomicJson.read(publish_manifest_path)

    assert {:ok, transition_manifest_path} =
             StoragePath.server_manifest("srv-expired-transition")

    assert {:ok, transition_manifest} = AtomicJson.read(transition_manifest_path)
    install_event_store_config(operation_timeout_ms: 20, transport_margin_ms: 5)
    config_versions = Process.whereis(ConfigVersions)
    :ok = :sys.suspend(config_versions)

    {publish_result, transition_result} =
      try do
        publish_task =
          Task.async(fn -> publish_server("srv-expired-publish") end)

        transition_task =
          Task.async(fn -> transition(desired, :delivered, 0) end)

        assert_config_version_calls_queued(config_versions, 2)
        {Task.await(publish_task, 1_000), Task.await(transition_task, 1_000)}
      after
        :ok = :sys.resume(config_versions)
      end

    :sys.get_state(config_versions)
    assert_error(publish_result, :timeout)
    assert_error(transition_result, :timeout)
    assert {:ok, ^publish_manifest} = AtomicJson.read(publish_manifest_path)
    assert {:ok, ^transition_manifest} = AtomicJson.read(transition_manifest_path)

    versions_dir =
      Path.join([data_dir, "management", "servers", "srv-expired-publish", "versions"])

    assert Path.wildcard(Path.join(versions_dir, "*.json")) == []

    assert {:ok, persisted} =
             ManagementCore.get_server_config_version("srv-expired-transition", desired.version)

    assert persisted.state == :desired
    assert persisted.state_revision == 0
  end

  test "expiry after immutable creation leaves only an orphan", %{data_dir: data_dir} do
    register_server("srv-expired-immutable")
    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-expired-immutable")
    assert {:ok, manifest} = AtomicJson.read(manifest_path)

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.BlockingImmutableFileOps
    )

    Application.put_env(:yellow_dog_management_core, :config_version_file_ops_owner, self())

    install_event_store_config(
      file_ops: __MODULE__.BlockingImmutableFileOps,
      operation_timeout_ms: 20,
      transport_margin_ms: 5
    )

    publish_task = Task.async(fn -> publish_server("srv-expired-immutable") end)
    assert_receive {:immutable_created, config_versions, version_path}, 1_000
    assert config_versions == Process.whereis(ConfigVersions)
    assert_error(Task.await(publish_task, 1_000), :timeout)
    send(config_versions, :release_immutable_write)
    :sys.get_state(config_versions)

    assert {:ok, ^manifest} = AtomicJson.read(manifest_path)
    assert File.exists?(version_path)

    versions_dir =
      Path.join([data_dir, "management", "servers", "srv-expired-immutable", "versions"])

    assert [^version_path] = Path.wildcard(Path.join(versions_dir, "*.json"))
  end

  test "reserves orphan filenames, ignores malformed temporary files, and rejects max overflow",
       %{
         data_dir: data_dir
       } do
    register_server("srv-orphan")
    versions_dir = Path.join([data_dir, "management", "servers", "srv-orphan", "versions"])
    File.mkdir_p!(versions_dir)
    File.write!(Path.join(versions_dir, "7-#{@digest_a}.json"), "orphan")
    File.write!(Path.join(versions_dir, "999-not-a-digest.json"), "malformed")
    File.write!(Path.join(versions_dir, ".8-#{@digest_a}.json.tmp"), "temporary")

    assert {:ok, %ConfigVersion{version: 8}} = publish_server("srv-orphan")

    register_server("srv-max")
    max_dir = Path.join([data_dir, "management", "servers", "srv-max", "versions"])
    File.mkdir_p!(max_dir)
    File.write!(Path.join(max_dir, "#{@max_version - 1}-#{@digest_a}.json"), "orphan")

    assert {:ok, %ConfigVersion{version: @max_version}} = publish_server("srv-max")
    assert_error(publish_server("srv-max"), :conflict)
    assert_error(ManagementCore.get_server_config_version("srv-max", 0), :invalid)
  end

  test "corrupt referenced manifests and versions block only their concrete target" do
    register_server("srv-corrupt")
    register_server("srv-corrupt-manifest")
    register_server("srv-healthy")
    assert {:ok, corrupt} = publish_server("srv-corrupt")
    assert {:ok, _healthy} = publish_server("srv-healthy")

    assert {:ok, version_path} =
             StoragePath.server_version("srv-corrupt", corrupt.version, corrupt.digest)

    File.write!(version_path, "{")

    assert_error(
      ManagementCore.get_server_config_version("srv-corrupt", corrupt.version),
      :invalid
    )

    assert_error(publish_server("srv-corrupt"), :invalid)

    assert {:ok, corrupt_manifest_path} =
             StoragePath.server_manifest("srv-corrupt-manifest")

    assert {:ok, corrupt_manifest} = AtomicJson.read(corrupt_manifest_path)

    assert {:ok, ^corrupt_manifest_path} =
             AtomicJson.replace(
               corrupt_manifest_path,
               Map.put(corrupt_manifest, "config_lifecycle", %{"schema_version" => 1})
             )

    assert_error(publish_server("srv-corrupt-manifest"), :invalid)

    assert {:ok, %ConfigVersion{version: 2}} =
             ManagementCore.publish_server_config("srv-healthy", server_attrs(2))
  end

  test "manifest write failure leaves an immutable orphan that retry never reuses", %{
    data_dir: data_dir
  } do
    register_server("srv-manifest-failure")

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.FailingManifestFileOps
    )

    install_event_store_file_ops(__MODULE__.FailingManifestFileOps)

    assert {:ok, preflight_manifest_path} =
             StoragePath.server_manifest("srv-manifest-failure")

    assert {:ok, preflight_manifest} = AtomicJson.read(preflight_manifest_path)
    assert is_map(preflight_manifest["registration"])

    assert_error(
      ManagementCore.latest_desired_config(:server, "srv-manifest-failure"),
      :not_found
    )

    Application.put_env(:yellow_dog_management_core, :fail_config_manifest_write, true)

    assert_error(publish_server("srv-manifest-failure"), :internal)

    assert_error(
      ManagementCore.latest_desired_config(:server, "srv-manifest-failure"),
      :not_found
    )

    versions_dir =
      Path.join([
        data_dir,
        "management",
        "servers",
        "srv-manifest-failure",
        "versions"
      ])

    assert [_orphan] = Path.wildcard(Path.join(versions_dir, "*.json"))
    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-manifest-failure")
    assert {:ok, manifest} = AtomicJson.read(manifest_path)
    refute Map.has_key?(manifest, "config_lifecycle")

    Application.put_env(:yellow_dog_management_core, :fail_config_manifest_write, false)
    assert {:ok, %ConfigVersion{version: 2}} = publish_server("srv-manifest-failure")

    version_paths = Path.wildcard(Path.join(versions_dir, "*.json"))
    assert length(version_paths) == 2
    assert Enum.any?(version_paths, &(Path.basename(&1) =~ ~r/^1-/))
    assert Enum.any?(version_paths, &(Path.basename(&1) =~ ~r/^2-/))

    assert {:ok, updated_manifest} = AtomicJson.read(manifest_path)
    assert updated_manifest["config_lifecycle"]["desired_version"] == 2
  end

  test "manifest section commits preserve registration and unknown top-level sections" do
    register_server("srv-shared")
    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-shared")
    assert {:ok, manifest} = AtomicJson.read(manifest_path)

    assert {:ok, ^manifest_path} =
             AtomicJson.replace(manifest_path, Map.put(manifest, "future_section", %{"v" => 1}))

    assert {:ok, _version} = publish_server("srv-shared")
    assert {:ok, updated} = AtomicJson.read(manifest_path)

    assert is_map(updated["registration"])
    assert updated["future_section"] == %{"v" => 1}
    assert is_map(updated["config_lifecycle"])
    refute Map.has_key?(updated, "registration_audit_outbox")
  end

  test "section commit rejects a pending registration audit before invoking its callback" do
    register_server("srv-pending-callback")
    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-pending-callback")
    assert {:ok, pending_manifest} = install_pending_audit(manifest_path, "srv-pending-callback")
    events_before = ManagementCore.list_events()
    owner = self()

    assert_error(
      ManifestStore.commit_section(manifest_path, "config_lifecycle", fn _section ->
        send(owner, :lifecycle_callback_called)
        {:error, Error.new(:conflict, "callback failed", %{})}
      end),
      :conflict
    )

    refute_receive :lifecycle_callback_called
    assert {:ok, ^pending_manifest} = AtomicJson.read(manifest_path)
    assert ManagementCore.list_events() == events_before
  end

  test "publish leaves pending registration audit, events, and lifecycle untouched" do
    register_server("srv-pending-publish")
    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-pending-publish")
    assert {:ok, pending_manifest} = install_pending_audit(manifest_path, "srv-pending-publish")
    events_before = ManagementCore.list_events()

    assert_error(publish_server("srv-pending-publish"), :conflict)

    assert {:ok, ^pending_manifest} = AtomicJson.read(manifest_path)
    assert ManagementCore.list_events() == events_before
    refute Map.has_key?(pending_manifest, "config_lifecycle")
  end

  defp publish_server(server_id) do
    ManagementCore.publish_server_config(server_id, server_attrs(1))
  end

  defp apply_version(version) do
    assert {:ok, delivered} = transition(version, :delivered, 0)
    assert {:ok, applying} = transition(delivered, :applying, 1)
    assert {:ok, applied} = transition(applying, :applied, 2, applied_revision: @digest_a)
    applied
  end

  defp assert_terminal_conflicts(version, expected_state_revision) do
    transitions = [
      {:desired, []},
      {:delivered, []},
      {:applying, []},
      {:applied, [applied_revision: @digest_a]},
      {:failed, [failure_phase: :apply]}
    ]

    for {next_state, opts} <- transitions do
      assert_error(transition(version, next_state, expected_state_revision, opts), :conflict)
    end
  end

  defp transition(version, state, expected_state_revision, opts \\ []) do
    ack = acknowledgement(version, state, opts)

    ManagementCore.transition_config(
      version.target_type,
      version.target_id,
      version.version,
      state,
      %{expected_state_revision: expected_state_revision, acknowledgement: ack}
    )
  end

  defp acknowledgement(version, state, opts) do
    applied_revision = Keyword.get(opts, :applied_revision)
    failure_phase = Keyword.get(opts, :failure_phase)
    reason = Keyword.get(opts, :reason, "transition failed")
    rollback = Keyword.get(opts, :rollback)

    base = %ConfigState{
      target_type: Keyword.get(opts, :target_type, version.target_type),
      target_id: Keyword.get(opts, :target_id, version.target_id),
      operation: Keyword.get(opts, :operation, version.operation),
      state: state,
      version: Keyword.get(opts, :version, version.version),
      digest: Keyword.get(opts, :digest, version.digest),
      applied_revision: applied_revision,
      previous_version: previous_version(version, state),
      previous_revision: previous_revision(version, state),
      failure:
        if(state == :failed,
          do: %{"phase" => Atom.to_string(failure_phase), "reason" => reason},
          else: nil
        ),
      rollback: rollback,
      observed_at: DateTime.utc_now(:second)
    }

    overrides =
      opts
      |> Map.new()
      |> Map.take([
        :target_type,
        :target_id,
        :operation,
        :state,
        :version,
        :digest,
        :applied_revision,
        :previous_version,
        :previous_revision,
        :failure,
        :rollback,
        :observed_at
      ])

    struct!(base, overrides)
  end

  defp previous_version(_version, :delivered), do: nil

  defp previous_version(%ConfigVersion{state: state}, :failed)
       when state in [:desired, :delivered],
       do: nil

  defp previous_version(version, _state), do: version.previous_version
  defp previous_revision(_version, :delivered), do: nil

  defp previous_revision(%ConfigVersion{state: state}, :failed)
       when state in [:desired, :delivered],
       do: nil

  defp previous_revision(version, _state), do: version.previous_revision

  defp server_attrs(index, overrides \\ []) do
    defaults = %{
      operation: "server.settings.update",
      payload: %{
        "service" => "dns",
        "entries" => [
          %{
            "key" => "listen",
            "value" => %{"type" => "string", "value" => "192.0.2.#{index}"}
          }
        ]
      },
      expected_revision: nil
    }

    Enum.into(overrides, defaults)
  end

  defp netman_attrs do
    %{
      operation: "netman.resolved.config.update",
      payload: %{"upstreams" => ["192.0.2.53"], "search_domains" => ["example.com"]},
      expected_revision: nil
    }
  end

  defp register_server(id) do
    assert {:ok, _server} = ManagementCore.register_server(%{id: id, profile: :dns_only})
  end

  defp register_netman(id) do
    assert {:ok, _netman} = ManagementCore.register_netman(%{id: id, profile: :vm})
  end

  defp assert_error(result, code) do
    assert {:error, %Error{code: ^code}} = result
  end

  defp restart_application do
    :ok = Application.stop(:yellow_dog_management_core)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
  end

  defp install_event_store_file_ops(file_ops) do
    install_event_store_config(file_ops: file_ops)
  end

  defp install_event_store_config(overrides) do
    :sys.replace_state(EventStore, fn state ->
      config = struct!(state.config, overrides)
      true = :ets.insert(YellowDog.Management.EventStore.ConfigSnapshot, {:config, config})
      %{state | config: config}
    end)
  end

  defp assert_config_version_calls_queued(config_versions, expected) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    assert_config_version_calls_queued(config_versions, expected, deadline)
  end

  defp assert_config_version_calls_queued(config_versions, expected, deadline) do
    {:messages, messages} = Process.info(config_versions, :messages)
    calls = Enum.count(messages, &match?({:"$gen_call", _from, _request}, &1))

    cond do
      calls >= expected ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          1 -> assert_config_version_calls_queued(config_versions, expected, deadline)
        end

      true ->
        flunk("expected #{expected} queued ConfigVersions calls, found #{calls}")
    end
  end

  defp install_pending_audit(manifest_path, source_id) do
    {deadline, config} = EventStore.operation()

    assert {:ok, reservation} =
             EventStore.reserve(
               %{
                 source: :server,
                 source_id: source_id,
                 type: :server_registered,
                 message: "Pending server registration audit"
               },
               deadline,
               config
             )

    assert {:ok, manifest} = AtomicJson.read(manifest_path)
    registration = manifest["registration"]

    outbox = %{
      "schema_version" => 1,
      "event" => reservation.event_map,
      "event_digest" => reservation.event_digest,
      "registration_digest" => Event.digest(registration),
      "previous_registration" => %{"present" => true, "value" => registration}
    }

    pending_manifest = Map.put(manifest, "registration_audit_outbox", outbox)
    assert {:ok, ^manifest_path} = AtomicJson.replace(manifest_path, pending_manifest)
    {:ok, pending_manifest}
  end

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defmodule FailingManifestFileOps do
    @moduledoc false

    def read(path), do: File.read(path)
    def open(path), do: :file.open(path, [:write, :exclusive, :binary, :raw])
    def write(device, contents), do: :file.write(device, contents)
    def sync(device), do: :file.sync(device)
    def close(device), do: :file.close(device)
    def link(source, target), do: :file.make_link(source, target)
    def rm(path), do: File.rm(path)

    def rename(source, target) do
      fail? =
        Application.get_env(
          :yellow_dog_management_core,
          :fail_config_manifest_write,
          false
        )

      if fail? and Path.basename(target) == "manifest.json",
        do: {:error, :eacces},
        else: :file.rename(source, target)
    end
  end

  defmodule BlockingImmutableFileOps do
    @moduledoc false
    @version_filename ~r/^[1-9][0-9]*-[0-9a-f]{64}\.json$/

    def read(path), do: File.read(path)

    def open(path) do
      case :file.open(path, [:write, :exclusive, :binary, :raw]) do
        {:ok, _device} = success ->
          if Regex.match?(@version_filename, Path.basename(path)) do
            Process.put({__MODULE__, :immutable_path}, path)
          end

          success

        error ->
          error
      end
    end

    def write(device, contents), do: :file.write(device, contents)
    def sync(device), do: :file.sync(device)

    def close(device) do
      result = :file.close(device)

      case Process.delete({__MODULE__, :immutable_path}) do
        nil -> :ok
        path -> immutable_created(path)
      end

      result
    end

    def link(source, target) do
      case :file.make_link(source, target) do
        :ok ->
          if Regex.match?(@version_filename, Path.basename(target)), do: immutable_created(target)
          :ok

        error ->
          error
      end
    end

    def rm(path), do: File.rm(path)
    def rename(source, target), do: :file.rename(source, target)

    defp immutable_created(path) do
      owner =
        Application.fetch_env!(:yellow_dog_management_core, :config_version_file_ops_owner)

      send(owner, {:immutable_created, self(), path})

      receive do
        :release_immutable_write -> :ok
      end
    end
  end
end
