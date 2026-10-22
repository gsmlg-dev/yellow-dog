defmodule YellowDog.Management.ApplicationAPITest do
  use ExUnit.Case, async: false
  import Plug.Conn

  alias YellowDog.Management.{
    ApplicationAPI,
    Auth,
    Domain,
    GeoIPArtifact,
    HTTPAPI,
    OpenAPI,
    Operations,
    Repo,
    Worker
  }

  alias YellowDog.Management.DomainFixtures, as: Fixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    previous = Application.get_env(:yellow_dog_management, :integration)

    Application.put_env(:yellow_dog_management, :integration, %{
      mode: :trusted_local,
      http_enabled: true,
      mcp_enabled: true,
      write_enabled: true,
      allowed_hosts: ["www.example.com", "localhost", "127.0.0.1"]
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:yellow_dog_management, :integration, previous),
        else: Application.delete_env(:yellow_dog_management, :integration)
    end)

    {:ok, caller} = Auth.authenticate(Plug.Test.conn(:get, "/"), :http)
    Process.put(:covered, MapSet.new())
    %{caller: caller}
  end

  test "all 42 finite operations execute schema-valid canonical results", %{caller: caller} do
    {:ok, worker} =
      Domain.mutate(
        "create_worker",
        %{"id" => "api-node", "name" => "API node"},
        "fixture",
        Ecto.UUID.generate()
      )

    q(caller, "worker_list", %{})
    q(caller, "worker_get", %{"worker_id" => worker["id"]})

    worker =
      c(caller, "worker_update", %{
        "id" => worker["id"],
        "expected_revision" => 1,
        "name" => "Updated"
      })

    service = c(caller, "service_create", service_params(worker["id"], worker["revision"]))

    service =
      c(
        caller,
        "service_update",
        Map.put(
          service_params(worker["id"], service["worker_revision"]),
          "service_id",
          service["id"]
        )
      )

    scope = %{"worker_id" => worker["id"], "service_id" => service["id"]}
    q(caller, "service_list", %{"worker_id" => worker["id"]})
    q(caller, "service_get", scope)
    q(caller, "service_references", scope)
    zone = c(caller, "zone_create", Fixtures.zone())
    q(caller, "zone_list", %{})
    q(caller, "zone_get", %{"id" => zone["id"]})

    zone =
      c(
        caller,
        "zone_update",
        Map.merge(Fixtures.zone(), %{"id" => zone["id"], "expected_revision" => 1})
      )

    version =
      c(caller, "zone_confirm", %{"id" => zone["id"], "expected_revision" => zone["revision"]})

    q(caller, "zone_versions", %{"zone_id" => zone["id"]})
    q(caller, "zone_version_get", %{"zone_id" => zone["id"], "version_id" => version["id"]})
    snapshot = q(caller, "zone_assignments", %{"zone_id" => zone["id"]})

    assignments = [
      %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_version_id" => version["id"]
      }
    ]

    snapshot =
      c(caller, "zone_set_assignments", %{
        "zone_id" => zone["id"],
        "expected_assignment_token" => snapshot["assignment_token"],
        "expected_worker_revisions" => %{worker["id"] => service["worker_revision"]},
        "assignments" => assignments
      })

    assert snapshot["worker_revisions"] |> Map.keys() == [worker["id"]]
    view = c(caller, "dns_view_create", Map.put(scope, "name", "private"))
    q(caller, "dns_view_list", scope)
    q(caller, "dns_view_get", Map.put(scope, "id", view["id"]))

    view =
      c(
        caller,
        "dns_view_update",
        Map.merge(scope, %{"id" => view["id"], "expected_revision" => 1, "enabled" => false})
      )

    c(
      caller,
      "dns_view_delete",
      Map.merge(scope, %{"id" => view["id"], "expected_revision" => view["revision"]})
    )

    acl_fields = %{
      "name" => "office",
      "description" => "Office",
      "rules" => [%{"action" => "allow", "kind" => "networks", "networks" => ["192.0.2.5/24"]}]
    }

    acl = c(caller, "dns_acl_create", Map.merge(scope, acl_fields))
    q(caller, "dns_acl_list", scope)
    q(caller, "dns_acl_get", Map.put(scope, "id", acl["id"]))

    acl =
      c(
        caller,
        "dns_acl_update",
        Map.merge(Map.merge(scope, acl_fields), %{"id" => acl["id"], "expected_revision" => 1})
      )

    c(
      caller,
      "dns_acl_delete",
      Map.merge(scope, %{"id" => acl["id"], "expected_revision" => acl["revision"]})
    )

    preview = q(caller, "worker_target_preview", %{"worker_id" => worker["id"]})
    assert preview["export_scope"]["excluded"] == ~w(dns_views dns_acls geoip_artifacts)

    publish_params = %{
      "worker_id" => worker["id"],
      "expected_revision" => preview["worker_revision"]
    }

    assert {:ok, target} =
             ApplicationAPI.command(caller, "worker_target_publish", publish_params, "publish")

    cover("worker_target_publish")
    assert target["worker_revision"] == preview["worker_revision"] + 1
    assert Repo.get!(Worker, worker["id"]).revision == target["worker_revision"]
    audit_count = Repo.aggregate(YellowDog.Management.Audit, :count)

    assert {:ok, ^target} =
             ApplicationAPI.command(
               %{caller | source: :mcp},
               "worker_target_publish",
               publish_params,
               "publish"
             )

    assert Repo.aggregate(YellowDog.Management.Target, :count) == 1
    assert Repo.aggregate(YellowDog.Management.Audit, :count) == audit_count

    q(caller, "worker_target_history", %{"worker_id" => worker["id"]})
    target_params = %{"worker_id" => worker["id"], "revision" => target["revision"]}
    q(caller, "worker_target_get", target_params)
    export = q(caller, "worker_target_export", target_params)
    assert export["digest"] == target["digest"]
    q(caller, "task_list", %{})
    task = q(caller, "task_get", %{"key" => "ip_city"})

    c(caller, "task_update", %{
      "key" => "ip_city",
      "expected_revision" => task["revision"],
      "enabled" => false,
      "cron" => "0 2 * * *"
    })

    job = c(caller, "ip_database_sync", %{"key" => "ip_city"})
    assert job["verification"] == "unknown"
    q(caller, "task_jobs", %{})
    q(caller, "task_job_get", %{"key" => "ip_city", "job_id" => job["id"]})
    digest = String.duplicate("a", 64)

    Repo.insert!(%GeoIPArtifact{
      digest: digest,
      kind: "city",
      format: "mmdb",
      path: "/private/secret.mmdb",
      size: 32,
      source_url: "https://user:password@source.invalid/a?token=secret",
      metadata: %{"secret" => "sensitive"}
    })

    q(caller, "ip_database_catalog", %{"kind" => "city"})
    metadata = q(caller, "ip_database_artifact", %{"kind" => "city", "digest" => digest})
    refute Jason.encode!(metadata) =~ "secret"
    assert metadata["available"] == nil
    q(caller, "audit_list", %{})
    snapshot = q(caller, "zone_assignments", %{"zone_id" => zone["id"]})

    c(caller, "zone_set_assignments", %{
      "zone_id" => zone["id"],
      "expected_assignment_token" => snapshot["assignment_token"],
      "expected_worker_revisions" => snapshot["worker_revisions"],
      "assignments" => []
    })

    c(caller, "zone_delete", %{"id" => zone["id"], "expected_revision" => zone["revision"]})
    assert Process.get(:covered) == MapSet.new(Operations.all(), & &1.id)
  end

  test "View contracts retain ordered IPv4 and IPv6 endpoints and complete rule fields", %{
    caller: caller
  } do
    raw("create_worker", %{"id" => "rich-api-view", "name" => "Rich View"})
    service = c(caller, "service_create", service_params("rich-api-view", 1))
    scope = %{"worker_id" => "rich-api-view", "service_id" => service["id"]}

    params =
      Map.merge(scope, %{
        "name" => "ordered",
        "priority" => 42,
        "enabled" => false,
        "recursion_enabled" => false,
        "ecs_enabled" => true,
        "client_rules" => [
          %{
            "action" => "deny",
            "kind" => "networks",
            "networks" => ["192.0.2.99/24", "2001:DB8::123/64"]
          },
          %{"action" => "allow", "kind" => "countries", "countries" => ["US", "CA", "US"]},
          %{"action" => "allow", "kind" => "networks", "networks" => []},
          %{"action" => "deny", "kind" => "any"}
        ],
        "fallback_forwarders" => [
          %{"address" => "2001:0DB8:0000::53", "port" => 5353},
          %{"address" => "192.0.2.53", "port" => 53},
          %{"address" => "2001:db8::53", "port" => 5353},
          %{"address" => "::ffff:192.0.2.1", "port" => 65535}
        ],
        "fallback_timeout" => 30000,
        "fallback_retries" => 5
      })

    before = Domain.preview_target("rich-api-view")
    created = c(caller, "dns_view_create", params)

    assert created["fallback_forwarders"] == [
             %{"address" => "2001:db8::53", "port" => 5353},
             %{"address" => "192.0.2.53", "port" => 53},
             %{"address" => "2001:db8::53", "port" => 5353},
             %{"address" => "::ffff:192.0.2.1", "port" => 65535}
           ]

    assert created["client_rules"] == [
             %{
               "action" => "deny",
               "kind" => "networks",
               "networks" => ["192.0.2.0/24", "2001:db8::/64"]
             },
             %{"action" => "allow", "kind" => "countries", "countries" => ["CA", "US"]},
             %{"action" => "allow", "kind" => "networks", "networks" => []},
             %{"action" => "deny", "kind" => "any"}
           ]

    for key <-
          ~w(priority enabled recursion_enabled ecs_enabled fallback_timeout fallback_retries),
        do: assert(created[key] == params[key])

    assert q(%{caller | source: :mcp}, "dns_view_get", Map.put(scope, "id", created["id"])) ==
             created

    assert Domain.preview_target("rich-api-view") == before

    for address <- [
          "::",
          "::1",
          "1:2:3:4:5:6:7:8",
          "1::2:3:4:5:6:7",
          "1:2:3:4:5:6:7::",
          "1:2:3:4:5:6:192.0.2.1",
          "1:2:3:4:5::192.0.2.1"
        ] do
      {:ok, operation} = Operations.get("dns_view_create")
      candidate = Map.put(params, "fallback_forwarders", [%{"address" => address, "port" => 53}])
      assert {:ok, ^candidate} = ApplicationAPI.validate(operation.input_schema, candidate)
    end

    for endpoint <- [
          %{"address" => "1:::2", "port" => 53},
          %{"address" => "1:2:3:4:5:6:7:8:9", "port" => 53},
          %{"address" => "::1%lo", "port" => 53},
          %{"address" => "[::1]", "port" => 53},
          %{"address" => "dns.example.test", "port" => 53},
          %{"address" => "::1", "port" => 53, "unknown" => true}
        ] do
      assert {:error, %{code: "invalid_request", details: %{"fields" => _}}} =
               ApplicationAPI.command(
                 caller,
                 "dns_view_create",
                 Map.put(params, "fallback_forwarders", [endpoint]),
                 Ecto.UUID.generate()
               )
    end

    updated =
      c(
        caller,
        "dns_view_update",
        Map.merge(scope, %{
          "id" => created["id"],
          "expected_revision" => 1,
          "client_rules" => [],
          "fallback_forwarders" => List.duplicate(%{"address" => "::1", "port" => 53}, 128)
        })
      )

    assert updated["client_rules"] == []

    assert updated["fallback_forwarders"] ==
             List.duplicate(%{"address" => "::1", "port" => 53}, 128)

    assert {:error, %{code: "invalid_request"}} =
             ApplicationAPI.command(
               caller,
               "service_create",
               put_in(
                 service_params("rich-api-view", service["worker_revision"]),
                 ["config", "listen_address"],
                 "::1"
               ),
               "ipv4-service-only"
             )
  end

  test "closed schemas reject unknown and nested fields before effects", %{caller: caller} do
    for {operation, params} <- [
          {"worker_update",
           %{"id" => "absent", "expected_revision" => 1, "actor" => "scheduler"}},
          {"service_create", put_in(service_params("absent", 1), ["config", "secret"], true)},
          {"zone_create",
           put_in(Fixtures.zone(), ["records", Access.at(0), "data", "unknown"], true)},
          {"ip_database_sync", %{"key" => "ip_city", "source_url" => "http://example.invalid"}},
          {"ip_database_sync", %{"key" => "mac"}},
          {"task_update",
           %{
             "key" => "ip_city",
             "expected_revision" => 1,
             "enabled" => "true",
             "cron" => "* * * * *"
           }}
        ] do
      assert {:error, %{code: "invalid_request", details: %{"fields" => fields}}} =
               ApplicationAPI.command(caller, operation, params, "bad-schema")

      assert fields != []
    end

    {:ok, operation} = Operations.get("task_update")

    assert {:error, %{details: %{"fields" => fields}}} =
             ApplicationAPI.validate(operation.input_schema, %{
               "key" => "ip_city",
               "expected_revision" => 1,
               "enabled" => "true"
             })

    assert "#/enabled" in fields

    assert Repo.aggregate(YellowDog.Management.Idempotency, :count) == 0
  end

  test "output contract failures roll back new effects and validate successful replays" do
    before = effect_counts()
    params = Fixtures.zone("output-contract.test.")

    reject_output = fn result ->
      assert {:error, %{code: "invalid_request"}} =
               ApplicationAPI.validate(%{"type" => "null"}, result)

      raise ArgumentError, "Output contract mismatch"
    end

    assert_raise ArgumentError, "Output contract mismatch", fn ->
      Domain.mutate("create_zone", params, "fixture", "output-contract",
        validate_result: reject_output
      )
    end

    assert effect_counts() == before
    assert Repo.get_by(YellowDog.Management.Zone, name: params["name"]) == nil

    assert {:ok, zone} = Domain.mutate("create_zone", params, "fixture", "output-contract")

    assert_raise ArgumentError, "Output contract mismatch", fn ->
      Domain.mutate("create_zone", params, "fixture", "output-contract",
        validate_result: reject_output
      )
    end

    assert {:ok, ^zone} = Domain.mutate("create_zone", params, "fixture", "output-contract")
    assert effect_counts() == Enum.map(before, &(&1 + 1))
    assert Repo.get!(YellowDog.Management.Zone, zone["id"]).name == params["name"]
  end

  test "replays preserve identity across transports and reauthorize before receipts", %{
    caller: caller
  } do
    before = effect_counts()
    params = Fixtures.zone("replay.test.")
    assert {:ok, first} = ApplicationAPI.command(caller, "zone_create", params, "logical-intent")
    mcp = %{caller | source: :mcp, correlation_id: Ecto.UUID.generate()}
    assert {:ok, ^first} = ApplicationAPI.command(mcp, "zone_create", params, "logical-intent")

    assert {:error, %{code: "idempotency_conflict"}} =
             ApplicationAPI.command(
               mcp,
               "zone_create",
               Fixtures.zone("other.test."),
               "logical-intent"
             )

    assert {:error, %{code: "forbidden"}} =
             ApplicationAPI.command(%{mcp | scopes: []}, "zone_create", params, "logical-intent")

    assert {:error, %{code: "invalid_token"}} =
             ApplicationAPI.command(
               %{mcp | expires_at: 1},
               "zone_create",
               params,
               "logical-intent"
             )

    assert effect_counts() == Enum.map(before, &(&1 + 1))
    assert Repo.get!(YellowDog.Management.Zone, first["id"]).name == params["name"]

    assert {:ok, new} =
             ApplicationAPI.command(
               %{caller | subject: "another-operator"},
               "zone_create",
               Fixtures.zone("another.test."),
               "logical-intent"
             )

    refute new["id"] == first["id"]
  end

  test "paging is bounded, stable and metadata-only with honest continuation", %{caller: caller} do
    now = DateTime.utc_now()

    Repo.insert_all(
      Worker,
      Enum.map(1..105, fn n ->
        %{
          id: "node-#{String.pad_leading(to_string(n), 3, "0")}",
          name: "Node",
          profile_name: "custom",
          revision: 1,
          inserted_at: now,
          updated_at: now
        }
      end)
    )

    first = q(caller, "worker_list", %{"page_size" => 100})
    assert length(first["items"]) == 100 and first["has_next"]
    second = q(caller, "worker_list", %{"page_size" => 100, "page" => 2})
    assert length(second["items"]) == 5 and not second["has_next"]
    refute Map.has_key?(hd(first["items"]), "connection_token_hash")
    refute Map.has_key?(hd(first["items"]), "reported_services")

    assert {:error, %{code: "invalid_request"}} =
             ApplicationAPI.query(caller, "worker_list", %{"page_size" => 101})

    assert {:error, %{code: "invalid_request"}} =
             ApplicationAPI.query(caller, "worker_list", %{"page" => 0})

    assert {:error, %{code: "invalid_request"}} =
             ApplicationAPI.query(caller, "worker_list", %{"page" => "2"})
  end

  test "scope and exact-version validation never falls back to another object", %{caller: caller} do
    worker = raw("create_worker", %{"id" => "first", "name" => "First"})
    service = c(caller, "service_create", service_params(worker["id"], 1))
    wrong_scope = %{"worker_id" => "other", "service_id" => service["id"]}

    assert {:error, %{code: "not_found"}} =
             ApplicationAPI.query(caller, "service_get", wrong_scope)

    assert {:error, %{code: "not_found"}} =
             ApplicationAPI.query(caller, "dns_view_list", wrong_scope)

    assert {:error, %{code: "invalid_request"}} =
             ApplicationAPI.query(caller, "worker_target_export", %{
               "worker_id" => worker["id"],
               "revision" => "latest"
             })

    assert {:error, %{code: "invalid_request"}} =
             ApplicationAPI.query(caller, "zone_get", %{"id" => "bad"})

    assert {:error, %{code: "forbidden"}} =
             ApplicationAPI.query(%{caller | scopes: []}, "worker_get", %{"worker_id" => "absent"})
  end

  test "HTTP uses finite routes, authoritative IDs, logical keys and documented envelopes" do
    response = request(:post, "/api/v1/zones", Fixtures.zone("http.test."), "http-intent")
    assert response.status == 200
    %{"data" => zone, "correlation_id" => correlation} = Jason.decode!(response.resp_body)
    assert is_binary(correlation)
    response = request(:post, "/api/v1/zones", Fixtures.zone("http.test."), "http-intent")
    assert Jason.decode!(response.resp_body)["data"] == zone

    assert request(
             :patch,
             "/api/v1/zones/#{zone["id"]}",
             %{"id" => Ecto.UUID.generate(), "expected_revision" => 1},
             "different"
           ).status == 400

    assert request(:post, "/api/v1/zones", Fixtures.zone("missing.test.")).status == 400
    response = request(:get, "/api/v1/zones?page=1&page_size=1")
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["data"]["page_size"] == 1
    assert request(:get, "/api/v1/zones?page_size=101").status == 400

    assert request(:post, "/api/v1/commands", %{"operation" => "create_worker"}, "escape").status ==
             404

    response = request(:get, "/api/v1/openapi.json")
    assert Jason.decode!(response.resp_body)["openapi"] == "3.1.2"
  end

  test "HTTP PATCH Worker retains authoritative identity and validates the response contract" do
    raw("create_worker", %{"id" => "patch-node", "name" => "Before"})

    response =
      request(
        :patch,
        "/api/v1/workers/patch-node",
        %{"expected_revision" => 1, "name" => "After"},
        "patch-worker"
      )

    assert response.status == 200
    envelope = Jason.decode!(response.resp_body)
    assert %{"id" => "patch-node", "name" => "After", "revision" => 2} = envelope["data"]
    {:ok, operation} = Operations.get("worker_update")
    assert {:ok, ^envelope} = ApplicationAPI.validate(OpenAPI.success_schema(operation), envelope)

    assert request(
             :patch,
             "/api/v1/workers/patch-node",
             %{"id" => "other-node", "expected_revision" => 2},
             "wrong-worker"
           ).status == 400

    assert {:ok, %{"name" => "After", "revision" => 2}} = Domain.get_worker("patch-node")
  end

  test "HTTP rejects misleading JSON media types before creating a receipt" do
    before = effect_counts()

    for content_type <- [
          "application/jsonp",
          "application/json-evil",
          "text/plain",
          "application/json; charset=iso-8859-1"
        ] do
      response =
        Plug.Test.conn(:post, "/api/v1/zones", Jason.encode!(Fixtures.zone("media.test.")))
        |> put_req_header("content-type", content_type)
        |> put_req_header("idempotency-key", "media-intent")
        |> HTTPAPI.call([])

      assert response.status == 400
      envelope = Jason.decode!(response.resp_body)
      assert {:ok, ^envelope} = ApplicationAPI.validate(OpenAPI.error_schema(), envelope)
    end

    assert effect_counts() == before
    assert Repo.get_by(YellowDog.Management.Zone, name: "media.test.") == nil

    response =
      Plug.Test.conn(:post, "/api/v1/zones", Jason.encode!(Fixtures.zone("valid-media.test.")))
      |> put_req_header("content-type", "application/json; charset=UTF-8")
      |> put_req_header("idempotency-key", "valid-media")
      |> HTTPAPI.call([])

    assert response.status == 200
  end

  test "HTTP and MCP-style facade replay share the same caller namespace", %{caller: caller} do
    data = Fixtures.zone("cross.test.")

    assert {:ok, zone} =
             ApplicationAPI.command(%{caller | source: :mcp}, "zone_create", data, "cross-key")

    conn = request(:post, "/api/v1/zones", data, "cross-key")
    assert conn.status == 200
    assert Jason.decode!(conn.resp_body)["data"] == zone
  end

  test "all operation input and output schemas build as JSON Schema2020-12" do
    assert length(Operations.all()) == 42
    assert length(Enum.uniq_by(Operations.all(), & &1.id)) == 42

    for entry <- Operations.all() do
      assert {:ok, _} = JSV.build(entry.input_schema)
      assert {:ok, _} = JSV.build(entry.output_schema)
      assert entry.input_schema["additionalProperties"] == false
    end

    doc = OpenAPI.document()
    assert doc["openapi"] == "3.1.2"

    ids =
      for {_path, methods} <- doc["paths"], {_method, entry} <- methods, do: entry["operationId"]

    assert MapSet.new(ids) == MapSet.new(Operations.all(), & &1.id)
  end

  defp effect_counts do
    for schema <- [
          YellowDog.Management.Zone,
          YellowDog.Management.Audit,
          YellowDog.Management.Idempotency
        ],
        do: Repo.aggregate(schema, :count)
  end

  defp q(caller, id, params) do
    assert {:ok, data} = ApplicationAPI.query(caller, id, params)
    cover(id)
    data
  end

  defp c(caller, id, params) do
    assert {:ok, data} = ApplicationAPI.command(caller, id, params, Ecto.UUID.generate())
    cover(id)
    data
  end

  defp cover(id), do: Process.put(:covered, MapSet.put(Process.get(:covered), id))

  defp raw(id, params) do
    {:ok, result} = Domain.mutate(id, params, "fixture", Ecto.UUID.generate())
    result
  end

  defp service_params(worker, revision),
    do: %{
      "worker_id" => worker,
      "expected_revision" => revision,
      "instance_id" => "dns",
      "type" => "dns",
      "desired_state" => "running",
      "config" => %{"listen_address" => "127.0.0.1", "port" => 5300}
    }

  defp request(method, path, body \\ nil, key \\ nil) do
    conn =
      Plug.Test.conn(method, path, if(body, do: Jason.encode!(body), else: ""))
      |> put_req_header("content-type", "application/json")

    conn = if key, do: put_req_header(conn, "idempotency-key", key), else: conn
    HTTPAPI.call(conn, [])
  end
end
