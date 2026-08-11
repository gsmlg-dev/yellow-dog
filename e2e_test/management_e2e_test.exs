Code.compile_file("support/management_transport.ex", __DIR__)

defmodule E2ETest.ManagementE2ETest do
  use ExUnit.Case, async: false

  alias E2ETest.ManagementTransport
  alias E2ETest.ServerRuntime
  alias YellowDog.Management.ConfigVersion
  alias YellowDog.ManagementCore
  alias YellowDog.NetmanAgent.CommandJournal, as: NetmanCommandJournal
  alias YellowDog.ServerAgent.CommandJournal, as: ServerCommandJournal
  alias YellowDog.ServerAgent.ConfigApplier
  alias YellowDog.ServerAgent.ConfigApplyStore
  alias YellowDog.ServerAgent.ConfigStore

  @moduletag :e2e
  @moduletag :management
  @moduletag :tmp_dir

  @server_id "e2e-server"
  @netman_id "e2e-netman"
  @server_capabilities ["runtime.capabilities", "runtime.services"]
  @netman_capabilities ["runtime.capabilities"]
  @command_key "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

  setup %{tmp_dir: tmp_dir} do
    previous_env =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    management_was_started? = management_started?()
    stop_management()
    Application.put_env(:yellow_dog_management_core, :data_dir, Path.join(tmp_dir, "management"))
    Application.put_env(:yellow_dog_management_core, :transport_module, ManagementTransport)
    Application.put_env(:yellow_dog_management_core, :request_timeout, 2_000)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)

    on_exit(fn ->
      stop_management()
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)

      if management_was_started? do
        {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      end
    end)

    server_agent = start_server_agent(Path.join(tmp_dir, "server-agent"))
    netman_journal = start_netman_journal(Path.join(tmp_dir, "netman-agent"))

    transport =
      start_child(:management_transport, ManagementTransport,
        server: %{
          id: @server_id,
          capabilities: @server_capabilities,
          command_journal: server_agent.command_journal,
          config_applier: server_agent.config_applier,
          config_apply_store: server_agent.config_apply_store
        },
        netman: %{
          id: @netman_id,
          capabilities: @netman_capabilities,
          command_journal: netman_journal
        }
      )

    %{transport: transport}
  end

  test "Management remains source of truth across agent delivery, replay, rollback, and restart" do
    assert {:ok, %{id: @server_id, status: :registered}} =
             ManagementCore.register_server(%{id: @server_id, profile: :dns_only})

    assert {:ok, %{id: @netman_id, status: :registered}} =
             ManagementCore.register_netman(%{id: @netman_id, profile: :vm})

    assert {:ok, %{draft_revision: 1, document: first_document}} =
             ManagementCore.put_server_config(@server_id, 0, server_document("first"))

    assert first_document == server_document("first")

    assert {:ok, %ConfigVersion{version: 1, state: :desired} = first_desired} =
             ManagementCore.publish_server_config(@server_id, 1)

    assert ManagementTransport.deliveries() == []

    assert {:ok, %{pending_config: %ConfigVersion{version: 1}}} =
             ManagementTransport.connect(:server, @server_id)

    assert {:ok, %{pending_config: nil}} =
             ManagementTransport.connect(:netman, @netman_id)

    assert {:ok, %{status: :online}} = ManagementCore.get_server(@server_id)
    assert {:ok, %{status: :online}} = ManagementCore.get_netman(@netman_id)

    assert {:ok, %ConfigVersion{state: :applied, applied_revision: first_revision}} =
             ManagementCore.get_server_config_version(@server_id, first_desired.version)

    assert first_revision == first_desired.digest
    assert ServerRuntime.active_revision() == first_revision

    server_result = %{
      "capabilities" => ["runtime.capabilities", "runtime.services"]
    }

    netman_result = %{"capabilities" => ["runtime.capabilities"]}

    assert {:ok, ^server_result} =
             ManagementCore.query_server(
               @server_id,
               "runtime.capabilities",
               "server.runtime.capabilities.get",
               %{}
             )

    assert {:ok, ^netman_result} =
             ManagementCore.query_netman(
               @netman_id,
               "runtime.capabilities",
               "netman.runtime.capabilities.get",
               %{}
             )

    [server_query, netman_query] =
      ManagementTransport.requests()
      |> Enum.filter(&(&1.kind == :query))

    assert server_query.envelope.target_type == :server
    assert server_query.envelope.target_id == @server_id
    assert netman_query.envelope.target_type == :netman
    assert netman_query.envelope.target_id == @netman_id
    refute server_query.envelope.request_id == netman_query.envelope.request_id

    assert {:ok, %{request_id: server_request_id, value: ^server_result}} =
             ManagementCore.get_server_snapshot(@server_id, "runtime.capabilities")

    assert {:ok, %{request_id: netman_request_id, value: ^netman_result}} =
             ManagementCore.get_netman_snapshot(@netman_id, "runtime.capabilities")

    assert server_request_id == server_query.envelope.request_id
    assert netman_request_id == netman_query.envelope.request_id

    command_args = [
      @server_id,
      "server.runtime.services.start",
      %{"service" => "dns"},
      first_revision,
      @command_key
    ]

    expected_command_result = %{"service" => "dns", "state" => "running"}

    assert {:ok, ^expected_command_result} = apply(ManagementCore, :command_server, command_args)
    assert {:ok, ^expected_command_result} = apply(ManagementCore, :command_server, command_args)
    assert ManagementTransport.request_count(:command) == 1
    assert ServerRuntime.command_calls() == 1

    assert {:ok, %{draft_revision: 2}} =
             ManagementCore.put_server_config(@server_id, 1, server_document("second"))

    :ok = ServerRuntime.fail_next_activation()

    assert {:ok, %ConfigVersion{version: 2}} =
             ManagementCore.publish_server_config(@server_id, 2)

    assert {:ok,
            %ConfigVersion{
              state: :failed,
              failure_phase: :apply,
              restored_version: 1,
              restored_revision: ^first_revision,
              rollback: %{"succeeded" => true}
            } = failed_version} =
             ManagementCore.get_server_config_version(@server_id, 2)

    assert failed_version.previous_revision == first_revision
    assert ServerRuntime.active_revision() == first_revision
    assert ServerRuntime.rollback_calls() == 1
    assert length(ManagementTransport.deliveries()) == 2

    restart_management()

    assert {:ok, %{id: @server_id, status: :online}} = ManagementCore.get_server(@server_id)
    assert {:ok, %{id: @netman_id, status: :online}} = ManagementCore.get_netman(@netman_id)

    assert {:ok, %{draft_revision: 2, document: persisted_document}} =
             ManagementCore.get_server_config(@server_id)

    assert persisted_document == server_document("second")

    assert {:ok, %{request_id: ^server_request_id, value: ^server_result}} =
             ManagementCore.get_server_snapshot(@server_id, "runtime.capabilities")

    assert {:ok, %{request_id: ^netman_request_id, value: ^netman_result}} =
             ManagementCore.get_netman_snapshot(@netman_id, "runtime.capabilities")

    assert {:ok, %ConfigVersion{state: :applied, applied_revision: ^first_revision}} =
             ManagementCore.get_server_config_version(@server_id, 1)

    assert {:ok, %ConfigVersion{state: :failed, rollback: %{"succeeded" => true}}} =
             ManagementCore.get_server_config_version(@server_id, 2)

    assert {:ok, [%{target_id: @server_id, state: :completed}]} =
             ManagementCore.list_command_outcomes()

    assert {:ok, ^expected_command_result} = apply(ManagementCore, :command_server, command_args)
    assert ManagementTransport.request_count(:command) == 1
    assert ServerRuntime.command_calls() == 1
  end

  defp start_server_agent(data_dir) do
    File.mkdir_p!(data_dir)
    start_child(:server_runtime, ServerRuntime, [])

    config_store =
      start_child(:server_config_store, ConfigStore,
        name: unique_name(:server_config_store),
        data_dir: data_dir,
        server_id: @server_id,
        profile: :dns_only
      )

    config_apply_store =
      start_child(:server_config_apply_store, ConfigApplyStore,
        name: unique_name(:server_config_apply_store),
        data_dir: data_dir,
        server_id: @server_id,
        profile: :dns_only,
        config_store: config_store
      )

    config_applier =
      start_child(:server_config_applier, ConfigApplier,
        name: nil,
        server_id: @server_id,
        profile: :dns_only,
        config_store: config_store,
        config_apply_store: config_apply_store,
        runtime_adapter: ServerRuntime
      )

    command_journal =
      start_child(:server_command_journal, ServerCommandJournal,
        name: unique_name(:server_command_journal),
        data_dir: data_dir,
        server_id: @server_id,
        capabilities: @server_capabilities
      )

    %{
      command_journal: command_journal,
      config_applier: config_applier,
      config_apply_store: config_apply_store
    }
  end

  defp start_netman_journal(data_dir) do
    File.mkdir_p!(data_dir)

    start_child(:netman_command_journal, NetmanCommandJournal,
      name: unique_name(:netman_command_journal),
      data_dir: data_dir,
      netman_id: @netman_id,
      capabilities: @netman_capabilities
    )
  end

  defp start_child(id, module, opts) do
    start_supervised!(%{
      id: id,
      start: {module, :start_link, [opts]},
      restart: :temporary
    })
  end

  defp server_document(label) do
    %{
      "schema_version" => 1,
      "profile" => "dns_only",
      "entries" => [
        %{
          "setting" => "dns.tls_certificate_ref",
          "value" => %{"type" => "string", "value" => "certificate-#{label}"}
        },
        %{
          "setting" => "services.dns.enabled",
          "value" => %{"type" => "boolean", "value" => true}
        }
      ]
    }
  end

  defp unique_name(label),
    do: {:global, {__MODULE__, label, System.unique_integer([:positive])}}

  defp restart_management do
    stop_management()
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
    :ok
  end

  defp stop_management do
    case Application.stop(:yellow_dog_management_core) do
      :ok -> :ok
      {:error, {:not_started, :yellow_dog_management_core}} -> :ok
    end
  end

  defp management_started? do
    Enum.any?(Application.started_applications(), fn {app, _description, _version} ->
      app == :yellow_dog_management_core
    end)
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error),
    do: Application.delete_env(:yellow_dog_management_core, key)
end
