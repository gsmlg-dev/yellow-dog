defmodule YellowDog.Management.WorkerConnectionsTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias YellowDog.Management.{
    Audit,
    Domain,
    DomainFixtures,
    Idempotency,
    Repo,
    Worker,
    WorkerAPI,
    WorkerConnections
  }

  alias YellowDog.ManagementUI.Router

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "name-only enrollment generates unique identities and stores only credential hashes" do
    {:ok, first} = WorkerConnections.create("Office")
    {:ok, second} = WorkerConnections.create("Office")
    assert first["worker"]["id"] != second["worker"]["id"]
    assert first["token"] != second["token"]
    assert {:ok, _} = Ecto.UUID.cast(first["worker"]["id"])
    assert byte_size(first["token"]) == 43
    assert {:ok, worker} = Domain.get_worker(first["worker"]["id"])
    assert worker["name"] == "Office"
    assert worker["services"] == []
    assert worker["connection_status"] == "not_yet_connected"
    assert worker["status"] == "not_yet_connected"
    assert worker["actual_state"] == "unknown"

    stored = Repo.get!(Worker, worker["id"])
    assert stored.connection_token_hash == :crypto.hash(:sha256, first["token"])
    refute inspect(stored) =~ Base.encode16(stored.connection_token_hash)

    ordinary =
      Jason.encode!([
        Domain.list_workers(),
        worker,
        Repo.all(Audit) |> Enum.map(& &1.result),
        Repo.all(Idempotency) |> Enum.map(& &1.result)
      ])

    refute ordinary =~ first["token"]
    refute ordinary =~ "connection_token_hash"
  end

  test "invalid names leave no enrollment, audit or idempotency rows" do
    for name <- [nil, "", " ", " Office", "Office ", String.duplicate("a", 129), "a" <> <<0>>] do
      assert {:error, %{code: "invalid_request"}} = WorkerConnections.create(name)
    end

    assert Repo.aggregate(Worker, :count) == 0
    assert Repo.aggregate(Audit, :count) == 0
    assert Repo.aggregate(Idempotency, :count) == 0
  end

  test "generated configuration is complete flat TOML with escaped operator text" do
    {:ok, result} = WorkerConnections.create("Office")

    snippet =
      WorkerConnections.bootstrap(
        result["worker"],
        result["token"],
        "https://yellow-dog.gsmlg.net"
      )

    assert {:ok, config} = Toml.decode(snippet)

    assert config == %{
             "worker_id" => result["worker"]["id"],
             "data_dir" => "data",
             "management_url" => "https://yellow-dog.gsmlg.net",
             "token" => result["token"],
             "poll_interval_ms" => 10000
           }
  end

  test "Bearer authentication scopes identity, records contact and needs no browser CSRF" do
    {:ok, first} = WorkerConnections.create("First")
    {:ok, second} = WorkerConnections.create("Second")
    report = report(first)
    assert request(nil, report).status == 401
    assert request(String.duplicate("x", 43), report).status == 401
    assert request(second["token"], report).status == 401

    assert request(first["token"], Map.put(report, "worker_id", second["worker"]["id"])).status ==
             401

    response = request(first["token"], report, Router, "/api/worker/connect")
    assert response.status == 200, response.resp_body
    assert get_resp_header(response, "cache-control") == ["no-store"]

    assert Jason.decode!(response.resp_body) == %{
             "worker_id" => first["worker"]["id"],
             "target" => nil
           }

    assert {:ok, worker} = Domain.get_worker(first["worker"]["id"])
    assert worker["connection_status"] == "connected"
    assert worker["last_seen_at"] != nil
    assert worker["reported_capabilities"] == ["dns"]
    assert worker["reported_services"] == %{}
  end

  test "rotation revokes old tokens and leaves credentials out of audits" do
    {:ok, first} = WorkerConnections.create("Rotate")
    assert request(first["token"], report(first)).status == 200
    {:ok, rotated} = WorkerConnections.rotate(first["worker"]["id"])
    assert rotated["token"] != first["token"]
    assert rotated["worker"]["connection_status"] == "not_yet_connected"
    assert request(first["token"], report(first)).status == 401
    assert request(rotated["token"], report(rotated)).status == 200
    {:ok, worker} = Domain.get_worker(first["worker"]["id"])
    ordinary = Jason.encode!([Domain.list_audit(), worker])
    refute ordinary =~ first["token"]
    refute ordinary =~ rotated["token"]
    assert Enum.any?(Domain.list_audit(), &(&1["operation"] == "rotate_worker_token"))
    assert {:error, %{code: "not_found"}} = WorkerConnections.rotate("missing")
  end

  test "contact expires without changing reported observations or configuration" do
    {:ok, result} = WorkerConnections.create("Expire")
    assert request(result["token"], report(result)).status == 200
    worker = Repo.get!(Worker, result["worker"]["id"])

    worker
    |> Ecto.Changeset.change(last_seen_at: DateTime.add(DateTime.utc_now(), -46, :second))
    |> Repo.update!()

    assert {:ok, expired} = Domain.get_worker(worker.id)
    assert expired["connection_status"] == "offline"
    assert expired["services"] == []
    assert request(result["token"], report(result)).status == 200
    assert {:ok, reconnected} = Domain.get_worker(worker.id)
    assert reconnected["connection_status"] == "connected"
  end

  test "malformed or excessive observations do not record contact" do
    {:ok, result} = WorkerConnections.create("Reports")
    report = report(result)
    excessive = Map.new(1..65, &{"dns-#{&1}", %{"state" => "running"}})

    for invalid <- [
          Map.delete(report, "services"),
          Map.put(report, "capabilities", ["dns", "dhcpv4"]),
          Map.put(report, "services", excessive),
          Map.put(report, "services", %{
            "dns" => %{"state" => "running", "token" => result["token"]}
          }),
          Map.put(report, "services", %{"bad/id" => %{"state" => "running"}}),
          Map.put(report, "services", %{"dns" => %{"state" => "unknown"}}),
          Map.put(report, "applied_revision", 1),
          Map.merge(report, %{
            "applied_revision" => 9_223_372_036_854_775_808,
            "applied_digest" => String.duplicate("0", 64)
          }),
          Map.put(report, "apply_error", result["token"]),
          Map.put(report, "token", result["token"])
        ] do
      assert request(result["token"], invalid).status == 422
    end

    assert {:ok, worker} = Domain.get_worker(result["worker"]["id"])
    assert worker["last_seen_at"] == nil
    assert worker["reported_services"] == %{}
  end

  test "only confirmed targets are delivered and applied claims must match a persisted target" do
    {:ok, result} = WorkerConnections.create("Publish")
    id = result["worker"]["id"]
    mutate("put_service", DomainFixtures.service(id, 1))
    response = request(result["token"], report(result))
    assert Jason.decode!(response.resp_body)["target"] == nil
    target = mutate("confirm_target", %{"worker_id" => id, "expected_revision" => 2})
    response = request(result["token"], report(result))

    assert Jason.decode!(response.resp_body)["target"] ==
             Map.take(target, ~w(revision digest plan))

    applied =
      report(result)
      |> Map.merge(%{
        "applied_revision" => target["revision"],
        "applied_digest" => target["digest"],
        "services" => %{"dns" => %{"state" => "running"}}
      })

    assert request(result["token"], applied).status == 200

    assert request(result["token"], Map.put(applied, "applied_digest", String.duplicate("0", 64))).status ==
             422

    assert request(result["token"], Map.put(applied, "applied_revision", 999)).status == 422
    assert {:ok, worker} = Domain.get_worker(id)
    assert worker["applied_revision"] == target["revision"]
    assert worker["reported_services"] == applied["services"]

    mutate("put_service", DomainFixtures.service(id, worker["revision"], "stopped"))
    response = request(result["token"], applied)

    assert Jason.decode!(response.resp_body)["target"] ==
             Map.take(target, ~w(revision digest plan))
  end

  test "machine API bounds JSON and rejects malformed content without credential leakage" do
    response =
      conn(:post, "/connect", "{")
      |> put_req_header("content-type", "application/json")
      |> WorkerAPI.call([])

    assert response.status == 400

    response =
      conn(:post, "/connect", String.duplicate(" ", 65_537))
      |> put_req_header("content-type", "application/json")
      |> WorkerAPI.call([])

    assert response.status == 413
  end

  defp report(result) do
    %{
      "worker_id" => result["worker"]["id"],
      "capabilities" => ["dns"],
      "services" => %{},
      "applied_revision" => nil,
      "applied_digest" => nil,
      "apply_error" => nil
    }
  end

  defp request(token, report, plug \\ WorkerAPI, path \\ "/connect") do
    conn =
      conn(:post, path, Jason.encode!(report))
      |> put_req_header("content-type", "application/json")

    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    plug.call(conn, plug.init([]))
  end

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
