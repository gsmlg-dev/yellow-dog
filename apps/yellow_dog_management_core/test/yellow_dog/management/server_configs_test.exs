defmodule YellowDog.Management.ServerConfigsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.ConfigVersion
  alias YellowDog.Management.ServerConfigs
  alias YellowDog.Management.Storage.AtomicJson
  alias YellowDog.Management.Storage.Path, as: StoragePath
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Message.ConfigState

  @applied_revision_a String.duplicate("a", 64)
  @applied_revision_b String.duplicate("b", 64)

  setup context do
    previous_data_dir = Application.fetch_env(:yellow_dog_management_core, :data_dir)
    Application.put_env(:yellow_dog_management_core, :data_dir, context.tmp_dir)
    restart_application()

    on_exit(fn ->
      restore_env(:data_dir, previous_data_dir)
      restart_application()
    end)

    :ok
  end

  @moduletag :tmp_dir

  test "gets an empty draft only for a registered server" do
    register_server("server-empty")

    assert {:ok,
            %{
              server_id: "server-empty",
              draft_revision: 0,
              document: nil
            }} = ManagementCore.get_server_config("server-empty")

    assert_error(ManagementCore.get_server_config("missing"), :not_found)
  end

  test "draft writes use durable monotonic CAS while the server is offline" do
    server_id = "server-draft"
    register_server(server_id)
    assert {:ok, %{status: :offline}} = ManagementCore.update_server_status(server_id, :offline)

    assert {:ok, %{draft_revision: 1, document: document}} =
             ManagementCore.put_server_config(server_id, 0, cross_service_document())

    assert document == cross_service_document()

    assert_error(
      ManagementCore.put_server_config(server_id, 0, dns_document()),
      :conflict
    )

    assert {:ok, %{draft_revision: 2, document: document}} =
             ManagementCore.put_server_config(server_id, 1, dns_document())

    assert document == dns_document()

    restart_application()

    assert {:ok, %{draft_revision: 2, document: ^document}} =
             ManagementCore.get_server_config(server_id)

    assert {:ok, manifest_path} = StoragePath.server_manifest(server_id)
    assert {:ok, manifest} = AtomicJson.read(manifest_path)
    assert manifest["registration"]["id"] == server_id

    assert manifest["server_config_draft"] == %{
             "schema_version" => 1,
             "draft_revision" => 2,
             "document" => document
           }
  end

  test "draft writes validate the exact aggregate document before persistence" do
    server_id = "server-invalid-draft"
    register_server(server_id)

    invalid = put_in(cross_service_document(), ["entries", Access.at(0), "setting"], "dns.path")

    assert_error(ManagementCore.put_server_config(server_id, 0, invalid), :invalid)

    assert {:ok, %{draft_revision: 0, document: nil}} =
             ManagementCore.get_server_config(server_id)
  end

  test "publishes the exact draft with runtime CAS independent from draft revision" do
    server_id = "server-publish"
    register_server(server_id)

    assert {:ok, %{draft_revision: 1}} =
             ManagementCore.put_server_config(server_id, 0, cross_service_document())

    assert {:ok,
            %ConfigVersion{
              version: 1,
              operation: "server.config.replace",
              profile: "local_network",
              payload: published_document,
              expected_revision: nil,
              state: :desired
            } = first} = ManagementCore.publish_server_config(server_id, 1)

    assert published_document == cross_service_document()

    assert {:ok, %{draft_revision: 2}} =
             ManagementCore.put_server_config(server_id, 1, dns_document())

    assert_error(ManagementCore.publish_server_config(server_id, 2), :conflict)

    assert {:ok, %{draft_revision: 2, document: current_draft}} =
             ManagementCore.get_server_config(server_id)

    assert current_draft == dns_document()

    applied = apply_version(first, @applied_revision_a)

    assert {:ok,
            %ConfigVersion{
              version: 2,
              payload: second_document,
              expected_revision: @applied_revision_a,
              previous_version: 1,
              previous_revision: @applied_revision_a
            }} = ManagementCore.publish_server_config(server_id, 2)

    assert second_document == dns_document()
    assert applied.applied_revision == @applied_revision_a
  end

  test "publish rejects missing or stale drafts without creating a version" do
    server_id = "server-stale-publish"
    register_server(server_id)

    assert_error(ManagementCore.publish_server_config(server_id, 0), :not_found)

    assert {:ok, %{draft_revision: 1}} =
             ManagementCore.put_server_config(server_id, 0, dns_document())

    assert_error(ManagementCore.publish_server_config(server_id, 0), :conflict)
    assert_error(ManagementCore.get_server_config_version(server_id, 1), :not_found)
  end

  test "aggregate publication cannot bypass the Management-owned draft" do
    server_id = "server-publication-bypass"
    register_server(server_id)

    assert {:ok, %{draft_revision: 1}} =
             ManagementCore.put_server_config(server_id, 0, dns_document())

    assert_error(
      ManagementCore.publish_server_config(server_id, %{
        operation: "server.config.replace",
        payload: cross_service_document(),
        expected_revision: nil
      }),
      :invalid
    )

    assert_error(ManagementCore.get_server_config_version(server_id, 1), :not_found)
  end

  test "concurrent publication admits exactly one in-flight deployment" do
    server_id = "server-concurrent-publish"
    register_server(server_id)

    assert {:ok, %{draft_revision: 1}} =
             ManagementCore.put_server_config(server_id, 0, dns_document())

    results =
      1..2
      |> Task.async_stream(
        fn _index -> ManagementCore.publish_server_config(server_id, 1) end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert 1 == Enum.count(results, &match?({:ok, %ConfigVersion{version: 1}}, &1))
    assert 1 == Enum.count(results, &match?({:error, %Error{code: :conflict}}, &1))
    assert_error(ManagementCore.get_server_config_version(server_id, 2), :not_found)
  end

  test "rollback republishes a prior aggregate document as a new monotonic version" do
    server_id = "server-rollback"
    register_server(server_id)

    assert {:ok, %{draft_revision: 1}} =
             ManagementCore.put_server_config(server_id, 0, dns_document())

    assert {:ok, first} = ManagementCore.publish_server_config(server_id, 1)
    _first_applied = apply_version(first, @applied_revision_a)

    assert {:ok, %{draft_revision: 2}} =
             ManagementCore.put_server_config(server_id, 1, cross_service_document())

    assert {:ok, second} = ManagementCore.publish_server_config(server_id, 2)
    _second_applied = apply_version(second, @applied_revision_b)

    assert {:ok, %{draft_revision: 3}} =
             ManagementCore.put_server_config(server_id, 2, dhcp_document())

    assert {:ok,
            %ConfigVersion{
              version: 3,
              operation: "server.config.replace",
              payload: rollback_document,
              expected_revision: @applied_revision_b,
              previous_version: 2,
              previous_revision: @applied_revision_b
            }} = ManagementCore.rollback_server_config(server_id, 1, 3)

    assert rollback_document == dns_document()

    assert {:ok, %{draft_revision: 3, document: current_draft}} =
             ManagementCore.get_server_config(server_id)

    assert current_draft == dhcp_document()
    assert_error(ManagementCore.rollback_server_config(server_id, 2, 2), :conflict)
    assert_error(ManagementCore.rollback_server_config(server_id, 2, 3), :conflict)
  end

  test "rollback rejects non-aggregate history" do
    server_id = "server-legacy-history"
    register_server(server_id)

    assert {:ok, _legacy} =
             ManagementCore.publish_server_config(server_id, %{
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

    assert_error(ManagementCore.rollback_server_config(server_id, 1, 0), :invalid)
  end

  test "ServerConfigs remains a plain durable facade without a supervised process" do
    refute Process.whereis(ServerConfigs)
  end

  defp dns_document do
    %{
      "schema_version" => 1,
      "profile" => "dns_only",
      "entries" => [
        %{
          "setting" => "dns.tls_certificate_ref",
          "value" => %{"type" => "string", "value" => "dns-certificate-1"}
        },
        %{
          "setting" => "services.dns.enabled",
          "value" => %{"type" => "boolean", "value" => true}
        }
      ]
    }
  end

  defp cross_service_document do
    %{
      "schema_version" => 1,
      "profile" => "local_network",
      "entries" => [
        %{
          "setting" => "dhcpv4.payload_uri",
          "value" => %{
            "type" => "string",
            "value" => "https://assets.example.test/dhcp/payload"
          }
        },
        %{
          "setting" => "services.dhcpv4.enabled",
          "value" => %{"type" => "boolean", "value" => true}
        },
        %{
          "setting" => "services.dns.enabled",
          "value" => %{"type" => "boolean", "value" => true}
        }
      ]
    }
  end

  defp dhcp_document do
    %{
      "schema_version" => 1,
      "profile" => "dhcp_only",
      "entries" => [
        %{
          "setting" => "services.dhcpv4.enabled",
          "value" => %{"type" => "boolean", "value" => true}
        },
        %{
          "setting" => "services.dhcpv6.enabled",
          "value" => %{"type" => "boolean", "value" => true}
        }
      ]
    }
  end

  defp register_server(id) do
    assert {:ok, _server} = ManagementCore.register_server(%{id: id, profile: :dns_only})
  end

  defp apply_version(version, applied_revision) do
    assert {:ok, delivered} = transition(version, :delivered, 0)
    assert {:ok, applying} = transition(delivered, :applying, 1)
    assert {:ok, applied} = transition(applying, :applied, 2, applied_revision)
    applied
  end

  defp transition(version, state, expected_state_revision, applied_revision \\ nil) do
    acknowledgement = %ConfigState{
      target_type: version.target_type,
      target_id: version.target_id,
      operation: version.operation,
      state: state,
      version: version.version,
      digest: version.digest,
      applied_revision: applied_revision,
      previous_version: if(state == :delivered, do: nil, else: version.previous_version),
      previous_revision: if(state == :delivered, do: nil, else: version.previous_revision),
      failure: nil,
      rollback: nil,
      observed_at: DateTime.utc_now(:second)
    }

    ManagementCore.transition_config(
      version.target_type,
      version.target_id,
      version.version,
      state,
      %{expected_state_revision: expected_state_revision, acknowledgement: acknowledgement}
    )
  end

  defp assert_error(result, code) do
    assert {:error, %Error{code: ^code}} = result
  end

  defp restart_application do
    :ok = Application.stop(:yellow_dog_management_core)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
