defmodule YellowDog.Sync.NetmanOperation do
  @moduledoc false

  alias YellowDog.Sync.Error
  alias YellowDog.Sync.Operation

  @entries [
    {"netman.runtime.capabilities.get", :query, "runtime.capabilities", :empty,
     :runtime_capabilities, true},
    {"netman.runtime.apply_mode.get", :query, "runtime.apply_mode", :empty, :apply_mode, true},
    {"netman.runtime.reconciliation_health.get", :query, "runtime.reconciliation_health", :empty,
     :reconciliation_health, true},
    {"netman.profiles.list", :query, "profiles.read", :profile_list_query, :profile_list, true},
    {"netman.profiles.active_revision.get", :query, "profiles.read", :profile_ref,
     :profile_revision, true},
    {"netman.profiles.history.list", :query, "profiles.read", :profile_ref, :profile_history,
     true},
    {"netman.profiles.validate", :command, "profiles.validate", :profile_validate,
     :profile_validation, true},
    {"netman.profiles.put", :command, "profiles.write", :profile_put, :revisioned_resource, true},
    {"netman.profiles.delete", :command, "profiles.write", :profile_ref, :deleted_resource, true},
    {"netman.profiles.activate", :command, "profiles.activate", :profile_ref,
     :profile_activation_result, true},
    {"netman.profiles.rollback", :command, "profiles.rollback", :profile_rollback,
     :profile_activation_result, true},
    {"netman.network.links.list", :query, "network.links.read", :network_links_query,
     :network_link_list, true},
    {"netman.network.addresses.list", :query, "network.addresses.read", :network_addresses_query,
     :network_address_list, true},
    {"netman.network.routes.list", :query, "network.routes.read", :network_routes_query,
     :network_route_list, true},
    {"netman.network.connection_state.get", :query, "network.connections.read",
     :network_connection_query, :network_connection_state, true},
    {"netman.profiles.patch", :command, "profiles.write", :profile_patch, :revisioned_resource,
     true},
    {"netman.connections.activate", :command, "network.connections.write", :connection_ref,
     :connection_activation_result, true},
    {"netman.connections.deactivate", :command, "network.connections.write", :connection_ref,
     :connection_activation_result, true},
    {"netman.resolved.upstreams.list", :query, "resolved.upstreams.read", :empty,
     :resolved_upstream_list, true},
    {"netman.resolved.search_domains.list", :query, "resolved.search_domains.read", :empty,
     :resolved_search_domain_list, true},
    {"netman.resolved.cache.get", :query, "resolved.cache.read", :empty, :resolved_cache, true},
    {"netman.resolved.counters.get", :query, "resolved.counters.read", :empty, :resolved_counters,
     true},
    {"netman.resolved.config.update", :config, "resolved.config.write", :resolved_config_update,
     :config_state, false},
    {"netman.resolved.config.rollback", :config, "resolved.config.rollback",
     :resolved_config_rollback, :config_state, false},
    {"netman.resolved.cache.flush", :command, "resolved.cache.write", :empty, :cache_clear_result,
     true},
    {"netman.dhcp_client.fsm.get", :query, "dhcp_client.fsm.read", :empty, :dhcp_client_fsm,
     true},
    {"netman.dhcp_client.leases.list", :query, "dhcp_client.leases.read", :empty,
     :dhcp_client_lease_list, true},
    {"netman.dhcp_client.connections.release_lease", :command, "dhcp_client.leases.write",
     :dhcp_client_connection_ref, :lease_release_result, true},
    {"netman.vpn.profile.get", :query, "vpn.profile.read", :empty, :vpn_resolved_profile, true}
  ]

  @operations Map.new(@entries, fn {name, kind, capability, payload_schema, result_schema,
                                    online?} ->
                {name,
                 %Operation{
                   name: name,
                   target_type: :netman,
                   kind: kind,
                   capability: capability,
                   payload_schema: payload_schema,
                   result_schema: result_schema,
                   online?: online?
                 }}
              end)

  @spec all() :: %{String.t() => Operation.t()}
  def all, do: @operations

  @spec fetch(term()) :: {:ok, Operation.t()} | {:error, Error.t()}
  def fetch(name) when is_binary(name) do
    case Map.fetch(@operations, name) do
      {:ok, operation} -> {:ok, operation}
      :error -> invalid_error()
    end
  end

  def fetch(_name), do: invalid_error()

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}
end
