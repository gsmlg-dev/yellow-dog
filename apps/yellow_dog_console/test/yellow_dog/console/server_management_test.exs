defmodule YellowDog.Console.ServerManagementTest do
  use ExUnit.Case, async: false

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.ServerManagement
  alias YellowDog.Console.TestManagementTransport
  alias YellowDog.Management.ConfigVersion
  alias YellowDog.Management.Snapshots
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.ServerOperation

  setup do
    previous =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-console-server-management-#{System.unique_integer([:positive])}"
      )

    Application.stop(:yellow_dog_management_core)
    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)

    Application.put_env(
      :yellow_dog_management_core,
      :transport_module,
      TestManagementTransport
    )

    Application.put_env(:yellow_dog_management_core, :request_timeout, 50)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
    start_supervised!(TestManagementTransport)

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)

    %{data_dir: data_dir}
  end

  test "exports one named gateway for every approved Server operation" do
    specs = ServerManagement.__operations__()

    assert MapSet.new(Enum.map(specs, & &1.operation)) ==
             MapSet.new(Map.keys(ServerOperation.all()))

    assert length(specs) == map_size(ServerOperation.all())
    assert length(Enum.uniq_by(specs, & &1.function)) == map_size(ServerOperation.all())

    for %{function: function, kind: kind} <- specs do
      assert function_exported?(ServerManagement, function, minimum_arity(kind))
    end
  end

  test "online queries use the selected Server and offline queries return its cached snapshot" do
    server_id = unique_id("server-query")
    register_server(server_id)
    :ok = TestManagementTransport.connect(:server, server_id)
    :ok = TestManagementTransport.script_request([{:ok, %{"capabilities" => ["dns"]}}])

    assert %ManagementResult{
             status: :ok,
             source: :runtime,
             value: %{"capabilities" => ["dns"]},
             observed_at: nil
           } = ServerManagement.runtime_capabilities_get(server_id)

    assert [{:request, %Envelope{} = envelope, 50}] = TestManagementTransport.recorded()
    assert envelope.target_type == :server
    assert envelope.target_id == server_id
    assert envelope.operation == "server.runtime.capabilities.get"
    assert envelope.payload == %{}
    assert is_binary(envelope.idempotency_key)

    :ok = TestManagementTransport.disconnect(:server, server_id)

    assert %ManagementResult{
             status: :ok,
             source: :cache,
             value: %{"capabilities" => ["dns"]},
             observed_at: %DateTime{},
             snapshot: %{operation: "server.runtime.capabilities.get"}
           } = ServerManagement.runtime_capabilities_get(server_id)
  end

  test "parameterized queries retain distinct payload caches across snapshot restart", %{
    data_dir: data_dir
  } do
    server_id = unique_id("server-parameterized-cache")
    register_server(server_id)
    :ok = TestManagementTransport.connect(:server, server_id)

    public_payload = %{"view_name" => "public"}
    private_payload = %{"view_name" => "private"}
    public_result = zone_list("public", String.duplicate("a", 64))
    private_result = zone_list("private", String.duplicate("b", 64))

    :ok = TestManagementTransport.script_request([{:ok, public_result}, {:ok, private_result}])

    assert %ManagementResult{status: :ok, source: :runtime, value: ^public_result} =
             ServerManagement.dns_zones_list(server_id, public_payload)

    assert %ManagementResult{status: :ok, source: :runtime, value: ^private_result} =
             ServerManagement.dns_zones_list(server_id, private_payload)

    expected_domains =
      MapSet.new([
        expected_snapshot_domain("server.dns.zones.list", public_payload),
        expected_snapshot_domain("server.dns.zones.list", private_payload)
      ])

    assert snapshot_domains(data_dir, :server, server_id) == expected_domains

    for domain <- expected_domains do
      assert {:ok, _path} =
               StoragePath.server_snapshot(
                 Path.join(data_dir, "management"),
                 server_id,
                 domain
               )
    end

    :ok = TestManagementTransport.disconnect(:server, server_id)
    restart_snapshots()

    assert %ManagementResult{status: :ok, source: :cache, value: ^public_result} =
             ServerManagement.dns_zones_list(server_id, public_payload)

    assert %ManagementResult{status: :ok, source: :cache, value: ^private_result} =
             ServerManagement.dns_zones_list(server_id, private_payload)
  end

  test "commands supply CAS and idempotency fields and are rejected while offline" do
    server_id = unique_id("server-command")
    register_server(server_id)
    :ok = TestManagementTransport.connect(:server, server_id)

    :ok =
      TestManagementTransport.script_request([{:ok, %{"service" => "dns", "state" => "running"}}])

    revision = String.duplicate("a", 64)
    start_key = "47b8f6f4-9293-4a20-9327-1a15d87fe427"

    assert %ManagementResult{
             status: :ok,
             source: :runtime,
             value: %{"service" => "dns", "state" => "running"}
           } =
             ServerManagement.runtime_services_start(
               server_id,
               %{"service" => "dns"},
               expected_revision: revision,
               idempotency_key: start_key
             )

    assert [{:request, %Envelope{} = envelope, 50}] = TestManagementTransport.recorded()
    assert envelope.target_type == :server
    assert envelope.target_id == server_id
    assert envelope.operation == "server.runtime.services.start"
    assert envelope.expected_revision == revision
    assert envelope.idempotency_key == start_key

    :ok = TestManagementTransport.disconnect(:server, server_id)

    assert %ManagementResult{status: :error, code: :not_connected} =
             ServerManagement.runtime_services_stop(
               server_id,
               %{"service" => "dns"},
               idempotency_key: "2a190220-45d1-4ac6-aa73-d8cc132c4a34"
             )

    assert [_online_request] = TestManagementTransport.recorded()
  end

  test "aggregate Server config draft, publication, and history stay behind named gateways" do
    server_id = unique_id("server-config")
    register_server(server_id)
    :ok = TestManagementTransport.connect(:server, server_id)
    :ok = TestManagementTransport.script_config([:ok])

    document = %{
      "schema_version" => 1,
      "profile" => "dns_only",
      "entries" => [
        %{
          "setting" => "dns.listen",
          "value" => %{"type" => "string", "value" => "192.0.2.53"}
        }
      ]
    }

    assert %ManagementResult{
             status: :ok,
             source: :desired,
             value: %{draft_revision: 0, document: nil}
           } = ServerManagement.get_config_draft(server_id)

    assert %ManagementResult{
             status: :ok,
             source: :desired,
             value: %{draft_revision: 1, document: ^document}
           } = ServerManagement.put_config_draft(server_id, 0, document)

    assert %ManagementResult{
             status: :ok,
             source: :desired,
             value: %ConfigVersion{target_type: :server, target_id: ^server_id}
           } = ServerManagement.publish_config_draft(server_id, 1)

    assert [{:config, %Envelope{} = envelope}] = TestManagementTransport.recorded()
    assert envelope.target_type == :server
    assert envelope.target_id == server_id
    assert envelope.operation == "server.config.replace"
    assert envelope.payload == document

    assert %ManagementResult{
             status: :ok,
             source: :desired,
             value: [%{target_id: ^server_id, version: 1, state: :desired}]
           } = ServerManagement.config_versions(server_id)
  end

  defp register_server(server_id) do
    assert {:ok, _server} = ManagementCore.register_server(%{id: server_id, status: :online})
  end

  defp zone_list(view_name, revision) do
    %{
      "items" => [
        %{
          "view_name" => view_name,
          "zone_name" => "#{view_name}.example",
          "zone_type" => "authoritative",
          "provider_id" => nil
        }
      ],
      "revision" => revision,
      "observed_at" => "2026-08-11T00:00:00Z"
    }
  end

  defp expected_snapshot_domain(operation, payload) do
    assert {:ok, digest} = Digest.calculate(payload)
    {first, second} = String.split_at(digest, 32)
    Enum.join([String.replace(operation, "_", "-"), first, second], ".")
  end

  defp snapshot_domains(data_dir, :server, server_id) do
    data_dir
    |> Path.join("management/snapshots/servers/#{server_id}/*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> MapSet.new()
  end

  defp restart_snapshots do
    assert :ok =
             Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, Snapshots)

    assert {:ok, _pid} =
             Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, Snapshots)
  end

  defp minimum_arity(:query), do: 1
  defp minimum_arity(kind) when kind in [:command, :config], do: 2

  defp unique_id(prefix),
    do: "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
