defmodule YellowDog.Sync.NetmanOperationTest do
  use ExUnit.Case, async: false

  alias YellowDog.Sync.Error
  alias YellowDog.Sync.NetmanOperation
  alias YellowDog.Sync.Operation

  @revision String.duplicate("b", 64)
  @observed_at "2026-07-16T08:30:00Z"

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

      assert {:ok, _payload} =
               Operation.validate_payload(operation, valid(payload_schema))

      assert {:ok, _result} =
               Operation.validate_result(operation, valid_result(name, result_schema))
    end
  end

  test "only config operations are offline queueable" do
    for {_name, operation} <- NetmanOperation.all() do
      assert operation.online? == (operation.kind != :config)
    end
  end

  test "rejects unknown operations without creating atoms" do
    _ = NetmanOperation.fetch("netman.runtime.capabilities.get")
    _last_warmup_name = reject_unknown_batch("warmup")
    initial_atom_count = :erlang.system_info(:atom_count)

    last_name = reject_unknown_batch("measured")

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

  test "profile patches enforce field-specific values" do
    valid_changes = [
      %{"field" => "name", "value" => "Office"},
      %{"field" => "method", "interface" => "eth0", "value" => "static"},
      %{"field" => "addresses", "interface" => "eth0", "value" => ["192.0.2.10/24"]},
      %{"field" => "gateway", "interface" => "eth0", "value" => "192.0.2.1"}
    ]

    for change <- valid_changes do
      assert {:ok, _payload} =
               Operation.validate_schema(:profile_patch, %{
                 "profile_id" => "office",
                 "changes" => [change]
               })
    end

    for change <- [
          %{"field" => "name", "value" => true},
          %{"field" => "method", "interface" => "eth0", "value" => "Office"},
          %{"field" => "addresses", "interface" => "eth0", "value" => "192.0.2.10/24"},
          %{"field" => "gateway", "interface" => "eth0", "value" => ["192.0.2.1"]},
          %{"field" => "method", "value" => "dhcp"},
          %{"field" => "name", "interface" => "eth0", "value" => "Office"}
        ] do
      assert_invalid(
        Operation.validate_schema(:profile_patch, %{
          "profile_id" => "office",
          "changes" => [change]
        })
      )
    end
  end

  defp valid(schema) do
    case schema do
      :empty ->
        %{}

      :profile_list_query ->
        %{}

      :profile_ref ->
        %{"profile_id" => "office"}

      :profile_validate ->
        profile()

      :profile_put ->
        profile()

      :profile_rollback ->
        %{"profile_id" => "office", "target_revision" => @revision}

      :network_links_query ->
        %{}

      :network_addresses_query ->
        %{}

      :network_routes_query ->
        %{}

      :network_connection_query ->
        %{"connection_id" => "uplink"}

      :profile_patch ->
        profile_patch()

      :connection_ref ->
        %{"connection_id" => "uplink"}

      :resolved_config_update ->
        resolved_config()

      :resolved_config_rollback ->
        %{"target_revision" => @revision}

      :dhcp_client_connection_ref ->
        %{"connection_id" => "uplink"}

      :runtime_capabilities ->
        %{"capabilities" => ["runtime.apply_mode"]}

      :apply_mode ->
        %{"mode" => "managed"}

      :reconciliation_health ->
        %{"status" => "healthy", "pending_changes" => 0}

      :profile_list ->
        list_result(profile())

      :profile_revision ->
        %{"profile_id" => "office", "revision" => @revision}

      :profile_history ->
        list_result(profile_history())

      :profile_validation ->
        %{"profile_id" => "office", "valid" => true, "errors" => []}

      :profile_activation_result ->
        profile_activation()

      :network_link_list ->
        list_result(network_link())

      :network_address_list ->
        list_result(network_address())

      :network_route_list ->
        list_result(network_route())

      :network_connection_state ->
        connection_state()

      :connection_activation_result ->
        connection_state()

      :resolved_upstream_list ->
        list_result(resolved_upstream())

      :resolved_search_domain_list ->
        list_result(resolved_search_domain())

      :resolved_cache ->
        resolved_cache()

      :resolved_counters ->
        %{"hits" => 5, "misses" => 1}

      :config_state ->
        config_state()

      :cache_clear_result ->
        %{"cleared_entries" => 4}

      :dhcp_client_fsm ->
        %{"connection_id" => "uplink", "state" => "bound"}

      :dhcp_client_lease_list ->
        list_result(dhcp_client_lease())

      :lease_release_result ->
        lease_release_result()

      :vpn_resolved_profile ->
        %{"profile_id" => "vpn-default", "state" => "resolved"}
    end
  end

  defp valid_result(_name, :revisioned_resource) do
    %{
      "resource_type" => "netman_profile",
      "resource_id" => "office",
      "revision" => @revision,
      "resource" => profile()
    }
  end

  defp valid_result(_name, :deleted_resource) do
    %{
      "resource_type" => "netman_profile",
      "resource_id" => "office",
      "resource_ref" => %{"profile_id" => "office"},
      "revision" => @revision
    }
  end

  defp valid_result(_name, schema), do: valid(schema)

  defp profile do
    %{
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
  end

  defp profile_patch do
    %{
      "profile_id" => "office",
      "changes" => [
        %{"field" => "gateway", "interface" => "eth0", "value" => "192.0.2.1"}
      ]
    }
  end

  defp resolved_config,
    do: %{"upstreams" => ["1.1.1.1"], "search_domains" => ["example.test"]}

  defp profile_history,
    do: %{"profile_id" => "office", "revision" => @revision, "activated_at" => @observed_at}

  defp profile_activation,
    do: %{"profile_id" => "office", "revision" => @revision, "state" => "activated"}

  defp network_link, do: %{"link_id" => "eth0", "name" => "eth0", "state" => "up"}

  defp network_address,
    do: %{"link_id" => "eth0", "address" => "192.0.2.10/24", "scope" => "global"}

  defp network_route,
    do: %{"destination" => "0.0.0.0/0", "gateway" => "192.0.2.1", "link_id" => "eth0"}

  defp connection_state, do: %{"connection_id" => "uplink", "state" => "activated"}
  defp resolved_upstream, do: %{"address" => "1.1.1.1", "source" => "managed"}
  defp resolved_search_domain, do: %{"domain" => "example.test", "routing_only" => false}

  defp resolved_cache do
    %{
      "entries" => [
        %{
          "domain" => "example.test",
          "address" => "192.0.2.10",
          "expires_at" => @observed_at
        }
      ]
    }
  end

  defp dhcp_client_lease do
    %{"connection_id" => "uplink", "address" => "192.0.2.10", "expires_at" => @observed_at}
  end

  defp lease_release_result do
    %{
      "family" => "ipv4",
      "lease_id" => "lease-1",
      "address" => "192.0.2.20",
      "released" => true
    }
  end

  defp list_result(item) do
    %{"items" => [item], "revision" => @revision, "observed_at" => @observed_at}
  end

  defp config_state do
    %{
      "state" => "desired",
      "version" => "version-1",
      "digest" => @revision,
      "applied_revision" => nil,
      "previous_revision" => nil,
      "failure" => nil,
      "rollback" => nil
    }
  end

  defp assert_invalid(result) do
    assert {:error, %Error{code: :invalid, message: "invalid value", details: %{}}} = result
  end

  defp reject_unknown_batch(label) do
    Enum.reduce(1..500, nil, fn index, _last_name ->
      name = "netman.unknown.#{label}.#{index}_#{System.unique_integer([:positive])}"
      assert_invalid(NetmanOperation.fetch(name))
      name
    end)
  end
end
