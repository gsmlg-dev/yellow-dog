defmodule YellowDog.Management.DnsViewsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.{
    Assignment,
    Audit,
    Caller,
    ConfigCompiler,
    DnsAcl,
    DnsAcls,
    DnsView,
    DnsViews,
    Domain,
    Idempotency,
    IntegrationSettings,
    Repo,
    ResourceVersion,
    Rrset,
    Service,
    Target,
    Worker,
    Zone
  }

  alias YellowDog.Management.DomainFixtures, as: Fixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    worker = mutate("create_worker", %{"id" => "view-worker", "name" => "View Worker"})
    service = mutate("put_service", Fixtures.service(worker["id"], worker["revision"], "stopped"))
    assert {:ok, [default]} = DnsViews.list(worker["id"], service["id"])
    %{scope: %{"worker_id" => worker["id"], "service_id" => service["id"]}, default: default}
  end

  test "pure rule normalization preserves order, emptiness and canonical desired inputs without writes" do
    before = {receipts(), business_snapshot(), Repo.all(DnsView)}

    rules = [
      %{
        "action" => "deny",
        "kind" => "networks",
        "networks" => ["192.0.2.17", "2001:DB8::12/64"]
      },
      %{"action" => "allow", "kind" => "countries", "countries" => ["US", "CA", "US"]},
      %{"action" => "deny", "kind" => "any"},
      %{"action" => "allow", "kind" => "networks", "networks" => []}
    ]

    assert {:ok, normalized} = DnsAcls.normalize_rules(rules)

    assert normalized == [
             %{
               "action" => "deny",
               "kind" => "networks",
               "networks" => ["192.0.2.17/32", "2001:db8::/64"]
             },
             %{"action" => "allow", "kind" => "countries", "countries" => ["CA", "US"]},
             %{"action" => "deny", "kind" => "any"},
             %{"action" => "allow", "kind" => "networks", "networks" => []}
           ]

    assert {:ok, []} = DnsAcls.normalize_rules([])

    for invalid <- [
          nil,
          %{},
          [nil],
          [%{"action" => "allow", "kind" => "countries", "countries" => ["ZZ"]}]
        ] do
      assert {:error, %{code: "invalid_request"}} = DnsAcls.normalize_rules(invalid)
    end

    assert {receipts(), business_snapshot(), Repo.all(DnsView)} == before
  end

  test "DNS Service creation provisions its default and repeated provisioning preserves edited settings",
       %{scope: scope, default: default} do
    assert default["name"] == "default"
    assert default["is_default"]
    assert is_nil(default["priority"])
    assert default["client_rules"] == [%{"action" => "allow", "kind" => "any"}]
    assert default["enabled"]
    assert default["recursion_enabled"]
    refute default["ecs_enabled"]
    assert default["fallback_forwarders"] == []
    assert default["fallback_timeout"] == 2000
    assert default["fallback_retries"] == 1
    assert default["revision"] == 1

    edited =
      mutate(
        "update_dns_view",
        edit(scope, default, %{"enabled" => false, "ecs_enabled" => true})
      )

    before = receipts()

    assert {:ok, ^edited} =
             Repo.transaction(fn ->
               DnsViews.provision_default(Repo.get!(Service, scope["service_id"]))
             end)

    assert receipts() == before
    assert {:ok, [^edited]} = DnsViews.list(scope["worker_id"], scope["service_id"])
  end

  test "one resource is assigned to multiple registered Workers and projects explicit ordered rules",
       %{scope: scope} do
    second = mutate("create_worker", %{"id" => "second-worker", "name" => "Second Worker"})
    third = mutate("create_worker", %{"id" => "third-worker", "name" => "Third Worker"})
    original = worker_revisions([scope["worker_id"], second["id"], third["id"]])
    assert DnsViews.resources() == []
    refute DnsViews.has_assignments?(scope["worker_id"])

    attrs = %{
      "name" => "shared",
      "priority" => 7,
      "enabled" => true,
      "recursion_enabled" => true,
      "client_rules" => [
        %{"action" => "deny", "kind" => "networks", "networks" => ["192.0.2.7"]},
        %{"action" => "allow", "kind" => "any"}
      ],
      "worker_ids" => [scope["worker_id"], second["id"], scope["worker_id"]]
    }

    assert {:ok, resource} = DnsViews.save_resource(ui_caller(), attrs)
    id = resource["id"]
    assert resource["worker_ids"] == [second["id"], scope["worker_id"]]
    assert [^resource] = DnsViews.resources()
    assert DnsViews.has_assignments?(scope["worker_id"])
    assert DnsViews.has_assignments?(second["id"])
    refute DnsViews.has_assignments?(third["id"])

    assert DnsViews.target_views(second["id"]) == [
             %{
               "id" => id,
               "priority" => 7,
               "recursion_enabled" => true,
               "client_rules" => [
                 %{"action" => "deny", "kind" => "networks", "networks" => ["192.0.2.7/32"]},
                 %{"action" => "allow", "kind" => "any"}
               ]
             }
           ]

    assert [%{"id" => ^id, "name" => "shared"}] = DnsViews.references(second["id"], 1)
    assert {:ok, %{"id" => ^id}} = DnsViews.get(scope["worker_id"], scope["service_id"], id)
    error("conflict", "delete_dns_view", edit(scope, resource))

    assert worker_revisions(Map.keys(original)) ==
             Map.merge(original, %{
               scope["worker_id"] => original[scope["worker_id"]] + 1,
               second["id"] => original[second["id"]] + 1
             })

    updated_attrs =
      Map.merge(attrs, %{
        "id" => id,
        "expected_revision" => resource["revision"],
        "enabled" => false,
        "worker_ids" => [second["id"], third["id"]]
      })

    assert {:ok, %{"id" => ^id, "revision" => 2} = updated} =
             DnsViews.save_resource(ui_caller(), updated_attrs)

    assert DnsViews.target_views(second["id"]) == []
    assert DnsViews.has_assignments?(second["id"])
    refute DnsViews.has_assignments?(scope["worker_id"])
    assert DnsViews.has_assignments?(third["id"])

    assert worker_revisions(Map.keys(original)) ==
             Map.merge(original, %{
               scope["worker_id"] => original[scope["worker_id"]] + 2,
               second["id"] => original[second["id"]] + 2,
               third["id"] => original[third["id"]] + 1
             })

    assert {:error, %{code: "revision_conflict"}} =
             DnsViews.save_resource(ui_caller(), updated_attrs)

    assert {:ok, ^updated} = DnsViews.delete_resource(ui_caller(), id, updated["revision"])
    assert DnsViews.resources() == []
    refute DnsViews.has_assignments?(second["id"])
    refute DnsViews.has_assignments?(third["id"])
  end

  test "names are unique within one Worker and assignments validate before writing",
       %{scope: scope} do
    second = mutate("create_worker", %{"id" => "other-worker", "name" => "Other Worker"})
    attrs = %{"name" => "same-name", "worker_ids" => [scope["worker_id"]]}
    assert {:ok, first} = DnsViews.save_resource(ui_caller(), attrs)

    assert {:ok, second_view} =
             DnsViews.save_resource(
               ui_caller(),
               Map.merge(attrs, %{"worker_ids" => [second["id"]], "priority" => 12})
             )

    refute first["id"] == second_view["id"]
    prior = worker_revisions([scope["worker_id"], second["id"]])

    for {worker_ids, error} <- [
          {[], "invalid_request"},
          {["missing-worker"], "not_found"},
          {[second["id"]], "conflict"}
        ] do
      assert {:error, %{code: ^error}} =
               DnsViews.save_resource(
                 ui_caller(),
                 Map.merge(attrs, %{
                   "id" => first["id"],
                   "expected_revision" => first["revision"],
                   "worker_ids" => worker_ids
                 })
               )
    end

    assert worker_revisions(Map.keys(prior)) == prior
    assert Enum.sort(DnsViews.resources()) == Enum.sort([first, second_view])

    assert {:error, %{code: "forbidden"}} =
             DnsViews.save_resource(%{ui_caller() | scopes: ["config:read"]}, attrs)
  end

  test "custom Views have complete desired DTOs and numeric priority ordering with default last",
       %{scope: scope, default: default} do
    later = mutate("create_dns_view", create(scope, "later"))
    earlier = mutate("create_dns_view", create(scope, "earlier", %{"priority" => 0}))

    assert Map.keys(later) |> Enum.sort() ==
             Enum.sort(
               ~w(id worker_id service_id name is_default priority enabled recursion_enabled ecs_enabled client_rules fallback_forwarders fallback_timeout fallback_retries revision inserted_at updated_at)
             )

    assert later["worker_id"] == scope["worker_id"]
    assert later["service_id"] == scope["service_id"]
    refute later["is_default"]
    assert later["priority"] == 100
    assert later["client_rules"] == default["client_rules"]
    assert {:ok, _uuid} = Ecto.UUID.cast(later["id"])
    assert {:ok, _time, 0} = DateTime.from_iso8601(later["inserted_at"])

    assert {:ok, [^earlier, ^later, ^default]} =
             DnsViews.list(scope["worker_id"], scope["service_id"])

    assert {:ok, ^later} = DnsViews.get(scope["worker_id"], scope["service_id"], later["id"])
  end

  test "basic partial edits preserve hidden settings, rule order and registration time", %{
    scope: scope
  } do
    settings = %{
      "enabled" => false,
      "recursion_enabled" => false,
      "ecs_enabled" => true,
      "client_rules" => [
        %{"action" => "deny", "kind" => "networks", "networks" => ["192.0.2.17"]},
        %{"action" => "allow", "kind" => "countries", "countries" => ["US", "CA"]}
      ],
      "fallback_forwarders" => [
        %{"address" => "2001:DB8::1", "port" => 5353},
        %{"address" => "192.0.2.1", "port" => 53}
      ],
      "fallback_timeout" => 30_000,
      "fallback_retries" => 5
    }

    view = mutate("create_dns_view", create(scope, "private", settings))
    changed = mutate("update_dns_view", edit(scope, view, %{"priority" => 7}))
    assert changed["priority"] == 7
    assert changed["revision"] == 2

    assert Map.drop(changed, ~w(priority revision updated_at)) ==
             Map.drop(view, ~w(priority revision updated_at))

    refute changed["enabled"]

    assert changed["fallback_forwarders"] == [
             %{"address" => "2001:db8::1", "port" => 5353},
             %{"address" => "192.0.2.1", "port" => 53}
           ]

    empty =
      mutate(
        "update_dns_view",
        edit(scope, changed, %{"client_rules" => [], "fallback_forwarders" => []})
      )

    assert empty["client_rules"] == []
    assert empty["fallback_forwarders"] == []

    assert Map.take(
             empty,
             ~w(enabled recursion_enabled ecs_enabled fallback_timeout fallback_retries)
           ) ==
             Map.take(
               view,
               ~w(enabled recursion_enabled ecs_enabled fallback_timeout fallback_retries)
             )
  end

  test "name and backend-controlled flags cannot change, and default protection applies at the write boundary",
       %{scope: scope, default: default} do
    custom = mutate("create_dns_view", create(scope, "custom"))

    for view <- [default, custom],
        fields <- [%{"name" => view["name"]}, %{"name" => "renamed"}, %{"is_default" => true}] do
      error("invalid_request", "update_dns_view", edit(scope, view, fields))
    end

    for fields <- [
          %{"priority" => nil},
          %{"priority" => 0},
          %{"client_rules" => default["client_rules"]},
          %{"client_rules" => []}
        ] do
      error("invalid_request", "update_dns_view", edit(scope, default, fields))
    end

    error("invalid_request", "create_dns_view", create(scope, "default"))
    error("invalid_request", "create_dns_view", create(scope, "forged", %{"is_default" => true}))
    error("conflict", "delete_dns_view", edit(scope, default))
    assert {:ok, ^default} = DnsViews.get(scope["worker_id"], scope["service_id"], default["id"])
    assert {:ok, ^custom} = DnsViews.get(scope["worker_id"], scope["service_id"], custom["id"])
  end

  test "name, priority and boolean validation reject invalid native values atomically", %{
    scope: scope
  } do
    for name <- [nil, "", "bad.name", "bad name", "end\n", "é", String.duplicate("a", 64)] do
      error("invalid_request", "create_dns_view", create(scope, name))
    end

    for priority <- [nil, -1, 1.0, "1", true, 9_223_372_036_854_775_808] do
      error(
        "invalid_request",
        "create_dns_view",
        create(scope, "invalid", %{"priority" => priority})
      )
    end

    for field <- ~w(enabled recursion_enabled ecs_enabled), value <- [nil, 0, "false", []] do
      error("invalid_request", "create_dns_view", create(scope, "invalid", %{field => value}))
    end

    boundary =
      mutate(
        "create_dns_view",
        create(scope, "_" <> String.duplicate("a", 62), %{"priority" => 9_223_372_036_854_775_807})
      )

    assert boundary["priority"] == 9_223_372_036_854_775_807
    assert byte_size(boundary["name"]) == 63
  end

  test "fallback endpoints preserve IPv4/IPv6 order and duplicates with explicit ports", %{
    scope: scope
  } do
    forwarders = [
      %{"address" => "2001:0DB8:0000::1", "port" => 65_535},
      %{"address" => "192.0.2.1", "port" => 1},
      %{"address" => "2001:db8::1", "port" => 65_535}
    ]

    view =
      mutate(
        "create_dns_view",
        create(scope, "forwarders", %{
          "fallback_forwarders" => forwarders,
          "fallback_timeout" => 100,
          "fallback_retries" => 0
        })
      )

    assert view["fallback_forwarders"] == [
             %{"address" => "2001:db8::1", "port" => 65_535},
             %{"address" => "192.0.2.1", "port" => 1},
             %{"address" => "2001:db8::1", "port" => 65_535}
           ]

    assert view["fallback_retries"] == 0
    assert view["fallback_timeout"] == 100
    maximum = List.duplicate(%{"address" => "::1", "port" => 53}, 128)

    assert mutate("update_dns_view", edit(scope, view, %{"fallback_forwarders" => maximum}))[
             "fallback_forwarders"
           ] == maximum
  end

  test "fallback validation rejects malformed shape, addresses, ports and numeric bounds", %{
    scope: scope
  } do
    for forwarders <- [
          nil,
          %{},
          "192.0.2.1",
          [nil],
          [[]],
          [%{}],
          [%{"address" => "::1"}],
          [%{"port" => 53}],
          [%{"address" => "::1", "port" => 53, "extra" => true}],
          List.duplicate(%{"address" => "::1", "port" => 53}, 129)
        ] do
      error(
        "invalid_request",
        "create_dns_view",
        create(scope, "invalid", %{"fallback_forwarders" => forwarders})
      )
    end

    for address <- [
          nil,
          7,
          "bad-host",
          "127.1",
          "192.0.2.1/24",
          "::1%lo",
          "[::1]:53",
          "192.0.2.1:53",
          "::1\n"
        ] do
      error(
        "invalid_request",
        "create_dns_view",
        create(scope, "invalid", %{
          "fallback_forwarders" => [%{"address" => address, "port" => 53}]
        })
      )
    end

    for port <- [nil, 0, 65_536, -1, "53", 53.0, true] do
      error(
        "invalid_request",
        "create_dns_view",
        create(scope, "invalid", %{
          "fallback_forwarders" => [%{"address" => "::1", "port" => port}]
        })
      )
    end

    for {field, values} <- [
          {"fallback_timeout", [nil, 99, 30_001, "2000", 2000.0]},
          {"fallback_retries", [nil, -1, 6, "1", 1.0]}
        ],
        value <- values do
      error("invalid_request", "create_dns_view", create(scope, "invalid", %{field => value}))
    end
  end

  test "client rule validation shares the ACL contract and failed partial candidates leave prior state intact",
       %{scope: scope} do
    view = mutate("create_dns_view", create(scope, "client-rules"))

    for rules <- [
          nil,
          [nil],
          [%{"action" => "allow", "kind" => "countries", "countries" => []}],
          [%{"action" => "allow", "kind" => "countries", "countries" => ["ZZ"]}],
          [%{"action" => "allow", "kind" => "networks", "networks" => ["::/129"]}],
          [%{"action" => "allow", "kind" => "any", "countries" => ["US"]}],
          List.duplicate(%{"action" => "allow", "kind" => "any"}, 129)
        ] do
      error(
        "invalid_request",
        "update_dns_view",
        edit(scope, view, %{"enabled" => false, "client_rules" => rules})
      )

      assert {:ok, ^view} = DnsViews.get(scope["worker_id"], scope["service_id"], view["id"])
    end
  end

  test "unknown settings and unsupported associations cannot be silently persisted", %{
    scope: scope
  } do
    view = mutate("create_dns_view", create(scope, "strict"))

    for key <-
          ~w(match_clients recursion zones rpz_zones acl_id runtime_state description expected_worker_revision),
        operation <- ~w(create_dns_view update_dns_view delete_dns_view) do
      params =
        if operation == "create_dns_view", do: create(scope, "invalid"), else: edit(scope, view)

      error("invalid_request", operation, Map.put(params, key, []))
    end
  end

  test "concrete DNS Service and native View IDs cannot infer or retarget scope", %{scope: scope} do
    view = mutate("create_dns_view", create(scope, "private"))
    worker = mutate("create_worker", %{"id" => "other-worker", "name" => "Other"})
    other = mutate("put_service", Fixtures.service(worker["id"], 1, "stopped"))
    other_scope = %{"worker_id" => worker["id"], "service_id" => other["id"]}

    for bad_scope <- [
          Map.put(scope, "worker_id", "missing"),
          Map.put(scope, "worker_id", worker["id"]),
          Map.put(scope, "service_id", other["id"]),
          Map.put(scope, "service_id", Ecto.UUID.generate())
        ] do
      assert {:error, %{code: "not_found"}} =
               DnsViews.list(bad_scope["worker_id"], bad_scope["service_id"])

      error("not_found", "create_dns_view", create(bad_scope, "forged"))
      error("not_found", "delete_dns_view", edit(bad_scope, view))
    end

    for operation <- ~w(update_dns_view delete_dns_view),
        do: error("not_found", operation, edit(other_scope, view))

    error(
      "invalid_request",
      "create_dns_view",
      create(Map.put(scope, "service_id", "dns"), "invalid")
    )

    error("not_found", "delete_dns_view", Map.put(edit(scope, view), "id", Ecto.UUID.generate()))
    assert {:ok, ^view} = DnsViews.get(scope["worker_id"], scope["service_id"], view["id"])
    assert mutate("create_dns_view", create(other_scope, "private"))["service_id"] == other["id"]
  end

  test "public readers reject malformed identities without casting crashes or writes", %{
    scope: scope
  } do
    before = receipts()

    for id <- [nil, [], 7, "dns", "", <<255>>, <<0::128>>] do
      assert {:error, %{code: "invalid_request"}} = DnsViews.list(scope["worker_id"], id)

      assert {:error, %{code: "invalid_request"}} =
               DnsViews.get(scope["worker_id"], scope["service_id"], id)
    end

    for worker_id <- [nil, [], "bad name", "end\n", <<255>>] do
      assert {:error, %{code: "invalid_request"}} = DnsViews.list(worker_id, scope["service_id"])
    end

    assert receipts() == before
  end

  test "update and deletion use positive independent CAS with durable idempotent replay", %{
    scope: scope
  } do
    view = replay("create_dns_view", create(scope, "cas"))
    error("conflict", "create_dns_view", create(scope, "cas"))

    for revision <- [nil, 0, -1, "1", 1.0, true],
        operation <- ~w(update_dns_view delete_dns_view) do
      error(
        "invalid_request",
        operation,
        Map.put(edit(scope, view), "expected_revision", revision)
      )
    end

    updated = replay("update_dns_view", edit(scope, view, %{"enabled" => false}))
    assert updated["revision"] == 2
    error("revision_conflict", "update_dns_view", edit(scope, view, %{"priority" => 7}))
    error("revision_conflict", "delete_dns_view", edit(scope, view))
    assert replay("delete_dns_view", edit(scope, updated)) == updated

    assert {:error, %{code: "not_found"}} =
             DnsViews.get(scope["worker_id"], scope["service_id"], updated["id"])
  end

  test "View CRUD invalidates the Worker revision while preserving immutable targets and export bytes",
       %{
         scope: scope
       } do
    zone = mutate("create_zone", Fixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    worker = Repo.get!(Worker, scope["worker_id"])

    assigned =
      mutate(
        "assign",
        Map.merge(scope, %{
          "resource_version_id" => version["id"],
          "expected_revision" => worker.revision
        })
      )

    target =
      mutate("confirm_target", %{
        "worker_id" => worker.id,
        "expected_revision" => assigned["worker_revision"]
      })

    mutate("create_dns_acl", Map.merge(scope, %{"name" => "named", "rules" => []}))
    assert {:ok, exported} = ConfigCompiler.export_target(worker.id, target["revision"])
    before = business_snapshot()
    view = mutate("create_dns_view", create(scope, "desired"))

    updated =
      mutate(
        "update_dns_view",
        edit(scope, view, %{"enabled" => false, "recursion_enabled" => false})
      )

    receipts = receipts()
    assert {:ok, ^updated} = DnsViews.get(worker.id, scope["service_id"], view["id"])
    assert {:ok, views} = DnsViews.list(worker.id, scope["service_id"])
    assert updated in views
    assert receipts() == receipts
    mutate("delete_dns_view", edit(scope, updated))
    assert Map.delete(business_snapshot(), Worker) == Map.delete(before, Worker)
    assert Repo.get!(Worker, worker.id).revision == hd(before[Worker]).revision + 3
    assert {:ok, ^exported} = ConfigCompiler.export_target(worker.id, target["revision"])
  end

  defp create(scope, name, fields \\ %{}), do: scope |> Map.put("name", name) |> Map.merge(fields)

  defp edit(scope, view, fields \\ %{}),
    do:
      Map.merge(
        scope,
        Map.merge(%{"id" => view["id"], "expected_revision" => view["revision"]}, fields)
      )

  defp command(operation, params),
    do: Domain.mutate(operation, params, "operator", Ecto.UUID.generate())

  defp mutate(operation, params) do
    assert {:ok, result} = command(operation, params)
    result
  end

  defp error(code, operation, params),
    do: assert({:error, %{code: ^code}} = command(operation, params))

  defp receipts, do: {Repo.aggregate(Audit, :count), Repo.aggregate(Idempotency, :count)}

  defp worker_revisions(ids), do: Map.new(ids, &{&1, Repo.get!(Worker, &1).revision})

  defp ui_caller do
    %Caller{
      issuer: "urn:yellow-dog:trusted-local",
      subject: "dns-view-resource-test",
      scopes: IntegrationSettings.scopes(),
      source: :ui,
      correlation_id: Ecto.UUID.generate(),
      expires_at: System.system_time(:second) + 600,
      policy_revision: IntegrationSettings.get().policy_revision,
      authentication: :trusted_local
    }
  end

  defp replay(operation, params) do
    key = Ecto.UUID.generate()
    before = receipts()
    assert {:ok, result} = Domain.mutate(operation, params, "operator", key)
    assert {:ok, ^result} = Domain.mutate(operation, params, "operator", key)
    assert receipts() == {elem(before, 0) + 1, elem(before, 1) + 1}
    result
  end

  defp business_snapshot do
    for schema <- [Worker, Service, Zone, Rrset, ResourceVersion, Assignment, Target, DnsAcl],
        into: %{},
        do: {schema, Repo.all(schema) |> Enum.sort_by(& &1.id)}
  end
end
