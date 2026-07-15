defmodule YellowDog.Sync.NetmanOperationTest do
  use ExUnit.Case, async: false

  alias YellowDog.Sync.Error
  alias YellowDog.Sync.NetmanOperation
  alias YellowDog.Sync.Operation

  @operations [
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

  test "catalog exposes every Netman operation with explicit metadata and validators" do
    assert map_size(NetmanOperation.all()) == 29

    for {name, kind, capability, payload_schema, result_schema, online?} <- @operations do
      assert {:ok,
              %Operation{
                target_type: :netman,
                kind: ^kind,
                capability: ^capability,
                payload_schema: ^payload_schema,
                result_schema: ^result_schema,
                online?: ^online?
              } = operation} = NetmanOperation.fetch(name)

      assert {:ok, _payload} = Operation.validate_payload(operation, example(payload_schema))
      assert {:ok, _result} = Operation.validate_result(operation, example(result_schema))
    end
  end

  test "only config operations are offline queueable" do
    for {_name, operation} <- NetmanOperation.all() do
      assert operation.online? == (operation.kind != :config)
    end
  end

  test "rejects unknown operations without creating atoms" do
    _ = NetmanOperation.fetch("netman.runtime.capabilities.get")
    initial_atom_count = :erlang.system_info(:atom_count)

    last_name =
      Enum.reduce(1..500, nil, fn index, _last_name ->
        name = "netman.unknown.#{index}_#{System.unique_integer([:positive])}"
        assert_invalid(NetmanOperation.fetch(name))
        name
      end)

    assert :erlang.system_info(:atom_count) == initial_atom_count
    assert_raise ArgumentError, fn -> String.to_existing_atom(last_name) end
  end

  test "rejects malformed and oversized schema values with stable errors" do
    assert_invalid(
      Operation.validate_payload("netman.profiles.put", :netman, :command, %{
        "resource_id" => "profile-1",
        "value" => %{},
        "unexpected" => true
      })
    )

    assert_invalid(
      Operation.validate_payload("netman.profiles.put", :netman, :command, %{
        "resource_id" => String.duplicate("x", 129),
        "value" => %{}
      })
    )

    assert_invalid(Operation.validate_result("netman.profiles.put", :server, :command, %{}))
  end

  defp example(:empty), do: %{}

  defp example(schema) do
    cond do
      schema == :config_state ->
        config_state()

      schema in list_results() ->
        snapshot(%{"items" => []})

      schema in value_results() ->
        snapshot(%{"value" => %{}})

      schema in refs() ->
        %{"resource_id" => "resource-1"}

      schema in writes() ->
        %{"resource_id" => "resource-1", "value" => %{}}

      schema in queries() ->
        %{}

      schema in command_results() ->
        %{"resource_id" => "resource-1", "revision" => digest(), "value" => %{}}

      true ->
        raise "missing example for #{inspect(schema)}"
    end
  end

  defp queries do
    [
      :profile_list_query,
      :network_links_query,
      :network_addresses_query,
      :network_routes_query,
      :network_connection_query
    ]
  end

  defp refs do
    [
      :profile_ref,
      :profile_rollback,
      :connection_ref,
      :dhcp_client_connection_ref,
      :resolved_config_rollback
    ]
  end

  defp writes do
    [:profile_validate, :profile_put, :profile_patch, :resolved_config_update]
  end

  defp list_results do
    [
      :profile_list,
      :profile_history,
      :network_link_list,
      :network_address_list,
      :network_route_list,
      :resolved_upstream_list,
      :resolved_search_domain_list,
      :dhcp_client_lease_list
    ]
  end

  defp value_results do
    [
      :runtime_capabilities,
      :apply_mode,
      :reconciliation_health,
      :profile_revision,
      :network_connection_state,
      :resolved_cache,
      :resolved_counters,
      :dhcp_client_fsm,
      :vpn_resolved_profile
    ]
  end

  defp command_results do
    [
      :profile_validation,
      :revisioned_resource,
      :deleted_resource,
      :profile_activation_result,
      :connection_activation_result,
      :cache_clear_result,
      :lease_release_result
    ]
  end

  defp snapshot(value),
    do: Map.merge(value, %{"revision" => digest(), "observed_at" => timestamp()})

  defp config_state do
    %{
      "state" => "desired",
      "version" => "version-1",
      "digest" => digest(),
      "applied_revision" => nil,
      "previous_revision" => nil,
      "failure" => nil,
      "rollback" => nil
    }
  end

  defp digest, do: String.duplicate("b", 64)
  defp timestamp, do: "2026-07-16T08:30:00Z"

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} = result
  end
end
