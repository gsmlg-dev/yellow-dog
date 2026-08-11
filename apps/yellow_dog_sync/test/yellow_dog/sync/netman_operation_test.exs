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
    {"netman.profiles.put", :command, "profiles.write", :profile_put, :profile_write_result,
     true},
    {"netman.profiles.replace", :config, "profiles.write", :profile_set_replace, :config_state,
     false},
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
    {"netman.profiles.patch", :command, "profiles.write", :profile_patch, :profile_write_result,
     true},
    {"netman.connections.activate", :command, "network.connections.write", :connection_ref,
     :connection_activation_result, true},
    {"netman.connections.deactivate", :command, "network.connections.write", :connection_ref,
     :connection_activation_result, true},
    {"netman.resolved.upstreams.list", :query, "resolved.upstreams.read", :empty,
     :resolved_upstream_list, true},
    {"netman.resolved.search_domains.list", :query, "resolved.search_domains.read", :empty,
     :resolved_search_domain_list, true},
    {"netman.resolved.link_dns.list", :query, "resolved.link_dns.read", :resolved_link_dns_query,
     :resolved_link_dns_list, true},
    {"netman.resolved.queries.list", :query, "resolved.queries.read", :resolved_queries_query,
     :resolved_query_list, true},
    {"netman.resolved.cache.get", :query, "resolved.cache.read", :empty, :resolved_cache, true},
    {"netman.resolved.counters.get", :query, "resolved.counters.read", :empty, :resolved_counters,
     true},
    {"netman.resolved.config.update", :config, "resolved.config.write", :resolved_config_update,
     :config_state, false},
    {"netman.resolved.config.rollback", :config, "resolved.config.rollback",
     :resolved_config_rollback, :config_state, false},
    {"netman.resolved.cache.flush", :command, "resolved.cache.write", :empty, :cache_clear_result,
     true},
    {"netman.dhcp_client.fsm.get", :query, "dhcp_client.fsm.read", :dhcp_client_connection_ref,
     :dhcp_client_fsm, true},
    {"netman.dhcp_client.leases.list", :query, "dhcp_client.leases.read", :empty,
     :dhcp_client_lease_list, true},
    {"netman.dhcp_client.connections.release_lease", :command, "dhcp_client.leases.write",
     :dhcp_client_connection_ref, :lease_release_result, true},
    {"netman.vpn.profile.get", :query, "vpn.profile.read", :empty, :vpn_resolved_profile, true}
  ]

  test "catalog exposes every Netman operation with explicit metadata and validators" do
    assert map_size(NetmanOperation.all()) == 32

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

  test "Netman apply-mode results accept only Netman runtime modes" do
    assert {:ok, operation} = NetmanOperation.fetch("netman.runtime.apply_mode.get")

    for mode <- ["managed", "observe_first", "observe"] do
      assert {:ok, %{"mode" => ^mode}} =
               Operation.validate_result(operation, %{"mode" => mode})
    end

    assert_invalid(Operation.validate_result(operation, %{"mode" => "standalone"}))
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
      %{"field" => "interface", "value" => "eth1"},
      %{"field" => "autoconnect", "value" => false},
      %{"field" => "autoconnect_priority", "value" => 200},
      %{"field" => "zone", "value" => "guest"},
      %{"field" => "ethernet.mtu", "value" => 9_000},
      %{"field" => "ipv4", "value" => runtime_profile()["ipv4"]},
      %{"field" => "ipv6", "value" => runtime_profile()["ipv6"]}
    ]

    for change <- valid_changes do
      assert {:ok, _payload} =
               Operation.validate_schema(:profile_patch, %{
                 "profile_id" => "office",
                 "changes" => [change]
               })
    end

    for change <- [
          %{"field" => "name", "value" => "Office"},
          %{"field" => "interface", "value" => String.duplicate("x", 16)},
          %{"field" => "autoconnect", "value" => "true"},
          %{"field" => "autoconnect_priority", "value" => 10_001},
          %{"field" => "zone", "value" => true},
          %{"field" => "ethernet.mtu", "value" => 67},
          %{"field" => "ipv4", "value" => runtime_profile()["ipv6"]},
          %{"field" => "ipv6", "value" => runtime_profile()["ipv4"]},
          %{"profile_id" => "办公", "changes" => [%{"field" => "zone", "value" => "guest"}]},
          %{"field" => "zone", "interface" => "eth0", "value" => "guest"}
        ] do
      payload =
        if Map.has_key?(change, "profile_id") do
          change
        else
          %{"profile_id" => "office", "changes" => [change]}
        end

      assert_invalid(Operation.validate_schema(:profile_patch, payload))
    end
  end

  test "Netman profiles preserve the complete runtime profile model" do
    profile = runtime_profile()

    assert {:ok, ^profile} = Operation.validate_schema(:profile_put, profile)

    assert_invalid(
      Operation.validate_schema(:profile_put, %{
        "profile_id" => "office",
        "name" => "Office",
        "interfaces" => []
      })
    )

    for invalid <- [
          put_in(profile, ["autoconnect_priority"], -1001),
          put_in(profile, ["autoconnect_priority"], 10_001),
          put_in(profile, ["ethernet", "mtu"], 67),
          put_in(profile, ["ethernet", "mtu"], 65_536),
          put_in(profile, ["ipv4", "address"], "2001:db8::10/64"),
          put_in(profile, ["ipv4", "gateway"], "2001:db8::1"),
          put_in(profile, ["ipv6", "dns"], ["192.0.2.53"]),
          put_in(profile, ["ipv4", "dns_search"], ["_svc.example.test"]),
          put_in(profile, ["ipv4", "method"], "link-local"),
          put_in(profile, ["ipv4", "address"], nil)
        ] do
      assert_invalid(Operation.validate_schema(:profile_put, invalid))
    end
  end

  test "connection operations use the profile and interface composite identity" do
    connection = %{"profile_id" => "office", "interface" => "eth0"}

    for schema <- [:network_connection_query, :connection_ref, :dhcp_client_connection_ref] do
      assert {:ok, ^connection} = Operation.validate_schema(schema, connection)
      assert_invalid(Operation.validate_schema(schema, %{"connection_id" => "uplink"}))
    end

    state = Map.put(connection, "state", "activated")
    assert {:ok, ^state} = Operation.validate_schema(:network_connection_state, state)
    assert {:ok, ^state} = Operation.validate_schema(:connection_activation_result, state)
  end

  test "authoritative profile replacement is an offline config operation" do
    assert {:ok, %Operation{kind: :config, online?: false, payload_schema: :profile_set_replace}} =
             NetmanOperation.fetch("netman.profiles.replace")

    payload = %{"profiles" => [runtime_profile()]}
    assert {:ok, ^payload} = Operation.validate_schema(:profile_set_replace, payload)

    assert {:ok, %{"profiles" => []}} =
             Operation.validate_schema(:profile_set_replace, %{"profiles" => []})

    assert_invalid(
      Operation.validate_schema(:profile_set_replace, %{
        "profiles" => [runtime_profile(), runtime_profile()]
      })
    )
  end

  test "profile results distinguish desired and active durable revisions" do
    revision_state = %{
      "profile_id" => "office",
      "desired_revision" => @revision,
      "active_revision" => nil
    }

    assert {:ok, ^revision_state} = Operation.validate_schema(:profile_revision, revision_state)

    active = %{
      "profile_id" => "office",
      "desired_revision" => @revision,
      "active_revision" => @revision,
      "state" => "activated",
      "connections" => [
        %{"profile_id" => "office", "interface" => "eth0", "state" => "activated"}
      ]
    }

    assert {:ok, ^active} = Operation.validate_schema(:profile_activation_result, active)

    history = %{
      "profile_id" => "office",
      "revision" => @revision,
      "profile" => runtime_profile(),
      "stored_at" => @observed_at,
      "activated_at" => nil
    }

    assert {:ok, ^history} = Operation.validate_schema(:profile_history_item, history)

    assert_invalid(
      Operation.validate_schema(:profile_history_item, %{
        history
        | "profile" => %{runtime_profile() | "profile_id" => "other"}
      })
    )

    assert_invalid(
      Operation.validate_schema(:profile_revision, %{
        "profile_id" => "office",
        "revision" => @revision
      })
    )
  end

  test "network route results preserve on-link routes with an explicit null gateway" do
    on_link_route = %{
      "destination" => "192.0.2.0/24",
      "gateway" => nil,
      "link_id" => "eth0"
    }

    assert {:ok, _result} =
             Operation.validate_schema(:network_route_list, list_result(on_link_route))

    assert_invalid(
      Operation.validate_schema(:network_route_list, %{
        list_result(on_link_route)
        | "items" => [Map.delete(on_link_route, "gateway")]
      })
    )
  end

  test "profile activation results preserve every selected interface" do
    activation = %{
      "profile_id" => "office",
      "desired_revision" => @revision,
      "active_revision" => @revision,
      "state" => "activated",
      "connections" => [
        %{"profile_id" => "office", "interface" => "eth0", "state" => "activated"},
        %{"profile_id" => "office", "interface" => "eth1", "state" => "activated"}
      ]
    }

    assert {:ok, ^activation} =
             Operation.validate_schema(:profile_activation_result, activation)

    assert_invalid(
      Operation.validate_schema(:profile_activation_result, Map.delete(activation, "connections"))
    )

    assert_invalid(
      Operation.validate_schema(:profile_activation_result, %{activation | "connections" => []})
    )

    assert_invalid(
      Operation.validate_schema(:profile_activation_result, %{
        activation
        | "connections" => [
            %{"profile_id" => "other", "interface" => "eth0", "state" => "activated"}
          ]
      })
    )

    assert_invalid(
      Operation.validate_schema(:profile_activation_result, %{
        activation
        | "connections" => [
            %{"profile_id" => "office", "interface" => "eth0", "state" => "activated"},
            %{"profile_id" => "office", "interface" => "eth0", "state" => "activated"}
          ]
      })
    )
  end

  test "Resolved link DNS results preserve each link without invented provenance" do
    link_dns = %{
      "link_id" => "eth0",
      "servers" => ["192.0.2.53"],
      "search_domains" => ["example.test"],
      "priority" => 100
    }

    assert {:ok, _result} =
             Operation.validate_schema(:resolved_link_dns_list, list_result(link_dns))

    assert_invalid(
      Operation.validate_schema(:resolved_link_dns_list, %{
        list_result(link_dns)
        | "items" => [Map.put(link_dns, "source", "static")]
      })
    )
  end

  test "Resolved recent-query payloads and results are bounded" do
    assert {:ok, %{"limit" => 100}} =
             Operation.validate_schema(:resolved_queries_query, %{"limit" => 100})

    assert_invalid(Operation.validate_schema(:resolved_queries_query, %{"limit" => 101}))

    query = %{
      "timestamp" => @observed_at,
      "domain" => "example.test",
      "type" => "A",
      "source" => "cache",
      "duration_us" => 25
    }

    assert {:ok, _result} =
             Operation.validate_schema(:resolved_query_list, list_result(query))

    assert_invalid(
      Operation.validate_schema(:resolved_query_list, %{
        list_result(query)
        | "items" => [%{query | "source" => "filesystem"}]
      })
    )
  end

  test "Resolved mutation reads expose their exact owner revisions" do
    upstreams =
      resolved_upstream()
      |> list_result()
      |> Map.put("config_revision", @revision)

    assert {:ok, ^upstreams} =
             Operation.validate_schema(:resolved_upstream_list, upstreams)

    assert_invalid(
      Operation.validate_schema(
        :resolved_upstream_list,
        Map.delete(upstreams, "config_revision")
      )
    )

    cache = resolved_cache()
    assert {:ok, ^cache} = Operation.validate_schema(:resolved_cache, cache)

    assert_invalid(Operation.validate_schema(:resolved_cache, Map.delete(cache, "revision")))
  end

  test "DHCP client lease items expose the exact release owner revision" do
    lease = dhcp_client_lease()
    result = list_result(lease)

    assert {:ok, ^result} = Operation.validate_schema(:dhcp_client_lease_list, result)

    assert_invalid(
      Operation.validate_schema(:dhcp_client_lease_list, %{
        result
        | "items" => [Map.delete(lease, "revision")]
      })
    )
  end

  test "VPN results carry a canonical revision" do
    result = %{"profile_id" => "vpn-default", "state" => "resolved", "revision" => @revision}

    assert {:ok, ^result} = Operation.validate_schema(:vpn_resolved_profile, result)

    assert_invalid(
      Operation.validate_schema(:vpn_resolved_profile, Map.delete(result, "revision"))
    )
  end

  test "config state enforces the full Netman lifecycle matrix" do
    accepted = [
      config_state("delivered"),
      config_state("applying"),
      config_state("applying", %{"previous_version" => 1, "previous_revision" => @revision}),
      config_state("applying", %{
        "version" => 9_223_372_036_854_775_807,
        "previous_version" => 9_223_372_036_854_775_806,
        "previous_revision" => @revision
      }),
      config_state("applied", %{"applied_revision" => @revision}),
      config_state("applied", %{
        "applied_revision" => @revision,
        "previous_version" => 1,
        "previous_revision" => @revision
      }),
      config_state("failed", %{
        "failure" => %{"phase" => "delivery", "reason" => "delivery failed"}
      }),
      config_state("failed", %{
        "failure" => %{"phase" => "validation", "reason" => "invalid config"}
      }),
      config_state("failed", %{
        "failure" => %{"phase" => "apply", "reason" => "first apply failed"}
      }),
      config_state("failed", %{
        "previous_version" => 1,
        "previous_revision" => @revision,
        "failure" => %{"phase" => "apply", "reason" => "activation failed"},
        "rollback" => %{
          "succeeded" => false,
          "restored_version" => nil,
          "restored_revision" => nil,
          "reason" => "restore command failed"
        }
      }),
      config_state("failed", %{
        "previous_version" => 1,
        "previous_revision" => @revision,
        "failure" => %{"phase" => "apply", "reason" => "activation failed"},
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 1,
          "restored_revision" => @revision,
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "previous_version" => 1,
        "previous_revision" => @revision,
        "failure" => %{"phase" => "rollback", "reason" => "rollback failed"},
        "rollback" => %{
          "succeeded" => false,
          "restored_version" => nil,
          "restored_revision" => nil,
          "reason" => "restore command failed"
        }
      })
    ]

    for state <- accepted do
      assert {:ok, ^state} =
               Operation.validate_result(
                 "netman.resolved.config.update",
                 :netman,
                 :config,
                 state
               )
    end

    rejected = [
      config_state("desired"),
      config_state("delivered", %{"previous_version" => 1, "previous_revision" => @revision}),
      config_state("applying", %{"previous_version" => 1}),
      config_state("applying", %{"previous_revision" => @revision}),
      config_state("applying", %{"previous_version" => 2, "previous_revision" => @revision}),
      config_state("applying", %{"previous_version" => 3, "previous_revision" => @revision}),
      config_state("applied"),
      config_state("applied", %{"applied_revision" => @revision, "previous_version" => 1}),
      config_state("applied", %{
        "applied_revision" => @revision,
        "previous_version" => 2,
        "previous_revision" => @revision
      }),
      config_state("applied", %{
        "applied_revision" => @revision,
        "previous_version" => 3,
        "previous_revision" => @revision
      }),
      config_state("failed"),
      config_state("failed", %{
        "previous_version" => 1,
        "previous_revision" => @revision,
        "failure" => %{"phase" => "apply", "reason" => "failed"}
      }),
      config_state("failed", %{
        "previous_version" => 1,
        "previous_revision" => @revision,
        "failure" => %{"phase" => "apply", "reason" => "failed"},
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 2,
          "restored_revision" => @revision,
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "previous_version" => 1,
        "previous_revision" => @revision,
        "failure" => %{"phase" => "rollback", "reason" => "failed"},
        "rollback" => %{
          "succeeded" => false,
          "restored_version" => nil,
          "restored_revision" => nil,
          "reason" => String.duplicate("x", 1_025)
        }
      }),
      config_state("failed", %{
        "previous_version" => 1,
        "previous_revision" => @revision,
        "failure" => %{"phase" => "delivery", "reason" => "delivery failed"},
        "rollback" => %{
          "succeeded" => false,
          "restored_version" => nil,
          "restored_revision" => nil,
          "reason" => "failed"
        }
      }),
      config_state("failed", %{
        "previous_version" => 1,
        "previous_revision" => @revision,
        "failure" => %{"phase" => "validation", "reason" => "invalid"},
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 1,
          "restored_revision" => @revision,
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "failure" => %{"phase" => "rollback", "reason" => "rollback failed"}
      }),
      config_state("failed", %{
        "previous_version" => 1,
        "previous_revision" => @revision,
        "failure" => %{"phase" => "rollback", "reason" => "rollback failed"},
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 1,
          "restored_revision" => @revision,
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "previous_version" => 2,
        "previous_revision" => @revision,
        "failure" => %{"phase" => "apply", "reason" => "failed"},
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 2,
          "restored_revision" => @revision,
          "reason" => nil
        }
      }),
      config_state("failed", %{
        "previous_version" => 3,
        "previous_revision" => @revision,
        "failure" => %{"phase" => "apply", "reason" => "failed"},
        "rollback" => %{
          "succeeded" => true,
          "restored_version" => 3,
          "restored_revision" => @revision,
          "reason" => nil
        }
      })
    ]

    for state <- rejected do
      assert_invalid(
        Operation.validate_result(
          "netman.resolved.config.update",
          :netman,
          :config,
          state
        )
      )
    end

    for invalid_version <- ["version-1", 0, -1, 9_223_372_036_854_775_808] do
      assert_invalid(
        Operation.validate_result(
          "netman.resolved.config.update",
          :netman,
          :config,
          config_state("delivered", %{"version" => invalid_version})
        )
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

      :profile_set_replace ->
        %{"profiles" => [profile()]}

      :profile_rollback ->
        %{"profile_id" => "office", "target_revision" => @revision}

      :network_links_query ->
        %{}

      :network_addresses_query ->
        %{}

      :network_routes_query ->
        %{}

      :network_connection_query ->
        connection_ref()

      :profile_patch ->
        profile_patch()

      :connection_ref ->
        connection_ref()

      :resolved_config_update ->
        resolved_config()

      :resolved_config_rollback ->
        %{"target_revision" => @revision}

      :resolved_link_dns_query ->
        %{}

      :resolved_queries_query ->
        %{"limit" => 50}

      :dhcp_client_connection_ref ->
        connection_ref()

      :runtime_capabilities ->
        %{"capabilities" => ["runtime.apply_mode"]}

      :apply_mode ->
        %{"mode" => "managed"}

      :reconciliation_health ->
        %{"status" => "healthy", "pending_changes" => 0}

      :profile_list ->
        list_result(profile_state())

      :profile_revision ->
        %{
          "profile_id" => "office",
          "desired_revision" => @revision,
          "active_revision" => @revision
        }

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
        resolved_upstream()
        |> list_result()
        |> Map.put("config_revision", @revision)

      :resolved_search_domain_list ->
        list_result(resolved_search_domain())

      :resolved_link_dns_list ->
        list_result(resolved_link_dns())

      :resolved_query_list ->
        list_result(resolved_query())

      :resolved_cache ->
        resolved_cache()

      :resolved_counters ->
        %{"hits" => 5, "misses" => 1}

      :config_state ->
        config_state()

      :cache_clear_result ->
        %{"cleared_entries" => 4}

      :dhcp_client_fsm ->
        Map.put(connection_ref(), "state", "bound")

      :dhcp_client_lease_list ->
        list_result(dhcp_client_lease())

      :lease_release_result ->
        lease_release_result()

      :vpn_resolved_profile ->
        %{"profile_id" => "vpn-default", "state" => "resolved", "revision" => @revision}
    end
  end

  defp valid_result(_name, :profile_write_result), do: profile_state()

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

  defp profile, do: runtime_profile()

  defp runtime_profile do
    %{
      "profile_id" => "office",
      "type" => "ethernet",
      "interface" => "eth0",
      "autoconnect" => true,
      "autoconnect_priority" => 100,
      "zone" => "trusted",
      "ethernet" => %{"mtu" => 1_500},
      "ipv4" => %{
        "method" => "manual",
        "address" => "192.0.2.10/24",
        "gateway" => "192.0.2.1",
        "dns" => ["192.0.2.53"],
        "dns_search" => ["example.test"]
      },
      "ipv6" => %{
        "method" => "manual",
        "address" => "2001:db8::10/64",
        "gateway" => "2001:db8::1",
        "dns" => ["2001:db8::53"],
        "dns_search" => ["example.test"]
      }
    }
  end

  defp profile_patch do
    %{
      "profile_id" => "office",
      "changes" => [
        %{"field" => "ethernet.mtu", "value" => 1_500}
      ]
    }
  end

  defp resolved_config,
    do: %{"upstreams" => ["1.1.1.1"], "search_domains" => ["example.test"]}

  defp profile_history,
    do: %{
      "profile_id" => "office",
      "revision" => @revision,
      "profile" => profile(),
      "stored_at" => @observed_at,
      "activated_at" => @observed_at
    }

  defp profile_state,
    do: %{
      "profile" => profile(),
      "desired_revision" => @revision,
      "active_revision" => @revision
    }

  defp profile_activation,
    do: %{
      "profile_id" => "office",
      "desired_revision" => @revision,
      "active_revision" => @revision,
      "state" => "activated",
      "connections" => [connection_state()]
    }

  defp network_link, do: %{"link_id" => "eth0", "name" => "eth0", "state" => "up"}

  defp network_address,
    do: %{"link_id" => "eth0", "address" => "192.0.2.10/24", "scope" => "global"}

  defp network_route,
    do: %{"destination" => "0.0.0.0/0", "gateway" => "192.0.2.1", "link_id" => "eth0"}

  defp connection_ref, do: %{"profile_id" => "office", "interface" => "eth0"}
  defp connection_state, do: Map.put(connection_ref(), "state", "activated")
  defp resolved_upstream, do: %{"address" => "1.1.1.1", "source" => "managed"}
  defp resolved_search_domain, do: %{"domain" => "example.test", "routing_only" => false}

  defp resolved_link_dns do
    %{
      "link_id" => "eth0",
      "servers" => ["192.0.2.53"],
      "search_domains" => ["example.test"],
      "priority" => 100
    }
  end

  defp resolved_query do
    %{
      "timestamp" => @observed_at,
      "domain" => "example.test",
      "type" => "A",
      "source" => "forward",
      "duration_us" => 25
    }
  end

  defp resolved_cache do
    %{
      "revision" => @revision,
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
    Map.merge(connection_ref(), %{
      "address" => "192.0.2.10",
      "expires_at" => @observed_at,
      "revision" => @revision
    })
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

  defp config_state(state \\ "delivered", overrides \\ %{}) do
    Map.merge(
      %{
        "state" => state,
        "version" => 2,
        "digest" => @revision,
        "applied_revision" => nil,
        "previous_version" => nil,
        "previous_revision" => nil,
        "failure" => nil,
        "rollback" => nil
      },
      overrides
    )
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
