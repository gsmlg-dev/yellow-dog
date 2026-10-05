defmodule YellowDog.Management.DnsViewsWebTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Domain, DomainFixtures, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    worker = mutate("create_worker", %{"id" => "view-http", "name" => "Views HTTP"})
    service = mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"]))
    %{conn: build_conn(), scope: %{"worker_id" => worker["id"], "service_id" => service["id"]}}
  end

  test "native no-login API exposes durable default and partial desired edits", context do
    path = path(context.scope)
    [default] = json_response(get(context.conn, path), 200)["data"]
    assert default["is_default"] and default["priority"] == nil
    assert default["client_rules"] == [%{"action" => "allow", "kind" => "any"}]

    body =
      Map.merge(context.scope, %{
        "name" => "office",
        "ecs_enabled" => true,
        "client_rules" => [
          %{"action" => "allow", "kind" => "countries", "countries" => ["US", "CA"]}
        ],
        "fallback_forwarders" => [%{"address" => "2001:0DB8::1", "port" => 5353}]
      })

    created = command(context.conn, "create_dns_view", body, 200)["data"]
    assert created["fallback_forwarders"] == [%{"address" => "2001:db8::1", "port" => 5353}]

    update =
      Map.merge(context.scope, %{
        "id" => created["id"],
        "expected_revision" => created["revision"],
        "enabled" => false
      })

    changed = command(context.conn, "update_dns_view", update, 200)["data"]
    assert changed["enabled"] == false

    for field <-
          ~w(name priority recursion_enabled ecs_enabled client_rules fallback_forwarders fallback_timeout fallback_retries) do
      assert changed[field] == created[field]
    end

    assert json_response(get(context.conn, path <> "/" <> created["id"]), 200)["data"] == changed

    assert command(context.conn, "update_dns_view", update, 409)["error"]["code"] ==
             "revision_conflict"

    {:ok, view, _html} = live(context.conn, "/management/events")
    assert has_element?(view, "#management-worker-events", "create_dns_view")
    assert has_element?(view, "#management-worker-events", "update_dns_view")
  end

  test "scope errors and default mutations reject without changing data", context do
    [default] = json_response(get(context.conn, path(context.scope)), 200)["data"]

    body =
      Map.merge(context.scope, %{
        "id" => default["id"],
        "expected_revision" => default["revision"]
      })

    for {operation, patch, status} <- [
          {"delete_dns_view", %{}, 409},
          {"update_dns_view", %{"priority" => 0}, 422},
          {"update_dns_view", %{"client_rules" => []}, 422}
        ] do
      assert command(context.conn, operation, Map.merge(body, patch), status)["error"]
    end

    assert json_response(get(context.conn, path(context.scope)), 200)["data"] == [default]

    assert json_response(
             get(context.conn, path(%{context.scope | "worker_id" => "missing"})),
             404
           )["error"]["code"] == "not_found"

    assert json_response(
             get(context.conn, path(%{context.scope | "service_id" => "bad-id"})),
             422
           )["error"]["code"] == "invalid_request"

    assert json_response(
             get(context.conn, path(context.scope) <> "/" <> Ecto.UUID.generate()),
             404
           )["error"]["code"] == "not_found"
  end

  defp path(scope),
    do: "/api/workers/#{scope["worker_id"]}/dns-services/#{scope["service_id"]}/views"

  defp command(conn, operation, params, status) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("idempotency-key", Ecto.UUID.generate())
    |> post("/api/commands/" <> operation, Jason.encode!(params))
    |> json_response(status)
  end

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
