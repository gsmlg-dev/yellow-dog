defmodule YellowDog.Management.DnsAclsTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.{
    Assignment,
    Audit,
    ConfigCompiler,
    Countries,
    DnsAcl,
    DnsAcls,
    Domain,
    Idempotency,
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
    worker = mutate("create_worker", %{"id" => "worker", "name" => "Worker"})
    service = mutate("put_service", Fixtures.service(worker["id"], worker["revision"]))
    %{scope: %{"worker_id" => worker["id"], "service_id" => service["id"]}}
  end

  test "native ACL DTO canonicalizes masks without adding execution or observation fields", %{
    scope: scope
  } do
    acl =
      mutate(
        "create_dns_acl",
        params(scope, "office", [
          "192.0.2.123/24",
          "2001:0DB8:0001::1234/48",
          "198.51.100.1/32",
          "2001:db8::1/128",
          "203.0.113.5/0",
          "2001:db8::1/0",
          "::ffff:192.0.2.123/120",
          "192.0.2.17",
          "2001:db8::17"
        ])
      )

    assert {:ok, _uuid} = Ecto.UUID.cast(acl["id"])

    assert Map.keys(acl) |> Enum.sort() ==
             Enum.sort(
               ~w(id worker_id service_id name description rules revision inserted_at updated_at)
             )

    assert acl["worker_id"] == scope["worker_id"]
    assert acl["service_id"] == scope["service_id"]
    assert acl["name"] == "office"
    assert acl["description"] == ""
    assert acl["revision"] == 1

    assert hd(acl["rules"])["networks"] == [
             "192.0.2.0/24",
             "2001:db8:1::/48",
             "198.51.100.1/32",
             "2001:db8::1/128",
             "0.0.0.0/0",
             "::/0",
             "::ffff:192.0.2.0/120",
             "192.0.2.17/32",
             "2001:db8::17/128"
           ]

    assert {:ok, _created, 0} = DateTime.from_iso8601(acl["inserted_at"])
    assert {:ok, _updated, 0} = DateTime.from_iso8601(acl["updated_at"])
    assert {:ok, ^acl} = DnsAcls.get(scope["worker_id"], scope["service_id"], acl["id"])
    assert Repo.get!(DnsAcl, acl["id"]).rules == acl["rules"]
  end

  test "empty named sets preserve either desired action and list deterministically", %{
    scope: scope
  } do
    last = mutate("create_dns_acl", params(scope, "z-empty", [], "allow"))
    first = mutate("create_dns_acl", params(scope, "a-empty", [], "deny"))
    assert first["rules"] == [network_rule([], "deny")]
    assert last["rules"] == [network_rule([], "allow")]
    assert {:ok, [^first, ^last]} = DnsAcls.list(scope["worker_id"], scope["service_id"])
  end

  test "required fields and identifier bounds validate before storing a candidate", %{
    scope: scope
  } do
    valid = params(scope)

    for field <- ~w(name rules) do
      assert_error("invalid_request", "create_dns_acl", Map.delete(valid, field))
    end

    for name <- [
          "",
          "_first",
          ".first",
          "white space",
          "nonascii-é",
          "end\n",
          String.duplicate("a", 129),
          nil,
          7
        ] do
      assert_error("invalid_request", "create_dns_acl", Map.put(valid, "name", name))
    end

    for action <- ["ALLOW", "reject", "", nil, false, []] do
      candidate = Map.put(valid, "rules", [network_rule([], action)])
      assert_error("invalid_request", "create_dns_acl", candidate)
    end

    acl = mutate("create_dns_acl", params(scope, "9" <> String.duplicate("._-a", 31) <> "end"))
    assert byte_size(acl["name"]) == 128
    assert Repo.aggregate(DnsAcl, :count) == 1
  end

  test "CIDR lists reject malformed, nonstring, nested and excessive networks", %{scope: scope} do
    for networks <- [
          nil,
          "192.0.2.0/24",
          %{},
          [nil],
          [7],
          [false],
          [["192.0.2.0/24"]],
          ["any"],
          ["192.0.2.1/33"],
          ["2001:db8::/129"],
          ["192.0.2.1/-1"],
          ["::/"],
          ["::/+1"],
          ["::/1/2"],
          ["::/1.0"],
          ["192.0.2.999/24"],
          ["127.1/8"],
          ["192.000.2.1/24"],
          [" ::/0"],
          ["::/0\n"],
          ["fe80::1%eth0/64"],
          ["example.test/24"],
          List.duplicate("192.0.2.0/24", 129)
        ] do
      assert_error(
        "invalid_request",
        "create_dns_acl",
        Map.put(params(scope), "rules", [network_rule(networks)])
      )
    end

    assert Repo.aggregate(DnsAcl, :count) == 0
    acl = mutate("create_dns_acl", params(scope, "max", List.duplicate("192.0.2.1/24", 128)))
    assert length(hd(acl["rules"])["networks"]) == 128
    assert Enum.uniq(hd(acl["rules"])["networks"]) == ["192.0.2.0/24"]
  end

  test "only documented mutation keys are accepted", %{scope: scope} do
    acl = mutate("create_dns_acl", params(scope))
    update = params(scope) |> Map.merge(%{"id" => acl["id"], "expected_revision" => 1})
    delete = delete_params(scope, acl)

    for {operation, candidate} <- [
          {"create_dns_acl", params(scope)},
          {"update_dns_acl", update},
          {"delete_dns_acl", delete}
        ],
        key <- ~w(worker_revision config enabled observed_state unexpected action networks) do
      assert_error("invalid_request", operation, Map.put(candidate, key, true))
    end

    assert_error("invalid_request", "create_dns_acl", Map.put(params(scope), "id", acl["id"]))
    assert_error("invalid_request", "delete_dns_acl", Map.put(delete, "name", "office"))
    assert {:ok, ^acl} = DnsAcls.get(scope["worker_id"], scope["service_id"], acl["id"])
  end

  test "native service and ACL identities cannot be inferred or retargeted across scopes", %{
    scope: scope
  } do
    acl = mutate("create_dns_acl", params(scope))
    other_worker = mutate("create_worker", %{"id" => "other", "name" => "Other"})
    other_service = mutate("put_service", Fixtures.service(other_worker["id"], 1))

    for bad_scope <- [
          Map.put(scope, "worker_id", "missing"),
          Map.put(scope, "worker_id", "other"),
          Map.put(scope, "service_id", other_service["id"]),
          Map.put(scope, "service_id", Ecto.UUID.generate())
        ] do
      assert {:error, %{code: "not_found"}} =
               DnsAcls.list(bad_scope["worker_id"], bad_scope["service_id"])

      assert_error("not_found", "create_dns_acl", params(bad_scope))
      assert_error("not_found", "delete_dns_acl", delete_params(bad_scope, acl))
    end

    other_scope = %{"worker_id" => "other", "service_id" => other_service["id"]}
    assert {:error, %{code: "not_found"}} = DnsAcls.get("other", other_service["id"], acl["id"])

    assert_error(
      "not_found",
      "update_dns_acl",
      Map.merge(params(other_scope), %{"id" => acl["id"], "expected_revision" => 1})
    )

    assert_error("not_found", "delete_dns_acl", delete_params(other_scope, acl))

    assert_error(
      "not_found",
      "delete_dns_acl",
      Map.put(delete_params(scope, acl), "id", Ecto.UUID.generate())
    )

    assert_error("invalid_request", "create_dns_acl", params(Map.put(scope, "service_id", "dns")))
    assert {:ok, ^acl} = DnsAcls.get(scope["worker_id"], scope["service_id"], acl["id"])
  end

  test "malformed public reader IDs return errors without writes or Ecto casting crashes", %{
    scope: scope
  } do
    before = receipts()

    for worker_id <- [nil, [], 7, "", "../worker", "worker\n", <<255>>, String.duplicate("w", 65)] do
      assert {:error, %{code: "invalid_request"}} = DnsAcls.list(worker_id, scope["service_id"])
    end

    for id <- [nil, [], 7, "", "dns", "bad-uuid", <<255>>, <<0::128>>, String.duplicate("a", 36)] do
      assert {:error, %{code: "invalid_request"}} = DnsAcls.list(scope["worker_id"], id)

      assert {:error, %{code: "invalid_request"}} =
               DnsAcls.get(scope["worker_id"], scope["service_id"], id)
    end

    assert receipts() == before
  end

  test "a concrete non-DNS service is never treated as a DNS ACL scope", %{scope: scope} do
    worker = Repo.get!(Worker, scope["worker_id"])

    service =
      Repo.insert!(%Service{
        worker_id: worker.id,
        instance_id: "other",
        type: "mdns",
        desired_state: "stopped",
        config: %{}
      })

    bad_scope = Map.put(scope, "service_id", service.id)
    assert {:error, %{code: "invalid_request"}} = DnsAcls.list(worker.id, service.id)
    assert_error("invalid_request", "create_dns_acl", params(bad_scope))
    assert Repo.aggregate(DnsAcl, :count) == 0
  end

  test "uniqueness is per native DNS Service and rename preserves UUID under CAS", %{scope: scope} do
    first = mutate("create_dns_acl", params(scope))
    assert_error("conflict", "create_dns_acl", params(scope))
    worker = Repo.get!(Worker, scope["worker_id"])

    candidate =
      Fixtures.service(worker.id, worker.revision)
      |> Map.put("id", "second")
      |> put_in(["config", "port"], 5301)

    service = mutate("put_service", candidate)
    second_scope = Map.put(scope, "service_id", service["id"])
    other = mutate("create_dns_acl", params(second_scope))
    refute first["id"] == other["id"]
    occupied = mutate("create_dns_acl", params(scope, "occupied"))

    update =
      params(scope, "occupied") |> Map.merge(%{"id" => first["id"], "expected_revision" => 1})

    assert_error("conflict", "update_dns_acl", update)
    updated = mutate("update_dns_acl", Map.put(update, "name", "renamed"))
    assert updated["id"] == first["id"]
    assert updated["revision"] == 2
    assert updated["inserted_at"] == first["inserted_at"]
    assert {:ok, [^occupied, ^updated]} = DnsAcls.list(scope["worker_id"], scope["service_id"])
  end

  test "updates and deletion require positive ACL CAS and rejected edits are atomic", %{
    scope: scope
  } do
    acl = mutate("create_dns_acl", params(scope))
    update = params(scope, "changed", ["2001:db8:1::17/64"], "deny") |> Map.put("id", acl["id"])

    for revision <- [nil, 0, -1, 1.0, "1", true] do
      assert_error(
        "invalid_request",
        "update_dns_acl",
        Map.put(update, "expected_revision", revision)
      )

      assert_error(
        "invalid_request",
        "delete_dns_acl",
        Map.put(delete_params(scope, acl), "expected_revision", revision)
      )
    end

    valid_update = Map.put(update, "expected_revision", 1)

    for field <- ~w(name rules) do
      assert_error("invalid_request", "update_dns_acl", Map.delete(valid_update, field))
    end

    assert_error(
      "invalid_request",
      "update_dns_acl",
      Map.put(valid_update, "rules", [network_rule(["::/129"])])
    )

    assert {:ok, ^acl} = DnsAcls.get(scope["worker_id"], scope["service_id"], acl["id"])
    changed = mutate("update_dns_acl", valid_update)
    assert changed["rules"] == [network_rule(["2001:db8:1::/64"], "deny")]
    assert_error("revision_conflict", "update_dns_acl", valid_update)
    assert_error("revision_conflict", "delete_dns_acl", delete_params(scope, acl))
    assert {:ok, ^changed} = DnsAcls.get(scope["worker_id"], scope["service_id"], acl["id"])
    assert mutate("delete_dns_acl", delete_params(scope, changed)) == changed

    assert {:error, %{code: "not_found"}} =
             DnsAcls.get(scope["worker_id"], scope["service_id"], acl["id"])
  end

  test "Domain idempotency replays create, update, delete and rejection without second audits", %{
    scope: scope
  } do
    create = params(scope)
    acl = replay("create_dns_acl", create)

    update =
      params(scope, "new", [], "deny")
      |> Map.merge(%{"id" => acl["id"], "expected_revision" => 1})

    updated = replay("update_dns_acl", update)
    before = receipts()
    key = Ecto.UUID.generate()

    assert {:error, %{code: "revision_conflict"}} =
             result = Domain.mutate("update_dns_acl", update, "operator", key)

    assert Domain.mutate("update_dns_acl", update, "operator", key) == result
    assert receipts() == {elem(before, 0) + 1, elem(before, 1) + 1}
    assert replay("delete_dns_acl", delete_params(scope, updated)) == updated
    assert {:ok, []} = DnsAcls.list(scope["worker_id"], scope["service_id"])
  end

  test "ACL CRUD and refresh leave worker revisions, DNS configuration, versions and exported targets unchanged",
       %{scope: scope} do
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

    assert {:ok, exported} = ConfigCompiler.export_target(worker.id, target["revision"])
    snapshot = business_snapshot()
    acl = mutate("create_dns_acl", params(scope))

    updated =
      mutate(
        "update_dns_acl",
        params(scope, "new", [], "deny")
        |> Map.merge(%{"id" => acl["id"], "expected_revision" => 1})
      )

    before = receipts()
    assert {:ok, [^updated]} = DnsAcls.list(worker.id, scope["service_id"])
    assert {:ok, ^updated} = DnsAcls.get(worker.id, scope["service_id"], acl["id"])
    assert receipts() == before
    mutate("delete_dns_acl", delete_params(scope, updated))
    assert business_snapshot() == snapshot
    assert {:ok, ^exported} = ConfigCompiler.export_target(worker.id, target["revision"])
  end

  test "PostgreSQL independently enforces native names, descriptions, revisions, uniqueness and FK restriction",
       %{scope: scope} do
    acl = mutate("create_dns_acl", params(scope))

    for {field, value, code} <- [
          {"name", "_bad", :check_violation},
          {"name", "nonascii-é", :check_violation},
          {"name", String.duplicate("a", 129), :string_data_right_truncation},
          {"revision", 0, :check_violation},
          {"description", String.duplicate("界", 256), :check_violation}
        ] do
      pg_error(
        "UPDATE management_dns_acls SET #{field} = $1 WHERE id = '#{acl["id"]}'",
        [value],
        code
      )
    end

    insert =
      "INSERT INTO management_dns_acls (id,service_id,name,description,rules,revision,inserted_at,updated_at) VALUES ('#{Ecto.UUID.generate()}','#{scope["service_id"]}','office','','{}',1,now(),now())"

    pg_error(insert, [], :unique_violation)

    pg_error(
      String.replace(insert, scope["service_id"], Ecto.UUID.generate()),
      [],
      :foreign_key_violation
    )

    pg_error(
      "DELETE FROM management_services WHERE id = '#{scope["service_id"]}'",
      [],
      :foreign_key_violation
    )

    assert {:ok, ^acl} = DnsAcls.get(scope["worker_id"], scope["service_id"], acl["id"])
  end

  test "country catalogue reads are pure, complete and safe for search inputs" do
    before = {receipts(), business_snapshot(), Repo.aggregate(DnsAcl, :count)}
    countries = Countries.list()
    assert length(countries) == 249
    assert Countries.codes() == Enum.map(countries, & &1.code)
    assert length(Enum.uniq(Countries.codes())) == 249
    assert Countries.codes() == Enum.sort(Countries.codes())
    assert {:ok, %{code: "US", name: "United States"}} = Countries.get("US")
    assert Countries.valid?("US")
    assert Countries.search("uNiTeD") |> Enum.map(& &1.code) == ["AE", "GB", "US"]
    assert Countries.search(" US ") |> Enum.any?(&(&1.code == "US"))
    assert Countries.search("") == countries

    for invalid <- [nil, [], 7, "us", "ZZ", "US\n", <<255>>] do
      refute Countries.valid?(invalid)
      assert {:error, :not_found} = Countries.get(invalid)
    end

    for invalid <- [nil, [], 7, <<255>>], do: assert(Countries.search(invalid) == [])
    assert {receipts(), business_snapshot(), Repo.aggregate(DnsAcl, :count)} == before
  end

  test "builtin recipes return ordinary desired rules without writes or implicit scope" do
    before = {receipts(), business_snapshot(), Repo.aggregate(DnsAcl, :count)}
    assert {:ok, [%{"action" => "allow", "kind" => "any"}]} = DnsAcls.preset_rules("any")
    assert {:ok, [%{"action" => "deny", "kind" => "any"}]} = DnsAcls.preset_rules("none")
    assert {:ok, [localhost]} = DnsAcls.preset_rules("localhost")
    assert localhost == network_rule(["127.0.0.1/32", "::1/128"])
    assert {:ok, [localnets]} = DnsAcls.preset_rules("localnets")
    assert localnets == network_rule(["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"])

    for invalid <- [nil, [], 7, "ANY", "geo", "custom", "missing"] do
      assert {:error, %{code: "invalid_request"}} = DnsAcls.preset_rules(invalid)
    end

    assert {receipts(), business_snapshot(), Repo.aggregate(DnsAcl, :count)} == before
  end

  test "mixed rule order and repeated rules survive while countries normalize within their own rule",
       %{scope: scope} do
    rules = [
      network_rule(["192.0.2.17"], "deny"),
      %{"action" => "allow", "kind" => "countries", "countries" => ["US", "CA", "US"]},
      network_rule(["198.51.100.17/24", "192.0.2.17/24", "198.51.100.17/24"]),
      %{"action" => "deny", "kind" => "countries", "countries" => ["US"]},
      %{"action" => "deny", "kind" => "any"},
      %{"action" => "deny", "kind" => "any"}
    ]

    expected = [
      network_rule(["192.0.2.17/32"], "deny"),
      %{"action" => "allow", "kind" => "countries", "countries" => ["CA", "US"]},
      network_rule(["198.51.100.0/24", "192.0.2.0/24", "198.51.100.0/24"]),
      %{"action" => "deny", "kind" => "countries", "countries" => ["US"]},
      %{"action" => "deny", "kind" => "any"},
      %{"action" => "deny", "kind" => "any"}
    ]

    acl = mutate("create_dns_acl", Map.put(params(scope), "rules", rules))
    assert acl["rules"] == expected
    assert Repo.get!(DnsAcl, acl["id"]).rules == expected
    assert {:ok, ^acl} = DnsAcls.get(scope["worker_id"], scope["service_id"], acl["id"])
  end

  test "empty rules and both empty network actions are preserved independently", %{scope: scope} do
    empty = mutate("create_dns_acl", Map.put(params(scope, "empty"), "rules", []))

    sets =
      mutate(
        "create_dns_acl",
        Map.put(params(scope, "sets"), "rules", [network_rule([]), network_rule([], "deny")])
      )

    assert empty["rules"] == []
    assert sets["rules"] == [network_rule([]), network_rule([], "deny")]
    assert {:ok, [^empty, ^sets]} = DnsAcls.list(scope["worker_id"], scope["service_id"])
  end

  test "Unicode descriptions roundtrip at 255 codepoints and invalid descriptions abort before mutation",
       %{scope: scope} do
    description = String.duplicate("界", 255)
    acl = mutate("create_dns_acl", Map.put(params(scope), "description", description))
    assert acl["description"] == description

    for invalid <- [nil, [], 7, String.duplicate("界", 256), String.duplicate("e\u0301", 128)] do
      assert_error(
        "invalid_request",
        "create_dns_acl",
        Map.put(params(scope, "invalid"), "description", invalid)
      )
    end

    before = {receipts(), business_snapshot(), Repo.all(DnsAcl)}

    for invalid <- ["bad\0text", <<255>>] do
      candidate = Map.put(params(scope, "invalid"), "description", invalid)

      assert {:management_abort, %{code: "invalid_request"}} =
               catch_throw(DnsAcls.dispatch("create_dns_acl", candidate))
    end

    assert {receipts(), business_snapshot(), Repo.all(DnsAcl)} == before
    assert {:ok, ^acl} = DnsAcls.get(scope["worker_id"], scope["service_id"], acl["id"])
  end

  test "strict rule shapes reject missing actions, mixed payloads, references and unknown fields",
       %{scope: scope} do
    for rules <- [
          nil,
          %{},
          "any",
          [nil],
          [[]],
          [7],
          [%{}],
          [%{"kind" => "any"}],
          [%{"action" => "allow"}],
          [%{"action" => "ALLOW", "kind" => "any"}],
          [%{"action" => "allow", "kind" => "builtin", "name" => "any"}],
          [%{"action" => "allow", "kind" => "acl", "id" => Ecto.UUID.generate()}],
          [%{"action" => "allow", "kind" => "any", "networks" => []}],
          [%{"action" => "allow", "kind" => "any", "negated" => true}],
          [%{"action" => "allow", "kind" => "networks"}],
          [%{"action" => "allow", "kind" => "countries"}],
          [Map.put(network_rule([]), "countries", ["US"])],
          [Map.put(network_rule([]), "extra", true)]
        ] do
      assert_error("invalid_request", "create_dns_acl", Map.put(params(scope), "rules", rules))
    end

    assert Repo.aggregate(DnsAcl, :count) == 0
  end

  test "country rules require nonempty uppercase catalogue entries and bounded input", %{
    scope: scope
  } do
    for countries <- [
          nil,
          [],
          %{},
          "US",
          [nil],
          [7],
          [false],
          [["US"]],
          ["us"],
          ["ZZ"],
          ["USA"],
          ["US\n"],
          List.duplicate("US", 250)
        ] do
      rule = %{"action" => "allow", "kind" => "countries", "countries" => countries}
      assert_error("invalid_request", "create_dns_acl", Map.put(params(scope), "rules", [rule]))
    end

    rule = %{
      "action" => "deny",
      "kind" => "countries",
      "countries" => Enum.reverse(Countries.codes())
    }

    acl = mutate("create_dns_acl", Map.put(params(scope), "rules", [rule]))
    assert hd(acl["rules"])["countries"] == Countries.codes()
  end

  test "rule count and aggregate network count are bounded without merging", %{scope: scope} do
    any = %{"action" => "allow", "kind" => "any"}

    assert_error(
      "invalid_request",
      "create_dns_acl",
      Map.put(params(scope), "rules", List.duplicate(any, 129))
    )

    rules = [
      network_rule(List.duplicate("192.0.2.0/24", 65)),
      network_rule(List.duplicate("::/0", 64))
    ]

    assert_error("invalid_request", "create_dns_acl", Map.put(params(scope), "rules", rules))

    bounded = [
      network_rule(List.duplicate("192.0.2.0/24", 64)),
      network_rule(List.duplicate("::/0", 64))
    ]

    acl = mutate("create_dns_acl", Map.put(params(scope, "bounded"), "rules", bounded))
    assert acl["rules"] == bounded
    rules = List.duplicate(any, 128)
    maximum = mutate("create_dns_acl", Map.put(params(scope, "maximum"), "rules", rules))
    assert maximum["rules"] == rules
  end

  test "rich list reorder and description changes are atomic under ACL CAS", %{scope: scope} do
    rules = [
      network_rule(["192.0.2.0/24"], "deny"),
      %{"action" => "allow", "kind" => "countries", "countries" => ["US"]}
    ]

    acl =
      mutate(
        "create_dns_acl",
        params(scope) |> Map.put("rules", rules) |> Map.put("description", "first")
      )

    update =
      params(scope)
      |> Map.merge(%{
        "id" => acl["id"],
        "expected_revision" => 1,
        "rules" => Enum.reverse(rules),
        "description" => "second"
      })

    edited = mutate("update_dns_acl", update)
    assert edited["rules"] == Enum.reverse(rules)
    assert edited["description"] == "second"
    assert edited["revision"] == 2
    assert_error("revision_conflict", "update_dns_acl", update)

    invalid =
      update
      |> Map.put("expected_revision", 2)
      |> Map.put("rules", [%{"action" => "allow", "kind" => "countries", "countries" => ["ZZ"]}])

    assert_error("invalid_request", "update_dns_acl", invalid)
    assert {:ok, ^edited} = DnsAcls.get(scope["worker_id"], scope["service_id"], acl["id"])
    reset = update |> Map.put("expected_revision", 2) |> Map.delete("description")
    assert mutate("update_dns_acl", reset)["description"] == ""
  end

  test "PostgreSQL rejects malformed rule shapes, noncanonical networks and aggregate overflow",
       %{scope: scope} do
    acl = mutate("create_dns_acl", params(scope))
    any = %{"action" => "allow", "kind" => "any"}

    for rules <- [
          [nil],
          [7],
          ["any"],
          [%{}],
          [%{"kind" => "any"}],
          [%{"action" => "allow"}],
          [%{"action" => nil, "kind" => "any"}],
          [%{"action" => "allow", "kind" => nil}],
          [%{"action" => 7, "kind" => "any"}],
          [%{"action" => "allow", "kind" => "unknown"}],
          [%{"action" => "drop", "kind" => "any"}],
          [Map.put(any, "extra", true)],
          [Map.put(any, "networks", [])],
          [network_rule(["192.0.2.1/24"])],
          [network_rule(["192.0.2.0/024"])],
          [network_rule(["::1"])],
          [network_rule(["bad-cidr"])],
          [network_rule([nil])],
          [network_rule(nil)],
          [%{"action" => "allow", "kind" => "networks"}],
          [%{"action" => "allow", "kind" => "countries"}],
          [%{"action" => "allow", "kind" => "countries", "countries" => nil}],
          [%{"action" => "allow", "kind" => "countries", "countries" => []}],
          [%{"action" => "allow", "kind" => "countries", "countries" => ["us"]}],
          [%{"action" => "allow", "kind" => "countries", "countries" => ["USA"]}],
          [%{"action" => "allow", "kind" => "countries", "countries" => ["US\n"]}],
          [%{"action" => "allow", "kind" => "countries", "countries" => [7]}],
          [
            %{
              "action" => "allow",
              "kind" => "countries",
              "countries" => List.duplicate("US", 250)
            }
          ],
          List.duplicate(any, 129),
          [
            network_rule(List.duplicate("192.0.2.0/24", 65)),
            network_rule(List.duplicate("::/0", 64))
          ]
        ] do
      pg_error(
        "UPDATE management_dns_acls SET rules = $1 WHERE id = '#{acl["id"]}'",
        [rules],
        :check_violation
      )
    end

    for value <- [
          "ARRAY['null'::jsonb]",
          "ARRAY[ARRAY[jsonb_build_object('action','allow','kind','any')]]",
          "array_fill(jsonb_build_object('action','allow','kind','any'), ARRAY[1], ARRAY[0])"
        ] do
      pg_error(
        "UPDATE management_dns_acls SET rules = #{value} WHERE id = '#{acl["id"]}'",
        [],
        :check_violation
      )
    end

    assert {:ok, ^acl} = DnsAcls.get(scope["worker_id"], scope["service_id"], acl["id"])
  end

  defp params(scope, name \\ "office", networks \\ ["192.0.2.0/24"], action \\ "allow"),
    do: Map.merge(scope, %{"name" => name, "rules" => [network_rule(networks, action)]})

  defp network_rule(networks, action \\ "allow"),
    do: %{"action" => action, "kind" => "networks", "networks" => networks}

  defp delete_params(scope, acl),
    do: Map.merge(scope, %{"id" => acl["id"], "expected_revision" => acl["revision"]})

  defp command(operation, params),
    do: Domain.mutate(operation, params, "operator", Ecto.UUID.generate())

  defp mutate(operation, params) do
    assert {:ok, result} = command(operation, params)
    result
  end

  defp assert_error(code, operation, params) do
    assert {:error, %{code: ^code}} = command(operation, params)
  end

  defp receipts, do: {Repo.aggregate(Audit, :count), Repo.aggregate(Idempotency, :count)}

  defp replay(operation, params) do
    key = Ecto.UUID.generate()
    before = receipts()
    assert {:ok, result} = Domain.mutate(operation, params, "operator", key)
    assert {:ok, ^result} = Domain.mutate(operation, params, "operator", key)
    assert receipts() == {elem(before, 0) + 1, elem(before, 1) + 1}
    result
  end

  defp business_snapshot do
    for schema <- [Worker, Service, Zone, Rrset, ResourceVersion, Assignment, Target],
        into: %{},
        do: {schema, Repo.all(schema) |> Enum.sort_by(& &1.id)}
  end

  defp pg_error(statement, params, code) do
    assert {:error, %Postgrex.Error{postgres: %{code: ^code}}} = Repo.query(statement, params)
  end
end
