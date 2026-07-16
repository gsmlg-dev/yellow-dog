defmodule YellowDog.Management.SnapshotsTest do
  use ExUnit.Case, async: false

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
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(System.tmp_dir!(), "yellow-dog-snapshots-#{System.unique_integer([:positive])}")

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.put_env(:yellow_dog_management_core, :transport_module, FakeTransport)
    Application.put_env(:yellow_dog_management_core, :request_timeout, 250)
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
