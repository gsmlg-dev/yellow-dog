defmodule YellowDog.Management.CommandsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.Commands
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
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(System.tmp_dir!(), "yellow-dog-commands-#{System.unique_integer([:positive])}")

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.put_env(:yellow_dog_management_core, :transport_module, FakeTransport)
    Application.put_env(:yellow_dog_management_core, :request_timeout, 75)
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
