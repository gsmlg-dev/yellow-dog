defmodule YellowDog.Console.NetmanManagementTest do
  use ExUnit.Case, async: false

  alias YellowDog.Console.ManagementResult
  alias YellowDog.Console.NetmanManagement
  alias YellowDog.Console.TestManagementTransport
  alias YellowDog.Management.ConfigVersion
  alias YellowDog.Management.Snapshots
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Envelope
  alias YellowDog.Sync.NetmanOperation

  setup do
    previous =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-console-netman-management-#{System.unique_integer([:positive])}"
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

  test "exports one named gateway for every approved Netman operation" do
    specs = NetmanManagement.__operations__()

    assert MapSet.new(Enum.map(specs, & &1.operation)) ==
             MapSet.new(Map.keys(NetmanOperation.all()))

    assert length(specs) == 32
    assert length(Enum.uniq_by(specs, & &1.function)) == 32

    for %{function: function, kind: kind} <- specs do
      assert function_exported?(NetmanManagement, function, minimum_arity(kind))
    end
  end

  test "queries and commands target only the selected Netman" do
    netman_id = unique_id("netman-selected")
    register_netman(netman_id)
    :ok = TestManagementTransport.connect(:netman, netman_id)

    :ok =
      TestManagementTransport.script_request([
        {:ok, %{"mode" => "observe_first"}},
        {:ok, %{"cleared_entries" => 4}}
      ])

    assert %ManagementResult{
             status: :ok,
             value: %{"mode" => "observe_first"},
             source: :runtime
           } = NetmanManagement.runtime_apply_mode_get(netman_id)

    assert %ManagementResult{
             status: :ok,
             value: %{"cleared_entries" => 4},
             source: :runtime
           } =
             NetmanManagement.resolved_cache_flush(
               netman_id,
               %{},
               idempotency_key: "4cbd8969-af2f-4089-8ce2-a23ebd7eaeda"
             )

    assert [
             {:request, %Envelope{} = query, 50},
             {:request, %Envelope{} = command, 50}
           ] = TestManagementTransport.recorded()

    assert query.target_type == :netman
    assert query.target_id == netman_id
    assert query.operation == "netman.runtime.apply_mode.get"

    assert command.target_type == :netman
    assert command.target_id == netman_id
    assert command.operation == "netman.resolved.cache.flush"
    assert command.idempotency_key == "4cbd8969-af2f-4089-8ce2-a23ebd7eaeda"
  end

  test "exposes typed gateways for per-link DNS and recent-query reads" do
    netman_id = unique_id("netman-resolved")
    register_netman(netman_id)
    :ok = TestManagementTransport.connect(:netman, netman_id)

    revision = String.duplicate("a", 64)
    observed_at = "2026-08-11T00:00:00Z"

    link_dns = %{
      "items" => [
        %{
          "link_id" => "eth0",
          "servers" => ["192.0.2.53"],
          "search_domains" => ["example.test"],
          "priority" => 100
        }
      ],
      "revision" => revision,
      "observed_at" => observed_at
    }

    queries = %{
      "items" => [
        %{
          "timestamp" => observed_at,
          "domain" => "example.test",
          "type" => "A",
          "source" => "cache",
          "duration_us" => 25
        }
      ],
      "revision" => revision,
      "observed_at" => observed_at
    }

    :ok = TestManagementTransport.script_request([{:ok, link_dns}, {:ok, queries}])

    assert %ManagementResult{status: :ok, value: ^link_dns, source: :runtime} =
             apply(NetmanManagement, :resolved_link_dns_list, [netman_id, %{}])

    assert %ManagementResult{status: :ok, value: ^queries, source: :runtime} =
             apply(NetmanManagement, :resolved_queries_list, [netman_id, %{"limit" => 25}])

    assert [
             {:request, %Envelope{operation: "netman.resolved.link_dns.list"}, 50},
             {:request, %Envelope{operation: "netman.resolved.queries.list"}, 50}
           ] = TestManagementTransport.recorded()
  end

  test "parameterized queries retain distinct payload caches across snapshot restart", %{
    data_dir: data_dir
  } do
    netman_id = unique_id("netman-parameterized-cache")
    register_netman(netman_id)
    :ok = TestManagementTransport.connect(:netman, netman_id)

    office_payload = %{"profile_id" => "office"}
    branch_payload = %{"profile_id" => "branch"}
    office_result = history_list(String.duplicate("a", 64))
    branch_result = history_list(String.duplicate("b", 64))

    :ok = TestManagementTransport.script_request([{:ok, office_result}, {:ok, branch_result}])

    assert %ManagementResult{status: :ok, source: :runtime, value: ^office_result} =
             NetmanManagement.profiles_history_list(netman_id, office_payload)

    assert %ManagementResult{status: :ok, source: :runtime, value: ^branch_result} =
             NetmanManagement.profiles_history_list(netman_id, branch_payload)

    expected_domains =
      MapSet.new([
        expected_snapshot_domain("netman.profiles.history.list", office_payload),
        expected_snapshot_domain("netman.profiles.history.list", branch_payload)
      ])

    assert snapshot_domains(data_dir, :netman, netman_id) == expected_domains

    for domain <- expected_domains do
      assert {:ok, _path} =
               StoragePath.netman_snapshot(
                 Path.join(data_dir, "management"),
                 netman_id,
                 domain
               )
    end

    :ok = TestManagementTransport.disconnect(:netman, netman_id)
    restart_snapshots()

    assert %ManagementResult{status: :ok, source: :cache, value: ^office_result} =
             NetmanManagement.profiles_history_list(netman_id, office_payload)

    assert %ManagementResult{status: :ok, source: :cache, value: ^branch_result} =
             NetmanManagement.profiles_history_list(netman_id, branch_payload)
  end

  test "preserves exact Resolved and DHCP mutation-owner revisions" do
    netman_id = unique_id("netman-cas-reads")
    register_netman(netman_id)
    :ok = TestManagementTransport.connect(:netman, netman_id)

    config_revision = String.duplicate("a", 64)
    cache_revision = String.duplicate("b", 64)
    lease_revision = String.duplicate("c", 64)
    collection_revision = String.duplicate("d", 64)
    observed_at = "2026-08-11T00:00:00Z"

    upstreams = %{
      "items" => [%{"address" => "192.0.2.53", "source" => "managed"}],
      "revision" => collection_revision,
      "config_revision" => config_revision,
      "observed_at" => observed_at
    }

    cache = %{
      "entries" => [],
      "revision" => cache_revision
    }

    leases = %{
      "items" => [
        %{
          "profile_id" => "office",
          "interface" => "eth0",
          "address" => "192.0.2.20",
          "expires_at" => observed_at,
          "revision" => lease_revision
        }
      ],
      "revision" => collection_revision,
      "observed_at" => observed_at
    }

    :ok = TestManagementTransport.script_request([{:ok, upstreams}, {:ok, cache}, {:ok, leases}])

    assert %ManagementResult{status: :ok, value: ^upstreams} =
             NetmanManagement.resolved_upstreams_list(netman_id)

    assert %ManagementResult{status: :ok, value: ^cache} =
             NetmanManagement.resolved_cache_get(netman_id)

    assert %ManagementResult{status: :ok, value: ^leases} =
             NetmanManagement.dhcp_client_leases_list(netman_id)
  end

  test "Netman config operations use durable desired-config publication" do
    netman_id = unique_id("netman-config")
    register_netman(netman_id)
    :ok = TestManagementTransport.connect(:netman, netman_id)
    :ok = TestManagementTransport.script_config([:ok])

    payload = %{
      "upstreams" => ["192.0.2.53"],
      "search_domains" => ["example.test"]
    }

    assert %ManagementResult{
             status: :ok,
             source: :desired,
             value: %ConfigVersion{target_type: :netman, target_id: ^netman_id}
           } = NetmanManagement.resolved_config_update(netman_id, payload)

    assert [{:config, %Envelope{} = envelope}] = TestManagementTransport.recorded()
    assert envelope.target_type == :netman
    assert envelope.target_id == netman_id
    assert envelope.operation == "netman.resolved.config.update"
    assert envelope.payload == payload
  end

  defp register_netman(netman_id) do
    assert {:ok, _netman} =
             ManagementCore.register_netman(%{
               id: netman_id,
               profile: :custom,
               apply_mode: :observe_first,
               status: :online
             })
  end

  defp history_list(revision) do
    %{
      "items" => [],
      "revision" => revision,
      "observed_at" => "2026-08-11T00:00:00Z"
    }
  end

  defp expected_snapshot_domain(operation, payload) do
    assert {:ok, digest} = Digest.calculate(payload)
    {first, second} = String.split_at(digest, 32)
    Enum.join([String.replace(operation, "_", "-"), first, second], ".")
  end

  defp snapshot_domains(data_dir, :netman, netman_id) do
    data_dir
    |> Path.join("management/snapshots/netmans/#{netman_id}/*.json")
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
