defmodule YellowDog.Management.CommandsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.Commands
  alias YellowDog.Management.ControlledFileOps
  alias YellowDog.Management.FakeTransport
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message.Journal

  @key_a "11111111-1111-4111-8111-111111111111"
  @key_b "22222222-2222-4222-8222-222222222222"
  @key_c "33333333-3333-4333-8333-333333333333"
  @key_d "55555555-5555-4555-8555-555555555555"
  @revision_a String.duplicate("a", 64)
  @revision_b String.duplicate("b", 64)

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
      Path.join(System.tmp_dir!(), "yellow-dog-commands-#{System.unique_integer([:positive])}")

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.put_env(:yellow_dog_management_core, :transport_module, FakeTransport)
    Application.put_env(:yellow_dog_management_core, :request_timeout, 75)
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

  test "offline commands create no durable or in-memory queue", %{data_dir: data_dir} do
    register_server("server-offline")

    assert_error(
      ManagementCore.command_server(
        "server-offline",
        "server.runtime.services.start",
        %{"service" => "dns"},
        nil,
        @key_a
      ),
      :not_connected
    )

    assert FakeTransport.recorded() == []
    assert command_files(data_dir) == []
    assert Commands.unresolved_ids(:server, "server-offline") == {:ok, []}
  end

  test "commands are durable before delivery and correlate deferred replies in reverse order", %{
    data_dir: data_dir
  } do
    register_server("server-deferred")
    :ok = FakeTransport.connect(:server, "server-deferred")
    :ok = FakeTransport.script([{:defer, self(), :first}, {:defer, self(), :second}])

    first =
      Task.async(fn ->
        ManagementCore.command_server(
          "server-deferred",
          "server.runtime.services.start",
          %{"service" => "dns"},
          nil,
          @key_a
        )
      end)

    assert_receive {:fake_transport_deferred, :first, first_envelope}
    assert pending_document(data_dir, first_envelope.request_id)["state"] == "pending"

    second =
      Task.async(fn ->
        ManagementCore.command_server(
          "server-deferred",
          "server.runtime.services.stop",
          %{"service" => "mdns"},
          nil,
          @key_b
        )
      end)

    assert_receive {:fake_transport_deferred, :second, second_envelope}
    assert pending_document(data_dir, second_envelope.request_id)["state"] == "pending"
    refute first_envelope.request_id == second_envelope.request_id

    :ok = FakeTransport.reply(:second, {:ok, service_result("mdns", "stopped")})
    :ok = FakeTransport.reply(:first, {:ok, service_result("dns", "running")})

    assert Task.await(second) == {:ok, service_result("mdns", "stopped")}
    assert Task.await(first) == {:ok, service_result("dns", "running")}

    assert completed_document(data_dir, first_envelope.request_id)["result"] ==
             service_result("dns", "running")

    assert completed_document(data_dir, second_envelope.request_id)["result"] ==
             service_result("mdns", "stopped")
  end

  test "terminal idempotency replay skips transport and changed fingerprints conflict" do
    register_server("server-replay")
    register_server("server-other")
    :ok = FakeTransport.connect(:server, "server-replay")
    :ok = FakeTransport.connect(:server, "server-other")
    :ok = FakeTransport.script([{:ok, service_result("dns", "running")}])

    args = [
      "server-replay",
      "server.runtime.services.start",
      %{"service" => "dns"},
      @revision_a,
      @key_a
    ]

    assert apply(ManagementCore, :command_server, args) ==
             {:ok, service_result("dns", "running")}

    assert apply(ManagementCore, :command_server, args) ==
             {:ok, service_result("dns", "running")}

    assert length(FakeTransport.recorded()) == 1

    assert_error(
      ManagementCore.command_server(
        "server-replay",
        "server.runtime.services.start",
        %{"service" => "mdns"},
        @revision_a,
        @key_a
      ),
      :conflict
    )

    assert_error(
      ManagementCore.command_server(
        "server-replay",
        "server.runtime.services.start",
        %{"service" => "dns"},
        @revision_b,
        @key_a
      ),
      :conflict
    )

    assert_error(
      ManagementCore.command_server(
        "server-other",
        "server.runtime.services.start",
        %{"service" => "dns"},
        @revision_a,
        @key_a
      ),
      :conflict
    )
  end

  test "terminal idempotency replay survives a Commands restart without delivery" do
    register_server("server-replay-restart")
    :ok = FakeTransport.connect(:server, "server-replay-restart")
    result = service_result("dns", "running")
    :ok = FakeTransport.script([{:ok, result}])

    args = [
      "server-replay-restart",
      "server.runtime.services.start",
      %{"service" => "dns"},
      nil,
      @key_d
    ]

    assert apply(ManagementCore, :command_server, args) == {:ok, result}
    assert length(FakeTransport.recorded()) == 1

    restart_child(Commands)

    assert apply(ManagementCore, :command_server, args) == {:ok, result}
    assert length(FakeTransport.recorded()) == 1
  end

  test "concurrent calls with one idempotency key reserve and deliver once" do
    register_server("server-concurrent")
    :ok = FakeTransport.connect(:server, "server-concurrent")
    :ok = FakeTransport.script([{:defer, self(), :barrier}])

    args = [
      "server-concurrent",
      "server.runtime.services.start",
      %{"service" => "dns"},
      nil,
      @key_d
    ]

    first = Task.async(fn -> apply(ManagementCore, :command_server, args) end)
    assert_receive {:fake_transport_deferred, :barrier, envelope}

    second = Task.async(fn -> apply(ManagementCore, :command_server, args) end)
    assert_error(Task.await(second), :conflict)
    assert length(FakeTransport.recorded()) == 1

    result = service_result("dns", "running")
    :ok = FakeTransport.reply(:barrier, {:ok, result})
    assert Task.await(first) == {:ok, result}
    assert {:replay, {:ok, ^result}} = Commands.replay(envelope)
    assert length(FakeTransport.recorded()) == 1
  end

  test "recovery rejects tampered durable errors and never replays them", %{data_dir: data_dir} do
    register_server("server-tampered-error")
    :ok = FakeTransport.connect(:server, "server-tampered-error")
    :ok = FakeTransport.script([{:defer, self(), :tampered}])

    assert_error(
      ManagementCore.command_server(
        "server-tampered-error",
        "server.runtime.services.start",
        %{"service" => "dns"},
        nil,
        @key_d
      ),
      :timeout
    )

    assert_receive {:fake_transport_deferred, :tampered, envelope}
    document = unknown_document(data_dir, envelope.request_id)
    details = document["error"]["details"]

    invalid_details = [
      %{"path" => "/etc/shadow"},
      Map.put(details, "request_id", "ffffffff-ffff-4fff-8fff-ffffffffffff"),
      Map.put(details, "reason", "not-a-durable-unknown-reason"),
      Map.put(details, "outcome", "completed")
    ]

    for replacement <- invalid_details do
      document
      |> put_in(["error", "details"], replacement)
      |> then(&File.write!(command_path(data_dir, envelope.request_id), Jason.encode!(&1)))

      restart_child(Commands)
      assert :miss = Commands.replay(envelope)
    end

    document
    |> Map.put("state", "failed")
    |> Map.put("unknown_reason", nil)
    |> then(&File.write!(command_path(data_dir, envelope.request_id), Jason.encode!(&1)))

    restart_child(Commands)
    assert :miss = Commands.replay(envelope)
  end

  test "recovery keeps a future durable timestamp monotonic across restarts", %{
    data_dir: data_dir
  } do
    Application.put_env(:yellow_dog_management_core, :request_timeout, 5_000)
    register_server("server-future-clock")
    :ok = FakeTransport.connect(:server, "server-future-clock")
    :ok = FakeTransport.script([{:defer, self(), :future_clock}])

    task =
      Task.async(fn ->
        ManagementCore.command_server(
          "server-future-clock",
          "server.runtime.services.start",
          %{"service" => "dns"},
          nil,
          @key_d
        )
      end)

    assert_receive {:fake_transport_deferred, :future_clock, envelope}
    future = "2036-01-01T00:00:00Z"

    data_dir
    |> command_path(envelope.request_id)
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("inserted_at", future)
    |> Map.put("updated_at", future)
    |> then(&File.write!(command_path(data_dir, envelope.request_id), Jason.encode!(&1)))

    restart_child(Commands)
    assert unknown_document(data_dir, envelope.request_id)["updated_at"] == future

    restart_child(Commands)

    assert {:replay, {:error, %Error{details: %{"request_id" => request_id}}}} =
             Commands.replay(envelope)

    assert request_id == envelope.request_id
    assert length(FakeTransport.recorded()) == 1
    Task.shutdown(task, :brutal_kill)
  end

  test "command capacity rejects only new idempotency keys and survives restart" do
    Application.put_env(:yellow_dog_management_core, :max_command_records, 1)
    restart_application()
    register_server("server-command-capacity")
    :ok = FakeTransport.connect(:server, "server-command-capacity")
    result = service_result("dns", "running")
    :ok = FakeTransport.script([{:ok, result}])

    args = [
      "server-command-capacity",
      "server.runtime.services.start",
      %{"service" => "dns"},
      nil,
      @key_a
    ]

    assert apply(ManagementCore, :command_server, args) == {:ok, result}
    assert apply(ManagementCore, :command_server, args) == {:ok, result}

    assert {:error, %Error{code: :conflict, details: %{"limit" => 1, "resource" => "commands"}}} =
             ManagementCore.command_server(
               "server-command-capacity",
               "server.runtime.services.stop",
               %{"service" => "dns"},
               nil,
               @key_b
             )

    assert length(FakeTransport.recorded()) == 1
    restart_child(Commands)
    assert apply(ManagementCore, :command_server, args) == {:ok, result}
    assert length(FakeTransport.recorded()) == 1
  end

  test "command startup fails deterministically when durable records exceed the limit" do
    Application.put_env(:yellow_dog_management_core, :max_command_records, 2)
    restart_application()
    register_server("server-command-over-capacity")
    :ok = FakeTransport.connect(:server, "server-command-over-capacity")

    :ok =
      FakeTransport.script([
        {:ok, service_result("dns", "running")},
        {:ok, service_result("mdns", "stopped")}
      ])

    assert {:ok, _result} =
             ManagementCore.command_server(
               "server-command-over-capacity",
               "server.runtime.services.start",
               %{"service" => "dns"},
               nil,
               @key_a
             )

    assert {:ok, _result} =
             ManagementCore.command_server(
               "server-command-over-capacity",
               "server.runtime.services.stop",
               %{"service" => "mdns"},
               nil,
               @key_b
             )

    :ok = Application.stop(:yellow_dog_management_core)
    Application.put_env(:yellow_dog_management_core, :max_command_records, 1)
    assert {:error, _reason} = Application.ensure_all_started(:yellow_dog_management_core)

    Application.put_env(:yellow_dog_management_core, :max_command_records, 2)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
  end

  test "duplicate durable idempotency keys fail recovery instead of leaving an unindexed record",
       %{
         data_dir: data_dir
       } do
    register_server("server-duplicate-durable-key")
    :ok = FakeTransport.connect(:server, "server-duplicate-durable-key")
    :ok = FakeTransport.script([{:ok, service_result("dns", "running")}])

    assert {:ok, _result} =
             ManagementCore.command_server(
               "server-duplicate-durable-key",
               "server.runtime.services.start",
               %{"service" => "dns"},
               nil,
               @key_a
             )

    [path] = command_files(data_dir)
    duplicate_id = "99999999-9999-4999-8999-999999999999"

    path
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("request_id", duplicate_id)
    |> put_in(["envelope", "request_id"], duplicate_id)
    |> then(&File.write!(command_path(data_dir, duplicate_id), Jason.encode!(&1)))

    assert :ok = Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, Commands)

    assert {:error, {:command_recovery_failed, :conflict}} =
             Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, Commands)

    assert :ok = File.rm(command_path(data_dir, duplicate_id))
    assert {:ok, _pid} = Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, Commands)
  end

  test "command persistence timeout drains a blocked create without durable residue", %{
    data_dir: data_dir
  } do
    owner = self()
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 500)
    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops, ControlledFileOps)

    Application.put_env(:yellow_dog_management_core, :management_test_file_ops_hook, fn
      :link, [_source, target] ->
        if String.contains?(target, "/commands/") do
          send(owner, {:controlled_file_ops_blocked, :link})

          receive do
            {:release_controlled_file_ops, :link} -> :ok
          end
        else
          :ok
        end

      _operation, _arguments ->
        :ok
    end)

    restart_application()
    register_server("server-blocked-create")
    :ok = FakeTransport.connect(:server, "server-blocked-create")
    :ok = FakeTransport.script([{:ok, service_result("dns", "running")}])

    task =
      Task.async(fn ->
        ManagementCore.command_server(
          "server-blocked-create",
          "server.runtime.services.start",
          %{"service" => "dns"},
          nil,
          @key_a
        )
      end)

    assert_receive {:controlled_file_ops_blocked, :link}
    assert_error(Task.await(task, 1_000), :timeout)
    assert command_files(data_dir) == []
    assert stage_files(data_dir) == []
    assert Commands.unresolved_ids(:server, "server-blocked-create") == {:ok, []}

    restart_child(Commands)
    assert Commands.unresolved_ids(:server, "server-blocked-create") == {:ok, []}
  end

  test "command resolution timeout keeps a coherent pending record and cleans its stage", %{
    data_dir: data_dir
  } do
    owner = self()
    Application.put_env(:yellow_dog_management_core, :event_write_timeout_ms, 500)
    Application.put_env(:yellow_dog_management_core, :atomic_json_file_ops, ControlledFileOps)
    Application.put_env(:yellow_dog_management_core, :management_test_file_ops_block, true)

    Application.put_env(:yellow_dog_management_core, :management_test_file_ops_hook, fn
      :rename, [_source, target] ->
        if String.contains?(target, "/commands/") and
             Application.get_env(:yellow_dog_management_core, :management_test_file_ops_block) do
          send(owner, {:controlled_file_ops_blocked, :rename})

          receive do
            {:release_controlled_file_ops, :rename} -> :ok
          end
        else
          :ok
        end

      _operation, _arguments ->
        :ok
    end)

    restart_application()
    register_server("server-blocked-resolution")
    :ok = FakeTransport.connect(:server, "server-blocked-resolution")
    :ok = FakeTransport.script([{:ok, service_result("dns", "running")}])

    task =
      Task.async(fn ->
        ManagementCore.command_server(
          "server-blocked-resolution",
          "server.runtime.services.start",
          %{"service" => "dns"},
          nil,
          @key_b
        )
      end)

    assert_receive {:controlled_file_ops_blocked, :rename}
    Application.put_env(:yellow_dog_management_core, :management_test_file_ops_block, false)
    assert_error(Task.await(task, 1_000), :timeout)
    assert [path] = command_files(data_dir)
    assert Jason.decode!(File.read!(path))["state"] == "pending"
    assert stage_files(data_dir) == []
    assert {:ok, [_request_id]} = Commands.unresolved_ids(:server, "server-blocked-resolution")

    restart_child(Commands)

    assert unknown_document(data_dir, Path.basename(path) |> String.trim_trailing(".json"))[
             "state"
           ] ==
             "unknown"
  end

  test "malformed command successes become durable unknown outcomes without replay", %{
    data_dir: data_dir
  } do
    register_server("server-malformed-success")
    :ok = FakeTransport.connect(:server, "server-malformed-success")
    :ok = FakeTransport.script([{:ok, %{"state" => "running"}}])

    args = [
      "server-malformed-success",
      "server.runtime.services.start",
      %{"service" => "dns"},
      nil,
      @key_d
    ]

    assert {:error, %Error{code: :invalid, details: %{"request_id" => request_id}} = error} =
             apply(ManagementCore, :command_server, args)

    assert unknown_document(data_dir, request_id)["unknown_reason"] == "malformed_success"
    assert apply(ManagementCore, :command_server, args) == {:error, error}
    assert length(FakeTransport.recorded()) == 1
  end

  test "request timeout and disconnect after delivery become durable unknown outcomes", %{
    data_dir: data_dir
  } do
    register_server("server-unknown")
    :ok = FakeTransport.connect(:server, "server-unknown")
    :ok = FakeTransport.script([{:defer, self(), :timeout}])

    assert {:error, %Error{code: :timeout, details: %{"request_id" => timeout_id}} = timeout} =
             ManagementCore.command_server(
               "server-unknown",
               "server.runtime.services.start",
               %{"service" => "dns"},
               nil,
               @key_a
             )

    assert_receive {:fake_transport_deferred, :timeout, %{request_id: ^timeout_id}}
    assert unknown_document(data_dir, timeout_id)["unknown_reason"] == "transport_timeout"

    assert {:error, ^timeout} =
             ManagementCore.command_server(
               "server-unknown",
               "server.runtime.services.start",
               %{"service" => "dns"},
               nil,
               @key_a
             )

    :ok = FakeTransport.script([{:disconnect_after_delivery, {:error, not_connected_error()}}])

    assert {:error, %Error{code: :not_connected, details: %{"request_id" => disconnected_id}}} =
             ManagementCore.command_server(
               "server-unknown",
               "server.runtime.services.stop",
               %{"service" => "mdns"},
               nil,
               @key_b
             )

    assert unknown_document(data_dir, disconnected_id)["unknown_reason"] ==
             "runtime_disconnected"

    assert {:ok, %{status: :offline}} = ManagementCore.get_server("server-unknown")
  end

  test "restart converts pending to unknown and a matching reconnect journal resolves it", %{
    data_dir: data_dir
  } do
    register_server("server-restart")
    :ok = FakeTransport.connect(:server, "server-restart")
    :ok = FakeTransport.script([{:defer, self(), :restart}])

    task =
      Task.async(fn ->
        ManagementCore.command_server(
          "server-restart",
          "server.runtime.services.start",
          %{"service" => "dns"},
          nil,
          @key_c
        )
      end)

    assert_receive {:fake_transport_deferred, :restart, envelope}
    assert pending_document(data_dir, envelope.request_id)["state"] == "pending"

    restart_child(Commands)

    assert unknown_document(data_dir, envelope.request_id)["unknown_reason"] ==
             "management_restart"

    journal =
      journal(:server, "server-restart", [
        journal_completed(
          envelope.request_id,
          envelope.operation,
          service_result("dns", "running")
        )
      ])

    assert {:ok, %{pending_config: nil, unresolved_command_ids: []}} =
             ManagementCore.runtime_connected(:server, "server-restart", journal)

    assert completed_document(data_dir, envelope.request_id)["state"] == "completed"
    :ok = FakeTransport.reply(:restart, {:ok, service_result("dns", "running")})
    assert Task.await(task) == {:ok, service_result("dns", "running")}
  end

  test "reconnect rejects contradictory duplicates and ignores unknown journal IDs", %{
    data_dir: data_dir
  } do
    register_server("server-journal")
    unknown_id = "44444444-4444-4444-8444-444444444444"

    unknown_entry = %{
      "request_id" => unknown_id,
      "operation" => "server.runtime.services.start",
      "status" => "unknown",
      "result" => nil,
      "error" => nil
    }

    assert {:ok, %{pending_config: nil, unresolved_command_ids: []}} =
             ManagementCore.runtime_connected(
               :server,
               "server-journal",
               journal(:server, "server-journal", [unknown_entry, unknown_entry])
             )

    refute File.exists?(command_path(data_dir, unknown_id))

    contradictory = [
      journal_completed(
        unknown_id,
        "server.runtime.services.start",
        service_result("dns", "running")
      ),
      %{
        "request_id" => unknown_id,
        "operation" => "server.runtime.services.start",
        "status" => "failed",
        "result" => nil,
        "error" => not_connected_error()
      }
    ]

    assert_error(
      ManagementCore.runtime_connected(
        :server,
        "server-journal",
        journal(:server, "server-journal", contradictory)
      ),
      :invalid
    )

    refute File.exists?(command_path(data_dir, unknown_id))
  end

  test "runtime connection persists status and returns the latest pending config" do
    register_server("server-config")

    assert {:ok, version} =
             ManagementCore.publish_server_config("server-config", %{
               operation: "server.settings.update",
               payload: %{
                 "service" => "dns",
                 "entries" => [
                   %{
                     "key" => "listen",
                     "value" => %{"type" => "string", "value" => "192.0.2.53"}
                   }
                 ]
               },
               expected_revision: nil
             })

    assert {:ok, %{pending_config: ^version, unresolved_command_ids: []}} =
             ManagementCore.runtime_connected(
               :server,
               "server-config",
               journal(:server, "server-config", [])
             )

    assert {:ok, %{status: :online}} = ManagementCore.get_server("server-config")

    assert {:ok, %{pending_config: nil, unresolved_command_ids: []}} =
             ManagementCore.runtime_disconnected(:server, "server-config")
  end

  defp register_server(id) do
    assert {:ok, _server} = ManagementCore.register_server(%{id: id, profile: :dns_only})
  end

  defp service_result(service, state), do: %{"service" => service, "state" => state}

  defp journal(target_type, target_id, entries) do
    %Journal{target_type: target_type, target_id: target_id, entries: entries}
  end

  defp journal_completed(request_id, operation, result) do
    %{
      "request_id" => request_id,
      "operation" => operation,
      "status" => "completed",
      "result" => result,
      "error" => nil
    }
  end

  defp not_connected_error do
    Error.new(:not_connected, "runtime disconnected", %{})
  end

  defp pending_document(data_dir, request_id),
    do: document_with_state(data_dir, request_id, "pending")

  defp completed_document(data_dir, request_id),
    do: document_with_state(data_dir, request_id, "completed")

  defp unknown_document(data_dir, request_id),
    do: document_with_state(data_dir, request_id, "unknown")

  defp document_with_state(data_dir, request_id, state) do
    document = data_dir |> command_path(request_id) |> File.read!() |> Jason.decode!()
    assert document["state"] == state
    document
  end

  defp command_path(data_dir, request_id) do
    Path.join([data_dir, "management", "commands", "#{request_id}.json"])
  end

  defp command_files(data_dir) do
    Path.wildcard(Path.join([data_dir, "management", "commands", "*.json"]))
  end

  defp stage_files(data_dir) do
    Path.wildcard(Path.join([data_dir, "management", "commands", ".*.stage"]))
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
