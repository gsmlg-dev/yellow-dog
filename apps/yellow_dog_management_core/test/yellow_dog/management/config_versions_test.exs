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
  alias YellowDog.Sync.Message
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
          :block_config_manifest_replace,
          :config_version_blocking_operation,
          :config_version_blocking_owner,
          :config_staging_cleanup_counter,
          :config_staging_cleanup_mode,
          :config_version_file_ops_owner,
          :exhausted_recovery_owner,
          :exhausted_manifest_recovery_state,
          :fail_config_manifest_write,
          :manifest_replace_file_ops_owner,
          :block_manifest_read_number,
          :manifest_read_counter,
          :manifest_read_file_ops_owner,
          :manifest_staging_cleanup_counter,
          :manifest_staging_cleanup_mode,
          :manifest_staging_cleanup_owner
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
    Application.delete_env(:yellow_dog_management_core, :block_config_manifest_replace)
    Application.delete_env(:yellow_dog_management_core, :config_version_blocking_operation)
    Application.delete_env(:yellow_dog_management_core, :config_version_blocking_owner)
    Application.delete_env(:yellow_dog_management_core, :config_version_file_ops_owner)
    Application.delete_env(:yellow_dog_management_core, :fail_config_manifest_write)
    Application.delete_env(:yellow_dog_management_core, :manifest_replace_file_ops_owner)
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

  test "accepts canonical ConfigState publications for success and every legal failure phase" do
    register_server("srv-publication-success")
    assert {:ok, desired} = publish_server("srv-publication-success")

    assert {:ok, delivered_receipt} = accept_publication(desired, 1, :delivered)

    assert delivered_receipt == %{
             "target_type" => "server",
             "target_id" => "srv-publication-success",
             "publication_sequence" => 1,
             "state_revision" => 1
           }

    assert {:ok, delivered} =
             ManagementCore.get_server_config_version("srv-publication-success", desired.version)

    assert {:ok, applying_receipt} = accept_publication(delivered, 2, :applying)
    assert applying_receipt["state_revision"] == 2

    assert {:ok, applying} =
             ManagementCore.get_server_config_version("srv-publication-success", desired.version)

    assert {:ok, applied_receipt} =
             accept_publication(applying, 3, :applied, applied_revision: @digest_a)

    assert applied_receipt["state_revision"] == 3

    failure_cases = [
      {"delivery", :desired, :delivery, 1},
      {"validation", :delivered, :validation, 2},
      {"apply", :applying, :apply, 3}
    ]

    for {suffix, prior_state, phase, terminal_sequence} <- failure_cases do
      server_id = "srv-publication-failure-#{suffix}"
      register_server(server_id)
      assert {:ok, version} = publish_server(server_id)

      version =
        case prior_state do
          :desired ->
            version

          :delivered ->
            assert {:ok, _receipt} = accept_publication(version, 1, :delivered)

            {:ok, delivered} =
              ManagementCore.get_server_config_version(server_id, version.version)

            delivered

          :applying ->
            assert {:ok, _receipt} = accept_publication(version, 1, :delivered)

            {:ok, delivered} =
              ManagementCore.get_server_config_version(server_id, version.version)

            assert {:ok, _receipt} = accept_publication(delivered, 2, :applying)
            {:ok, applying} = ManagementCore.get_server_config_version(server_id, version.version)
            applying
        end

      assert {:ok, receipt} =
               accept_publication(version, terminal_sequence, :failed,
                 failure_phase: phase,
                 reason: "#{suffix} failed"
               )

      assert receipt["state_revision"] == terminal_sequence
      assert {:ok, failed} = ManagementCore.get_server_config_version(server_id, version.version)
      assert failed.failure_phase == phase
    end

    assert {:ok, first_applied} =
             ManagementCore.get_server_config_version("srv-publication-success", desired.version)

    assert {:ok, rollback_candidate} =
             ManagementCore.publish_server_config(
               "srv-publication-success",
               server_attrs(2, expected_revision: first_applied.applied_revision)
             )

    assert {:ok, _receipt} = accept_publication(rollback_candidate, 4, :delivered)

    assert {:ok, rollback_delivered} =
             ManagementCore.get_server_config_version(
               "srv-publication-success",
               rollback_candidate.version
             )

    assert {:ok, _receipt} = accept_publication(rollback_delivered, 5, :applying)

    assert {:ok, rollback_applying} =
             ManagementCore.get_server_config_version(
               "srv-publication-success",
               rollback_candidate.version
             )

    assert {:ok, rollback_receipt} =
             accept_publication(rollback_applying, 6, :failed,
               failure_phase: :rollback,
               reason: "rollback failed",
               rollback: %{
                 "succeeded" => false,
                 "restored_version" => nil,
                 "restored_revision" => nil,
                 "reason" => "runtime rollback failed"
               }
             )

    assert rollback_receipt["state_revision"] == 3
  end

  test "exact publication replay survives restart without revision increment or manifest write" do
    server_id = "srv-publication-replay"
    register_server(server_id)
    assert {:ok, desired} = publish_server(server_id)
    encoded = encoded_acknowledgement(desired, :delivered)

    assert {:ok, receipt} =
             ManagementCore.accept_config_state_publication(:server, server_id, 1, encoded)

    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    manifest_bytes = File.read!(manifest_path)

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.FailingManifestFileOps
    )

    install_event_store_file_ops(__MODULE__.FailingManifestFileOps)
    Application.put_env(:yellow_dog_management_core, :fail_config_manifest_write, true)

    assert {:ok, ^receipt} =
             ManagementCore.accept_config_state_publication(:server, server_id, 1, encoded)

    assert File.read!(manifest_path) == manifest_bytes
    assert {:ok, delivered} = ManagementCore.get_server_config_version(server_id, desired.version)
    assert delivered.state_revision == 1

    restart_application()

    assert {:ok, ^receipt} =
             ManagementCore.accept_config_state_publication(:server, server_id, 1, encoded)

    assert File.read!(manifest_path) == manifest_bytes

    assert {:ok, ^delivered} =
             ManagementCore.get_server_config_version(server_id, desired.version)
  end

  test "rejects publication sequence reuse, gaps, duplicate subjects, and invalid sequences" do
    server_id = "srv-publication-sequence"
    register_server(server_id)
    register_server("srv-publication-sequence-other")
    assert {:ok, desired} = publish_server(server_id)
    encoded = encoded_acknowledgement(desired, :delivered)

    for sequence <- [0, -1, @max_version + 1, "1"] do
      assert_error(
        ManagementCore.accept_config_state_publication(
          :server,
          server_id,
          sequence,
          encoded
        ),
        :invalid
      )
    end

    assert_error(
      ManagementCore.accept_config_state_publication(:server, server_id, 2, encoded),
      :conflict
    )

    assert {:ok, _receipt} =
             ManagementCore.accept_config_state_publication(:server, server_id, 1, encoded)

    different_bytes =
      desired
      |> acknowledgement(:delivered, observed_at: DateTime.add(DateTime.utc_now(:second), 1))
      |> then(fn message ->
        {:ok, encoded} = Message.encode(message)
        encoded
      end)

    assert different_bytes != encoded

    assert_error(
      ManagementCore.accept_config_state_publication(
        :server,
        server_id,
        1,
        different_bytes
      ),
      :conflict
    )

    wrong_identity =
      encoded_acknowledgement(desired, :delivered, target_id: "srv-publication-sequence-other")

    assert_error(
      ManagementCore.accept_config_state_publication(
        :server,
        server_id,
        1,
        wrong_identity
      ),
      :conflict
    )

    assert_error(
      ManagementCore.accept_config_state_publication(:server, server_id, 2, encoded),
      :conflict
    )

    assert {:ok, delivered} = ManagementCore.get_server_config_version(server_id, desired.version)
    applying = encoded_acknowledgement(delivered, :applying)

    assert_error(
      ManagementCore.accept_config_state_publication(:server, server_id, 3, applying),
      :conflict
    )

    assert {:ok, _receipt} =
             ManagementCore.accept_config_state_publication(:server, server_id, 2, applying)

    assert_error(
      ManagementCore.accept_config_state_publication(:server, server_id, 2, encoded),
      :conflict
    )
  end

  test "rejects malformed, noncanonical, non-ConfigState, and incoherent publications" do
    server_id = "srv-publication-validation"
    register_server(server_id)
    register_server("srv-publication-other")
    assert {:ok, desired} = publish_server(server_id)

    invalid_messages = [
      " " <> encoded_acknowledgement(desired, :delivered),
      encoded_message(%Message.Heartbeat{
        target_type: :server,
        target_id: server_id,
        observed_at: DateTime.utc_now(:second)
      }),
      encoded_acknowledgement(desired, :delivered, target_id: "srv-publication-other"),
      encoded_acknowledgement(desired, :delivered, version: desired.version + 1),
      encoded_acknowledgement(desired, :delivered, digest: @digest_b),
      encoded_acknowledgement(desired, :delivered, operation: "server.settings.apply")
    ]

    for encoded <- invalid_messages do
      assert {:error, %Error{code: code}} =
               ManagementCore.accept_config_state_publication(
                 :server,
                 server_id,
                 1,
                 encoded
               )

      assert code in [:invalid, :conflict]
    end

    assert_error(
      ManagementCore.accept_config_state_publication(
        :netman,
        server_id,
        1,
        encoded_acknowledgement(desired, :delivered)
      ),
      :invalid
    )

    assert_error(
      ManagementCore.accept_config_state_publication(
        :server,
        "missing",
        1,
        encoded_acknowledgement(desired, :delivered)
      ),
      :not_found
    )

    assert {:ok, unchanged} = ManagementCore.get_server_config_version(server_id, desired.version)
    assert unchanged.state == :desired
    assert unchanged.state_revision == 0
  end

  test "publication persistence failure creates no transition receipt or sequence high-water" do
    server_id = "srv-publication-persistence"
    register_server(server_id)
    assert {:ok, desired} = publish_server(server_id)
    encoded = encoded_acknowledgement(desired, :delivered)
    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    manifest_before = File.read!(manifest_path)

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      __MODULE__.FailingManifestFileOps
    )

    install_event_store_file_ops(__MODULE__.FailingManifestFileOps)
    Application.put_env(:yellow_dog_management_core, :fail_config_manifest_write, true)

    assert_error(
      ManagementCore.accept_config_state_publication(:server, server_id, 1, encoded),
      :internal
    )

    assert File.read!(manifest_path) == manifest_before
    assert {:ok, unchanged} = ManagementCore.get_server_config_version(server_id, desired.version)
    assert unchanged.state == :desired
    assert unchanged.state_revision == 0

    Application.put_env(:yellow_dog_management_core, :fail_config_manifest_write, false)

    assert {:ok, receipt} =
             ManagementCore.accept_config_state_publication(:server, server_id, 1, encoded)

    assert receipt["publication_sequence"] == 1
    assert receipt["state_revision"] == 1
  end

  test "corrupt v2 publication receipts fail closed for every lifecycle API", %{
    data_dir: data_dir
  } do
    corruptions = [
      {"high-water",
       fn lifecycle ->
         Map.put(lifecycle, "publication_high_water", 2)
       end},
      {"lifecycle-keys",
       fn lifecycle ->
         Map.put(lifecycle, "unexpected", true)
       end},
      {"receipt-keys",
       fn lifecycle ->
         put_in(lifecycle, ["publication_receipts", "1", "unexpected"], true)
       end},
      {"message",
       fn lifecycle ->
         put_in(lifecycle, ["publication_receipts", "1", "encoded_message"], "{")
       end},
      {"message-coherence",
       fn lifecycle ->
         receipt = lifecycle["publication_receipts"]["1"]
         {:ok, message} = Message.decode(receipt["encoded_message"])
         changed = %{message | observed_at: DateTime.add(message.observed_at, 1)}
         {:ok, encoded} = Message.encode(changed)

         put_in(lifecycle, ["publication_receipts", "1", "encoded_message"], encoded)
       end},
      {"canonical-sequence",
       fn lifecycle ->
         receipt = lifecycle["publication_receipts"]["1"]

         lifecycle
         |> put_in(["publication_receipts"], %{"01" => receipt})
       end},
      {"subject",
       fn lifecycle ->
         first = lifecycle["publication_receipts"]["1"]

         lifecycle
         |> Map.put("publication_high_water", 2)
         |> put_in(
           ["publication_receipts", "2"],
           %{first | "sequence" => 2}
         )
       end},
      {"revision",
       fn lifecycle ->
         put_in(lifecycle, ["publication_receipts", "1", "resulting_state_revision"], 2)
       end}
    ]

    for {suffix, corrupt} <- corruptions do
      server_id = "srv-publication-corrupt-#{suffix}"
      register_server(server_id)
      assert {:ok, desired} = publish_server(server_id)
      assert {:ok, _receipt} = accept_publication(desired, 1, :delivered)
      assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
      assert {:ok, manifest} = AtomicJson.read(manifest_path)

      corrupted =
        Map.update!(manifest, "config_lifecycle", corrupt)

      assert {:ok, ^manifest_path} = AtomicJson.replace(manifest_path, corrupted)
      manifest_bytes = File.read!(manifest_path)

      assert_error(
        ManagementCore.get_server_config_version(server_id, desired.version),
        :invalid
      )

      assert_error(ManagementCore.latest_desired_config(:server, server_id), :invalid)

      assert_error(
        ManagementCore.accept_config_state_publication(
          :server,
          server_id,
          1,
          encoded_acknowledgement(desired, :delivered)
        ),
        :invalid
      )

      assert_error(
        ManagementCore.publish_server_config(server_id, server_attrs(2)),
        :invalid
      )

      versions_dir = Path.join([data_dir, "management", "servers", server_id, "versions"])
      assert File.read!(manifest_path) == manifest_bytes
      assert map_size(snapshot_files(versions_dir)) == 1
    end
  end

  test "v2 requires a committed first receipt and rejects sequence one from empty progress" do
    server_id = "srv-publication-empty-v2"
    register_server(server_id)
    assert {:ok, desired} = publish_server(server_id)
    assert {:ok, delivered} = transition(desired, :delivered, 0)
    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    assert {:ok, manifest} = AtomicJson.read(manifest_path)

    lifecycle =
      manifest["config_lifecycle"]
      |> Map.put("schema_version", 2)
      |> Map.put("publication_high_water", 0)
      |> Map.put("publication_receipts", %{})

    corrupted = %{manifest | "config_lifecycle" => lifecycle}
    assert {:ok, ^manifest_path} = AtomicJson.replace(manifest_path, corrupted)
    manifest_bytes = File.read!(manifest_path)

    assert_error(
      ManagementCore.accept_config_state_publication(
        :server,
        server_id,
        1,
        encoded_acknowledgement(delivered, :applying)
      ),
      :invalid
    )

    assert_error(
      ManagementCore.get_server_config_version(server_id, desired.version),
      :invalid
    )

    assert File.read!(manifest_path) == manifest_bytes
  end

  test "v2 validates same-version receipts in numeric lifecycle order" do
    server_id = "srv-publication-same-version-order"
    register_server(server_id)
    assert {:ok, desired} = publish_server(server_id)
    assert {:ok, _receipt} = accept_publication(desired, 1, :delivered)
    assert {:ok, delivered} = ManagementCore.get_server_config_version(server_id, 1)
    assert {:ok, _receipt} = accept_publication(delivered, 2, :applying)
    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    assert {:ok, manifest} = AtomicJson.read(manifest_path)

    lifecycle = manifest["config_lifecycle"]
    delivered_receipt = lifecycle["publication_receipts"]["1"]
    applying_receipt = lifecycle["publication_receipts"]["2"]

    reordered =
      lifecycle
      |> put_in(
        ["publication_receipts", "1"],
        %{applying_receipt | "sequence" => 1}
      )
      |> put_in(
        ["publication_receipts", "2"],
        %{delivered_receipt | "sequence" => 2}
      )

    assert {:ok, ^manifest_path} =
             AtomicJson.replace(manifest_path, %{manifest | "config_lifecycle" => reordered})

    assert_error(ManagementCore.get_server_config_version(server_id, 1), :invalid)
    assert_error(ManagementCore.latest_desired_config(:server, server_id), :invalid)
  end

  test "v2 rejects an earlier version after a newer version in the receipt ledger" do
    server_id = "srv-publication-cross-version-order"
    register_server(server_id)
    assert {:ok, first} = publish_server(server_id)
    assert {:ok, _receipt} = accept_publication(first, 1, :delivered)
    assert {:ok, delivered} = ManagementCore.get_server_config_version(server_id, 1)
    assert {:ok, _receipt} = accept_publication(delivered, 2, :applying)
    assert {:ok, applying} = ManagementCore.get_server_config_version(server_id, 1)

    assert {:ok, _receipt} =
             accept_publication(applying, 3, :applied, applied_revision: @digest_a)

    assert {:ok, second} =
             ManagementCore.publish_server_config(
               server_id,
               server_attrs(2, expected_revision: @digest_a)
             )

    assert {:ok, _receipt} = accept_publication(second, 4, :delivered)
    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    assert {:ok, manifest} = AtomicJson.read(manifest_path)

    lifecycle = manifest["config_lifecycle"]
    first_applied_receipt = lifecycle["publication_receipts"]["3"]
    second_delivered_receipt = lifecycle["publication_receipts"]["4"]

    reordered =
      lifecycle
      |> put_in(
        ["publication_receipts", "3"],
        %{second_delivered_receipt | "sequence" => 3}
      )
      |> put_in(
        ["publication_receipts", "4"],
        %{first_applied_receipt | "sequence" => 4}
      )

    assert {:ok, ^manifest_path} =
             AtomicJson.replace(manifest_path, %{manifest | "config_lifecycle" => reordered})

    assert_error(
      ManagementCore.get_server_config_version(server_id, second.version),
      :invalid
    )

    assert_error(ManagementCore.latest_desired_config(:server, server_id), :invalid)
  end

  test "v2 publication state is server-only while legacy Netman lifecycle remains compatible" do
    legacy_id = "netman-publication-v1"
    register_netman(legacy_id)

    assert {:ok, first} = ManagementCore.publish_netman_config(legacy_id, netman_attrs())
    assert {:ok, ^first} = ManagementCore.get_netman_config_version(legacy_id, first.version)
    assert {:ok, second} = ManagementCore.publish_netman_config(legacy_id, netman_attrs())
    assert {:ok, ^second} = ManagementCore.get_netman_config_version(legacy_id, second.version)
    assert {:ok, legacy_manifest_path} = StoragePath.netman_manifest(legacy_id)
    assert {:ok, legacy_manifest} = AtomicJson.read(legacy_manifest_path)
    assert legacy_manifest["config_lifecycle"]["schema_version"] == 1

    forged_id = "netman-publication-v2"
    register_netman(forged_id)
    assert {:ok, desired} = ManagementCore.publish_netman_config(forged_id, netman_attrs())
    acknowledgement = acknowledgement(desired, :delivered, [])
    encoded_message = encoded_message(acknowledgement)

    assert {:ok, delivered} =
             ManagementCore.transition_config(
               :netman,
               forged_id,
               desired.version,
               :delivered,
               %{expected_state_revision: 0, acknowledgement: acknowledgement}
             )

    assert {:ok, manifest_path} = StoragePath.netman_manifest(forged_id)
    assert {:ok, manifest} = AtomicJson.read(manifest_path)

    receipt = %{
      "sequence" => 1,
      "encoded_message" => encoded_message,
      "version" => delivered.version,
      "state" => "delivered",
      "operation" => delivered.operation,
      "digest" => delivered.digest,
      "resulting_state_revision" => delivered.state_revision
    }

    forged_lifecycle =
      manifest["config_lifecycle"]
      |> Map.put("schema_version", 2)
      |> Map.put("publication_high_water", 1)
      |> Map.put("publication_receipts", %{"1" => receipt})

    assert {:ok, ^manifest_path} =
             AtomicJson.replace(manifest_path, %{
               manifest
               | "config_lifecycle" => forged_lifecycle
             })

    assert_error(
      ManagementCore.get_netman_config_version(forged_id, delivered.version),
      :invalid
    )

    assert_error(ManagementCore.latest_desired_config(:netman, forged_id), :invalid)
    assert_error(ManagementCore.publish_netman_config(forged_id, netman_attrs()), :invalid)
  end

  test "clean v1 lifecycle upgrades on first accepted publication and preserves desired history" do
    server_id = "srv-publication-v1-upgrade"
    register_server(server_id)
    assert {:ok, first} = publish_server(server_id)
    assert {:ok, second} = ManagementCore.publish_server_config(server_id, server_attrs(2))
    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    assert {:ok, manifest_v1} = AtomicJson.read(manifest_path)
    assert manifest_v1["config_lifecycle"]["schema_version"] == 1

    assert {:ok, receipt} = accept_publication(second, 1, :delivered)
    assert receipt["state_revision"] == 1

    assert {:ok, manifest_v2} = AtomicJson.read(manifest_path)
    lifecycle = manifest_v2["config_lifecycle"]

    assert Enum.sort(Map.keys(lifecycle)) ==
             Enum.sort([
               "schema_version",
               "counter",
               "desired_version",
               "applied_version",
               "versions",
               "publication_high_water",
               "publication_receipts"
             ])

    assert lifecycle["schema_version"] == 2
    assert lifecycle["publication_high_water"] == 1
    assert Map.keys(lifecycle["publication_receipts"]) == ["1"]
    expected_operation = second.operation
    expected_digest = second.digest

    assert %{
             "sequence" => 1,
             "encoded_message" => encoded_message,
             "version" => 2,
             "state" => "delivered",
             "operation" => ^expected_operation,
             "digest" => ^expected_digest,
             "resulting_state_revision" => 1
           } = lifecycle["publication_receipts"]["1"]

    assert Enum.sort(Map.keys(lifecycle["publication_receipts"]["1"])) ==
             Enum.sort([
               "sequence",
               "encoded_message",
               "version",
               "state",
               "operation",
               "digest",
               "resulting_state_revision"
             ])

    assert {:ok, %ConfigState{target_id: ^server_id, state: :delivered}} =
             Message.decode(encoded_message)

    assert {:ok, %ConfigVersion{state: :desired, state_revision: 0}} =
             ManagementCore.get_server_config_version(server_id, first.version)
  end

  test "v1 with prior lifecycle progress rejects publication acceptance but remains readable" do
    server_id = "srv-publication-v1-progress"
    register_server(server_id)
    assert {:ok, desired} = publish_server(server_id)
    assert {:ok, delivered} = transition(desired, :delivered, 0)
    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    assert {:ok, manifest} = AtomicJson.read(manifest_path)
    assert manifest["config_lifecycle"]["schema_version"] == 1
    manifest_bytes = File.read!(manifest_path)

    assert_error(
      ManagementCore.accept_config_state_publication(
        :server,
        server_id,
        1,
        encoded_acknowledgement(delivered, :applying)
      ),
      :conflict
    )

    assert File.read!(manifest_path) == manifest_bytes

    assert {:ok, ^delivered} =
             ManagementCore.get_server_config_version(server_id, desired.version)

    assert {:ok, ^delivered} = ManagementCore.latest_desired_config(:server, server_id)
  end

  test "direct transition on v2 does not fabricate publication receipts or high-water" do
    server_id = "srv-publication-direct-transition"
    register_server(server_id)
    assert {:ok, desired} = publish_server(server_id)
    assert {:ok, _receipt} = accept_publication(desired, 1, :delivered)
    assert {:ok, delivered} = ManagementCore.get_server_config_version(server_id, desired.version)
    assert {:ok, applying} = transition(delivered, :applying, 1)
    assert applying.state_revision == 2

    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    assert {:ok, manifest} = AtomicJson.read(manifest_path)
    lifecycle = manifest["config_lifecycle"]

    assert lifecycle["schema_version"] == 2
    assert lifecycle["publication_high_water"] == 1
    assert Map.keys(lifecycle["publication_receipts"]) == ["1"]

    assert {:ok, receipt} =
             accept_publication(applying, 2, :applied, applied_revision: @digest_a)

    assert receipt["state_revision"] == 3
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

  test "rollback-phase durable decode rejects succeeded rollback for only the tampered target" do
    valid = rollback_phase_failure("srv-rollback-reload-valid")
    tampered = rollback_phase_failure("srv-rollback-reload-tampered")

    assert {:ok, manifest_path} =
             StoragePath.server_manifest("srv-rollback-reload-tampered")

    assert {:ok, manifest} = AtomicJson.read(manifest_path)
    version_key = Integer.to_string(tampered.version)

    tampered_lifecycle =
      manifest["config_lifecycle"]
      |> put_in(
        ["versions", version_key, "rollback"],
        %{
          "succeeded" => true,
          "restored_version" => tampered.previous_version,
          "restored_revision" => tampered.previous_revision,
          "reason" => nil
        }
      )
      |> put_in(["versions", version_key, "restored_version"], tampered.previous_version)
      |> put_in(["versions", version_key, "restored_revision"], tampered.previous_revision)

    assert {:ok, ^manifest_path} =
             AtomicJson.replace(
               manifest_path,
               Map.put(manifest, "config_lifecycle", tampered_lifecycle)
             )

    restart_application()

    assert {:ok, restored_valid} =
             ManagementCore.get_server_config_version(
               "srv-rollback-reload-valid",
               valid.version
             )

    assert restored_valid == valid

    assert_error(
      ManagementCore.get_server_config_version(
        "srv-rollback-reload-tampered",
        tampered.version
      ),
      :invalid
    )
  end

  test "rollback-phase durable decode requires previous version and revision" do
    valid = rollback_phase_failure("srv-rollback-previous-valid")
    tampered = rollback_phase_failure("srv-rollback-previous-missing")

    assert {:ok, manifest_path} =
             StoragePath.server_manifest("srv-rollback-previous-missing")

    assert {:ok, manifest} = AtomicJson.read(manifest_path)
    version_key = Integer.to_string(tampered.version)

    assert {:ok, immutable_path} =
             StoragePath.server_version(
               "srv-rollback-previous-missing",
               tampered.version,
               tampered.digest
             )

    assert {:ok, immutable} = AtomicJson.read(immutable_path)

    assert {:ok, ^immutable_path} =
             AtomicJson.replace(immutable_path, %{immutable | "expected_revision" => nil})

    tampered_lifecycle =
      manifest["config_lifecycle"]
      |> put_in(["versions", version_key, "previous_version"], nil)
      |> put_in(["versions", version_key, "previous_revision"], nil)

    assert {:ok, ^manifest_path} =
             AtomicJson.replace(
               manifest_path,
               Map.put(manifest, "config_lifecycle", tampered_lifecycle)
             )

    restart_application()

    assert {:ok, ^valid} =
             ManagementCore.get_server_config_version(
               "srv-rollback-previous-valid",
               valid.version
             )

    assert_error(
      ManagementCore.get_server_config_version(
        "srv-rollback-previous-missing",
        tampered.version
      ),
      :invalid
    )
  end

  test "queued publish keeps its captured storage root for writes and decode identity", %{
    data_dir: root_a
  } do
    assert_error(StoragePath.server_manifest(nil, "srv-root-drift"), :internal)
    assert_error(StoragePath.server_versions("", "srv-root-drift"), :internal)

    assert {:ok, captured_root} = StoragePath.root()
    assert_error(StoragePath.server_manifest(captured_root, "../root-drift"), :invalid)

    register_server("srv-root-drift")

    root_b =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-config-versions-root-b-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root_b) end)

    config_versions = Process.whereis(ConfigVersions)
    :ok = :sys.suspend(config_versions)

    publish_result =
      try do
        publish_task = Task.async(fn -> publish_server("srv-root-drift") end)
        assert_config_version_calls_queued(config_versions, 1)
        Application.put_env(:yellow_dog_management_core, :data_dir, root_b)
        :ok = :sys.resume(config_versions)
        Task.await(publish_task, 1_000)
      after
        safe_resume(config_versions)
      end

    assert {:ok, published} = publish_result

    assert {:ok, decoded} =
             ManagementCore.get_server_config_version("srv-root-drift", published.version)

    assert decoded == published

    manifest_a =
      Path.join([root_a, "management", "servers", "srv-root-drift", "manifest.json"])

    versions_a =
      Path.join([root_a, "management", "servers", "srv-root-drift", "versions"])

    assert {:ok, manifest} = AtomicJson.read(manifest_a)
    assert manifest["config_lifecycle"]["desired_version"] == published.version
    assert [_version_path] = Path.wildcard(Path.join(versions_a, "*.json"))
    refute File.exists?(Path.join(root_b, "management"))
  end

  test "application capture normalizes a relative data directory to an absolute root" do
    relative_data_dir =
      Path.join(".tmp", "config-root-relative-#{System.unique_integer([:positive])}")

    absolute_data_dir = Path.expand(relative_data_dir)
    expected_root = Path.join(absolute_data_dir, "management")
    on_exit(fn -> File.rm_rf(absolute_data_dir) end)

    Application.put_env(:yellow_dog_management_core, :data_dir, relative_data_dir)
    restart_application()

    assert %EventStore.Config{root: ^expected_root} = EventStore.config()
    assert Path.type(expected_root) == :absolute

    register_server("srv-relative-root")
    assert {:ok, published} = publish_server("srv-relative-root")

    expected_manifest =
      Path.join([expected_root, "servers", "srv-relative-root", "manifest.json"])

    assert {:ok, manifest} = AtomicJson.read(expected_manifest)
    assert manifest["config_lifecycle"]["desired_version"] == published.version
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
    assert_receive {:immutable_created, worker_pid, version_path}, 1_000
    config_versions = Process.whereis(ConfigVersions)
    refute worker_pid == config_versions
    assert_error(Task.await(publish_task, 1_000), :timeout)
    send(worker_pid, :release_immutable_write)
    :sys.get_state(config_versions)
    refute Process.alive?(worker_pid)

    assert {:ok, ^manifest} = AtomicJson.read(manifest_path)
    assert File.exists?(version_path)

    versions_dir =
      Path.join([data_dir, "management", "servers", "srv-expired-immutable", "versions"])

    assert [^version_path] = Path.wildcard(Path.join(versions_dir, "*.json"))
  end

  test "blocking manifest read times out without wedging ConfigVersions", context do
    assert_blocking_filesystem_timeout(:read, "srv-block-read", false, context.data_dir)
  end

  test "blocking referenced immutable read returns timeout without mutation", %{
    data_dir: data_dir
  } do
    register_server("srv-block-version-read")
    assert {:ok, published} = publish_server("srv-block-version-read")
    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-block-version-read")

    assert {:ok, version_path} =
             StoragePath.server_version(
               "srv-block-version-read",
               published.version,
               published.digest
             )

    assert {:ok, manifest_before} = AtomicJson.read(manifest_path)
    assert {:ok, immutable_before} = AtomicJson.read(version_path)

    Application.put_env(:yellow_dog_management_core, :config_version_blocking_owner, self())

    Application.put_env(
      :yellow_dog_management_core,
      :config_version_blocking_operation,
      :version_read
    )

    install_event_store_config(
      file_ops: __MODULE__.BlockingConfigFileOps,
      operation_timeout_ms: 100,
      transport_margin_ms: 50
    )

    config_versions = Process.whereis(ConfigVersions)

    read_task =
      Task.async(fn ->
        ManagementCore.get_server_config_version(
          "srv-block-version-read",
          published.version
        )
      end)

    assert_receive {:config_filesystem_blocked, :version_read, worker_pid, ^version_path}, 1_000
    result = Task.await(read_task, 1_000)
    send(worker_pid, :release_config_filesystem)
    :sys.get_state(config_versions)

    assert_error(result, :timeout)
    refute worker_pid == config_versions
    refute Process.alive?(worker_pid)
    assert {:ok, ^manifest_before} = AtomicJson.read(manifest_path)
    assert {:ok, ^immutable_before} = AtomicJson.read(version_path)

    target_dir =
      Path.join([data_dir, "management", "servers", "srv-block-version-read"])

    refute filesystem_residue?(target_dir)

    Application.put_env(:yellow_dog_management_core, :config_version_blocking_operation, nil)

    assert {:ok, ^published} =
             ManagementCore.get_server_config_version(
               "srv-block-version-read",
               published.version
             )
  end

  test "blocking versions listing times out without wedging ConfigVersions", context do
    assert_blocking_filesystem_timeout(:list, "srv-block-list", false, context.data_dir)
  end

  test "blocking captured mkdir times out without wedging ConfigVersions", context do
    assert_blocking_filesystem_timeout(:mkdir, "srv-block-mkdir", false, context.data_dir)
  end

  test "blocking immutable stage times out and removes its known staging file", context do
    assert_blocking_filesystem_timeout(:stage, "srv-block-stage", false, context.data_dir)
  end

  test "blocking immutable promotion reconciles only its exact orphan", context do
    assert_blocking_filesystem_timeout(:promotion, "srv-block-promotion", true, context.data_dir)
  end

  test "immutable cleanup gets a fresh budget after reconciliation exhausts its budget", %{
    data_dir: _data_dir
  } do
    server_id = "srv-exhausted-immutable-recovery"
    register_server(server_id)
    Application.put_env(:yellow_dog_management_core, :exhausted_recovery_owner, self())

    install_event_store_config(
      file_ops: __MODULE__.ExhaustedImmutableRecoveryFileOps,
      operation_timeout_ms: 100,
      transport_margin_ms: 100
    )

    config_versions = Process.whereis(ConfigVersions)
    publish_task = Task.async(fn -> publish_server(server_id) end)

    assert_receive {:immutable_promotion_blocked, promotion_pid, final_path, staging_path}, 1_000
    assert_receive {:immutable_reconciliation_blocked, reconciliation_pid, ^final_path}, 1_000
    assert_receive {:immutable_cleanup_started, cleanup_pid, ^staging_path}, 1_000

    assert_error(Task.await(publish_task, 2_000), :timeout)
    :sys.get_state(config_versions)

    for worker <- [promotion_pid, reconciliation_pid, cleanup_pid] do
      refute Process.alive?(worker)
    end

    assert File.exists?(final_path)
    refute File.exists?(staging_path)
    refute filesystem_residue?(Path.dirname(final_path))

    install_event_store_file_ops(AtomicJson.FileOps)
    assert {:ok, %ConfigVersion{version: 2}} = publish_server(server_id)
  end

  test "immutable staging cleanup retries a transient rm error", context do
    assert_config_staging_cleanup_recovery(:error_once, "srv-cleanup-rm-error", context)
  end

  test "immutable staging cleanup kills a blocked rm worker and retries", context do
    assert_config_staging_cleanup_recovery(:block_once, "srv-cleanup-rm-block", context)
  end

  test "deadline after manifest replacement restores the exact previous lifecycle", %{
    data_dir: data_dir
  } do
    register_server("srv-manifest-deadline")
    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-manifest-deadline")
    assert {:ok, previous_manifest} = AtomicJson.read(manifest_path)

    Application.put_env(
      :yellow_dog_management_core,
      :manifest_replace_file_ops_owner,
      self()
    )

    Application.put_env(:yellow_dog_management_core, :block_config_manifest_replace, true)

    install_event_store_config(
      file_ops: __MODULE__.BlockingManifestReplaceFileOps,
      operation_timeout_ms: 1_000,
      transport_margin_ms: 250
    )

    config_versions = Process.whereis(ConfigVersions)
    :ok = :sys.suspend(config_versions)

    {publish_task, request_deadline} =
      try do
        task = Task.async(fn -> publish_server("srv-manifest-deadline") end)
        deadline = queued_config_version_deadline(config_versions)
        :ok = :sys.resume(config_versions)
        {task, deadline}
      after
        safe_resume(config_versions)
      end

    assert_receive {:config_manifest_replaced, writer, staging_path, ^manifest_path,
                    committed_contents},
                   2_000

    assert String.ends_with?(staging_path, ".stage")
    assert {:ok, replaced_manifest} = Jason.decode(committed_contents)
    assert replaced_manifest["config_lifecycle"]["desired_version"] == 1

    await_deadline(request_deadline)
    send(writer, :release_config_manifest_replace)
    assert_error(Task.await(publish_task, 3_000), :timeout)
    :sys.get_state(ManifestStore)
    :sys.get_state(config_versions)

    assert {:ok, ^previous_manifest} = AtomicJson.read(manifest_path)
    refute Map.has_key?(previous_manifest, "config_lifecycle")

    versions_dir =
      Path.join([data_dir, "management", "servers", "srv-manifest-deadline", "versions"])

    assert [orphan_path] = Path.wildcard(Path.join(versions_dir, "*.json"))
    assert Path.basename(orphan_path) =~ ~r/^1-/
    refute filesystem_residue?(Path.dirname(manifest_path))

    assert {:ok, %ConfigVersion{version: 2}} = publish_server("srv-manifest-deadline")
  end

  test "blocking ManifestStore reconciliation read is cancelled and rolled back", %{
    data_dir: data_dir
  } do
    register_server("srv-manifest-read-deadline")

    assert {:ok, manifest_path} =
             StoragePath.server_manifest("srv-manifest-read-deadline")

    assert {:ok, previous_manifest} = AtomicJson.read(manifest_path)

    counter = :atomics.new(1, [])
    Application.put_env(:yellow_dog_management_core, :manifest_read_counter, counter)
    Application.put_env(:yellow_dog_management_core, :block_manifest_read_number, 3)
    Application.put_env(:yellow_dog_management_core, :manifest_read_file_ops_owner, self())

    install_event_store_config(
      file_ops: __MODULE__.BlockingManifestReadFileOps,
      operation_timeout_ms: 100,
      transport_margin_ms: 100
    )

    config_versions = Process.whereis(ConfigVersions)
    manifest_store = Process.whereis(ManifestStore)
    :ok = :sys.suspend(config_versions)

    {publish_task, request_deadline} =
      try do
        task = Task.async(fn -> publish_server("srv-manifest-read-deadline") end)
        deadline = queued_config_version_deadline(config_versions)
        :ok = :sys.resume(config_versions)
        {task, deadline}
      after
        safe_resume(config_versions)
      end

    assert_receive {:manifest_read_blocked, blocked_pid, ^manifest_path, 3}, 1_000
    await_deadline(request_deadline)
    send(blocked_pid, :release_manifest_read)

    assert_error(Task.await(publish_task, 2_000), :timeout)
    :sys.get_state(manifest_store)
    :sys.get_state(config_versions)

    refute blocked_pid == manifest_store
    refute Process.alive?(blocked_pid)
    assert {:ok, ^previous_manifest} = AtomicJson.read(manifest_path)
    refute filesystem_residue?(Path.dirname(manifest_path))

    versions_dir =
      Path.join([
        data_dir,
        "management",
        "servers",
        "srv-manifest-read-deadline",
        "versions"
      ])

    assert [orphan_path] = Path.wildcard(Path.join(versions_dir, "*.json"))
    assert Path.basename(orphan_path) =~ ~r/^1-/
    assert {:ok, %ConfigVersion{version: 2}} = publish_server("srv-manifest-read-deadline")
  end

  test "blocked manifest staging cleanup is killed retried and leaves no residue", %{
    data_dir: data_dir
  } do
    register_server("srv-manifest-cleanup")

    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-manifest-cleanup")
    assert {:ok, previous_manifest} = AtomicJson.read(manifest_path)

    counter = :atomics.new(1, [])
    Application.put_env(:yellow_dog_management_core, :manifest_staging_cleanup_counter, counter)
    Application.put_env(:yellow_dog_management_core, :manifest_staging_cleanup_mode, :block_once)
    Application.put_env(:yellow_dog_management_core, :manifest_staging_cleanup_owner, self())

    install_event_store_config(
      file_ops: __MODULE__.BlockingManifestCleanupFileOps,
      operation_timeout_ms: 100,
      transport_margin_ms: 100
    )

    publish_task = Task.async(fn -> publish_server("srv-manifest-cleanup") end)

    assert_receive {:manifest_rename_blocked, rename_pid, staging_path, ^manifest_path}, 1_000
    assert_receive {:manifest_staging_rm_blocked, cleanup_pid, ^staging_path}, 1_000
    assert_error(Task.await(publish_task, 2_000), :timeout)
    send(rename_pid, :release_manifest_rename)
    send(cleanup_pid, :release_manifest_staging_rm)

    :sys.get_state(ManifestStore)
    :sys.get_state(ConfigVersions)
    refute Process.alive?(rename_pid)
    refute Process.alive?(cleanup_pid)
    assert {:ok, ^previous_manifest} = AtomicJson.read(manifest_path)
    refute File.exists?(staging_path)
    refute filesystem_residue?(Path.dirname(manifest_path))

    versions_dir =
      Path.join([data_dir, "management", "servers", "srv-manifest-cleanup", "versions"])

    assert [orphan_path] = Path.wildcard(Path.join(versions_dir, "*.json"))
    assert Path.basename(orphan_path) =~ ~r/^1-/
    Application.put_env(:yellow_dog_management_core, :manifest_staging_cleanup_mode, nil)
    assert {:ok, %ConfigVersion{version: 2}} = publish_server("srv-manifest-cleanup")
  end

  test "manifest cleanup gets a fresh budget after reconciliation exhausts its budget", %{
    data_dir: data_dir
  } do
    server_id = "srv-exhausted-manifest-recovery"
    register_server(server_id)
    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    assert {:ok, previous_manifest} = AtomicJson.read(manifest_path)

    state = :atomics.new(2, [])
    Application.put_env(:yellow_dog_management_core, :exhausted_recovery_owner, self())
    Application.put_env(:yellow_dog_management_core, :exhausted_manifest_recovery_state, state)

    install_event_store_config(
      file_ops: __MODULE__.ExhaustedManifestRecoveryFileOps,
      operation_timeout_ms: 100,
      transport_margin_ms: 100
    )

    publish_task = Task.async(fn -> publish_server(server_id) end)

    assert_receive {:manifest_promotion_blocked, promotion_pid, staging_path, ^manifest_path},
                   1_000

    assert_receive {:manifest_reconciliation_blocked, reconciliation_pid, ^manifest_path}, 1_000
    assert_receive {:manifest_cleanup_started, cleanup_pid, ^staging_path}, 1_000

    assert_error(Task.await(publish_task, 2_000), :timeout)
    :sys.get_state(ManifestStore)
    :sys.get_state(ConfigVersions)

    for worker <- [promotion_pid, reconciliation_pid, cleanup_pid] do
      refute Process.alive?(worker)
    end

    assert {:ok, ^previous_manifest} = AtomicJson.read(manifest_path)
    refute File.exists?(staging_path)
    refute filesystem_residue?(Path.dirname(manifest_path))

    versions_dir = Path.join([data_dir, "management", "servers", server_id, "versions"])
    assert [_orphan] = Path.wildcard(Path.join(versions_dir, "*.json"))

    install_event_store_file_ops(AtomicJson.FileOps)
    assert {:ok, %ConfigVersion{version: 2}} = publish_server(server_id)
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

  test "incoherent lifecycle counter and desired metadata block every facade path", %{
    data_dir: data_dir
  } do
    cases = [
      {"counter-without-versions", 1,
       fn lifecycle ->
         lifecycle
         |> Map.put("counter", 5)
         |> Map.put("desired_version", nil)
         |> Map.put("applied_version", nil)
         |> Map.put("versions", %{})
       end},
      {"counter-above-max", 1,
       fn lifecycle ->
         lifecycle
         |> Map.put("counter", 2)
         |> Map.put("desired_version", 2)
       end},
      {"nil-desired", 1,
       fn lifecycle ->
         Map.put(lifecycle, "desired_version", nil)
       end},
      {"stale-desired", 2,
       fn lifecycle ->
         Map.put(lifecycle, "desired_version", 1)
       end}
    ]

    for {suffix, publish_count, tamper} <- cases do
      server_id = "srv-lifecycle-#{suffix}"
      register_server(server_id)

      published =
        Enum.map(1..publish_count, fn index ->
          assert {:ok, version} =
                   ManagementCore.publish_server_config(server_id, server_attrs(index))

          version
        end)

      transition_version = List.last(published)
      assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
      assert {:ok, manifest} = AtomicJson.read(manifest_path)

      tampered_manifest =
        Map.update!(manifest, "config_lifecycle", tamper)

      assert {:ok, ^manifest_path} = AtomicJson.replace(manifest_path, tampered_manifest)

      versions_dir =
        Path.join([data_dir, "management", "servers", server_id, "versions"])

      manifest_bytes = File.read!(manifest_path)
      version_files = snapshot_files(versions_dir)

      assert_error(
        ManagementCore.get_server_config_version(server_id, transition_version.version),
        :invalid
      )

      assert_error(ManagementCore.latest_desired_config(:server, server_id), :invalid)
      assert_error(transition(transition_version, :delivered, 0), :invalid)

      assert_error(
        ManagementCore.publish_server_config(server_id, server_attrs(publish_count + 1)),
        :invalid
      )

      assert File.read!(manifest_path) == manifest_bytes
      assert snapshot_files(versions_dir) == version_files
      refute filesystem_residue?(Path.dirname(manifest_path))
    end
  end

  test "concrete target profiles are enforced for new and durable versions", %{
    data_dir: data_dir
  } do
    now = DateTime.utc_now(:second)

    assert_error(
      ConfigVersion.new(
        :server,
        "srv-profile-new",
        1,
        "server.settings.update",
        "vm",
        server_attrs(1).payload,
        nil,
        now,
        nil
      ),
      :invalid
    )

    assert_error(
      ConfigVersion.new(
        :netman,
        "netman-profile-new",
        1,
        "netman.resolved.config.update",
        "dns_only",
        netman_attrs().payload,
        nil,
        now,
        nil
      ),
      :invalid
    )

    cases = [
      {:server, "srv-profile-tampered", "vm", &register_server/1, &publish_server/1,
       &ManagementCore.get_server_config_version/2, &server_attrs/1},
      {:netman, "netman-profile-tampered", "dns_only", &register_netman/1,
       fn id -> ManagementCore.publish_netman_config(id, netman_attrs()) end,
       &ManagementCore.get_netman_config_version/2, fn _index -> netman_attrs() end}
    ]

    for {target_type, target_id, invalid_profile, register, publish, get, attrs} <- cases do
      register.(target_id)
      assert {:ok, published} = publish.(target_id)

      assert {:ok, immutable_path} =
               target_version_path(target_type, target_id, published.version, published.digest)

      assert {:ok, immutable} = AtomicJson.read(immutable_path)

      assert {:ok, ^immutable_path} =
               AtomicJson.replace(immutable_path, %{immutable | "profile" => invalid_profile})

      assert {:ok, manifest_path} = target_manifest_path(target_type, target_id)
      manifest_bytes = File.read!(manifest_path)

      versions_dir =
        Path.join([
          data_dir,
          "management",
          target_directory(target_type),
          target_id,
          "versions"
        ])

      version_files = snapshot_files(versions_dir)

      assert_error(get.(target_id, published.version), :invalid)
      assert_error(ManagementCore.latest_desired_config(target_type, target_id), :invalid)
      assert_error(transition(published, :delivered, 0), :invalid)

      publish_result =
        case target_type do
          :server -> ManagementCore.publish_server_config(target_id, attrs.(2))
          :netman -> ManagementCore.publish_netman_config(target_id, attrs.(2))
        end

      assert_error(publish_result, :invalid)
      assert File.read!(manifest_path) == manifest_bytes
      assert snapshot_files(versions_dir) == version_files
      refute filesystem_residue?(Path.dirname(manifest_path))
    end

    assert {:ok, _server} =
             ManagementCore.register_server(%{id: "srv-profile-custom", profile: :custom})

    assert {:ok, %ConfigVersion{profile: "custom"}} = publish_server("srv-profile-custom")

    assert {:ok, _netman} =
             ManagementCore.register_netman(%{id: "netman-profile-custom", profile: :custom})

    assert {:ok, %ConfigVersion{profile: "custom"}} =
             ManagementCore.publish_netman_config("netman-profile-custom", netman_attrs())
  end

  test "current active desired previous pair must match the applied pointer", %{
    data_dir: data_dir
  } do
    server_id = "srv-active-desired-applied-mismatch"
    register_server(server_id)
    assert {:ok, first} = publish_server(server_id)
    first = apply_version(first, @digest_a)

    assert {:ok, second} =
             ManagementCore.publish_server_config(
               server_id,
               server_attrs(2, expected_revision: @digest_a)
             )

    second = apply_version(second, @digest_b)

    assert {:ok, desired} =
             ManagementCore.publish_server_config(
               server_id,
               server_attrs(3, expected_revision: @digest_b)
             )

    tamper_active_desired_pair(server_id, desired, first.version, @digest_a)
    assert_corrupt_target_rejected(server_id, desired, 4, data_dir)

    nil_applied_id = "srv-active-desired-nil-applied-mismatch"
    register_server(nil_applied_id)

    versions_dir =
      Path.join([data_dir, "management", "servers", nil_applied_id, "versions"])

    File.mkdir_p!(versions_dir)
    File.write!(Path.join(versions_dir, "1-#{@digest_a}.json"), "reserved orphan")
    assert {:ok, %ConfigVersion{version: 2} = nil_applied} = publish_server(nil_applied_id)

    tamper_active_desired_pair(nil_applied_id, nil_applied, 1, @digest_a)
    assert_corrupt_target_rejected(nil_applied_id, nil_applied, 3, data_dir)

    register_server("srv-active-desired-valid-empty")
    assert {:ok, valid_empty} = publish_server("srv-active-desired-valid-empty")

    assert {:ok, ^valid_empty} =
             ManagementCore.latest_desired_config(:server, "srv-active-desired-valid-empty")

    register_server("srv-active-desired-valid-applied")
    assert {:ok, valid_first} = publish_server("srv-active-desired-valid-applied")
    valid_first = apply_version(valid_first, @digest_a)

    assert {:ok, %ConfigVersion{previous_version: 1, previous_revision: @digest_a}} =
             ManagementCore.publish_server_config(
               "srv-active-desired-valid-applied",
               server_attrs(2, expected_revision: valid_first.applied_revision)
             )

    assert second.applied_revision == @digest_b
  end

  test "current applied desired must match the manifest applied pointer", %{
    data_dir: data_dir
  } do
    server_id = "srv-terminal-applied-pointer-backward"
    register_server(server_id)
    assert {:ok, first} = publish_server(server_id)
    first = apply_version(first, @digest_a)

    assert {:ok, second} =
             ManagementCore.publish_server_config(
               server_id,
               server_attrs(2, expected_revision: @digest_a)
             )

    second = apply_version(second, @digest_b)
    tamper_applied_pointer(server_id, first.version)
    assert_corrupt_target_rejected(server_id, second, 3, data_dir)

    nil_pointer_id = "srv-terminal-applied-pointer-nil"
    register_server(nil_pointer_id)
    assert {:ok, nil_pointer} = publish_server(nil_pointer_id)
    nil_pointer = apply_version(nil_pointer, @digest_a)
    tamper_applied_pointer(nil_pointer_id, nil)
    assert_corrupt_target_rejected(nil_pointer_id, nil_pointer, 2, data_dir)

    valid_id = "srv-terminal-applied-pointer-valid"
    register_server(valid_id)
    assert {:ok, valid_first} = publish_server(valid_id)
    valid_first = apply_version(valid_first, @digest_a)

    assert {:ok, valid_second} =
             ManagementCore.publish_server_config(
               valid_id,
               server_attrs(2, expected_revision: valid_first.applied_revision)
             )

    valid_second = apply_version(valid_second, @digest_b)

    assert {:ok, %ConfigVersion{version: 3, previous_version: 2, previous_revision: @digest_b}} =
             ManagementCore.publish_server_config(
               valid_id,
               server_attrs(3, expected_revision: valid_second.applied_revision)
             )
  end

  test "terminal failures preserve and validate the previous applied pointer", %{
    data_dir: data_dir
  } do
    server_id = "srv-terminal-failure-pointer"
    register_server(server_id)
    assert {:ok, first} = publish_server(server_id)
    first = apply_version(first, @digest_a)

    assert {:ok, second} = publish_with_revision(server_id, 2, first.applied_revision)

    assert {:ok, failed_delivery} =
             transition(second, :failed, 0,
               failure_phase: :delivery,
               reason: "delivery failed"
             )

    assert_terminal_failure_valid(server_id, failed_delivery)

    assert {:ok, third} = publish_with_revision(server_id, 3, first.applied_revision)
    assert {:ok, delivered_third} = transition(third, :delivered, 0)

    assert {:ok, failed_validation} =
             transition(delivered_third, :failed, 1,
               failure_phase: :validation,
               reason: "validation failed"
             )

    assert_terminal_failure_valid(server_id, failed_validation)

    assert {:ok, fourth} = publish_with_revision(server_id, 4, first.applied_revision)
    assert {:ok, delivered_fourth} = transition(fourth, :delivered, 0)
    assert {:ok, applying_fourth} = transition(delivered_fourth, :applying, 1)

    assert {:ok, failed_rollback_success} =
             transition(applying_fourth, :failed, 2,
               failure_phase: :apply,
               reason: "apply failed and rollback succeeded",
               rollback: %{
                 "succeeded" => true,
                 "restored_version" => first.version,
                 "restored_revision" => first.applied_revision,
                 "reason" => nil
               }
             )

    assert_terminal_failure_valid(server_id, failed_rollback_success)

    assert {:ok, fifth} = publish_with_revision(server_id, 5, first.applied_revision)
    assert {:ok, delivered_fifth} = transition(fifth, :delivered, 0)
    assert {:ok, applying_fifth} = transition(delivered_fifth, :applying, 1)

    assert {:ok, failed_rollback} =
             transition(applying_fifth, :failed, 2,
               failure_phase: :apply,
               reason: "apply and rollback failed",
               rollback: %{
                 "succeeded" => false,
                 "restored_version" => nil,
                 "restored_revision" => nil,
                 "reason" => "rollback failed"
               }
             )

    assert_terminal_failure_valid(server_id, failed_rollback)
    restart_application()
    assert_terminal_failure_valid(server_id, failed_rollback)

    tamper_applied_pointer(server_id, nil)
    assert_corrupt_target_rejected(server_id, failed_rollback, 6, data_dir)
  end

  test "orphan version gaps remain valid and reserve monotonic version numbers", %{
    data_dir: data_dir
  } do
    register_server("srv-lifecycle-orphan-gap")

    versions_dir =
      Path.join([
        data_dir,
        "management",
        "servers",
        "srv-lifecycle-orphan-gap",
        "versions"
      ])

    File.mkdir_p!(versions_dir)
    orphan_path = Path.join(versions_dir, "1-#{@digest_a}.json")
    File.write!(orphan_path, "unreferenced orphan")

    assert {:ok, %ConfigVersion{version: 2} = second} =
             publish_server("srv-lifecycle-orphan-gap")

    assert {:ok, ^second} =
             ManagementCore.latest_desired_config(:server, "srv-lifecycle-orphan-gap")

    assert {:ok, %ConfigVersion{version: 3} = third} =
             ManagementCore.publish_server_config(
               "srv-lifecycle-orphan-gap",
               server_attrs(3)
             )

    assert {:ok, manifest_path} = StoragePath.server_manifest("srv-lifecycle-orphan-gap")
    assert {:ok, manifest} = AtomicJson.read(manifest_path)
    lifecycle = manifest["config_lifecycle"]

    assert lifecycle["counter"] == 3
    assert lifecycle["desired_version"] == 3
    assert Enum.sort(Map.keys(lifecycle["versions"])) == ["2", "3"]
    assert File.exists?(orphan_path)
    assert {:ok, ^third} = ManagementCore.get_server_config_version("srv-lifecycle-orphan-gap", 3)
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

  defp publish_with_revision(server_id, index, expected_revision) do
    ManagementCore.publish_server_config(
      server_id,
      server_attrs(index, expected_revision: expected_revision)
    )
  end

  defp assert_terminal_failure_valid(server_id, version) do
    assert {:ok, ^version} =
             ManagementCore.get_server_config_version(server_id, version.version)

    assert_error(ManagementCore.latest_desired_config(:server, server_id), :not_found)
  end

  defp apply_version(version, applied_revision \\ @digest_a) do
    assert {:ok, delivered} = transition(version, :delivered, 0)
    assert {:ok, applying} = transition(delivered, :applying, 1)
    assert {:ok, applied} = transition(applying, :applied, 2, applied_revision: applied_revision)
    applied
  end

  defp tamper_active_desired_pair(server_id, desired, previous_version, previous_revision) do
    assert {:ok, immutable_path} =
             StoragePath.server_version(server_id, desired.version, desired.digest)

    assert {:ok, immutable} = AtomicJson.read(immutable_path)

    assert {:ok, ^immutable_path} =
             AtomicJson.replace(immutable_path, %{
               immutable
               | "expected_revision" => previous_revision
             })

    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    assert {:ok, manifest} = AtomicJson.read(manifest_path)
    version_key = Integer.to_string(desired.version)

    lifecycle =
      manifest["config_lifecycle"]
      |> put_in(["versions", version_key, "previous_version"], previous_version)
      |> put_in(["versions", version_key, "previous_revision"], previous_revision)

    assert {:ok, ^manifest_path} =
             AtomicJson.replace(manifest_path, %{manifest | "config_lifecycle" => lifecycle})
  end

  defp tamper_applied_pointer(server_id, applied_version) do
    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    assert {:ok, manifest} = AtomicJson.read(manifest_path)

    lifecycle = Map.put(manifest["config_lifecycle"], "applied_version", applied_version)

    assert {:ok, ^manifest_path} =
             AtomicJson.replace(manifest_path, %{manifest | "config_lifecycle" => lifecycle})
  end

  defp assert_corrupt_target_rejected(server_id, version, next_index, data_dir) do
    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    manifest_bytes = File.read!(manifest_path)

    versions_dir =
      Path.join([data_dir, "management", "servers", server_id, "versions"])

    version_files = snapshot_files(versions_dir)

    assert_error(
      ManagementCore.get_server_config_version(server_id, version.version),
      :invalid
    )

    assert_error(ManagementCore.latest_desired_config(:server, server_id), :invalid)
    assert_error(transition(version, :delivered, 0), :invalid)

    assert_error(
      ManagementCore.publish_server_config(server_id, server_attrs(next_index)),
      :invalid
    )

    assert File.read!(manifest_path) == manifest_bytes
    assert snapshot_files(versions_dir) == version_files
    refute filesystem_residue?(Path.dirname(manifest_path))
  end

  defp target_version_path(:server, target_id, version, digest),
    do: StoragePath.server_version(target_id, version, digest)

  defp target_version_path(:netman, target_id, version, digest),
    do: StoragePath.netman_version(target_id, version, digest)

  defp target_manifest_path(:server, target_id), do: StoragePath.server_manifest(target_id)
  defp target_manifest_path(:netman, target_id), do: StoragePath.netman_manifest(target_id)
  defp target_directory(:server), do: "servers"
  defp target_directory(:netman), do: "netmans"

  defp rollback_phase_failure(server_id) do
    register_server(server_id)
    assert {:ok, first} = publish_server(server_id)
    applied = apply_version(first)

    assert {:ok, second} =
             ManagementCore.publish_server_config(
               server_id,
               server_attrs(2, expected_revision: applied.applied_revision)
             )

    assert {:ok, delivered} = transition(second, :delivered, 0)
    assert {:ok, applying} = transition(delivered, :applying, 1)

    assert {:ok, failed} =
             transition(applying, :failed, 2,
               failure_phase: :rollback,
               reason: "rollback failed",
               rollback: %{
                 "succeeded" => false,
                 "restored_version" => nil,
                 "restored_revision" => nil,
                 "reason" => "runtime rollback failed"
               }
             )

    failed
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

  defp accept_publication(version, sequence, state, opts \\ []) do
    ManagementCore.accept_config_state_publication(
      version.target_type,
      version.target_id,
      sequence,
      encoded_acknowledgement(version, state, opts)
    )
  end

  defp encoded_acknowledgement(version, state, opts \\ []) do
    version
    |> acknowledgement(state, opts)
    |> encoded_message()
  end

  defp encoded_message(message) do
    assert {:ok, encoded} = Message.encode(message)
    encoded
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

  defp queued_config_version_deadline(config_versions) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    queued_config_version_deadline(config_versions, deadline)
  end

  defp queued_config_version_deadline(config_versions, wait_deadline) do
    {:messages, messages} = Process.info(config_versions, :messages)

    request_deadline =
      Enum.find_value(messages, fn
        {:"$gen_call", _from, {{:publish, _target_type, _target_id, _attrs}, deadline, _config}} ->
          deadline

        _message ->
          nil
      end)

    cond do
      is_integer(request_deadline) ->
        request_deadline

      System.monotonic_time(:millisecond) < wait_deadline ->
        receive do
        after
          1 -> queued_config_version_deadline(config_versions, wait_deadline)
        end

      true ->
        flunk("expected a queued ConfigVersions publish call")
    end
  end

  defp await_deadline(deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      receive do
      after
        1 -> await_deadline(deadline)
      end
    end
  end

  defp safe_resume(process) do
    :sys.resume(process)
  catch
    :exit, _reason -> :ok
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

  defp assert_blocking_filesystem_timeout(operation, server_id, orphan?, data_dir) do
    register_server(server_id)
    Application.put_env(:yellow_dog_management_core, :config_version_blocking_owner, self())

    Application.put_env(
      :yellow_dog_management_core,
      :config_version_blocking_operation,
      operation
    )

    install_event_store_config(
      file_ops: __MODULE__.BlockingConfigFileOps,
      operation_timeout_ms: 100,
      transport_margin_ms: 50
    )

    config_versions = Process.whereis(ConfigVersions)
    publish_task = Task.async(fn -> publish_server(server_id) end)

    assert_receive {:config_filesystem_blocked, ^operation, blocked_pid, blocked_path}, 1_000
    publish_result = Task.await(publish_task, 1_000)
    send(blocked_pid, :release_config_filesystem)
    :sys.get_state(config_versions)

    assert_error(publish_result, :timeout)
    refute blocked_pid == config_versions
    refute Process.alive?(blocked_pid)

    target_dir = Path.join([data_dir, "management", "servers", server_id])
    refute filesystem_residue?(target_dir)

    versions_dir = Path.join(target_dir, "versions")
    version_paths = Path.wildcard(Path.join(versions_dir, "*.json"))

    if orphan? do
      assert [orphan_path] = version_paths
      assert Path.basename(orphan_path) =~ ~r/^1-/
      assert blocked_path == orphan_path
    else
      assert version_paths == []
    end

    Application.put_env(:yellow_dog_management_core, :config_version_blocking_operation, nil)
    expected_version = if orphan?, do: 2, else: 1
    assert {:ok, %ConfigVersion{version: ^expected_version}} = publish_server(server_id)
  end

  defp assert_config_staging_cleanup_recovery(mode, server_id, %{data_dir: data_dir}) do
    register_server(server_id)
    counter = :atomics.new(1, [])

    Application.put_env(:yellow_dog_management_core, :config_version_blocking_owner, self())
    Application.put_env(:yellow_dog_management_core, :config_version_blocking_operation, :stage)
    Application.put_env(:yellow_dog_management_core, :config_staging_cleanup_counter, counter)
    Application.put_env(:yellow_dog_management_core, :config_staging_cleanup_mode, mode)

    install_event_store_config(
      file_ops: __MODULE__.BlockingConfigFileOps,
      operation_timeout_ms: 100,
      transport_margin_ms: 100
    )

    publish_task = Task.async(fn -> publish_server(server_id) end)
    assert_receive {:config_filesystem_blocked, :stage, stage_pid, staging_path}, 1_000

    cleanup_pid =
      if mode == :block_once do
        assert_receive {:config_staging_rm_blocked, blocked_pid, ^staging_path}, 1_000
        blocked_pid
      end

    assert_error(Task.await(publish_task, 2_000), :timeout)
    send(stage_pid, :release_config_filesystem)
    if is_pid(cleanup_pid), do: send(cleanup_pid, :release_config_staging_rm)

    :sys.get_state(ConfigVersions)
    refute Process.alive?(stage_pid)
    if is_pid(cleanup_pid), do: refute(Process.alive?(cleanup_pid))
    refute File.exists?(staging_path)

    target_dir = Path.join([data_dir, "management", "servers", server_id])
    refute filesystem_residue?(target_dir)
    Application.put_env(:yellow_dog_management_core, :config_version_blocking_operation, nil)
    Application.put_env(:yellow_dog_management_core, :config_staging_cleanup_mode, nil)
    assert {:ok, %ConfigVersion{version: 1}} = publish_server(server_id)
  end

  defp filesystem_residue?(path) do
    case File.ls(path) do
      {:ok, names} ->
        Enum.any?(names, fn name ->
          child = Path.join(path, name)
          String.ends_with?(name, [".stage", ".tmp"]) or filesystem_residue?(child)
        end)

      {:error, :enotdir} ->
        false

      {:error, :enoent} ->
        false
    end
  end

  defp snapshot_files(directory) do
    directory
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Map.new(fn path -> {path, File.read!(path)} end)
  end

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defmodule FailingManifestFileOps do
    @moduledoc false

    def read(path), do: File.read(path)
    def ls(path), do: File.ls(path)
    def mkdir_p(path), do: File.mkdir_p(path)
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
    def ls(path), do: File.ls(path)
    def mkdir_p(path), do: File.mkdir_p(path)

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

  defmodule BlockingManifestReplaceFileOps do
    @moduledoc false

    def read(path), do: File.read(path)
    def ls(path), do: File.ls(path)
    def mkdir_p(path), do: File.mkdir_p(path)
    def open(path), do: :file.open(path, [:write, :exclusive, :binary, :raw])
    def write(device, contents), do: :file.write(device, contents)
    def sync(device), do: :file.sync(device)
    def close(device), do: :file.close(device)
    def link(source, target), do: :file.make_link(source, target)
    def rm(path), do: File.rm(path)

    def rename(source, target) do
      case :file.rename(source, target) do
        :ok ->
          maybe_block_manifest_replace(source, target)
          :ok

        error ->
          error
      end
    end

    defp maybe_block_manifest_replace(source, target) do
      block? =
        Path.basename(target) == "manifest.json" and
          Application.get_env(
            :yellow_dog_management_core,
            :block_config_manifest_replace,
            false
          )

      if block? do
        Application.put_env(:yellow_dog_management_core, :block_config_manifest_replace, false)

        owner =
          Application.fetch_env!(
            :yellow_dog_management_core,
            :manifest_replace_file_ops_owner
          )

        {:ok, committed_contents} = File.read(target)

        send(owner, {
          :config_manifest_replaced,
          self(),
          source,
          target,
          committed_contents
        })

        receive do
          :release_config_manifest_replace -> :ok
        end
      end
    end
  end

  defmodule BlockingManifestReadFileOps do
    @moduledoc false

    alias YellowDog.Management.Storage.AtomicJson.FileOps

    def read(path) do
      maybe_block_manifest_read(path)
      FileOps.read(path)
    end

    defdelegate ls(path), to: FileOps
    defdelegate mkdir_p(path), to: FileOps
    defdelegate open(path), to: FileOps
    defdelegate write(device, contents), to: FileOps
    defdelegate sync(device), to: FileOps
    defdelegate close(device), to: FileOps
    defdelegate rename(source, target), to: FileOps
    defdelegate link(source, target), to: FileOps
    defdelegate rm(path), to: FileOps

    defp maybe_block_manifest_read(path) do
      if Path.basename(path) == "manifest.json" do
        counter = Application.fetch_env!(:yellow_dog_management_core, :manifest_read_counter)
        read_number = :atomics.add_get(counter, 1, 1)

        if read_number ==
             Application.fetch_env!(
               :yellow_dog_management_core,
               :block_manifest_read_number
             ) do
          owner =
            Application.fetch_env!(
              :yellow_dog_management_core,
              :manifest_read_file_ops_owner
            )

          send(owner, {:manifest_read_blocked, self(), path, read_number})

          receive do
            :release_manifest_read -> :ok
          end
        end
      end
    end
  end

  defmodule BlockingManifestCleanupFileOps do
    @moduledoc false

    alias YellowDog.Management.Storage.AtomicJson.FileOps

    defdelegate read(path), to: FileOps
    defdelegate ls(path), to: FileOps
    defdelegate mkdir_p(path), to: FileOps
    defdelegate open(path), to: FileOps
    defdelegate write(device, contents), to: FileOps
    defdelegate sync(device), to: FileOps
    defdelegate close(device), to: FileOps

    def rename(source, target) do
      if Path.basename(target) == "manifest.json" and cleanup_mode() == :block_once do
        owner =
          Application.fetch_env!(
            :yellow_dog_management_core,
            :manifest_staging_cleanup_owner
          )

        send(owner, {:manifest_rename_blocked, self(), source, target})

        receive do
          :release_manifest_rename -> :ok
        end
      end

      FileOps.rename(source, target)
    end

    defdelegate link(source, target), to: FileOps

    def rm(path) do
      if manifest_staging_path?(path) and cleanup_mode() == :block_once do
        counter =
          Application.fetch_env!(
            :yellow_dog_management_core,
            :manifest_staging_cleanup_counter
          )

        if :atomics.add_get(counter, 1, 1) == 1 do
          owner =
            Application.fetch_env!(
              :yellow_dog_management_core,
              :manifest_staging_cleanup_owner
            )

          send(owner, {:manifest_staging_rm_blocked, self(), path})

          receive do
            :release_manifest_staging_rm -> :ok
          end
        end
      end

      FileOps.rm(path)
    end

    defp cleanup_mode,
      do: Application.get_env(:yellow_dog_management_core, :manifest_staging_cleanup_mode)

    defp manifest_staging_path?(path) do
      String.contains?(Path.basename(path), ".manifest.json.") and
        String.ends_with?(path, ".stage")
    end
  end

  defmodule ExhaustedImmutableRecoveryFileOps do
    @moduledoc false

    alias YellowDog.Management.Storage.AtomicJson.FileOps

    def read(path) do
      if String.contains?(path, "/versions/") do
        owner = Application.fetch_env!(:yellow_dog_management_core, :exhausted_recovery_owner)
        send(owner, {:immutable_reconciliation_blocked, self(), path})

        receive do
          :release_immutable_reconciliation -> :ok
        end
      end

      FileOps.read(path)
    end

    defdelegate ls(path), to: FileOps
    defdelegate mkdir_p(path), to: FileOps
    defdelegate open(path), to: FileOps
    defdelegate write(device, contents), to: FileOps
    defdelegate sync(device), to: FileOps
    defdelegate close(device), to: FileOps
    defdelegate rename(source, target), to: FileOps

    def link(source, target) do
      with :ok <- FileOps.link(source, target) do
        owner = Application.fetch_env!(:yellow_dog_management_core, :exhausted_recovery_owner)
        send(owner, {:immutable_promotion_blocked, self(), target, source})

        receive do
          :release_immutable_promotion -> :ok
        end
      end
    end

    def rm(path) do
      if String.ends_with?(path, ".stage") do
        owner = Application.fetch_env!(:yellow_dog_management_core, :exhausted_recovery_owner)
        send(owner, {:immutable_cleanup_started, self(), path})
      end

      FileOps.rm(path)
    end
  end

  defmodule ExhaustedManifestRecoveryFileOps do
    @moduledoc false

    alias YellowDog.Management.Storage.AtomicJson.FileOps

    def read(path) do
      state = state()

      if Path.basename(path) == "manifest.json" and :atomics.get(state, 1) == 1 and
           :atomics.compare_exchange(state, 2, 0, 1) == :ok do
        owner = Application.fetch_env!(:yellow_dog_management_core, :exhausted_recovery_owner)
        send(owner, {:manifest_reconciliation_blocked, self(), path})

        receive do
          :release_manifest_reconciliation -> :ok
        end
      end

      FileOps.read(path)
    end

    defdelegate ls(path), to: FileOps
    defdelegate mkdir_p(path), to: FileOps
    defdelegate open(path), to: FileOps
    defdelegate write(device, contents), to: FileOps
    defdelegate sync(device), to: FileOps
    defdelegate close(device), to: FileOps
    defdelegate link(source, target), to: FileOps

    def rename(source, target) do
      state = state()

      if Path.basename(target) == "manifest.json" and
           :atomics.compare_exchange(state, 1, 0, 1) == :ok do
        with :ok <- FileOps.rename(source, target) do
          owner = Application.fetch_env!(:yellow_dog_management_core, :exhausted_recovery_owner)
          send(owner, {:manifest_promotion_blocked, self(), source, target})

          receive do
            :release_manifest_promotion -> :ok
          end
        end
      else
        FileOps.rename(source, target)
      end
    end

    def rm(path) do
      if String.ends_with?(path, ".stage") and :atomics.get(state(), 1) == 1 do
        owner = Application.fetch_env!(:yellow_dog_management_core, :exhausted_recovery_owner)
        send(owner, {:manifest_cleanup_started, self(), path})
      end

      FileOps.rm(path)
    end

    defp state do
      Application.fetch_env!(
        :yellow_dog_management_core,
        :exhausted_manifest_recovery_state
      )
    end
  end

  defmodule BlockingConfigFileOps do
    @moduledoc false

    alias YellowDog.Management.Storage.AtomicJson.FileOps

    def read(path) do
      operation = if String.contains?(path, "/versions/"), do: :version_read, else: :read
      maybe_block(operation, path)
      FileOps.read(path)
    end

    def ls(path) do
      maybe_block(:list, path)
      FileOps.ls(path)
    end

    def mkdir_p(path) do
      maybe_block(:mkdir, path)
      FileOps.mkdir_p(path)
    end

    def open(path) do
      case FileOps.open(path) do
        {:ok, _device} = success ->
          if String.ends_with?(path, ".stage"), do: maybe_block(:stage, path)
          success

        error ->
          error
      end
    end

    defdelegate write(device, contents), to: FileOps
    defdelegate sync(device), to: FileOps
    defdelegate close(device), to: FileOps
    defdelegate rename(source, target), to: FileOps

    def link(source, target) do
      case FileOps.link(source, target) do
        :ok ->
          maybe_block(:promotion, target)
          :ok

        error ->
          error
      end
    end

    def rm(path) do
      if String.ends_with?(path, ".stage") do
        maybe_cleanup_failure(path)
      else
        FileOps.rm(path)
      end
    end

    defp maybe_block(operation, path) do
      if Application.get_env(
           :yellow_dog_management_core,
           :config_version_blocking_operation
         ) == operation do
        owner =
          Application.fetch_env!(
            :yellow_dog_management_core,
            :config_version_blocking_owner
          )

        send(owner, {:config_filesystem_blocked, operation, self(), path})

        receive do
          :release_config_filesystem -> :ok
        end
      end
    end

    defp maybe_cleanup_failure(path) do
      case Application.get_env(:yellow_dog_management_core, :config_staging_cleanup_mode) do
        mode when mode in [:error_once, :block_once] ->
          counter =
            Application.fetch_env!(
              :yellow_dog_management_core,
              :config_staging_cleanup_counter
            )

          if :atomics.add_get(counter, 1, 1) == 1 do
            cleanup_failure(mode, path)
          else
            FileOps.rm(path)
          end

        _other ->
          FileOps.rm(path)
      end
    end

    defp cleanup_failure(:error_once, _path), do: {:error, :injected_rm}

    defp cleanup_failure(:block_once, path) do
      owner =
        Application.fetch_env!(
          :yellow_dog_management_core,
          :config_version_blocking_owner
        )

      send(owner, {:config_staging_rm_blocked, self(), path})

      receive do
        :release_config_staging_rm -> FileOps.rm(path)
      end
    end
  end
end
