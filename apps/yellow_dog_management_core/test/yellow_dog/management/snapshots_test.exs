defmodule YellowDog.Management.SnapshotsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.ControlledFileOps
  alias YellowDog.Management.FakeTransport
  alias YellowDog.Management.Snapshots
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.Error

  @request_id "55555555-5555-4555-8555-555555555555"
  @idempotency_key "66666666-6666-4666-8666-666666666666"
  @revision_a String.duplicate("a", 64)
  @revision_b String.duplicate("b", 64)
  @observed_at ~U[2026-07-16 09:30:00Z]

  setup do
    previous_env =
      Map.new(
        [
          :data_dir,
          :transport_module,
          :request_timeout,
          :event_write_timeout_ms,
          :max_command_records,
          :max_snapshot_records,
          :atomic_json_file_ops,
          :management_test_file_ops_hook,
          :management_test_file_ops_block
        ],
        fn key ->
          {key, Application.fetch_env(:yellow_dog_management_core, key)}
        end
      )

    data_dir =
      Path.join(System.tmp_dir!(), "yellow-dog-snapshots-#{System.unique_integer([:positive])}")

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.put_env(:yellow_dog_management_core, :transport_module, FakeTransport)
    Application.put_env(:yellow_dog_management_core, :request_timeout, 250)
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 100)
    Application.put_env(:yellow_dog_management_core, :max_command_records, 100)
    Application.put_env(:yellow_dog_management_core, :max_snapshot_records, 100)

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      YellowDog.Management.Storage.AtomicJson.FileOps
    )

    Application.delete_env(:yellow_dog_management_core, :management_test_file_ops_hook)
    restart_application()
    start_supervised!(FakeTransport)

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "missing concrete snapshots return typed not-found errors" do
    register_server("server-missing")
    register_netman("netman-missing")

    assert_error(
      ManagementCore.get_server_snapshot("server-missing", "runtime.capabilities"),
      :not_found
    )

    assert_error(
      ManagementCore.get_netman_snapshot("netman-missing", "runtime.capabilities"),
      :not_found
    )
  end

  test "offline queries do not request or store snapshots" do
    register_server("server-offline-query")

    assert_error(
      ManagementCore.query_server(
        "server-offline-query",
        "runtime.capabilities",
        "server.runtime.capabilities.get",
        %{}
      ),
      :not_connected
    )

    assert FakeTransport.recorded() == []

    assert_error(
      ManagementCore.get_server_snapshot("server-offline-query", "runtime.capabilities"),
      :not_found
    )
  end

  test "validated query results are persisted by concrete target and domain", %{
    data_dir: data_dir
  } do
    register_server("server-snapshot")
    register_netman("netman-snapshot")
    :ok = FakeTransport.connect(:server, "server-snapshot")
    :ok = FakeTransport.connect(:netman, "netman-snapshot")

    server_result = service_list(@revision_a, @observed_at, "dns")
    netman_result = %{"capabilities" => ["network.links"]}
    :ok = FakeTransport.script([{:ok, server_result}, {:ok, netman_result}])

    assert {:ok, ^server_result} =
             ManagementCore.query_server(
               "server-snapshot",
               "runtime.services",
               "server.runtime.services.list",
               %{}
             )

    assert {:ok, ^netman_result} =
             ManagementCore.query_netman(
               "netman-snapshot",
               "runtime.capabilities",
               "netman.runtime.capabilities.get",
               %{}
             )

    assert {:ok,
            %{
              target_type: :server,
              target_id: "server-snapshot",
              domain: "runtime.services",
              revision: @revision_a,
              value: ^server_result,
              observed_at: @observed_at
            }} = ManagementCore.get_server_snapshot("server-snapshot", "runtime.services")

    assert {:ok,
            %{target_type: :netman, target_id: "netman-snapshot", value: ^netman_result} =
              snapshot} =
             ManagementCore.get_netman_snapshot("netman-snapshot", "runtime.capabilities")

    assert {:ok, derived_revision} = Digest.calculate(netman_result)
    assert snapshot.revision == derived_revision
    assert %DateTime{} = snapshot.requested_at
    assert %DateTime{} = snapshot.received_at
    assert %DateTime{} = snapshot.stored_at

    assert File.exists?(
             Path.join([
               data_dir,
               "management",
               "snapshots",
               "servers",
               "server-snapshot",
               "runtime.services.json"
             ])
           )
  end

  test "reverse response arrival cannot replace a newer observation" do
    register_server("server-order")
    :ok = FakeTransport.connect(:server, "server-order")
    :ok = FakeTransport.script([{:defer, self(), :older}, {:defer, self(), :newer}])

    older =
      Task.async(fn ->
        ManagementCore.query_server(
          "server-order",
          "runtime.services",
          "server.runtime.services.list",
          %{}
        )
      end)

    assert_receive {:fake_transport_deferred, :older, _older_envelope}

    newer =
      Task.async(fn ->
        ManagementCore.query_server(
          "server-order",
          "runtime.services",
          "server.runtime.services.list",
          %{}
        )
      end)

    assert_receive {:fake_transport_deferred, :newer, _newer_envelope}

    newer_result = service_list(@revision_b, ~U[2026-07-16 09:31:00Z], "mdns")
    older_result = service_list(@revision_a, ~U[2026-07-16 09:30:00Z], "dns")
    :ok = FakeTransport.reply(:newer, {:ok, newer_result})
    assert Task.await(newer) == {:ok, newer_result}
    :ok = FakeTransport.reply(:older, {:ok, older_result})
    assert Task.await(older) == {:ok, older_result}

    assert {:ok, %{revision: @revision_b, value: ^newer_result}} =
             ManagementCore.get_server_snapshot("server-order", "runtime.services")
  end

  test "equal snapshot order is idempotent only for the same revision" do
    register_server("server-equal")
    envelope = query_envelope("server-equal")
    first = service_list(@revision_a, @observed_at, "dns")
    conflicting = service_list(@revision_b, @observed_at, "dns")
    received_at = ~U[2026-07-16 09:32:00Z]

    assert {:ok, first_snapshot} =
             Snapshots.put(envelope, "runtime.services", first, received_at)

    assert {:ok, ^first_snapshot} =
             Snapshots.put(envelope, "runtime.services", first, received_at)

    assert_error(
      Snapshots.put(envelope, "runtime.services", conflicting, received_at),
      :conflict
    )

    assert {:ok, ^first_snapshot} =
             ManagementCore.get_server_snapshot("server-equal", "runtime.services")
  end

  test "snapshot capacity permits replacement but rejects a new durable key" do
    Application.put_env(:yellow_dog_management_core, :max_snapshot_records, 1)
    restart_application()

    envelope = query_envelope("server-snapshot-capacity")
    first = service_list(@revision_a, @observed_at, "dns")
    replacement = service_list(@revision_b, ~U[2026-07-16 09:31:00Z], "mdns")
    received_at = ~U[2026-07-16 09:32:00Z]

    assert {:ok, %{revision: @revision_a}} =
             Snapshots.put(envelope, "runtime.services", first, received_at)

    assert {:ok, %{revision: @revision_b, value: ^replacement}} =
             Snapshots.put(envelope, "runtime.services", replacement, received_at)

    other = %{
      envelope
      | request_id: "77777777-7777-4777-8777-777777777777",
        target_id: "server-snapshot-capacity-other"
    }

    assert {:error, %Error{code: :conflict, details: %{"limit" => 1, "resource" => "snapshots"}}} =
             Snapshots.put(other, "runtime.services", first, received_at)

    restart_child(Snapshots)

    assert {:ok, %{revision: @revision_b, value: ^replacement}} =
             Snapshots.get(:server, "server-snapshot-capacity", "runtime.services")
  end

  test "snapshot recovery rejects nonsensical management timestamp ordering", %{
    data_dir: data_dir
  } do
    envelope = query_envelope("server-snapshot-timestamps")
    result = service_list(@revision_a, @observed_at, "dns")
    received_at = ~U[2026-07-16 09:32:00Z]

    assert {:ok, _snapshot} = Snapshots.put(envelope, "runtime.services", result, received_at)

    data_dir
    |> snapshot_path(:server, "server-snapshot-timestamps", "runtime.services")
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("received_at", "2036-01-01T00:00:00Z")
    |> then(
      &File.write!(
        snapshot_path(data_dir, :server, "server-snapshot-timestamps", "runtime.services"),
        Jason.encode!(&1)
      )
    )

    restart_child(Snapshots)

    assert_error(
      Snapshots.get(:server, "server-snapshot-timestamps", "runtime.services"),
      :not_found
    )
  end

  test "snapshot normalizes received time against a future requested time across restart" do
    future = ~U[2036-01-01 00:00:00Z]
    envelope = %{query_envelope("server-snapshot-future-request") | sent_at: future}
    result = service_list(@revision_a, @observed_at, "dns")

    assert {:ok, %{requested_at: ^future, received_at: ^future, stored_at: stored_at} = snapshot} =
             Snapshots.put(
               envelope,
               "runtime.services",
               result,
               ~U[2026-07-16 09:32:00Z]
             )

    assert DateTime.compare(stored_at, future) in [:eq, :gt]
    restart_child(Snapshots)

    assert {:ok, ^snapshot} =
             Snapshots.get(:server, "server-snapshot-future-request", "runtime.services")
  end

  test "snapshot startup fails deterministically when durable records exceed the limit" do
    Application.put_env(:yellow_dog_management_core, :max_snapshot_records, 2)
    restart_application()

    first = query_envelope("server-snapshot-over-capacity-a")

    second = %{
      first
      | request_id: "88888888-8888-4888-8888-888888888888",
        target_id: "server-snapshot-over-capacity-b"
    }

    result = service_list(@revision_a, @observed_at, "dns")
    received_at = ~U[2026-07-16 09:32:00Z]
    assert {:ok, _snapshot} = Snapshots.put(first, "runtime.services", result, received_at)
    assert {:ok, _snapshot} = Snapshots.put(second, "runtime.services", result, received_at)

    :ok = Application.stop(:yellow_dog_management_core)
    Application.put_env(:yellow_dog_management_core, :max_snapshot_records, 1)
    assert {:error, _reason} = Application.ensure_all_started(:yellow_dog_management_core)

    Application.put_env(:yellow_dog_management_core, :max_snapshot_records, 2)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
  end

  test "snapshot replacement timeout preserves the last durable snapshot and cleans staging", %{
    data_dir: data_dir
  } do
    owner = self()
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 100)
    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops, ControlledFileOps)
    Application.put_env(:yellow_dog_management_core, :management_test_file_ops_block, false)

    Application.put_env(:yellow_dog_management_core, :management_test_file_ops_hook, fn
      :rename, _arguments ->
        if Application.get_env(:yellow_dog_management_core, :management_test_file_ops_block) do
          send(owner, {:controlled_file_ops_blocked, :snapshot_rename})

          receive do
            {:release_controlled_file_ops, :snapshot_rename} -> :ok
          end
        else
          :ok
        end

      _operation, _arguments ->
        :ok
    end)

    restart_application()

    envelope = query_envelope("server-snapshot-blocked-replace")
    first = service_list(@revision_a, @observed_at, "dns")
    replacement = service_list(@revision_b, ~U[2026-07-16 09:31:00Z], "mdns")
    received_at = ~U[2026-07-16 09:32:00Z]

    assert {:ok, %{revision: @revision_a, value: ^first}} =
             Snapshots.put(envelope, "runtime.services", first, received_at)

    Application.put_env(:yellow_dog_management_core, :management_test_file_ops_block, true)

    task =
      Task.async(fn -> Snapshots.put(envelope, "runtime.services", replacement, received_at) end)

    assert_receive {:controlled_file_ops_blocked, :snapshot_rename}
    assert_error(Task.await(task, 1_000), :timeout)

    assert {:ok, %{revision: @revision_a, value: ^first}} =
             Snapshots.get(:server, "server-snapshot-blocked-replace", "runtime.services")

    assert snapshot_stage_files(data_dir) == []
    restart_child(Snapshots)

    assert {:ok, %{revision: @revision_a, value: ^first}} =
             Snapshots.get(:server, "server-snapshot-blocked-replace", "runtime.services")
  end

  test "reconciled snapshot survives staging cleanup timeout without in-memory divergence", %{
    data_dir: data_dir
  } do
    owner = self()
    cleanup_attempts = :atomics.new(1, [])
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 100)
    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops, ControlledFileOps)

    Application.put_env(:yellow_dog_management_core, :management_test_file_ops_hook, fn
      :rename, [source, target] ->
        if String.contains?(target, "/snapshots/") do
          :ok = YellowDog.Management.Storage.AtomicJson.FileOps.rename(source, target)
          send(owner, {:controlled_file_ops_blocked, :snapshot_rename_after_commit})

          receive do
            {:release_controlled_file_ops, :snapshot_rename_after_commit} -> :ok
          end

          {:handled, :ok}
        else
          :ok
        end

      :rm, [path] ->
        if String.contains?(path, "/snapshots/") and String.ends_with?(path, ".stage") and
             :atomics.add_get(cleanup_attempts, 1, 1) == 1 do
          send(owner, {:controlled_file_ops_blocked, :snapshot_cleanup})

          receive do
            {:release_controlled_file_ops, :snapshot_cleanup} -> :ok
          end
        else
          :ok
        end

      _operation, _arguments ->
        :ok
    end)

    restart_application()

    envelope = query_envelope("server-snapshot-blocked-cleanup")
    result = service_list(@revision_a, @observed_at, "dns")
    received_at = ~U[2026-07-16 09:32:00Z]
    task = Task.async(fn -> Snapshots.put(envelope, "runtime.services", result, received_at) end)

    assert_receive {:controlled_file_ops_blocked, :snapshot_rename_after_commit}
    assert_receive {:controlled_file_ops_blocked, :snapshot_cleanup}, 1_000
    assert {:ok, %{revision: @revision_a, value: ^result}} = Task.await(task, 1_000)

    assert {:ok, %{revision: @revision_a, value: ^result}} =
             Snapshots.get(:server, "server-snapshot-blocked-cleanup", "runtime.services")

    assert snapshot_stage_files(data_dir) == []
    restart_child(Snapshots)

    assert {:ok, %{revision: @revision_a, value: ^result}} =
             Snapshots.get(:server, "server-snapshot-blocked-cleanup", "runtime.services")

    assert snapshot_stage_files(data_dir) == []
    refute_receive {:controlled_file_ops_blocked, :snapshot_cleanup}, 50
  end

  test "startup surfaces captured snapshot staging cleanup failure", %{data_dir: data_dir} do
    stage_path =
      Path.join([
        data_dir,
        "management",
        "snapshots",
        "servers",
        "server-staging-cleanup",
        ".runtime.services.json.stale.stage"
      ])

    assert :ok = File.mkdir_p(Path.dirname(stage_path))
    assert :ok = File.write(stage_path, "stale")

    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops, ControlledFileOps)

    Application.put_env(:yellow_dog_management_core, :management_test_file_ops_hook, fn
      :rm, _arguments -> {:error, :injected_cleanup_failure}
      _operation, _arguments -> :ok
    end)

    :ok = Application.stop(:yellow_dog_management_core)
    assert {:error, _reason} = Application.ensure_all_started(:yellow_dog_management_core)
    assert File.exists?(stage_path)

    Application.delete_env(:yellow_dog_management_core, :management_test_file_ops_hook)

    Application.put_env(
      :yellow_dog_management_core,
      :atomic_json_file_ops,
      YellowDog.Management.Storage.AtomicJson.FileOps
    )

    assert :ok = File.rm(stage_path)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
  end

  test "snapshot reads survive process restart" do
    register_netman("netman-restart")
    :ok = FakeTransport.connect(:netman, "netman-restart")
    result = %{"capabilities" => ["resolved.cache"]}
    :ok = FakeTransport.script([{:ok, result}])

    assert {:ok, ^result} =
             ManagementCore.query_netman(
               "netman-restart",
               "runtime.capabilities",
               "netman.runtime.capabilities.get",
               %{}
             )

    assert {:ok, before_restart} =
             ManagementCore.get_netman_snapshot("netman-restart", "runtime.capabilities")

    restart_child(Snapshots)

    assert {:ok, ^before_restart} =
             ManagementCore.get_netman_snapshot("netman-restart", "runtime.capabilities")
  end

  test "malformed query success is invalid and creates no snapshot" do
    register_server("server-invalid-result")
    :ok = FakeTransport.connect(:server, "server-invalid-result")
    :ok = FakeTransport.script([{:ok, %{"capabilities" => "not-a-list"}}])

    assert_error(
      ManagementCore.query_server(
        "server-invalid-result",
        "runtime.capabilities",
        "server.runtime.capabilities.get",
        %{}
      ),
      :invalid
    )

    assert_error(
      ManagementCore.get_server_snapshot("server-invalid-result", "runtime.capabilities"),
      :not_found
    )
  end

  defp query_envelope(target_id) do
    payload = %{}
    {:ok, payload_digest} = Digest.calculate(payload)

    %Envelope{
      protocol_version: 1,
      request_id: @request_id,
      target_type: :server,
      target_id: target_id,
      operation: "server.runtime.services.list",
      idempotency_key: @idempotency_key,
      payload: payload,
      payload_digest: payload_digest,
      expected_revision: nil,
      config_version: nil,
      sent_at: @observed_at
    }
  end

  defp service_list(revision, observed_at, service) do
    %{
      "items" => [%{"service" => service, "state" => "running"}],
      "revision" => revision,
      "observed_at" => DateTime.to_iso8601(observed_at)
    }
  end

  defp snapshot_path(data_dir, :server, target_id, domain) do
    Path.join([data_dir, "management", "snapshots", "servers", target_id, "#{domain}.json"])
  end

  defp snapshot_stage_files(data_dir) do
    Path.wildcard(Path.join([data_dir, "management", "snapshots", "**", ".*.stage"]))
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

  defp restart_child(child) do
    assert :ok = Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, child)
    assert {:ok, _pid} = Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, child)
  end

  defp restart_application do
    :ok = Application.stop(:yellow_dog_management_core)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
