defmodule YellowDog.Management.NodeWorkflowDomainTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias YellowDog.Management.{Audit, ConfigCompiler, Domain, Repo, Web}
  alias YellowDog.Management.DomainFixtures, as: Fixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "create and scoped update preserve separate intent, identity, receipts and stopped references" do
    worker = worker("node-a")
    other = worker("node-b")
    params = service_params(worker)
    key = Ecto.UUID.generate()
    assert {:ok, service} = Domain.mutate("create_service", params, "operator", key)
    assert {:ok, ^service} = Domain.mutate("create_service", params, "operator", key)
    assert Repo.aggregate(Audit, :count, :id) == 3
    assert {:ok, canonical} = Domain.get_service(worker["id"], service["id"])
    assert canonical["instance_id"] == "dns"
    assert Domain.list_worker_target_history(worker["id"]) == []

    assert {:error, %{code: "conflict"}} =
             Domain.mutate(
               "create_service",
               %{params | "expected_revision" => 2},
               "operator",
               Ecto.UUID.generate()
             )

    assert {:error, %{code: "not_found"}} = Domain.get_service(other["id"], service["id"])
    assert {:error, %{code: "invalid_request"}} = Domain.get_service(worker["id"], "dns")

    update = %{
      "worker_id" => other["id"],
      "service_id" => service["id"],
      "expected_revision" => 1,
      "config" => %{"listen_address" => "192.0.2.9", "port" => 5301}
    }

    assert {:error, %{code: "not_found"}} =
             Domain.mutate("update_service", update, "operator", Ecto.UUID.generate())

    update = %{update | "worker_id" => worker["id"], "expected_revision" => 2}

    assert {:error, %{code: "invalid_request"}} =
             Domain.mutate(
               "update_service",
               Map.put(update, "instance_id", "renamed"),
               "operator",
               Ecto.UUID.generate()
             )

    zone = mutate("create_zone", Fixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})

    assignment =
      mutate("assign", %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_version_id" => version["id"],
        "expected_revision" => 2
      })

    stopped =
      mutate(
        "update_service",
        update
        |> Map.put("expected_revision", assignment["worker_revision"])
        |> Map.put("desired_state", "stopped")
      )

    assert stopped["id"] == service["id"]
    assert stopped["instance_id"] == "dns"

    assert Domain.list_assignments(worker["id"]) |> hd() |> Map.fetch!("resource_version_id") ==
             version["id"]

    assert {:ok, references} = Domain.list_service_references(worker["id"], service["id"])
    assert [%{"zone_id" => zone_id, "version" => 1}] = references["zones"]
    assert zone_id == zone["id"]
    assert [%{"name" => "default"}] = references["views"]
    assert Domain.list_services(other["id"]) == []
    other_service = mutate("create_service", service_params(other))
    assert other_service["instance_id"] == service["instance_id"]
    refute other_service["id"] == service["id"]
    assert {:ok, other_refs} = Domain.list_service_references(other["id"], other_service["id"])
    assert other_refs["zones"] == []
    assert Domain.list_worker_target_history(worker["id"]) == []
  end

  test "HTTP and ordinary commands share scoped validation and stale preview rejection" do
    worker = worker("http-node")
    params = service_params(worker)
    created = command("create_service", params, Ecto.UUID.generate())
    assert created.status == 200, created.resp_body
    service = decoded(created)

    assert get("/api/workers/http-node/services/#{service["id"]}") |> decoded() ==
             Domain.get_service(worker["id"], service["id"]) |> elem(1)

    assert {:ok, preview} = Domain.preview_target(worker["id"])

    update = %{
      "worker_id" => worker["id"],
      "service_id" => service["id"],
      "expected_revision" => 2,
      "desired_state" => "stopped"
    }

    updated = command("update_service", update, Ecto.UUID.generate())
    assert updated.status == 200, updated.resp_body

    assert Domain.get_service(worker["id"], service["id"])
           |> elem(1)
           |> Map.fetch!("desired_state") == "stopped"

    stale =
      command(
        "confirm_target",
        %{"worker_id" => worker["id"], "expected_revision" => preview["worker_revision"]},
        Ecto.UUID.generate()
      )

    assert stale.status == 409
    assert Jason.decode!(stale.resp_body)["error"]["code"] == "revision_conflict"
    assert command("update_service", update, Ecto.UUID.generate()).status == 409

    for config <- [
          %{"listen_address" => "::1", "port" => 5300},
          %{"listen_address" => "127.0.0.1", "port" => 0},
          %{"listen_address" => "127.0.0.1", "port" => 65_536},
          %{"listen_address" => "127.0.0.1", "port" => 5300, "protocol" => "tcp"}
        ] do
      assert command(
               "update_service",
               update |> Map.put("expected_revision", 3) |> Map.put("config", config),
               Ecto.UUID.generate()
             ).status == 422
    end

    assert command(
             "create_service",
             params |> Map.put("expected_revision", 3) |> Map.put("unknown", true),
             Ecto.UUID.generate()
           ).status == 422

    for {field, value} <- [{"type", "dhcpv4"}, {"desired_state", "enabled"}] do
      assert command(
               "update_service",
               update |> Map.put("expected_revision", 3) |> Map.put(field, value),
               Ecto.UUID.generate()
             ).status == 422
    end

    duplicate_listener =
      params |> Map.put("expected_revision", 3) |> Map.put("instance_id", "second")

    # The stopped first service may share a listener; restart it before testing the conflict.
    running =
      command(
        "update_service",
        update |> Map.put("expected_revision", 3) |> Map.put("desired_state", "running"),
        Ecto.UUID.generate()
      )

    assert running.status == 200

    assert command(
             "create_service",
             Map.put(duplicate_listener, "expected_revision", 4),
             Ecto.UUID.generate()
           ).status == 422

    assert get("/api/workers/http-node/services") |> decoded() |> length() == 1
    assert get("/api/workers/http-node/services/#{service["id"]}/references").status == 200
    assert get("/api/workers/http-node/targets") |> decoded() == []
  end

  test "assignment changes and another confirmation invalidate previews; exact old exports remain immutable" do
    worker = worker("preview-node")
    service = mutate("create_service", service_params(worker))
    zone = mutate("create_zone", Fixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    assert {:ok, before_assignment} = Domain.preview_target(worker["id"])
    assert before_assignment["previous_plan"] == nil

    assigned =
      mutate("assign", %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_version_id" => version["id"],
        "expected_revision" => 2
      })

    reject_preview(worker, before_assignment)
    assert {:ok, preview} = Domain.preview_target(worker["id"])

    first =
      mutate("confirm_target", %{
        "worker_id" => worker["id"],
        "expected_revision" => assigned["worker_revision"]
      })

    reject_preview(worker, preview)
    assert {:ok, exported} = ConfigCompiler.export_target(worker["id"], first["revision"])

    mutate("update_service", %{
      "worker_id" => worker["id"],
      "service_id" => service["id"],
      "expected_revision" => first["worker_revision"],
      "desired_state" => "stopped"
    })

    assert {:ok, ^exported} = ConfigCompiler.export_target(worker["id"], first["revision"])
    assert {:ok, preview} = Domain.preview_target(worker["id"])
    assert preview["previous_plan"] == first["plan"]
    key = Ecto.UUID.generate()
    params = %{"worker_id" => worker["id"], "expected_revision" => preview["worker_revision"]}
    assert {:ok, target} = Domain.mutate("confirm_target", params, "operator", key)
    assert {:ok, ^target} = Domain.mutate("confirm_target", params, "operator", key)
    assert [%{"revision" => 2}] = Domain.list_worker_target_history(worker["id"], 1)
    assert length(Domain.list_worker_target_history(worker["id"])) == 2
    assert Domain.list_worker_target_history("other-node") == []
  end

  test "reference and history SQL reads are scoped, bounded and metadata only" do
    worker = worker("bounded-node")
    service = mutate("create_service", service_params(worker))

    for name <- ~w(a b c) do
      zone = mutate("create_zone", Fixtures.zone(name <> ".test."))
      version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
      {:ok, current} = Domain.get_worker(worker["id"])

      mutate("assign", %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_version_id" => version["id"],
        "expected_revision" => current["revision"]
      })
    end

    handler = Ecto.UUID.generate()
    test = self()

    :ok =
      :telemetry.attach(
        handler,
        [:yellow_dog, :management, :repo, :query],
        fn _, _, metadata, _ -> send(test, {:query, metadata.query}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, references} = Domain.list_service_references(worker["id"], service["id"], 2)
    assert length(references["zones"]) == 2
    Domain.list_worker_target_history(worker["id"], 2)
    queries = drain_queries([])

    for table <-
          ~w(management_assignments management_dns_views management_dns_acls management_targets) do
      query = Enum.find(queries, &String.contains?(&1, table))
      assert query, "Missing instrumented query for #{table}: #{inspect(queries)}"
      assert query =~ "WHERE"
      assert query =~ "LIMIT"
    end

    refute Enum.any?(queries, &String.contains?(&1, "management_rrsets"))
    assert Enum.any?(queries, &String.contains?(&1, "\"content\"->>'name'"))

    refute Enum.any?(queries, fn query ->
             query
             |> String.replace(".\"content\"->>'name'", "")
             |> String.contains?(".\"content\"")
           end)
  end

  defp drain_queries(acc) do
    receive do
      {:query, query} -> drain_queries([query | acc])
    after
      0 -> acc
    end
  end

  defp reject_preview(worker, preview) do
    assert {:error, %{code: "revision_conflict"}} =
             Domain.mutate(
               "confirm_target",
               %{"worker_id" => worker["id"], "expected_revision" => preview["worker_revision"]},
               "operator",
               Ecto.UUID.generate()
             )
  end

  defp worker(id), do: mutate("create_worker", %{"id" => id, "name" => id})

  defp service_params(worker),
    do:
      Fixtures.service(worker["id"], worker["revision"])
      |> Map.delete("id")
      |> Map.put("instance_id", "dns")

  defp mutate(operation, params) do
    assert {:ok, value} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    value
  end

  defp command(operation, params, key) do
    conn(:post, "/api/commands/" <> operation, Jason.encode!(params))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("idempotency-key", key)
    |> Web.call(Web.init([]))
  end

  defp get(path), do: conn(:get, path) |> Web.call(Web.init([]))
  defp decoded(conn), do: Jason.decode!(conn.resp_body)["data"]
end
