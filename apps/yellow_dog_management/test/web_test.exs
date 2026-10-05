defmodule YellowDog.Management.WebTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias YellowDog.Management.{Repo, Web}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "business API reads require no login" do
    for path <- ["/api/workers", "/api/zones"] do
      response = request(:get, path)
      assert response.status == 200
      assert get_resp_header(response, "www-authenticate") == []
    end
  end

  test "API creates a logical Worker without login and retries exactly once" do
    body = %{"id" => "api-worker", "name" => "API Worker", "expected_capabilities" => ["dns"]}
    first = command("create_worker", body, "create-worker")
    assert first.status == 200, first.resp_body
    assert command("create_worker", body, "create-worker").resp_body == first.resp_body
    workers = request(:get, "/api/workers") |> decoded()
    assert length(workers) == 1
    assert hd(workers)["actual_state"] == "unknown"

    conflict = command("create_worker", %{body | "name" => "Other"}, "create-worker")
    assert conflict.status == 409
  end

  test "mutations require idempotency keys and reject malformed, excessive and unsupported bodies" do
    assert request(:post, "/api/commands/create_worker", "{}").status == 422
    assert request(:post, "/api/commands/create_worker", "{").status == 400

    assert request(:post, "/api/commands/create_worker", String.duplicate(" ", 1_048_577)).status ==
             413

    response =
      conn(:post, "/api/commands/create_worker", "x")
      |> put_req_header("content-type", "text/plain")
      |> Web.call(Web.init([]))

    assert response.status == 415
  end

  test "unknown operations, malformed IDs and revision conflicts are structured errors" do
    assert command("activate_worker", %{}, "unsupported").status == 422
    assert request(:get, "/api/zones/not-a-uuid").status in [404, 422]
    assert request(:get, "/api/workers/absent/targets/bad/export").status == 422

    body = %{"id" => "stale-worker", "name" => "Original", "expected_capabilities" => ["dns"]}
    assert command("create_worker", body, "original").status == 200

    assert command(
             "update_worker",
             Map.merge(body, %{"name" => "Stale", "expected_revision" => 0}),
             "stale"
           ).status == 409
  end

  test "put_service rejects unsupported fields with 422 and unchanged Worker state" do
    worker = %{"id" => "api-service", "name" => "API Service", "expected_capabilities" => ["dns"]}
    assert command("create_worker", worker, "api-service-worker").status == 200
    before_worker = request(:get, "/api/workers/api-service") |> decoded()

    request = %{
      "worker_id" => worker["id"],
      "expected_revision" => before_worker["revision"],
      "id" => "dns",
      "type" => "dns",
      "desired_status" => "running",
      "config" => %{"listen_address" => "127.0.0.1", "port" => 5300}
    }

    rejected = command("put_service", request, "api-service-typo")
    assert rejected.status == 422, rejected.resp_body

    assert Jason.decode!(rejected.resp_body) == %{
             "error" => %{
               "code" => "invalid_request",
               "message" => "Unsupported field: desired_status",
               "details" => %{}
             }
           }

    assert command("put_service", request, "api-service-typo").resp_body == rejected.resp_body
    assert request(:get, "/api/workers/api-service") |> decoded() == before_worker

    corrected = request |> Map.delete("desired_status") |> Map.put("desired_state", "running")
    assert command("put_service", corrected, "api-service-typo").status == 409
    saved = command("put_service", corrected, "api-service-corrected")
    assert saved.status == 200, saved.resp_body
    assert decoded(saved)["desired_state"] == "running"
    running_worker = request(:get, "/api/workers/api-service") |> decoded()
    assert running_worker["revision"] == before_worker["revision"] + 1

    update = %{
      request
      | "expected_revision" => running_worker["revision"],
        "desired_status" => "stopped"
    }

    rejected_update = command("put_service", update, "api-service-update-typo")
    assert rejected_update.status == 422, rejected_update.resp_body
    assert request(:get, "/api/workers/api-service") |> decoded() == running_worker

    default_request = %{
      "worker_id" => worker["id"],
      "expected_revision" => running_worker["revision"],
      "config" => request["config"]
    }

    defaulted = command("put_service", default_request, "api-service-defaults")
    assert defaulted.status == 200, defaulted.resp_body

    assert %{"instance_id" => "dns", "type" => "dns", "desired_state" => "stopped"} =
             decoded(defaulted)
  end

  defp command(operation, body, key) do
    conn(:post, "/api/commands/" <> operation, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("idempotency-key", key)
    |> Web.call(Web.init([]))
  end

  defp request(method, path, body \\ nil) do
    conn(method, path, body)
    |> put_req_header("content-type", "application/json")
    |> Web.call(Web.init([]))
  end

  defp decoded(conn), do: Jason.decode!(conn.resp_body)["data"]
end
