defmodule YellowDog.Management.DnsAclsWebTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Domain, DomainFixtures, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    worker =
      mutate("create_worker", %{
        "id" => "acl-http",
        "name" => "ACL HTTP",
        "expected_capabilities" => ["dns"]
      })

    service = mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"]))
    %{worker: worker, service: service, conn: build_conn()}
  end

  test "unauthenticated native API reads explicit service scope and ordered rules",
       context do
    path = "/api/workers/#{context.worker["id"]}/dns-services/#{context.service["id"]}/acls"
    assert json_response(get(context.conn, path), 200)["data"] == []

    command = %{
      "worker_id" => context.worker["id"],
      "service_id" => context.service["id"],
      "name" => "Office",
      "description" => "Office access",
      "rules" => [
        %{
          "action" => "deny",
          "kind" => "networks",
          "networks" => ["192.0.2.15/24", "2001:db8::42/64"]
        },
        %{"action" => "allow", "kind" => "countries", "countries" => ["US", "CA", "US"]},
        %{"action" => "deny", "kind" => "any"}
      ]
    }

    created =
      context.conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("idempotency-key", Ecto.UUID.generate())
      |> post("/api/commands/create_dns_acl", Jason.encode!(command))
      |> json_response(200)
      |> Map.fetch!("data")

    assert created["description"] == "Office access"

    assert created["rules"] == [
             %{
               "action" => "deny",
               "kind" => "networks",
               "networks" => ["192.0.2.0/24", "2001:db8::/64"]
             },
             %{"action" => "allow", "kind" => "countries", "countries" => ["CA", "US"]},
             %{"action" => "deny", "kind" => "any"}
           ]

    assert created["worker_id"] == context.worker["id"]
    assert created["service_id"] == context.service["id"]
    assert json_response(get(context.conn, path), 200)["data"] == [created]
    assert json_response(get(context.conn, path <> "/" <> created["id"]), 200)["data"] == created
  end

  test "unknown and malformed native scopes fail closed without database errors", context do
    for path <- [
          "/api/workers/missing/dns-services/#{context.service["id"]}/acls",
          "/api/workers/#{context.worker["id"]}/dns-services/#{Ecto.UUID.generate()}/acls",
          "/api/workers/#{context.worker["id"]}/dns-services/#{context.service["id"]}/acls/#{Ecto.UUID.generate()}"
        ] do
      assert json_response(get(context.conn, path), 404)["error"]["code"] == "not_found"
    end

    path = "/api/workers/#{context.worker["id"]}/dns-services/not-a-uuid/acls"
    assert json_response(get(context.conn, path), 422)["error"]["code"] == "invalid_request"
  end

  test "malformed ordered rules reject without storing partial policy", context do
    scope = %{
      "worker_id" => context.worker["id"],
      "service_id" => context.service["id"],
      "name" => "Rejected"
    }

    for rule <- [
          %{"action" => "allow", "kind" => "any", "networks" => []},
          %{"action" => "allow", "kind" => "countries", "countries" => ["XX"]},
          %{"kind" => "networks", "networks" => []}
        ] do
      rejected =
        context.conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("idempotency-key", Ecto.UUID.generate())
        |> post("/api/commands/create_dns_acl", Jason.encode!(Map.put(scope, "rules", [rule])))
        |> json_response(422)

      assert rejected["error"]["code"] == "invalid_request"
    end

    assert {:ok, []} = Domain.list_dns_acls(context.worker["id"], context.service["id"])
  end

  test "ACL commands appear as real Worker desired events, never enforcement outcomes", context do
    created =
      mutate("create_dns_acl", %{
        "worker_id" => context.worker["id"],
        "service_id" => context.service["id"],
        "name" => "Restricted",
        "rules" => [%{"action" => "deny", "kind" => "networks", "networks" => []}]
      })

    assert {:error, %{code: "revision_conflict"}} =
             Domain.mutate(
               "delete_dns_acl",
               %{
                 "worker_id" => context.worker["id"],
                 "service_id" => context.service["id"],
                 "id" => created["id"],
                 "expected_revision" => created["revision"] + 1
               },
               "operator",
               Ecto.UUID.generate()
             )

    {:ok, view, _html} = live(context.conn, "/management/events")
    assert has_element?(view, "#management-worker-events", "create_dns_acl")
    assert has_element?(view, "#management-worker-events", "delete_dns_acl")
    assert has_element?(view, "#management-worker-events", "Worker acl-http")

    assert has_element?(
             view,
             "#management-command-outcomes [data-operation='create_dns_acl'][data-outcome='committed']"
           )

    assert has_element?(
             view,
             "#management-command-outcomes [data-operation='delete_dns_acl'][data-outcome='rejected']"
           )
  end

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
