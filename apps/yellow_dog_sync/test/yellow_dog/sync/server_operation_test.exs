defmodule YellowDog.Sync.ServerOperationTest do
  use ExUnit.Case, async: false

  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation

  @operations [
    {"server.runtime.capabilities.get", :query, "runtime.capabilities", :empty,
     :runtime_capabilities, true},
    {"server.runtime.services.list", :query, "runtime.services", :empty, :service_list, true},
    {"server.runtime.health.get", :query, "runtime.health", :empty, :runtime_health, true},
    {"server.runtime.stats.get", :query, "runtime.stats", :empty, :runtime_stats, true},
    {"server.runtime.services.start", :command, "runtime.services", :service_ref,
     :service_command_result, true},
    {"server.runtime.services.stop", :command, "runtime.services", :service_ref,
     :service_command_result, true},
    {"server.runtime.services.restart", :command, "runtime.services", :service_ref,
     :service_command_result, true},
    {"server.dns.views.list", :query, "dns.views.read", :dns_view_list_query, :dns_view_list,
     true},
    {"server.dns.zones.list", :query, "dns.zones.read", :dns_zone_list_query, :dns_zone_list,
     true},
    {"server.dns.records.list", :query, "dns.records.read", :dns_record_list_query,
     :dns_record_list, true},
    {"server.dns.acls.list", :query, "dns.acls.read", :dns_acl_list_query, :dns_acl_list, true},
    {"server.dns.providers.list", :query, "dns.providers.read", :dns_provider_list_query,
     :dns_provider_list, true},
    {"server.dns.logs.list", :query, "dns.logs.read", :dns_log_list_query, :dns_log_list, true},
    {"server.dns.metrics.get", :query, "dns.metrics.read", :dns_metrics_query, :dns_metrics,
     true},
    {"server.dns.views.create", :command, "dns.views.write", :dns_view_write,
     :revisioned_resource, true},
    {"server.dns.views.update", :command, "dns.views.write", :dns_view_write,
     :revisioned_resource, true},
    {"server.dns.views.delete", :command, "dns.views.write", :dns_view_ref, :deleted_resource,
     true},
    {"server.dns.zones.create", :command, "dns.zones.write", :dns_zone_write,
     :revisioned_resource, true},
    {"server.dns.zones.update", :command, "dns.zones.write", :dns_zone_write,
     :revisioned_resource, true},
    {"server.dns.zones.delete", :command, "dns.zones.write", :dns_zone_ref, :deleted_resource,
     true},
    {"server.dns.records.create", :command, "dns.records.write", :dns_record_write,
     :revisioned_resource, true},
    {"server.dns.records.update", :command, "dns.records.write", :dns_record_write,
     :revisioned_resource, true},
    {"server.dns.records.delete", :command, "dns.records.write", :dns_record_ref,
     :deleted_resource, true},
    {"server.dns.acls.create", :command, "dns.acls.write", :dns_acl_write, :revisioned_resource,
     true},
    {"server.dns.acls.update", :command, "dns.acls.write", :dns_acl_write, :revisioned_resource,
     true},
    {"server.dns.acls.delete", :command, "dns.acls.write", :dns_acl_ref, :deleted_resource, true},
    {"server.dns.providers.create", :command, "dns.providers.write", :dns_provider_write,
     :revisioned_resource, true},
    {"server.dns.providers.update", :command, "dns.providers.write", :dns_provider_write,
     :revisioned_resource, true},
    {"server.dns.providers.delete", :command, "dns.providers.write", :dns_provider_ref,
     :deleted_resource, true},
    {"server.dns.zones.import", :command, "dns.zones.write", :dns_zone_import, :dns_import_result,
     true},
    {"server.dns.zones.sync", :command, "dns.zones.sync", :dns_zone_sync, :dns_sync_result, true},
    {"server.dns.conflicts.resolve", :command, "dns.conflicts.resolve", :dns_conflict_resolution,
     :revisioned_resource, true},
    {"server.dhcp.pools.list", :query, "dhcp.pools.read", :dhcp_pool_list_query, :dhcp_pool_list,
     true},
    {"server.dhcp.leases.list", :query, "dhcp.leases.read", :dhcp_lease_list_query,
     :dhcp_lease_list, true},
    {"server.dhcp.activity.list", :query, "dhcp.activity.read", :dhcp_activity_query,
     :dhcp_activity_list, true},
    {"server.dhcp.status.get", :query, "dhcp.status.read", :dhcp_status_query, :dhcp_status,
     true},
    {"server.dhcp.pools.create", :command, "dhcp.pools.write", :dhcp_pool_write,
     :revisioned_resource, true},
    {"server.dhcp.pools.update", :command, "dhcp.pools.write", :dhcp_pool_write,
     :revisioned_resource, true},
    {"server.dhcp.pools.delete", :command, "dhcp.pools.write", :dhcp_pool_ref, :deleted_resource,
     true},
    {"server.dhcp.pools.force_delete", :command, "dhcp.pools.write", :dhcp_force_delete,
     :deleted_resource, true},
    {"server.dhcp.leases.release", :command, "dhcp.leases.write", :dhcp_lease_ref,
     :lease_release_result, true},
    {"server.mdns.services.list", :query, "mdns.services.read", :mdns_service_list_query,
     :mdns_service_list, true},
    {"server.mdns.discovery.list", :query, "mdns.discovery.read", :mdns_discovery_query,
     :mdns_discovery_list, true},
    {"server.mdns.monitor.list", :query, "mdns.monitor.read", :mdns_monitor_query,
     :mdns_monitor_list, true},
    {"server.mdns.cache.get", :query, "mdns.cache.read", :empty, :mdns_cache, true},
    {"server.mdns.services.register", :command, "mdns.services.write", :mdns_service_register,
     :revisioned_resource, true},
    {"server.mdns.services.update", :command, "mdns.services.write", :mdns_service_update,
     :revisioned_resource, true},
    {"server.mdns.services.delete", :command, "mdns.services.write", :mdns_service_ref,
     :deleted_resource, true},
    {"server.mdns.services.toggle", :command, "mdns.services.write", :mdns_service_toggle,
     :revisioned_resource, true},
    {"server.mdns.cache.clear", :command, "mdns.cache.write", :empty, :cache_clear_result, true},
    {"server.netboot.profiles.list", :query, "netboot.profiles.read", :netboot_profile_list_query,
     :netboot_profile_list, true},
    {"server.netboot.devices.list", :query, "netboot.devices.read", :netboot_device_list_query,
     :netboot_device_list, true},
    {"server.netboot.assets.list", :query, "netboot.assets.read", :netboot_asset_list_query,
     :netboot_asset_list, true},
    {"server.netboot.transfers.list", :query, "netboot.transfers.read",
     :netboot_transfer_list_query, :netboot_transfer_list, true},
    {"server.netboot.logs.list", :query, "netboot.logs.read", :netboot_log_list_query,
     :netboot_log_list, true},
    {"server.netboot.profiles.put", :command, "netboot.profiles.write", :netboot_profile_write,
     :revisioned_resource, true},
    {"server.netboot.profiles.delete", :command, "netboot.profiles.write", :netboot_profile_ref,
     :deleted_resource, true},
    {"server.netboot.devices.put", :command, "netboot.devices.write", :netboot_device_write,
     :revisioned_resource, true},
    {"server.netboot.devices.delete", :command, "netboot.devices.write", :netboot_device_ref,
     :deleted_resource, true},
    {"server.netboot.assets.upload", :command, "netboot.assets.write", :netboot_asset_upload,
     :netboot_asset, true},
    {"server.netboot.assets.delete", :command, "netboot.assets.write", :netboot_asset_ref,
     :deleted_resource, true},
    {"server.netboot.assets.rescan", :command, "netboot.assets.write", :netboot_asset_rescan,
     :netboot_asset_rescan_result, true},
    {"server.identity.hosts.list", :query, "identity.hosts.read", :identity_host_list_query,
     :identity_host_list, true},
    {"server.identity.approvals.list", :query, "identity.approvals.read",
     :identity_approval_list_query, :identity_approval_list, true},
    {"server.identity.tokens.list", :query, "identity.tokens.read", :identity_token_list_query,
     :identity_token_list, true},
    {"server.identity.policies.get", :query, "identity.policies.read", :empty,
     :identity_policy_set, true},
    {"server.identity.audit.list", :query, "identity.audit.read", :identity_audit_query,
     :identity_audit_list, true},
    {"server.identity.hosts.approve", :command, "identity.approvals.write", :identity_host_ref,
     :revisioned_resource, true},
    {"server.identity.hosts.revoke", :command, "identity.approvals.write", :identity_host_ref,
     :revisioned_resource, true},
    {"server.identity.hosts.delete", :command, "identity.hosts.write", :identity_host_ref,
     :deleted_resource, true},
    {"server.identity.tokens.create", :command, "identity.tokens.write", :identity_token_create,
     :identity_token_create_result, true},
    {"server.identity.tokens.revoke", :command, "identity.tokens.write", :identity_token_ref,
     :revisioned_resource, true},
    {"server.identity.policies.update", :command, "identity.policies.write", :identity_policy_set,
     :revisioned_resource, true},
    {"server.settings.effective.get", :query, "settings.read", :settings_query,
     :effective_settings, true},
    {"server.settings.source.get", :query, "settings.read", :settings_query, :settings_source,
     true},
    {"server.settings.revision.get", :query, "settings.read", :settings_query, :settings_revision,
     true},
    {"server.settings.validation.get", :query, "settings.read", :settings_query,
     :settings_validation, true},
    {"server.settings.update", :config, "settings.config.write", :server_settings_config,
     :config_state, false},
    {"server.settings.apply", :command, "settings.apply", :service_ref, :config_state, true},
    {"server.settings.reload", :command, "settings.reload", :service_ref, :service_command_result,
     true},
    {"server.settings.rollback", :command, "settings.rollback", :settings_rollback, :config_state,
     true}
  ]

  test "catalog exposes every Server operation with explicit metadata and validators" do
    assert map_size(ServerOperation.all()) == 81

    for {name, kind, capability, payload_schema, result_schema, online?} <- @operations do
      assert {:ok,
              %Operation{
                target_type: :server,
                kind: ^kind,
                capability: ^capability,
                payload_schema: ^payload_schema,
                result_schema: ^result_schema,
                online?: ^online?
              } = operation} = ServerOperation.fetch(name)

      assert {:ok, _payload} = Operation.validate_payload(operation, example(payload_schema))
      assert {:ok, _result} = Operation.validate_result(operation, example(result_schema))
    end
  end

  test "only config operations are offline queueable" do
    for {_name, operation} <- ServerOperation.all() do
      assert operation.online? == (operation.kind != :config)
    end
  end

  test "rejects unknown operations without creating atoms" do
    _ = ServerOperation.fetch("server.runtime.services.list")
    initial_atom_count = :erlang.system_info(:atom_count)

    last_name =
      Enum.reduce(1..500, nil, fn index, _last_name ->
        name = "server.unknown.#{index}_#{System.unique_integer([:positive])}"
        assert_invalid(ServerOperation.fetch(name))
        name
      end)

    assert :erlang.system_info(:atom_count) == initial_atom_count
    assert_raise ArgumentError, fn -> String.to_existing_atom(last_name) end
  end

  test "rejects target and kind mismatches before validation" do
    assert_invalid(
      Operation.validate_payload("server.runtime.services.list", :netman, :query, %{})
    )

    assert_invalid(
      Operation.validate_payload("server.runtime.services.list", :server, :command, %{})
    )
  end

  test "rejects extraneous payload fields and binary asset content" do
    assert_invalid(
      Operation.validate_payload(
        "server.runtime.services.list",
        :server,
        :query,
        %{"unexpected" => true}
      )
    )

    assert_invalid(
      Operation.validate_payload(
        "server.netboot.assets.upload",
        :server,
        :command,
        %{
          "asset_id" => "installer",
          "filename" => "installer.ipxe",
          "size" => 4,
          "blob_digest" => digest(),
          "content" => <<0, 1, 2, 3>>
        }
      )
    )
  end

  defp example(:empty), do: %{}

  defp example(schema) when schema in [:dns_zone_import, :netboot_asset_upload] do
    %{
      "resource_id" => "resource-1",
      "filename" => "asset.bin",
      "size" => 42,
      "blob_digest" => digest()
    }
  end

  defp example(schema) do
    cond do
      schema == :config_state ->
        config_state()

      schema == :mdns_service_toggle ->
        %{"resource_id" => "resource-1", "enabled" => true}

      schema in result_list_schemas() ->
        snapshot(%{"items" => []})

      schema in result_value_schemas() ->
        snapshot(%{"value" => %{}})

      schema in ref_schemas() ->
        %{"resource_id" => "resource-1"}

      schema in write_schemas() ->
        %{"resource_id" => "resource-1", "value" => %{}}

      schema in query_schemas() ->
        %{}

      schema in command_result_schemas() ->
        %{"resource_id" => "resource-1", "revision" => digest(), "value" => %{}}

      true ->
        raise "missing example for #{inspect(schema)}"
    end
  end

  defp query_schemas do
    [
      :dns_view_list_query,
      :dns_zone_list_query,
      :dns_record_list_query,
      :dns_acl_list_query,
      :dns_provider_list_query,
      :dns_log_list_query,
      :dns_metrics_query,
      :dhcp_pool_list_query,
      :dhcp_lease_list_query,
      :dhcp_activity_query,
      :dhcp_status_query,
      :mdns_service_list_query,
      :mdns_discovery_query,
      :mdns_monitor_query,
      :netboot_profile_list_query,
      :netboot_device_list_query,
      :netboot_asset_list_query,
      :netboot_transfer_list_query,
      :netboot_log_list_query,
      :identity_host_list_query,
      :identity_approval_list_query,
      :identity_token_list_query,
      :identity_audit_query,
      :settings_query
    ]
  end

  defp ref_schemas do
    [
      :service_ref,
      :dns_view_ref,
      :dns_zone_ref,
      :dns_record_ref,
      :dns_acl_ref,
      :dns_provider_ref,
      :dhcp_pool_ref,
      :dhcp_force_delete,
      :dhcp_lease_ref,
      :mdns_service_ref,
      :netboot_profile_ref,
      :netboot_device_ref,
      :netboot_asset_ref,
      :netboot_asset_rescan,
      :identity_host_ref,
      :identity_token_ref,
      :settings_rollback
    ]
  end

  defp write_schemas do
    [
      :dns_view_write,
      :dns_zone_write,
      :dns_record_write,
      :dns_acl_write,
      :dns_provider_write,
      :dns_zone_sync,
      :dns_conflict_resolution,
      :dhcp_pool_write,
      :mdns_service_register,
      :mdns_service_update,
      :mdns_service_toggle,
      :netboot_profile_write,
      :netboot_device_write,
      :identity_token_create,
      :identity_policy_set,
      :server_settings_config
    ]
  end

  defp result_list_schemas do
    [
      :service_list,
      :dns_view_list,
      :dns_zone_list,
      :dns_record_list,
      :dns_acl_list,
      :dns_provider_list,
      :dns_log_list,
      :dhcp_pool_list,
      :dhcp_lease_list,
      :dhcp_activity_list,
      :mdns_service_list,
      :mdns_discovery_list,
      :mdns_monitor_list,
      :netboot_profile_list,
      :netboot_device_list,
      :netboot_asset_list,
      :netboot_transfer_list,
      :netboot_log_list,
      :identity_host_list,
      :identity_approval_list,
      :identity_token_list,
      :identity_audit_list
    ]
  end

  defp result_value_schemas do
    [
      :runtime_capabilities,
      :runtime_health,
      :runtime_stats,
      :dns_metrics,
      :dhcp_status,
      :mdns_cache,
      :effective_settings,
      :settings_source,
      :settings_revision,
      :settings_validation
    ]
  end

  defp command_result_schemas do
    [
      :service_command_result,
      :revisioned_resource,
      :deleted_resource,
      :dns_import_result,
      :dns_sync_result,
      :lease_release_result,
      :cache_clear_result,
      :netboot_asset,
      :netboot_asset_rescan_result,
      :identity_token_create_result
    ]
  end

  defp snapshot(value),
    do: Map.merge(value, %{"revision" => digest(), "observed_at" => timestamp()})

  defp config_state do
    %{
      "state" => "applied",
      "version" => "version-1",
      "digest" => digest(),
      "applied_revision" => digest(),
      "previous_revision" => nil,
      "failure" => nil,
      "rollback" => nil
    }
  end

  defp digest, do: String.duplicate("a", 64)
  defp timestamp, do: "2026-07-16T08:30:00Z"

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} = result
  end
end
