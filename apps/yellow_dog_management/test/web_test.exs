defmodule YellowDog.Management.WebTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias YellowDog.Management.{Repo, Web}

  @token String.duplicate("test-operator-", 3)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    previous = System.get_env("YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN")
    System.put_env("YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN", @token)

    on_exit(fn ->
      if previous,
        do: System.put_env("YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN", previous),
        else: System.delete_env("YELLOW_DOG_MANAGEMENT_OPERATOR_TOKEN")
    end)

    :ok
  end

  test "public shell contains usable workflows and protects all business API reads" do
    response = call(:get, "/")
    assert response.status == 200
    assert response.resp_body =~ "DNS zones"
    assert response.resp_body =~ "Actual runtime state is unknown"
    assert call(:get, "/api/workers").status == 401
    assert call(:get, "/api/zones").status == 401
  end

  test "authenticated API creates a logical Worker and retries exactly once" do
    body = %{"id" => "api-worker", "name" => "API Worker", "expected_capabilities" => ["dns"]}
    first = command("create_worker", body, "create-worker")
    assert first.status == 200, first.resp_body
    assert command("create_worker", body, "create-worker").resp_body == first.resp_body
    workers = authorized(:get, "/api/workers") |> decoded()
    assert length(workers) == 1
    assert hd(workers)["actual_state"] == "unknown"

    conflict = command("create_worker", %{body | "name" => "Other"}, "create-worker")
    assert conflict.status == 409
  end

  test "mutations require idempotency keys and reject malformed, excessive and unsupported bodies" do
    assert authorized(:post, "/api/commands/create_worker", "{}").status == 422
    assert authorized(:post, "/api/commands/create_worker", "{").status == 400

    assert authorized(:post, "/api/commands/create_worker", String.duplicate(" ", 1_048_577)).status ==
             413

    response =
      conn(:post, "/api/commands/create_worker", "x")
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "text/plain")
      |> Web.call(Web.init([]))

    assert response.status == 415
  end

  test "unknown operations, malformed IDs and revision conflicts are structured errors" do
    assert command("activate_worker", %{}, "unsupported").status == 422
    assert authorized(:get, "/api/zones/not-a-uuid").status in [404, 422]
    assert authorized(:get, "/api/workers/absent/targets/bad/export").status == 422

    body = %{"id" => "stale-worker", "name" => "Original", "expected_capabilities" => ["dns"]}
    assert command("create_worker", body, "original").status == 200

    assert command(
             "update_worker",
             Map.merge(body, %{"name" => "Stale", "expected_revision" => 0}),
             "stale"
           ).status == 409
  end

  defp command(operation, body, key) do
    conn(:post, "/api/commands/" <> operation, Jason.encode!(body))
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("idempotency-key", key)
    |> Web.call(Web.init([]))
  end

  defp authorized(method, path, body \\ nil) do
    conn(method, path, body)
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> Web.call(Web.init([]))
  end

  defp call(method, path), do: conn(method, path) |> Web.call(Web.init([]))
  defp decoded(conn), do: Jason.decode!(conn.resp_body)["data"]
end
