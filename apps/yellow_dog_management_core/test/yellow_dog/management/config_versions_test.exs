defmodule YellowDog.Management.ConfigVersionsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.ConfigVersion
  alias YellowDog.Management.ConfigVersions
  alias YellowDog.Management.EventStore
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
      Map.new([:data_dir, :atomic_json_file_ops, :fail_config_manifest_write], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-config-versions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.delete_env(:yellow_dog_management_core, :atomic_json_file_ops)
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

    assert_error(transition(desired, :applying, 0), :conflict)
    assert_error(transition(desired, :applied, 0, applied_revision: @digest_a), :conflict)
    assert_error(transition(desired, :delivered, 1), :conflict)

    assert {:ok, delivered} = transition(desired, :delivered, 0)
    assert_error(transition(delivered, :delivered, 1), :conflict)
    assert_error(transition(delivered, :desired, 1), :invalid)

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
  end

  test "requires exact acknowledgement identity and applied runtime revision" do
    register_server("srv-ack")
    assert {:ok, desired} = publish_server("srv-ack")
    assert {:ok, delivered} = transition(desired, :delivered, 0)
    assert {:ok, applying} = transition(delivered, :applying, 1)

    mismatches = [
      [target_type: :netman],
      [target_id: "other"],
      [operation: "server.settings.apply"],
      [version: applying.version + 1],
      [digest: @digest_b],
      [applied_revision: nil]
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

    restart_child(ConfigVersions)

    assert {:ok, restored} =
             ManagementCore.get_server_config_version("srv-restart", second.version)

    assert restored == failed
    assert restored.payload == second.payload
    assert restored.digest == second.digest
    assert restored.previous_version == applied.version
    assert restored.previous_revision == applied.applied_revision
    assert restored.failure_phase == :apply
    assert restored.failure_reason == "apply failed"
    assert restored.restored_version == applied.version
    assert restored.restored_revision == applied.applied_revision
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
    File.write!(Path.join(max_dir, "#{@max_version}-#{@digest_a}.json"), "orphan")

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

  test "manifest write failure leaves an immutable orphan and no desired pointer", %{
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

  defp publish_server(server_id) do
    ManagementCore.publish_server_config(server_id, server_attrs(1))
  end

  defp apply_version(version) do
    assert {:ok, delivered} = transition(version, :delivered, 0)
    assert {:ok, applying} = transition(delivered, :applying, 1)
    assert {:ok, applied} = transition(applying, :applied, 2, applied_revision: @digest_a)
    applied
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

  defp restart_child(child_id) do
    assert :ok = Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, child_id)
    assert {:ok, _pid} = Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, child_id)
  end

  defp restart_application do
    :ok = Application.stop(:yellow_dog_management_core)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
  end

  defp install_event_store_file_ops(file_ops) do
    :sys.replace_state(EventStore, fn state ->
      config = %{state.config | file_ops: file_ops}
      true = :ets.insert(YellowDog.Management.EventStore.ConfigSnapshot, {:config, config})
      %{state | config: config}
    end)
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
end
