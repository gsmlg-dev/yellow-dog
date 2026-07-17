defmodule YellowDog.Sync.OperationSchemaFixtures do
  @moduledoc false

  @revision String.duplicate("a", 64)
  @observed_at "2026-07-16T08:30:00Z"

  @list_schemas [
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
    :identity_audit_list,
    :profile_list,
    :profile_history,
    :network_link_list,
    :network_address_list,
    :network_route_list,
    :resolved_upstream_list,
    :resolved_search_domain_list,
    :dhcp_client_lease_list
  ]

  def schemas do
    operations =
      Map.values(YellowDog.Sync.ServerOperation.all()) ++
        Map.values(YellowDog.Sync.NetmanOperation.all())

    operations
    |> Enum.flat_map(&[&1.payload_schema, &1.result_schema])
    |> Enum.uniq()
    |> Enum.sort()
  end

  def valid(schema) when schema in @list_schemas do
    %{"items" => [list_item(schema)], "revision" => @revision, "observed_at" => @observed_at}
  end

  def valid(:empty), do: %{}

  def valid(schema) do
    case schema do
      :dns_view_list_query ->
        %{}

      :dns_zone_list_query ->
        %{"view_name" => "default"}

      :dns_record_list_query ->
        %{"view_name" => "default", "zone_name" => "example.test"}

      :dns_acl_list_query ->
        %{}

      :dns_provider_list_query ->
        %{}

      :dns_log_list_query ->
        %{"view_name" => "default"}

      :dns_metrics_query ->
        %{}

      :dhcp_pool_list_query ->
        %{"family" => "ipv4"}

      :dhcp_lease_list_query ->
        %{"family" => "ipv4"}

      :dhcp_activity_query ->
        %{"family" => "ipv4"}

      :dhcp_status_query ->
        %{"family" => "ipv4"}

      :mdns_service_list_query ->
        %{}

      :mdns_discovery_query ->
        %{}

      :mdns_monitor_query ->
        %{}

      :netboot_profile_list_query ->
        %{}

      :netboot_device_list_query ->
        %{}

      :netboot_asset_list_query ->
        %{}

      :netboot_transfer_list_query ->
        %{}

      :netboot_log_list_query ->
        %{}

      :identity_host_list_query ->
        %{}

      :identity_approval_list_query ->
        %{}

      :identity_token_list_query ->
        %{}

      :identity_audit_query ->
        %{}

      :settings_query ->
        %{"service" => "dns"}

      :profile_list_query ->
        %{}

      :network_links_query ->
        %{}

      :network_addresses_query ->
        %{}

      :network_routes_query ->
        %{}

      :network_connection_query ->
        %{"connection_id" => "uplink"}

      :service_ref ->
        %{"service" => "dns"}

      :dns_view_ref ->
        %{"view_name" => "default"}

      :dns_zone_ref ->
        %{"view_name" => "default", "zone_name" => "example.test"}

      :dns_record_ref ->
        dns_record_ref()

      :dns_acl_ref ->
        %{"acl_id" => "trusted"}

      :dns_provider_ref ->
        %{"provider_id" => "route53"}

      :dhcp_pool_ref ->
        %{"family" => "ipv4", "pool_id" => "office"}

      :dhcp_force_delete ->
        %{"family" => "ipv4", "pool_id" => "office", "force" => true}

      :dhcp_lease_ref ->
        %{"family" => "ipv4", "lease_id" => "lease-1"}

      :mdns_service_ref ->
        %{"service_id" => "printer"}

      :netboot_profile_ref ->
        %{"profile_id" => "linux"}

      :netboot_device_ref ->
        %{"device_id" => "device-1"}

      :netboot_asset_ref ->
        %{"asset_id" => "installer"}

      :netboot_asset_rescan ->
        %{"scope" => "all"}

      :identity_host_ref ->
        %{"host_id" => "host-1"}

      :identity_token_ref ->
        %{"token_id" => "token-1"}

      :settings_rollback ->
        %{"service" => "dns", "target_revision" => @revision}

      :profile_ref ->
        %{"profile_id" => "office"}

      :profile_rollback ->
        %{"profile_id" => "office", "target_revision" => @revision}

      :connection_ref ->
        %{"connection_id" => "uplink"}

      :dhcp_client_connection_ref ->
        %{"connection_id" => "uplink"}

      :resolved_config_rollback ->
        %{"target_revision" => @revision}

      :dns_view_write ->
        dns_view()

      :dns_zone_write ->
        dns_zone()

      :dns_record_write ->
        dns_record()

      :dns_acl_write ->
        dns_acl()

      :dns_provider_write ->
        dns_provider()

      :dns_zone_import ->
        %{
          "view_name" => "default",
          "zone_name" => "example.test",
          "filename" => "example.test.zone",
          "size" => 42,
          "blob_digest" => @revision
        }

      :dns_zone_sync ->
        %{"view_name" => "default", "zone_name" => "example.test", "provider_id" => "route53"}

      :dns_conflict_resolution ->
        %{"conflict_id" => "conflict-1", "resolution" => "use_local"}

      :dhcp_pool_write ->
        dhcp_pool()

      :mdns_service_register ->
        mdns_service()

      :mdns_service_update ->
        mdns_service()

      :mdns_service_toggle ->
        %{"service_id" => "printer", "enabled" => true}

      :netboot_profile_write ->
        netboot_profile()

      :netboot_device_write ->
        netboot_device()

      :netboot_asset_upload ->
        %{
          "asset_id" => "installer",
          "filename" => "installer.ipxe",
          "size" => 42,
          "blob_digest" => @revision
        }

      :identity_token_create ->
        %{"token_id" => "token-1", "label" => "automation", "expires_at" => nil}

      :identity_policy_set ->
        %{"policies" => [identity_policy()]}

      :server_settings_config ->
        settings_config()

      :profile_validate ->
        netman_profile()

      :profile_put ->
        netman_profile()

      :profile_patch ->
        %{
          "profile_id" => "office",
          "changes" => [
            %{
              "field" => "gateway",
              "interface" => "eth0",
              "value" => "192.0.2.1"
            }
          ]
        }

      :resolved_config_update ->
        %{"upstreams" => ["1.1.1.1"], "search_domains" => ["example.test"]}

      :runtime_capabilities ->
        %{"capabilities" => ["runtime.services"]}

      :runtime_health ->
        %{"status" => "healthy", "checks" => [%{"name" => "dns", "status" => "healthy"}]}

      :runtime_stats ->
        %{"requests" => 10, "errors" => 0}

      :dns_metrics ->
        %{"queries" => 10, "failures" => 0}

      :dns_import_result ->
        %{
          "view_name" => "default",
          "zone_name" => "example.test",
          "imported_records" => 4,
          "revision" => @revision
        }

      :dns_sync_result ->
        %{
          "view_name" => "default",
          "zone_name" => "example.test",
          "changed_records" => 2,
          "revision" => @revision
        }

      :dhcp_status ->
        %{"family" => "ipv4", "status" => "running"}

      :mdns_cache ->
        %{"entries" => [%{"name" => "printer.local", "type" => "A", "values" => ["192.0.2.20"]}]}

      :effective_settings ->
        %{"service" => "dns", "entries" => [setting_entry()]}

      :settings_source ->
        %{"service" => "dns", "source" => "managed"}

      :settings_revision ->
        %{"service" => "dns", "revision" => @revision}

      :settings_validation ->
        %{"service" => "dns", "valid" => true, "errors" => []}

      :apply_mode ->
        %{"mode" => "managed"}

      :reconciliation_health ->
        %{"status" => "healthy", "pending_changes" => 0}

      :profile_revision ->
        %{"profile_id" => "office", "revision" => @revision}

      :network_connection_state ->
        %{"connection_id" => "uplink", "state" => "activated"}

      :resolved_cache ->
        %{
          "entries" => [
            %{"domain" => "example.test", "address" => "192.0.2.10", "expires_at" => @observed_at}
          ]
        }

      :resolved_counters ->
        %{"hits" => 5, "misses" => 1}

      :dhcp_client_fsm ->
        %{"connection_id" => "uplink", "state" => "bound"}

      :vpn_resolved_profile ->
        %{"profile_id" => "vpn-default", "state" => "resolved"}

      :service_command_result ->
        %{"service" => "dns", "state" => "running"}

      :revisioned_resource ->
        %{
          "resource_type" => "dns_view",
          "resource_id" => "default",
          "revision" => @revision,
          "resource" => dns_view()
        }

      :deleted_resource ->
        %{
          "resource_type" => "dns_view",
          "resource_id" => "default",
          "resource_ref" => %{"view_name" => "default"},
          "revision" => @revision
        }

      :lease_release_result ->
        %{
          "family" => "ipv4",
          "lease_id" => "lease-1",
          "address" => "192.0.2.20",
          "released" => true
        }

      :cache_clear_result ->
        %{"cleared_entries" => 4}

      :netboot_asset ->
        netboot_asset()

      :netboot_asset_rescan_result ->
        %{"scope" => "all", "discovered_assets" => 2}

      :identity_token_create_result ->
        %{"token_id" => "token-1", "secret" => "one-time-token", "expires_at" => nil}

      :profile_validation ->
        %{"profile_id" => "office", "valid" => true, "errors" => []}

      :profile_activation_result ->
        %{"profile_id" => "office", "revision" => @revision, "state" => "activated"}

      :connection_activation_result ->
        %{"connection_id" => "uplink", "state" => "activated"}

      :config_state ->
        config_state()
    end
  end

  def depth_limit_payload do
    %{
      "service" => "dns",
      "entries" => [
        %{
          "key" => "nested",
          "value" => %{
            "type" => "object",
            "entries" => [
              %{
                "key" => "leaf",
                "value" => %{"type" => "list", "items" => ["value"]}
              }
            ]
          }
        }
      ]
    }
  end

  def valid_result(name, :revisioned_resource) do
    {resource_type, resource_id, resource} = operation_resource(name)

    %{
      "resource_type" => resource_type,
      "resource_id" => resource_id,
      "revision" => @revision,
      "resource" => resource
    }
  end

  def valid_result(name, :deleted_resource) do
    {resource_type, resource_id, resource} = operation_resource(name)

    %{
      "resource_type" => resource_type,
      "resource_id" => resource_id,
      "resource_ref" => resource_ref(resource_type, resource),
      "revision" => @revision
    }
  end

  def valid_result(_name, schema), do: valid(schema)

  def resource_domains do
    [
      {"dns_view", "default", dns_view()},
      {"dns_zone", "example.test", dns_zone()},
      {"dns_record", "www-a", dns_record()},
      {"dns_acl", "trusted", dns_acl()},
      {"dns_provider", "route53", dns_provider()},
      {"dhcp_pool", "office", dhcp_pool()},
      {"mdns_service", "printer", mdns_service()},
      {"netboot_profile", "linux", netboot_profile()},
      {"netboot_device", "device-1", netboot_device()},
      {"netboot_asset", "installer", netboot_asset()},
      {"identity_host", "host-1", list_item(:identity_host_list)},
      {"identity_token", "token-1", list_item(:identity_token_list)},
      {"identity_policy", "default", identity_policy()},
      {"netman_profile", "office", netman_profile()}
    ]
  end

  defp list_item(:service_list), do: %{"service" => "dns", "state" => "running"}
  defp list_item(:dns_view_list), do: dns_view()
  defp list_item(:dns_zone_list), do: dns_zone()
  defp list_item(:dns_record_list), do: dns_record()
  defp list_item(:dns_acl_list), do: dns_acl()
  defp list_item(:dns_provider_list), do: dns_provider()

  defp list_item(:dns_log_list),
    do: %{
      "log_id" => "log-1",
      "query_name" => "example.test",
      "action" => "answered",
      "occurred_at" => @observed_at
    }

  defp list_item(:dhcp_pool_list), do: dhcp_pool()

  defp list_item(:dhcp_lease_list),
    do: %{
      "family" => "ipv4",
      "lease_id" => "lease-1",
      "address" => "192.0.2.20",
      "state" => "active"
    }

  defp list_item(:dhcp_activity_list),
    do: %{
      "activity_id" => "activity-1",
      "family" => "ipv4",
      "action" => "lease_granted",
      "occurred_at" => @observed_at
    }

  defp list_item(:mdns_service_list), do: mdns_service()

  defp list_item(:mdns_discovery_list),
    do: %{"name" => "printer.local", "service_type" => "_ipp._tcp", "address" => "192.0.2.20"}

  defp list_item(:mdns_monitor_list),
    do: %{
      "event_id" => "event-1",
      "name" => "printer.local",
      "action" => "discovered",
      "occurred_at" => @observed_at
    }

  defp list_item(:netboot_profile_list), do: netboot_profile()
  defp list_item(:netboot_device_list), do: netboot_device()
  defp list_item(:netboot_asset_list), do: netboot_asset()

  defp list_item(:netboot_transfer_list),
    do: %{
      "transfer_id" => "transfer-1",
      "asset_id" => "installer",
      "device_id" => "device-1",
      "state" => "completed"
    }

  defp list_item(:netboot_log_list),
    do: %{
      "log_id" => "log-1",
      "device_id" => "device-1",
      "message" => "served",
      "occurred_at" => @observed_at
    }

  defp list_item(:identity_host_list),
    do: %{"host_id" => "host-1", "name" => "edge", "state" => "approved", "revision" => @revision}

  defp list_item(:identity_approval_list),
    do: %{"approval_id" => "approval-1", "host_id" => "host-1", "state" => "approved"}

  defp list_item(:identity_token_list),
    do: %{"token_id" => "token-1", "label" => "automation", "state" => "active"}

  defp list_item(:identity_audit_list),
    do: %{
      "audit_id" => "audit-1",
      "action" => "host_approved",
      "subject_id" => "host-1",
      "occurred_at" => @observed_at
    }

  defp list_item(:profile_list), do: netman_profile()

  defp list_item(:profile_history),
    do: %{"profile_id" => "office", "revision" => @revision, "activated_at" => @observed_at}

  defp list_item(:network_link_list),
    do: %{"link_id" => "eth0", "name" => "eth0", "state" => "up"}

  defp list_item(:network_address_list),
    do: %{"link_id" => "eth0", "address" => "192.0.2.10/24", "scope" => "global"}

  defp list_item(:network_route_list),
    do: %{"destination" => "0.0.0.0/0", "gateway" => "192.0.2.1", "link_id" => "eth0"}

  defp list_item(:resolved_upstream_list), do: %{"address" => "1.1.1.1", "source" => "managed"}

  defp list_item(:resolved_search_domain_list),
    do: %{"domain" => "example.test", "routing_only" => false}

  defp list_item(:dhcp_client_lease_list),
    do: %{"connection_id" => "uplink", "address" => "192.0.2.10", "expires_at" => @observed_at}

  defp dns_record_ref,
    do: %{"view_name" => "default", "zone_name" => "example.test", "record_id" => "www-a"}

  defp dns_view,
    do: %{"view_name" => "default", "match_clients" => ["0.0.0.0/0"], "recursion" => false}

  defp dns_zone,
    do: %{
      "view_name" => "default",
      "zone_name" => "example.test",
      "zone_type" => "authoritative",
      "provider_id" => nil
    }

  defp dns_record,
    do:
      Map.merge(dns_record_ref(), %{
        "name" => "www",
        "type" => "A",
        "ttl" => 300,
        "values" => ["192.0.2.10"]
      })

  defp dns_acl, do: %{"acl_id" => "trusted", "networks" => ["192.0.2.0/24"], "action" => "allow"}

  defp dns_provider,
    do: %{
      "provider_id" => "route53",
      "provider_type" => "route53",
      "endpoint" => nil,
      "credential_ref" => "secret-1"
    }

  defp dhcp_pool,
    do: %{
      "family" => "ipv4",
      "pool_id" => "office",
      "subnet" => "192.0.2.0/24",
      "start_address" => "192.0.2.20",
      "end_address" => "192.0.2.100",
      "lease_seconds" => 3600
    }

  defp mdns_service,
    do: %{
      "service_id" => "printer",
      "name" => "Printer",
      "service_type" => "_ipp._tcp",
      "service_port" => 631,
      "txt" => [%{"key" => "note", "value" => "Office"}]
    }

  defp netboot_profile,
    do: %{
      "profile_id" => "linux",
      "name" => "Linux",
      "boot_asset_id" => "installer",
      "arguments" => ["console=tty0"]
    }

  defp netboot_device,
    do: %{"device_id" => "device-1", "profile_id" => "linux", "mac" => "02:00:00:00:00:01"}

  defp netboot_asset,
    do: %{
      "asset_id" => "installer",
      "filename" => "installer.ipxe",
      "size" => 42,
      "blob_digest" => @revision
    }

  defp identity_policy,
    do: %{"policy_id" => "default", "action" => "require_approval", "enabled" => true}

  defp netman_profile,
    do: %{
      "profile_id" => "office",
      "name" => "Office",
      "interfaces" => [
        %{
          "name" => "eth0",
          "method" => "static",
          "addresses" => ["192.0.2.10/24"],
          "gateway" => "192.0.2.1"
        }
      ]
    }

  defp setting_entry,
    do: %{"key" => "listen", "value" => %{"type" => "string", "value" => "0.0.0.0"}}

  defp settings_config, do: %{"service" => "dns", "entries" => [setting_entry()]}

  defp config_state do
    %{
      "state" => "applied",
      "version" => 1,
      "digest" => @revision,
      "applied_revision" => @revision,
      "previous_version" => nil,
      "previous_revision" => nil,
      "failure" => nil,
      "rollback" => nil
    }
  end

  defp operation_resource(name) do
    cond do
      String.contains?(name, ".dns.views.") ->
        {"dns_view", "default", dns_view()}

      String.contains?(name, ".dns.zones.") or String.contains?(name, ".dns.conflicts.") ->
        {"dns_zone", "example.test", dns_zone()}

      String.contains?(name, ".dns.records.") ->
        {"dns_record", "www-a", dns_record()}

      String.contains?(name, ".dns.acls.") ->
        {"dns_acl", "trusted", dns_acl()}

      String.contains?(name, ".dns.providers.") ->
        {"dns_provider", "route53", dns_provider()}

      String.contains?(name, ".dhcp.pools.") ->
        {"dhcp_pool", "office", dhcp_pool()}

      String.contains?(name, ".mdns.services.") ->
        {"mdns_service", "printer", mdns_service()}

      String.contains?(name, ".netboot.profiles.") ->
        {"netboot_profile", "linux", netboot_profile()}

      String.contains?(name, ".netboot.devices.") ->
        {"netboot_device", "device-1", netboot_device()}

      String.contains?(name, ".netboot.assets.") ->
        {"netboot_asset", "installer", netboot_asset()}

      String.contains?(name, ".identity.hosts.") ->
        {"identity_host", "host-1", list_item(:identity_host_list)}

      String.contains?(name, ".identity.tokens.") ->
        {"identity_token", "token-1", list_item(:identity_token_list)}

      String.contains?(name, ".identity.policies.") ->
        {"identity_policy", "default", identity_policy()}

      String.contains?(name, ".profiles.") ->
        {"netman_profile", "office", netman_profile()}
    end
  end

  defp resource_ref("dns_view", resource), do: Map.take(resource, ["view_name"])
  defp resource_ref("dns_zone", resource), do: Map.take(resource, ["view_name", "zone_name"])

  defp resource_ref("dns_record", resource),
    do: Map.take(resource, ["view_name", "zone_name", "record_id"])

  defp resource_ref("dns_acl", resource), do: Map.take(resource, ["acl_id"])
  defp resource_ref("dns_provider", resource), do: Map.take(resource, ["provider_id"])
  defp resource_ref("dhcp_pool", resource), do: Map.take(resource, ["family", "pool_id"])
  defp resource_ref("mdns_service", resource), do: Map.take(resource, ["service_id"])
  defp resource_ref("netboot_profile", resource), do: Map.take(resource, ["profile_id"])
  defp resource_ref("netboot_device", resource), do: Map.take(resource, ["device_id"])
  defp resource_ref("netboot_asset", resource), do: Map.take(resource, ["asset_id"])
  defp resource_ref("identity_host", resource), do: Map.take(resource, ["host_id"])
  defp resource_ref("identity_token", resource), do: Map.take(resource, ["token_id"])
  defp resource_ref("identity_policy", resource), do: Map.take(resource, ["policy_id"])
  defp resource_ref("netman_profile", resource), do: Map.take(resource, ["profile_id"])
end

defmodule YellowDog.Sync.ServerOperationTest do
  use ExUnit.Case, async: false

  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation
  alias YellowDog.Sync.ServerOperation
  alias YellowDog.Sync.OperationSchemaFixtures, as: Fixtures

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

      assert {:ok, _payload} =
               Operation.validate_payload(operation, Fixtures.valid(payload_schema))

      assert {:ok, _result} =
               Operation.validate_result(operation, Fixtures.valid_result(name, result_schema))
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

  test "Netboot asset schemas accept normalized relative filenames" do
    filename = "images/installer.img"
    payload = Map.put(Fixtures.valid(:netboot_asset_upload), "filename", filename)
    asset = Map.put(Fixtures.valid(:netboot_asset), "filename", filename)
    list_result = %{Fixtures.valid(:netboot_asset_list) | "items" => [asset]}

    assert {:ok, ^payload} =
             Operation.validate_payload(
               "server.netboot.assets.upload",
               :server,
               :command,
               payload
             )

    assert {:ok, ^asset} =
             Operation.validate_result("server.netboot.assets.upload", :server, :command, asset)

    assert {:ok, ^list_result} =
             Operation.validate_result(
               "server.netboot.assets.list",
               :server,
               :query,
               list_result
             )
  end

  test "Netboot asset schemas reject unsafe or non-normalized relative filenames" do
    payload = Fixtures.valid(:netboot_asset_upload)
    list_result = Fixtures.valid(:netboot_asset_list)
    non_normalized = "images/cafe" <> <<0xCC, 0x81>> <> ".img"

    invalid_filenames = [
      "/images/installer.img",
      "C:/images/installer.img",
      "\\\\server\\share\\installer.img",
      "images\\installer.img",
      "images/\0installer.img",
      "images/\tinstaller.img",
      "",
      ".",
      "..",
      "./installer.img",
      "../installer.img",
      "images/../installer.img",
      "images//installer.img",
      "images/installer.img/",
      non_normalized,
      String.duplicate("x", 1_025)
    ]

    for filename <- invalid_filenames do
      invalid_payload = Map.put(payload, "filename", filename)
      invalid_asset = Map.put(hd(list_result["items"]), "filename", filename)
      invalid_list_result = %{list_result | "items" => [invalid_asset]}

      assert_invalid(
        Operation.validate_payload(
          "server.netboot.assets.upload",
          :server,
          :command,
          invalid_payload
        )
      )

      assert_invalid(
        Operation.validate_result(
          "server.netboot.assets.list",
          :server,
          :query,
          invalid_list_result
        )
      )
    end
  end

  test "generic filenames remain leaf names" do
    zone_import = Fixtures.valid(:dns_zone_import)

    assert {:ok, ^zone_import} = Operation.validate_schema(:dns_zone_import, zone_import)

    assert_invalid(
      Operation.validate_schema(
        :dns_zone_import,
        Map.put(zone_import, "filename", "images/installer.img")
      )
    )
  end

  test "blob metadata schemas reject cross-domain payloads" do
    dns_import = Fixtures.valid(:dns_zone_import)
    asset_upload = Fixtures.valid(:netboot_asset_upload)

    assert_invalid(Operation.validate_schema(:dns_zone_import, asset_upload))
    assert_invalid(Operation.validate_schema(:netboot_asset_upload, dns_import))
  end

  test "every catalog schema has a strict valid missing extraneous and malformed shape" do
    schemas = Fixtures.schemas()
    assert length(schemas) == 136

    for schema <- schemas do
      valid = Fixtures.valid(schema)
      assert {:ok, ^valid} = Operation.validate_schema(schema, valid)
      assert_invalid(Operation.validate_schema(schema, Map.put(valid, "unexpected", true)))

      if map_size(valid) > 0 do
        first_key = valid |> Map.keys() |> Enum.sort() |> hd()
        assert_invalid(Operation.validate_schema(schema, Map.delete(valid, first_key)))
        assert_invalid(Operation.validate_schema(schema, Map.put(valid, first_key, make_ref())))
      else
        assert_invalid(Operation.validate_schema(schema, []))
      end
    end
  end

  test "forbidden transport keys and values are rejected at any nesting level" do
    profile = Fixtures.valid(:profile_put)

    for forbidden <- [
          "expected_revision",
          "path",
          "file",
          "pathname",
          "pid",
          "ref",
          "ets",
          "table",
          "kernel_handle",
          "manager_handle",
          "blob",
          "content",
          "bytes",
          "data"
        ] do
      nested = put_in(profile, ["interfaces", Access.at(0), forbidden], "forbidden")
      assert_invalid(Operation.validate_schema(:profile_put, nested))
    end

    port = Port.open({:spawn, "cat"}, [])

    try do
      for forbidden_value <- [self(), make_ref(), port] do
        malformed = put_in(profile, ["interfaces", Access.at(0), "gateway"], forbidden_value)
        assert_invalid(Operation.validate_schema(:profile_put, malformed))
      end
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  test "forbidden transport names are case and separator insensitive" do
    for forbidden <- [
          "Path",
          "localPath",
          "local_path",
          "expected-revision",
          "Content",
          "blob_bytes",
          "etsTable",
          "managerHandle"
        ] do
      assert_invalid(Operation.validate_transport(%{forbidden => "forbidden"}))
    end
  end

  test "settings reject semantic transport names local paths and recursively oversized integers" do
    huge_integer = String.to_integer(String.duplicate("9", 1_001))

    for forbidden_name <- [
          "local_path",
          "path",
          "expected_revision",
          "content",
          "blob",
          "bytes",
          "pid",
          "ref",
          "port",
          "ets_table",
          "table",
          "kernel_handle",
          "manager_handle",
          "pidFile",
          "resource_ref",
          "listen_port",
          "blobDigest"
        ] do
      payload = %{
        "service" => "dns",
        "entries" => [
          %{"key" => forbidden_name, "value" => %{"type" => "string", "value" => "value"}}
        ]
      }

      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end

    invalid_entries = [
      %{"key" => "local_path", "value" => %{"type" => "string", "value" => "/etc/shadow"}},
      %{"key" => "expected_revision", "value" => %{"type" => "string", "value" => digest()}},
      %{"key" => "Path", "value" => %{"type" => "string", "value" => "relative"}},
      %{"key" => "Content", "value" => %{"type" => "string", "value" => "raw"}},
      %{"key" => "shadow_file", "value" => %{"type" => "string", "value" => "/etc/shadow"}},
      %{"key" => "nested", "value" => %{"type" => "list", "items" => [huge_integer]}},
      %{
        "key" => "nested",
        "value" => %{
          "type" => "object",
          "entries" => [
            %{"key" => "limit", "value" => %{"type" => "integer", "value" => huge_integer}}
          ]
        }
      }
    ]

    for entry <- invalid_entries do
      payload = %{"service" => "dns", "entries" => [entry]}
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end
  end

  test "typed identifiers and provider metadata reject local paths" do
    probes = [
      {:service_ref, %{"service" => "/etc/shadow"}},
      {:connection_ref, %{"connection_id" => "C:\\Windows\\System32"}},
      {:dns_provider_write,
       %{
         "provider_id" => "route53",
         "provider_type" => "route53",
         "endpoint" => "/etc/yellow-dog/provider",
         "credential_ref" => "secret-1"
       }},
      {:dns_zone_import,
       %{
         "view_name" => "default",
         "zone_name" => "example.test",
         "source_type" => "snapshot",
         "source_id" => "../snapshot.zone",
         "source_revision" => digest()
       }}
    ]

    for {schema, value} <- probes do
      assert_invalid(Operation.validate_schema(schema, value))
    end

    provider = %{
      "provider_id" => "route53",
      "provider_type" => "route53",
      "endpoint" => "https://provider.example.test/api/v1",
      "credential_ref" => "secret-1"
    }

    assert {:ok, ^provider} = Operation.validate_schema(:dns_provider_write, provider)
  end

  test "settings use Unicode-aware semantic and path validation with URI and CIDR exceptions" do
    fullwidth_path = IO.iodata_to_binary(["p", <<0xFF41::utf8>>, "th"])
    fullwidth_slash = <<0xFF0F::utf8>>

    forbidden_names = [
      "expectedRevision",
      "localPath",
      "payloadBody",
      "blobBytes",
      "managerHandle",
      fullwidth_path
    ]

    for name <- forbidden_names do
      payload = setting_payload(name, %{"type" => "string", "value" => "value"})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end

    forbidden_values = [
      "/etc/shadow",
      "C:\\Windows\\System32",
      "\\\\server\\share\\config",
      "../snapshot.zone",
      fullwidth_slash <> "etc" <> fullwidth_slash <> "shadow",
      "-----BEGIN PRIVATE KEY-----\nraw\n-----END PRIVATE KEY-----",
      "-----BEGIN CERTIFICATE-----\nraw\n-----END CERTIFICATE-----"
    ]

    for value <- forbidden_values do
      payload = setting_payload("safe_setting", %{"type" => "string", "value" => value})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end

    valid = %{
      "service" => "dns",
      "entries" => [
        %{
          "key" => "api_uri",
          "value" => %{"type" => "string", "value" => "https://api.example.test/v1/config"}
        },
        %{
          "key" => "allowed_cidr",
          "value" => %{"type" => "string", "value" => "192.0.2.0/24"}
        },
        %{
          "key" => "allowed_ipv6_cidr",
          "value" => %{"type" => "string", "value" => "2001:db8::/64"}
        }
      ]
    }

    assert {:ok, ^valid} = Operation.validate_schema(:server_settings_config, valid)
  end

  test "settings reject raw material names and non-printable string content" do
    fullwidth_raw = IO.iodata_to_binary(["r", <<0xFF41::utf8>>, "wPayload"])

    forbidden_names = [
      "rawPayload",
      "raw_payload",
      "raw-payload",
      "payloads",
      "contents",
      "blobs",
      "blobstore",
      "bodies",
      "byteBuffer",
      "tlsCert",
      "rawdata",
      "certificates",
      "payload_body",
      "tls_certificate",
      "privateKey",
      "certificateBytes",
      "rawpayload",
      "payloadbody",
      "blobcontent",
      "blobdata",
      "blobbytes",
      "certificatebytes",
      "payloadstore",
      "tls_pem",
      fullwidth_raw
    ]

    for name <- forbidden_names do
      payload = setting_payload(name, %{"type" => "string", "value" => "YWJjZA=="})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end

    for value <- [<<0, 1, 2, 3>>, "printable\ncontrol", "tab\tcontrol", <<0x7F>>] do
      payload = setting_payload("ordinary_setting", %{"type" => "string", "value" => value})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end

    valid_values = [
      "ordinary printable value",
      "https://api.example.test/v1",
      "192.0.2.0/24",
      "example.test",
      "identifier-1",
      "database-primary"
    ]

    for value <- valid_values do
      payload = setting_payload("ordinary_setting", %{"type" => "string", "value" => value})
      assert {:ok, ^payload} = Operation.validate_schema(:server_settings_config, payload)
    end

    valid_references = [
      setting_payload("private_network", %{"type" => "boolean", "value" => true}),
      setting_payload("payloads", %{"type" => "boolean", "value" => false}),
      setting_payload("rawpayload", %{"type" => "integer", "value" => 2}),
      setting_payload("blobcontent", %{"type" => "null", "value" => nil}),
      setting_payload("data", %{"type" => "string", "value" => "ordinary data label"}),
      setting_payload("certificate_authority_uri", %{
        "type" => "string",
        "value" => "https://ca.example.test/certificate"
      }),
      setting_payload("payload_digest", %{"type" => "string", "value" => digest()}),
      setting_payload("blob_ref", %{"type" => "string", "value" => "blob-1"})
    ]

    for payload <- valid_references do
      assert {:ok, ^payload} = Operation.validate_schema(:server_settings_config, payload)
    end

    invalid_references = [
      setting_payload("certificate_authority_uri", %{
        "type" => "string",
        "value" => "YWJjZA=="
      }),
      setting_payload("certificate_authority_uri", %{
        "type" => "string",
        "value" => "HTTPS://ca.example.test/certificate"
      }),
      setting_payload("payload_digest", %{"type" => "string", "value" => "not-a-digest"}),
      setting_payload("blobdigest", %{"type" => "string", "value" => "not-a-digest"}),
      setting_payload("contenturi", %{"type" => "string", "value" => "YWJjZA=="}),
      setting_payload("blob_ref", %{"type" => "string", "value" => "/etc/blob"}),
      setting_payload("content_uri", %{"type" => "list", "items" => ["https://example.test"]})
    ]

    for payload <- invalid_references do
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end

    noncanonical_references = [
      setting_payload("blobdigest", %{"type" => "string", "value" => digest()}),
      setting_payload("contenturi", %{
        "type" => "string",
        "value" => "https://content.example.test/reference"
      })
    ]

    for payload <- noncanonical_references do
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end
  end

  test "setting material grammar rejects aliases and non-reference suffix words" do
    forbidden_names = [
      "payload_valid",
      "certificate_grid",
      "tlsKey",
      "secretKey",
      "signingKey",
      "privatekey",
      "tlskey",
      "secretkey",
      "signingkey",
      "pkcs12",
      "pfx"
    ]

    for name <- forbidden_names do
      payload = setting_payload(name, %{"type" => "string", "value" => "YWJjZA=="})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end
  end

  test "setting material grammar normalizes plural private-key and PKCS12 aliases" do
    forbidden_names = [
      "privateKeys",
      "privatekeys",
      "tls_keys",
      "tlskeys",
      "secretkeys",
      "signingkeys",
      "pkcs-12"
    ]

    for name <- forbidden_names do
      payload = setting_payload(name, %{"type" => "string", "value" => "YWJjZA=="})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end

    invalid_references = [
      setting_payload("tlskeyref", %{"type" => "string", "value" => ""}),
      setting_payload("privatekeydigest", %{
        "type" => "string",
        "value" => "not-a-digest"
      })
    ]

    for payload <- invalid_references do
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end
  end

  test "setting material grammar accepts canonical plural references only" do
    uri = "https://content.example.test/reference"

    valid_references = [
      {"payloads_uri", uri},
      {"contents_digest", digest()},
      {"blobs_ref", "blob-1"},
      {"certificates_uri", uri}
    ]

    for {name, value} <- valid_references do
      payload = setting_payload(name, %{"type" => "string", "value" => value})
      assert {:ok, ^payload} = Operation.validate_schema(:server_settings_config, payload)
    end

    for {name, value} <- [
          {"payloadsuri", uri},
          {"payloadsUri", uri},
          {"contentsdigest", digest()},
          {"contentsDigest", digest()},
          {"blobsref", "blob-1"},
          {"blobsRef", "blob-1"},
          {"certificatesuri", uri},
          {"certificatesUri", uri}
        ] do
      payload = setting_payload(name, %{"type" => "string", "value" => value})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end
  end

  test "setting material grammar accepts canonical tokenized references only" do
    invalid_references = [
      {"privatekey_digest", "not-a-digest"},
      {"privatekeys_digest", "not-a-digest"},
      {"tlskey_uri", "YWJjZA=="},
      {"blobstore_uri", "YWJjZA=="},
      {"rawdataDigest", "not-a-digest"},
      {"certificatebytes_hash", "not-a-digest"},
      {"tlskeyreference", ""}
    ]

    for {name, value} <- invalid_references do
      payload = setting_payload(name, %{"type" => "string", "value" => value})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end

    uri = "https://config.example.test/material/reference"

    valid_references = [
      {"privatekey_digest", digest()},
      {"privatekeys_digest", digest()},
      {"tlskey_uri", uri},
      {"blobstore_uri", uri},
      {"certificatebytes_hash", digest()},
      {"tlskey_ref", "tls-key-1"},
      {"blobstore_ref", "blob-store-1"}
    ]

    for {name, value} <- valid_references do
      payload = setting_payload(name, %{"type" => "string", "value" => value})
      assert {:ok, ^payload} = Operation.validate_schema(:server_settings_config, payload)
    end

    for {name, value} <- [
          {"rawdataDigest", digest()},
          {"tlskeyreference", "tls-key-1"}
        ] do
      payload = setting_payload(name, %{"type" => "string", "value" => value})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end
  end

  test "setting material grammar normalizes PEM and PFX acronym plurals" do
    for name <- ["PEMs", "PFXs"] do
      payload = setting_payload(name, %{"type" => "string", "value" => "YWJjZA=="})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end
  end

  test "setting material grammar detects wrapped material tokens" do
    forbidden_names = [
      "request_payload_cache",
      "server_certificate_bundle",
      "client_tls_key_store",
      "archive_pfx_bundle",
      "tls_pem_bundle"
    ]

    for name <- forbidden_names do
      payload = setting_payload(name, %{"type" => "string", "value" => "YWJjZA=="})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end
  end

  test "setting material grammar validates wrapped typed references" do
    invalid_references = [
      {"request_payload_cache_digest", "not-a-digest"},
      {"client_tls_key_digest", "not-a-digest"},
      {"client_secret_key_uri", "YWJjZA=="},
      {"client_private_key_digest", "not-a-digest"},
      {"backup_blob_store_uri", "YWJjZA=="},
      {"request_payload_cache_id", ""}
    ]

    for {name, value} <- invalid_references do
      payload = setting_payload(name, %{"type" => "string", "value" => value})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end

    for {name, value} <- [
          {"request_payload_cache_digest", %{"type" => "boolean", "value" => true}},
          {"client_tls_key_ref", %{"type" => "integer", "value" => 1}}
        ] do
      payload = setting_payload(name, value)
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end

    for {name, value} <- [
          {"client_tls_key_ref", "client-tls-key-1"},
          {"request_payload_cache_ref", "request-payload-cache-1"}
        ] do
      payload = setting_payload(name, %{"type" => "string", "value" => value})
      assert {:ok, ^payload} = Operation.validate_schema(:server_settings_config, payload)
    end
  end

  test "setting keys require canonical lowercase snake case on the wire" do
    noncanonical_keys = [
      "archive_PFXs_bundle",
      "tls_PEMs_bundle",
      "archivePFXsBundle",
      "archive_PFXs_digest",
      "Payload",
      "payload-key",
      "payload__cache",
      "payload_",
      "_payload",
      "ｐayload",
      "payload_缓存"
    ]

    for name <- noncanonical_keys do
      payload = setting_payload(name, %{"type" => "boolean", "value" => true})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end
  end

  test "setting keys reject glued reference suffixes" do
    uri = "https://config.example.test/material/reference"

    for {name, value} <- [
          {"client_tls_keyref", "client-key-1"},
          {"client_tls_keydigest", digest()},
          {"client_secret_keyuri", uri},
          {"client_privatekeydigest", digest()},
          {"request_payload_cachedigest", digest()}
        ] do
      payload = setting_payload(name, %{"type" => "string", "value" => value})
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end
  end

  test "canonical material references validate typed values" do
    uri = "https://config.example.test/material/reference"

    valid_references = [
      {"client_tls_key_ref", "client-key-1"},
      {"client_tls_key_digest", digest()},
      {"client_secret_key_uri", uri},
      {"client_private_key_digest", digest()},
      {"request_payload_cache_digest", digest()},
      {"archive_pfxs_ref", "archive-pfx-1"}
    ]

    for {name, value} <- valid_references do
      payload = setting_payload(name, %{"type" => "string", "value" => value})
      assert {:ok, ^payload} = Operation.validate_schema(:server_settings_config, payload)
    end

    for payload <- [
          setting_payload("archive_pfxs_ref", %{"type" => "string", "value" => ""}),
          setting_payload("archive_pfxs_ref", %{
            "type" => "string",
            "value" => "/etc/archive.pfx"
          }),
          setting_payload("archive_pfxs_bundle", %{
            "type" => "string",
            "value" => "YWJjZA=="
          }),
          setting_payload("tls_pems_bundle", %{
            "type" => "string",
            "value" => "YWJjZA=="
          })
        ] do
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end
  end

  test "canonical PKCS 12 token sequences enforce material reference rules" do
    uri = "https://config.example.test/material/archive"

    for payload <- [
          setting_payload("pkcs_12", %{"type" => "string", "value" => "YWJjZA=="}),
          setting_payload("archive_pkcs_12_bundle", %{
            "type" => "string",
            "value" => "YWJjZA=="
          }),
          setting_payload("archive_pkcs_12_digest", %{
            "type" => "string",
            "value" => "not-a-digest"
          }),
          setting_payload("archive_pkcs_12_uri", %{
            "type" => "string",
            "value" => "YWJjZA=="
          }),
          setting_payload("archive_pkcs_12_id", %{"type" => "string", "value" => ""}),
          setting_payload("archive_pkcs_12_ref", %{"type" => "string", "value" => ""}),
          setting_payload("archive_pkcs_12_ref", %{
            "type" => "string",
            "value" => "/etc/archive.p12"
          })
        ] do
      assert_invalid(Operation.validate_schema(:server_settings_config, payload))
    end

    for {name, value} <- [
          {"archive_pkcs_12_digest", digest()},
          {"archive_pkcs_12_uri", uri},
          {"archive_pkcs_12_id", "archive-pkcs12-1"},
          {"archive_pkcs_12_ref", "archive-pkcs12-1"}
        ] do
      payload = setting_payload(name, %{"type" => "string", "value" => value})
      assert {:ok, ^payload} = Operation.validate_schema(:server_settings_config, payload)
    end
  end

  test "setting material grammar allows unrelated names with interior root text" do
    for name <- ["scope_mode", "type_map", "drawing_mode", "uncertainty_mode"] do
      payload = setting_payload(name, %{"type" => "string", "value" => "enabled"})
      assert {:ok, ^payload} = Operation.validate_schema(:server_settings_config, payload)
    end

    private_network = setting_payload("private_network", %{"type" => "boolean", "value" => true})

    certificate_uri =
      setting_payload("certificate_authority_uri", %{
        "type" => "string",
        "value" => "https://ca.example.test/certificate"
      })

    assert {:ok, ^private_network} =
             Operation.validate_schema(:server_settings_config, private_network)

    assert {:ok, ^certificate_uri} =
             Operation.validate_schema(:server_settings_config, certificate_uri)
  end

  test "provider endpoints require canonical usable HTTP or HTTPS URIs" do
    base = %{
      "provider_id" => "route53",
      "provider_type" => "route53",
      "endpoint" => nil,
      "credential_ref" => "secret-1"
    }

    valid_endpoints = [
      "https://provider.example.test/api/v1",
      "http://192.0.2.10:8080/provider",
      "https://[2001:db8::10]:8443/provider",
      "https://provider.example.test/api/v1?mode=full&active=true"
    ]

    for endpoint <- valid_endpoints do
      provider = %{base | "endpoint" => endpoint}
      assert {:ok, ^provider} = Operation.validate_schema(:dns_provider_write, provider)
    end

    fullwidth_endpoint =
      IO.iodata_to_binary([
        "https",
        <<0xFF1A::utf8>>,
        <<0xFF0F::utf8>>,
        <<0xFF0F::utf8>>,
        "provider.example.test"
      ])

    fullwidth_traversal =
      IO.iodata_to_binary([
        "https://provider.example.test/a/",
        <<0xFF0E::utf8>>,
        <<0xFF0E::utf8>>,
        <<0xFF0F::utf8>>,
        "config"
      ])

    invalid_endpoints = [
      fullwidth_endpoint,
      fullwidth_traversal,
      "/etc/yellow-dog/provider",
      "ftp://provider.example.test/config",
      "HTTPS://provider.example.test/config",
      "https://user:secret@provider.example.test/config",
      "https://",
      "https://.",
      "https://bad..example.test",
      "https://-bad.example.test",
      "https://bad-.example.test",
      "https://999.999.999.999/config",
      "https://provider.example.test:0/config",
      "https://provider.example.test:65536/config",
      "https://provider.example.test:invalid/config",
      "https://provider.example.test:/config",
      "https://provider.example.test/%ZZ",
      "https://provider.example.test/%2fconfig",
      "https://provider.example.test/%41",
      "https://provider.example.test/%7E",
      "https://provider.example.test/%00",
      "https://provider.example.test/%0A",
      "https://provider.example.test/%7F",
      "https://provider.example.test/config?value=%41",
      "https://provider.example.test/%2E/config",
      "https://provider.example.test/%2E%2E/config",
      "https://provider.example.test/./config",
      "https://provider.example.test/../config",
      "https://provider.example.test/a/../config",
      "https://provider.example.test/a/./config",
      "https://provider.example.test/a\\config",
      "https://provider.example.test/config#fragment",
      "https://provider example.test/config",
      "https://provider.example.test/white space"
    ]

    for endpoint <- invalid_endpoints do
      assert_invalid(
        Operation.validate_schema(:dns_provider_write, %{base | "endpoint" => endpoint})
      )
    end
  end

  test "DHCP pool address families are coherent" do
    ipv4 = Fixtures.valid(:dhcp_pool_write)

    ipv6 = %{
      ipv4
      | "family" => "ipv6",
        "subnet" => "2001:db8::/64",
        "start_address" => "2001:db8::20",
        "end_address" => "2001:db8::100"
    }

    assert {:ok, ^ipv4} = Operation.validate_schema(:dhcp_pool_write, ipv4)
    assert {:ok, ^ipv6} = Operation.validate_schema(:dhcp_pool_write, ipv6)

    for field <- ["subnet", "start_address", "end_address"] do
      ipv4_mismatch = Map.put(ipv4, field, ipv6[field])
      ipv6_mismatch = Map.put(ipv6, field, ipv4[field])
      assert_invalid(Operation.validate_schema(:dhcp_pool_write, ipv4_mismatch))
      assert_invalid(Operation.validate_schema(:dhcp_pool_write, ipv6_mismatch))
    end
  end

  test "DHCP pools enforce subnet membership and ordered ranges" do
    ipv4 = Fixtures.valid(:dhcp_pool_write)

    ipv6 = %{
      ipv4
      | "family" => "ipv6",
        "subnet" => "2001:db8::/64",
        "start_address" => "2001:db8::20",
        "end_address" => "2001:db8::100"
    }

    invalid = [
      %{ipv4 | "start_address" => "198.51.100.20"},
      %{ipv4 | "end_address" => "198.51.100.100"},
      %{ipv4 | "start_address" => "192.0.2.100", "end_address" => "192.0.2.20"},
      %{ipv6 | "start_address" => "2001:db9::20"},
      %{ipv6 | "end_address" => "2001:db9::100"},
      %{ipv6 | "start_address" => "2001:db8::100", "end_address" => "2001:db8::20"}
    ]

    for pool <- invalid do
      assert_invalid(Operation.validate_schema(:dhcp_pool_write, pool))
    end
  end

  test "DHCP typed lease values enforce family and address coherence" do
    ipv4_result = Fixtures.valid(:lease_release_result)
    ipv6_result = %{ipv4_result | "family" => "ipv6", "address" => "2001:db8::20"}

    assert {:ok, ^ipv4_result} = Operation.validate_schema(:lease_release_result, ipv4_result)
    assert {:ok, ^ipv6_result} = Operation.validate_schema(:lease_release_result, ipv6_result)

    assert_invalid(
      Operation.validate_schema(:lease_release_result, %{
        ipv4_result
        | "address" => "2001:db8::20"
      })
    )

    assert_invalid(
      Operation.validate_schema(:lease_release_result, %{ipv6_result | "address" => "192.0.2.20"})
    )

    lease_list = Fixtures.valid(:dhcp_lease_list)
    [lease] = lease_list["items"]

    for mismatch <- [
          %{lease | "address" => "2001:db8::20"},
          %{lease | "family" => "ipv6", "address" => "192.0.2.20"}
        ] do
      assert_invalid(
        Operation.validate_schema(:dhcp_lease_list, %{lease_list | "items" => [mismatch]})
      )
    end
  end

  test "DNS names enforce total and label bounds and service-label syntax" do
    label63 = String.duplicate("a", 63)
    max_name = Enum.join([label63, label63, label63, String.duplicate("a", 61)], ".")

    for name <- ["example.test", "example.test.", "_ipp._tcp.local", max_name] do
      assert {:ok, _value} =
               Operation.validate_schema(:dns_zone_ref, %{
                 "view_name" => "default",
                 "zone_name" => name
               })
    end

    invalid_names = [
      "",
      ".",
      "..",
      "example..test",
      "example.test..",
      "-bad.test",
      "bad-.test",
      "bad_name.test",
      String.duplicate("a", 64) <> ".test",
      max_name <> "a",
      "white space.test",
      "slash/test",
      "control\n.test"
    ]

    for name <- invalid_names do
      assert_invalid(
        Operation.validate_schema(:dns_zone_ref, %{
          "view_name" => "default",
          "zone_name" => name
        })
      )
    end
  end

  test "DNS records enforce owner and type-specific RDATA grammar" do
    base = Fixtures.valid(:dns_record_write)

    valid = [
      {"A", "www", ["192.0.2.10"]},
      {"AAAA", "www", ["2001:db8::10"]},
      {"CNAME", "alias", ["target.example.test."]},
      {"NS", "@", ["ns1.example.test."]},
      {"PTR", "10", ["host.example.test."]},
      {"MX", "@", ["10 mail.example.test."]},
      {"SRV", "_sip._tcp", ["10 20 5060 sip.example.test."]},
      {"TXT", "_service._tcp", ["bounded text"]}
    ]

    for {type, name, values} <- valid do
      record = %{base | "type" => type, "name" => name, "values" => values}
      assert {:ok, ^record} = Operation.validate_schema(:dns_record_write, record)
    end

    invalid = [
      {"A", "www", ["2001:db8::10"]},
      {"AAAA", "www", ["192.0.2.10"]},
      {"CNAME", "alias", ["not a domain"]},
      {"NS", "@", ["/etc/resolv.conf"]},
      {"PTR", "10", [""]},
      {"MX", "@", ["mail.example.test."]},
      {"MX", "@", ["70000 mail.example.test."]},
      {"SRV", "_sip._tcp", ["arbitrary text"]},
      {"SRV", "_sip._tcp", ["10 20 70000 sip.example.test."]},
      {"TXT", "txt", [String.duplicate("x", 1_025)]},
      {"CAA", "@", ["0 issue letsencrypt.org"]},
      {"A", "bad_name", ["192.0.2.10"]}
    ]

    for {type, name, values} <- invalid do
      record = %{base | "type" => type, "name" => name, "values" => values}
      assert_invalid(Operation.validate_schema(:dns_record_write, record))
    end
  end

  test "DNS records enforce wildcard, SRV owner, and root target semantics" do
    base = Fixtures.valid(:dns_record_write)

    valid = [
      {"A", "*", ["192.0.2.10"]},
      {"A", "*.sub", ["192.0.2.10"]},
      {"A", "*.sub.example", ["192.0.2.10"]},
      {"CNAME", "alias", ["target.example.test."]},
      {"MX", "@", ["0 ."]},
      {"MX", "@", ["10 mail1.example.test.", "20 mail2.example.test."]},
      {"SRV", "_sip._tcp", ["10 20 5060 sip.example.test."]},
      {"SRV", "_sip._tcp",
       [
         "10 20 5060 sip1.example.test.",
         "20 10 5060 sip2.example.test."
       ]},
      {"SRV", "_sip._udp.example", ["0 0 0 ."]}
    ]

    for {type, name, values} <- valid do
      record = %{base | "type" => type, "name" => name, "values" => values}
      assert {:ok, ^record} = Operation.validate_schema(:dns_record_write, record)
    end

    invalid = [
      {"A", "www.*", ["192.0.2.10"]},
      {"A", "foo*", ["192.0.2.10"]},
      {"A", "*foo.sub", ["192.0.2.10"]},
      {"A", "sub.*.example", ["192.0.2.10"]},
      {"SRV", "www", ["10 20 5060 sip.example.test."]},
      {"SRV", "_sip._http", ["10 20 5060 sip.example.test."]},
      {"SRV", "_sip._tcp.bad_name", ["10 20 5060 sip.example.test."]},
      {"CNAME", "alias", ["target.example.test.", "other.example.test."]},
      {"CNAME", "alias", ["target.example.test. other.example.test."]},
      {"MX", "@", ["10 ."]},
      {"MX", "@", ["0 . extra"]},
      {"MX", "@", ["0 .", "10 mail.example.test."]},
      {"MX", "@", ["0 .", "0 ."]},
      {"SRV", "_sip._tcp", ["0 0 5060 ."]},
      {"SRV", "_sip._tcp", ["0 1 0 ."]},
      {"SRV", "_sip._tcp", ["0 0 0 . extra"]},
      {"SRV", "_sip._tcp", ["0 0 0 .", "10 20 5060 sip.example.test."]},
      {"SRV", "_sip._tcp", ["0 0 0 .", "0 0 0 ."]}
    ]

    for {type, name, values} <- invalid do
      record = %{base | "type" => type, "name" => name, "values" => values}
      assert_invalid(Operation.validate_schema(:dns_record_write, record))
    end
  end

  test "revisioned and deleted resource IDs match every typed resource identifier" do
    for {resource_type, resource_id, resource} <- Fixtures.resource_domains() do
      revisioned = %{
        "resource_type" => resource_type,
        "resource_id" => resource_id,
        "revision" => digest(),
        "resource" => resource
      }

      deleted = %{
        "resource_type" => resource_type,
        "resource_id" => resource_id,
        "resource_ref" => resource_ref(resource_type, resource),
        "revision" => digest()
      }

      assert {:ok, ^revisioned} = Operation.validate_schema(:revisioned_resource, revisioned)
      assert {:ok, ^deleted} = Operation.validate_schema(:deleted_resource, deleted)

      assert_invalid(
        Operation.validate_schema(:revisioned_resource, %{revisioned | "resource_id" => "other"})
      )

      assert_invalid(
        Operation.validate_schema(:deleted_resource, %{deleted | "resource_id" => "other"})
      )
    end

    view = Fixtures.valid_result("server.dns.views.create", :revisioned_resource)

    assert_invalid(
      Operation.validate_result(
        "server.dns.views.create",
        :server,
        :command,
        %{view | "resource_id" => "other"}
      )
    )
  end

  test "config state enforces the lifecycle matrix" do
    accepted = [
      config_state("delivered"),
      config_state("delivered", %{"version" => 9_223_372_036_854_775_807}),
      config_state("applying"),
      config_state("applying", %{"previous_version" => 1, "previous_revision" => digest()}),
      config_state("applied", %{"applied_revision" => digest()}),
      config_state("applied", %{
        "applied_revision" => digest(),
        "previous_version" => 1,
        "previous_revision" => digest()
      }),
      config_state("failed", %{
        "failure" => %{"phase" => "delivery", "reason" => "delivery failed"}
      }),
      config_state("failed", %{
        "failure" => %{"phase" => "validation", "reason" => "invalid setting"}
      }),
      config_state("failed", %{
        "failure" => %{"phase" => "apply", "reason" => "first apply failed"}
      }),
      config_state("failed", %{
        "version" => 9_223_372_036_854_775_807,
        "failure" => config_failure(),
        "previous_version" => 9_223_372_036_854_775_806,
        "previous_revision" => digest(),
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 9_223_372_036_854_775_806,
          "restored_revision" => digest(),
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "failure" => config_failure(),
        "previous_version" => 1,
        "previous_revision" => digest(),
        "rollback" => %{
          "succeeded" => false,
          "restored_version" => nil,
          "restored_revision" => nil,
          "reason" => "rollback failed"
        }
      }),
      config_state("failed", %{
        "failure" => %{"phase" => "rollback", "reason" => "rollback failed"},
        "previous_version" => 1,
        "previous_revision" => digest(),
        "rollback" => %{
          "succeeded" => false,
          "restored_version" => nil,
          "restored_revision" => nil,
          "reason" => "rollback failed"
        }
      })
    ]

    for state <- accepted do
      assert {:ok, ^state} = Operation.validate_schema(:config_state, state)

      assert {:ok, ^state} =
               Operation.validate_result("server.settings.update", :server, :config, state)
    end

    contradictory = [
      config_state("desired"),
      config_state("delivered", %{"applied_revision" => digest()}),
      config_state("delivered", %{"previous_version" => 1, "previous_revision" => digest()}),
      config_state("applying", %{"previous_version" => 0, "previous_revision" => digest()}),
      config_state("applying", %{"previous_version" => 1}),
      config_state("applying", %{"previous_revision" => digest()}),
      config_state("applying", %{"previous_version" => 2, "previous_revision" => digest()}),
      config_state("applying", %{"previous_version" => 3, "previous_revision" => digest()}),
      config_state("applying", %{"failure" => config_failure()}),
      config_state("applied"),
      config_state("applied", %{"applied_revision" => digest(), "previous_version" => 1}),
      config_state("applied", %{
        "applied_revision" => digest(),
        "previous_version" => 2,
        "previous_revision" => digest()
      }),
      config_state("applied", %{
        "applied_revision" => digest(),
        "previous_version" => 3,
        "previous_revision" => digest()
      }),
      config_state("applied", %{"applied_revision" => digest(), "failure" => config_failure()}),
      config_state("failed"),
      config_state("failed", %{"applied_revision" => digest(), "failure" => config_failure()}),
      config_state("failed", %{"failure" => config_failure(), "previous_revision" => digest()}),
      config_state("failed", %{
        "failure" => config_failure(),
        "previous_version" => 1,
        "previous_revision" => digest()
      }),
      config_state("failed", %{
        "failure" => config_failure(),
        "rollback" => %{
          "succeeded" => false,
          "restored_version" => nil,
          "restored_revision" => nil,
          "reason" => "failed"
        }
      }),
      config_state("failed", %{
        "failure" => %{"phase" => "delivery", "reason" => "delivery failed"},
        "previous_version" => 1,
        "previous_revision" => digest(),
        "rollback" => %{
          "succeeded" => false,
          "restored_version" => nil,
          "restored_revision" => nil,
          "reason" => "failed"
        }
      }),
      config_state("failed", %{
        "failure" => %{"phase" => "validation", "reason" => "invalid"},
        "previous_version" => 1,
        "previous_revision" => digest(),
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 1,
          "restored_revision" => digest(),
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "failure" => %{"phase" => "rollback", "reason" => "rollback failed"}
      }),
      config_state("failed", %{
        "failure" => %{"phase" => "rollback", "reason" => "rollback failed"},
        "previous_version" => 1,
        "previous_revision" => digest(),
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 1,
          "restored_revision" => digest(),
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "failure" => config_failure(),
        "previous_version" => 2,
        "previous_revision" => digest(),
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 2,
          "restored_revision" => digest(),
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "failure" => config_failure(),
        "previous_version" => 3,
        "previous_revision" => digest(),
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 3,
          "restored_revision" => digest(),
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "failure" => config_failure(),
        "previous_version" => 1,
        "previous_revision" => digest(),
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 0,
          "restored_revision" => digest(),
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "failure" => config_failure(),
        "previous_version" => 1,
        "previous_revision" => digest(),
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 2,
          "restored_revision" => digest(),
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "failure" => config_failure(),
        "previous_version" => 1,
        "previous_revision" => digest(),
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 1,
          "restored_revision" => String.duplicate("b", 64),
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "failure" => config_failure(),
        "previous_version" => 1,
        "previous_revision" => digest(),
        "rollback" => %{
          "succeeded" => false,
          "restored_version" => 1,
          "restored_revision" => nil,
          "reason" => "failed"
        }
      })
    ]

    for state <- contradictory do
      assert_invalid(Operation.validate_schema(:config_state, state))
    end

    for invalid_version <- ["version-1", 0, -1, 9_223_372_036_854_775_808] do
      assert_invalid(
        Operation.validate_result(
          "server.settings.update",
          :server,
          :config,
          config_state("delivered", %{"version" => invalid_version})
        )
      )
    end

    assert_invalid(
      Operation.validate_result(
        "server.settings.update",
        :server,
        :config,
        config_state("failed", %{
          "failure" => %{
            "phase" => "validation",
            "reason" => String.duplicate("x", 1_025)
          }
        })
      )
    )
  end

  test "DNS zone import accepts exactly one strict source" do
    source = %{
      "view_name" => "default",
      "zone_name" => "example.test",
      "source_type" => "provider",
      "source_id" => "route53",
      "source_revision" => digest()
    }

    blob = Fixtures.valid(:dns_zone_import)

    assert {:ok, ^source} = Operation.validate_schema(:dns_zone_import, source)
    assert {:ok, ^blob} = Operation.validate_schema(:dns_zone_import, blob)
    assert_invalid(Operation.validate_schema(:dns_zone_import, Map.merge(source, blob)))
    assert_invalid(Operation.validate_schema(:dns_zone_import, Map.drop(source, ["source_id"])))

    for forbidden <- ["path", "Content", "blob_bytes"] do
      assert_invalid(Operation.validate_schema(:dns_zone_import, Map.put(blob, forbidden, "raw")))
    end
  end

  test "reviewer probes reject profile transport fields and arbitrary DNS list items" do
    profile = Fixtures.valid(:profile_put)

    for payload <- [
          Map.put(profile, "expected_revision", digest()),
          put_in(profile, ["interfaces", Access.at(0), "path"], "/etc/network"),
          put_in(profile, ["interfaces", Access.at(0), "blob"], "raw")
        ] do
      assert_invalid(
        Operation.validate_payload("netman.profiles.put", :netman, :command, payload)
      )
    end

    valid_result = Fixtures.valid(:dns_view_list)

    valid_item = hd(valid_result["items"])

    for item <- [%{"path" => "/tmp/view"}, %{"blob" => "raw"}] do
      result = %{valid_result | "items" => [valid_item, item]}

      assert_invalid(Operation.validate_result("server.dns.views.list", :server, :query, result))
    end
  end

  test "rejects oversized values and collections and cross-domain shapes" do
    profile = Fixtures.valid(:profile_put)
    oversized_text = %{profile | "name" => String.duplicate("x", 1_025)}

    oversized_collection = %{
      profile
      | "interfaces" => List.duplicate(hd(profile["interfaces"]), 1_001)
    }

    assert_invalid(Operation.validate_schema(:profile_put, oversized_text))
    assert_invalid(Operation.validate_schema(:profile_put, oversized_collection))
    assert_invalid(Operation.validate_schema(:dns_view_write, profile))
    assert_invalid(Operation.validate_schema(:profile_put, Fixtures.valid(:dns_view_write)))

    assert_invalid(
      Operation.validate_result(
        "server.dns.zones.create",
        :server,
        :command,
        Fixtures.valid(:revisioned_resource)
      )
    )
  end

  defp digest, do: String.duplicate("a", 64)

  defp resource_ref("dns_view", resource), do: Map.take(resource, ["view_name"])
  defp resource_ref("dns_zone", resource), do: Map.take(resource, ["view_name", "zone_name"])

  defp resource_ref("dns_record", resource),
    do: Map.take(resource, ["view_name", "zone_name", "record_id"])

  defp resource_ref("dns_acl", resource), do: Map.take(resource, ["acl_id"])
  defp resource_ref("dns_provider", resource), do: Map.take(resource, ["provider_id"])
  defp resource_ref("dhcp_pool", resource), do: Map.take(resource, ["family", "pool_id"])
  defp resource_ref("mdns_service", resource), do: Map.take(resource, ["service_id"])
  defp resource_ref("netboot_profile", resource), do: Map.take(resource, ["profile_id"])
  defp resource_ref("netboot_device", resource), do: Map.take(resource, ["device_id"])
  defp resource_ref("netboot_asset", resource), do: Map.take(resource, ["asset_id"])
  defp resource_ref("identity_host", resource), do: Map.take(resource, ["host_id"])
  defp resource_ref("identity_token", resource), do: Map.take(resource, ["token_id"])
  defp resource_ref("identity_policy", resource), do: Map.take(resource, ["policy_id"])
  defp resource_ref("netman_profile", resource), do: Map.take(resource, ["profile_id"])

  defp config_state(state, overrides \\ %{}) do
    Map.merge(
      %{
        "state" => state,
        "version" => 2,
        "digest" => digest(),
        "applied_revision" => nil,
        "previous_version" => nil,
        "previous_revision" => nil,
        "failure" => nil,
        "rollback" => nil
      },
      overrides
    )
  end

  defp config_failure, do: %{"phase" => "apply", "reason" => "invalid setting"}

  defp setting_payload(key, value) do
    %{"service" => "dns", "entries" => [%{"key" => key, "value" => value}]}
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} = result
  end
end
