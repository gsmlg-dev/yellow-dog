defmodule YellowDog.Management.DomainTest do
  use ExUnit.Case, async: false

  alias YellowDog.Management.{ConfigCompiler, Domain, Repo}
  alias YellowDog.Management.DomainFixtures, as: Fixtures

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "DNS business data is editable with zero Worker records and confirmed versions stay immutable" do
    assert Domain.list_workers() == []
    zone = create_zone("solo.example.test.")
    assert zone["revision"] == 1
    assert length(zone["records"]) == 3

    version_1 = mutation("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    assert version_1["version"] == 1

    assert mutation("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})["id"] ==
             version_1["id"]

    new_records = Fixtures.zone("solo.example.test.")["records"]

    new_records =
      Enum.map(new_records, fn
        %{"type" => "A"} = record -> put_in(record, ["data", "address"], "192.0.2.20")
        record -> record
      end)

    edited =
      mutation("update_zone", %{
        "id" => zone["id"],
        "name" => zone["name"],
        "records" => new_records,
        "expected_revision" => 1
      })

    assert edited["revision"] == 2
    version_2 = mutation("confirm_zone", %{"id" => zone["id"], "expected_revision" => 2})
    assert version_2["version"] == 2
    assert version_2["digest"] != version_1["digest"]
    assert Domain.list_versions(zone["id"]) |> Enum.at(0) == version_1
    assert Domain.list_workers() == []
  end

  test "four unconnected Workers share one selected version and export complete independent targets" do
    zone = create_zone("shared.example.test.")
    unused = create_zone("unused.example.test.")
    version = mutation("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    _unused_version = mutation("confirm_zone", %{"id" => unused["id"], "expected_revision" => 1})

    for index <- 1..4 do
      id = "worker-#{index}"
      worker = create_worker(id)
      service = mutation("put_service", Fixtures.service(id, worker["revision"]))

      assignment =
        mutation("assign", %{
          "worker_id" => id,
          "service_id" => service["id"],
          "resource_version_id" => version["id"],
          "expected_revision" => service["worker_revision"]
        })

      assert assignment["resource_version_id"] == version["id"]

      target =
        mutation("confirm_target", %{
          "worker_id" => id,
          "expected_revision" => assignment["worker_revision"]
        })

      assert target["status"] == "prepared"
      assert target["actual_state"] == "unknown"
      assert Enum.map(target["plan"]["resources"], & &1["id"]) == [zone["id"]]
      assert target["plan"]["services"] |> hd() |> Map.fetch!("resources") == [zone["id"]]

      assert {:ok, %{"toml" => toml, "plan" => decoded}} =
               ConfigCompiler.export_target(id, target["revision"])

      assert is_binary(toml)
      assert decoded == target["plan"]
    end

    assert Domain.list_versions(zone["id"]) |> length() == 1
  end

  test "unassigning one zone preserves another and a stopped DNS service" do
    zone_a = create_zone("a.example.test.")
    zone_b = create_zone("b.example.test.")
    a = mutation("confirm_zone", %{"id" => zone_a["id"], "expected_revision" => 1})
    b = mutation("confirm_zone", %{"id" => zone_b["id"], "expected_revision" => 1})
    worker = create_worker("stopped-worker")

    service =
      mutation("put_service", Fixtures.service(worker["id"], worker["revision"], "stopped"))

    first =
      mutation("assign", %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_version_id" => a["id"],
        "expected_revision" => service["worker_revision"]
      })

    second =
      mutation("assign", %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_version_id" => b["id"],
        "expected_revision" => first["worker_revision"]
      })

    old =
      mutation("confirm_target", %{
        "worker_id" => worker["id"],
        "expected_revision" => second["worker_revision"]
      })

    removed =
      mutation("unassign", %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_id" => zone_a["id"],
        "expected_revision" => old["worker_revision"]
      })

    new_target =
      mutation("confirm_target", %{
        "worker_id" => worker["id"],
        "expected_revision" => removed["worker_revision"]
      })

    assert Enum.map(new_target["plan"]["resources"], & &1["id"]) == [zone_b["id"]]
    assert new_target["plan"]["services"] |> hd() |> Map.fetch!("desired_state") == "stopped"

    assert Enum.sort(Enum.map(old["plan"]["resources"], & &1["id"])) ==
             Enum.sort([zone_a["id"], zone_b["id"]])

    assert {:ok, retained} = Domain.get_target(worker["id"], old["revision"])
    assert retained["plan"] == old["plan"]

    assert %{"deleted" => true} =
             mutation("delete_zone", %{"id" => zone_a["id"], "expected_revision" => 1})

    assert {:error, %{code: "not_found"}} = Domain.get_zone(zone_a["id"])

    assert {:ok, %{"plan" => retained_plan}} =
             ConfigCompiler.export_target(worker["id"], old["revision"])

    assert retained_plan == old["plan"]

    assert {:error, %{code: "assigned"}} =
             Domain.mutate(
               "delete_zone",
               %{"id" => zone_b["id"], "expected_revision" => 1},
               "operator",
               key()
             )
  end

  test "revision conflicts, idempotent retries and failed transactions have no partial effects" do
    worker = create_worker("conflict-worker")
    request = %{"id" => worker["id"], "name" => "Renamed", "expected_revision" => 1}
    key = key()
    assert {:ok, changed} = Domain.mutate("update_worker", request, "operator", key)
    assert {:ok, ^changed} = Domain.mutate("update_worker", request, "operator", key)

    assert {:error, %{code: "idempotency_conflict"}} =
             Domain.mutate("update_worker", %{request | "name" => "Other"}, "operator", key)

    stale_key = key()

    assert {:error, %{code: "revision_conflict"} = stale} =
             Domain.mutate("update_worker", %{request | "name" => "Stale"}, "operator", stale_key)

    assert {:error, ^stale} =
             Domain.mutate("update_worker", %{request | "name" => "Stale"}, "operator", stale_key)

    {:ok, before} = Domain.get_worker(worker["id"])

    assert {:error, %{code: "not_found"}} =
             Domain.mutate(
               "assign",
               %{
                 "worker_id" => worker["id"],
                 "service_id" => "dns",
                 "resource_version_id" => Ecto.UUID.generate(),
                 "expected_revision" => before["revision"]
               },
               "operator",
               key()
             )

    {:ok, after_failed} = Domain.get_worker(worker["id"])
    assert after_failed["revision"] == before["revision"]
    assert after_failed["assignments"] == []

    assert {:error, %{code: "invalid_request"}} =
             Domain.mutate(
               "create_zone",
               Map.put(Fixtures.zone("invalid.example.test."), "unsupported", "value"),
               "operator",
               key()
             )

    assert {:error, %{code: "invalid_config"}} =
             Domain.mutate(
               "create_zone",
               %{"name" => "invalid.example.test.", "records" => []},
               "operator",
               key()
             )
  end

  test "two concurrent updates against one revision produce one conflict" do
    worker = create_worker("parallel-worker")
    owner = self()

    tasks =
      for name <- ["First", "Second"] do
        task =
          Task.async(fn ->
            receive do
              :go -> :ok
            end

            Domain.mutate(
              "update_worker",
              %{"id" => worker["id"], "name" => name, "expected_revision" => worker["revision"]},
              "operator",
              key()
            )
          end)

        Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, task.pid)
        task
      end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %{code: "revision_conflict"}}, &1)) == 1
  end

  test "concurrent assignments cannot lose another zone on the same Worker" do
    zones = for name <- ["one.example.test.", "two.example.test."], do: create_zone(name)

    versions =
      Enum.map(zones, fn zone ->
        mutation("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
      end)

    worker = create_worker("assignment-worker")
    service = mutation("put_service", Fixtures.service(worker["id"], worker["revision"]))
    owner = self()

    tasks =
      Enum.map(versions, fn version ->
        task =
          Task.async(fn ->
            receive do
              :go -> :ok
            end

            {version["id"],
             Domain.mutate(
               "assign",
               %{
                 "worker_id" => worker["id"],
                 "service_id" => service["id"],
                 "resource_version_id" => version["id"],
                 "expected_revision" => service["worker_revision"]
               },
               "operator",
               key()
             )}
          end)

        Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, task.pid)
        task
      end)

    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, fn {_, result} -> match?({:ok, _}, result) end) == 1

    [{loser_id, {:error, %{code: "revision_conflict"}}}] =
      Enum.filter(results, fn {_, result} -> match?({:error, _}, result) end)

    {:ok, fresh} = Domain.get_worker(worker["id"])

    mutation("assign", %{
      "worker_id" => worker["id"],
      "service_id" => service["id"],
      "resource_version_id" => loser_id,
      "expected_revision" => fresh["revision"]
    })

    {:ok, preview} = Domain.preview_target(worker["id"])

    assert preview["plan"]["resources"] |> Enum.map(& &1["id"]) |> Enum.sort() ==
             Enum.map(zones, & &1["id"]) |> Enum.sort()
  end

  test "invalid complete target rolls back a newly inserted service and replays the failure" do
    worker = create_worker("listener-worker")
    first = mutation("put_service", Fixtures.service(worker["id"], worker["revision"]))

    attempted =
      Fixtures.service(worker["id"], first["worker_revision"]) |> Map.put("id", "dns-secondary")

    failure_key = key()

    assert {:error, %{code: "invalid_config"} = failure} =
             Domain.mutate("put_service", attempted, "operator", failure_key)

    assert {:error, ^failure} = Domain.mutate("put_service", attempted, "operator", failure_key)
    {:ok, after_failed} = Domain.get_worker(worker["id"])
    assert after_failed["revision"] == first["worker_revision"]
    assert Enum.map(after_failed["services"], & &1["instance_id"]) == ["dns"]
    assert {:ok, preview} = Domain.preview_target(worker["id"])
    assert Enum.map(preview["plan"]["services"], & &1["id"]) == ["dns"]
  end

  defp create_zone(name), do: mutation("create_zone", Fixtures.zone(name))

  defp create_worker(id) do
    mutation("create_worker", %{"id" => id, "name" => id, "expected_capabilities" => ["dns"]})
  end

  defp mutation(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", key())
    result
  end

  defp key, do: "domain-#{System.unique_integer([:positive, :monotonic])}"
end
