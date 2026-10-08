defmodule YellowDog.Management.AssignmentDomainTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Ecto.Query
  alias YellowDog.Management.{ConfigCompiler, Domain, Repo, Web}
  alias YellowDog.Management.DomainFixtures, as: Fixtures

  setup context do
    unless context[:independent_connections], do: Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "a global draft has an empty assignment snapshot before Workers or versions exist" do
    zone = mutate("create_zone", Fixtures.zone())
    assert {:ok, snapshot} = Domain.get_zone_assignments(zone["id"])
    assert snapshot["zone_id"] == zone["id"]
    assert snapshot["assignments"] == []
    assert snapshot["worker_revisions"] == %{}
    assert is_binary(snapshot["assignment_token"])
    assert {:ok, ^snapshot} = Domain.get_zone_assignments(zone["id"])

    response = conn(:get, "/api/zones/#{zone["id"]}/assignments") |> Web.call(Web.init([]))
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["data"] == snapshot
    assert {:error, %{code: "invalid_request"}} = Domain.get_zone_assignments("invalid")
  end

  test "one bulk submission persists shared assignments, selective removal and immutable targets" do
    {zone, version} = confirmed_zone()
    a = worker_service("worker-a")
    b = worker_service("worker-b")
    snapshot = snapshot(zone)
    request = request(zone, snapshot, [selection(a, version), selection(b, version)])
    key = Ecto.UUID.generate()
    assert {:ok, saved} = Domain.mutate("set_zone_assignments", request, "operator", key)
    assert {:ok, ^saved} = Domain.mutate("set_zone_assignments", request, "operator", key)
    assert length(saved["assignments"]) == 2
    assert saved["assignment_token"] != snapshot["assignment_token"]

    for worker_id <- ["worker-a", "worker-b"] do
      assert [%{"resource_version_id" => version_id}] = Domain.list_assignments(worker_id)
      assert version_id == version["id"]
    end

    target =
      mutate("confirm_target", %{
        "worker_id" => "worker-a",
        "expected_revision" => saved["worker_revisions"]["worker-a"]
      })

    assert {:ok, historical} = ConfigCompiler.export_target("worker-a", target["revision"])
    snapshot = snapshot(zone)
    removed = mutate("set_zone_assignments", request(zone, snapshot, [selection(b, version)]))
    assert Enum.map(removed["assignments"], & &1["worker_id"]) == ["worker-b"]
    assert Domain.list_assignments("worker-a") == []
    assert length(Domain.list_assignments("worker-b")) == 1
    assert {:ok, ^historical} = ConfigCompiler.export_target("worker-a", target["revision"])
    assert {:ok, _} = Domain.get_zone(zone["id"])

    assert {:error, %{code: "assigned"}} =
             Domain.mutate(
               "delete_zone",
               %{"id" => zone["id"], "expected_revision" => 1},
               "operator",
               Ecto.UUID.generate()
             )
  end

  test "draft edits and new confirmed versions never retarget assignments" do
    {zone, version} = confirmed_zone()
    service = worker_service("stable-worker")

    saved =
      mutate("set_zone_assignments", request(zone, snapshot(zone), [selection(service, version)]))

    fixture = Fixtures.zone()

    records =
      Enum.map(fixture["records"], fn
        %{"type" => "A"} = record -> put_in(record, ["data", "address"], "192.0.2.20")
        record -> record
      end)

    mutate("update_zone", %{
      "id" => zone["id"],
      "name" => zone["name"],
      "records" => records,
      "expected_revision" => 1
    })

    newer = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 2})
    assert newer["version"] == 2
    assert snapshot(zone)["assignments"] == saved["assignments"]
    assert snapshot(zone)["assignment_token"] == saved["assignment_token"]
  end

  test "a stale empty snapshot cannot erase an assignment added from the Worker command" do
    {zone, version} = confirmed_zone()
    a = worker_service("worker-a")
    b = worker_service("worker-b")
    stale = snapshot(zone)

    mutate("assign", %{
      "worker_id" => "worker-a",
      "service_id" => a["id"],
      "resource_version_id" => version["id"],
      "expected_revision" => a["worker_revision"]
    })

    assert {:error, %{code: "revision_conflict", message: message}} =
             Domain.mutate(
               "set_zone_assignments",
               request(zone, stale, [selection(b, version)]),
               "operator",
               Ecto.UUID.generate()
             )

    assert message =~ "Assignment set"
    assert length(Domain.list_assignments("worker-a")) == 1
    assert Domain.list_assignments("worker-b") == []
  end

  test "affected Worker revisions and all submitted services and versions validate atomically" do
    {zone, version} = confirmed_zone()
    a = worker_service("worker-a")
    b = worker_service("worker-b")
    snapshot = snapshot(zone)

    mutate("update_worker", %{
      "id" => "worker-a",
      "name" => "Changed",
      "expected_revision" => a["worker_revision"]
    })

    assert {:error, %{code: "revision_conflict"}} =
             Domain.mutate(
               "set_zone_assignments",
               request(zone, snapshot, [selection(a, version), selection(b, version)]),
               "operator",
               Ecto.UUID.generate()
             )

    assert Domain.list_assignments("worker-b") == []

    snapshot = snapshot(zone)
    foreign = selection(a, version) |> Map.put("service_id", b["id"])

    assert {:error, %{code: "not_found"}} =
             Domain.mutate(
               "set_zone_assignments",
               request(zone, snapshot, [selection(b, version), foreign]),
               "operator",
               Ecto.UUID.generate()
             )

    {_, other_version} = confirmed_zone("other.example.test.")

    assert {:error, %{code: "invalid_request"}} =
             Domain.mutate(
               "set_zone_assignments",
               request(zone, snapshot, [selection(b, version), selection(a, other_version)]),
               "operator",
               Ecto.UUID.generate()
             )

    assert snapshot(zone) == snapshot
  end

  test "different Workers may select different versions but one Worker must use one Zone version" do
    {zone, v1} = confirmed_zone()

    edited =
      mutate(
        "update_zone",
        Map.merge(Fixtures.zone(), %{"id" => zone["id"], "expected_revision" => 1})
      )

    v2 = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => edited["revision"]})
    a = worker_service("worker-a")
    b = worker_service("worker-b")

    saved =
      mutate(
        "set_zone_assignments",
        request(zone, snapshot(zone), [selection(a, v1), selection(b, v2)])
      )

    second =
      mutate(
        "put_service",
        Fixtures.service("worker-a", saved["worker_revisions"]["worker-a"])
        |> Map.put("id", "dns-second")
        |> put_in(["config", "port"], 5301)
      )

    before = snapshot(zone)

    assert {:error, %{code: "invalid_assignment_versions", message: message}} =
             Domain.mutate(
               "set_zone_assignments",
               request(zone, before, [selection(a, v1), selection(second, v2), selection(b, v2)]),
               "operator",
               Ecto.UUID.generate()
             )

    assert message =~ "same confirmed Zone version"
    assert snapshot(zone) == before

    assert {:error, %{code: "invalid_assignment_versions"}} =
             Domain.mutate(
               "assign",
               %{
                 "worker_id" => "worker-a",
                 "service_id" => second["id"],
                 "resource_version_id" => v2["id"],
                 "expected_revision" => second["worker_revision"]
               },
               "operator",
               Ecto.UUID.generate()
             )
  end

  test "a database failure rolls back every assignment and revision and records an idempotent failure" do
    {zone, version} = confirmed_zone()
    a = worker_service("worker-a")
    b = worker_service("worker-b")
    before = snapshot(zone)

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_assignment() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'assignment write rejected'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER reject_assignment BEFORE INSERT ON management_assignments FOR EACH ROW WHEN ((NEW.service_id)::text = '#{b["id"]}') EXECUTE FUNCTION pg_temp.reject_assignment()"
    )

    request = request(zone, before, [selection(a, version), selection(b, version)])
    key = Ecto.UUID.generate()

    assert {:error, %{code: "database_constraint"} = failure} =
             Domain.mutate("set_zone_assignments", request, "operator", key)

    assert snapshot(zone) == before
    Repo.query!("DROP TRIGGER reject_assignment ON management_assignments")
    assert {:error, ^failure} = Domain.mutate("set_zone_assignments", request, "operator", key)

    assert {:ok, _} =
             Domain.mutate("set_zone_assignments", request, "operator", Ecto.UUID.generate())
  end

  @tag :independent_connections
  test "concurrent bulk edits lock overlapping Workers consistently across distinct Zones" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      before_receipts = receipts()
      actor = Ecto.UUID.generate()
      {one, v1} = confirmed_zone("parallel-one.example.test.", actor)
      {two, v2} = confirmed_zone("parallel-two.example.test.", actor)
      a = worker_service("parallel-worker-a", actor)
      b = worker_service("parallel-worker-b", actor)

      try do
        results =
          concurrent_commands(
            [
              {"set_zone_assignments",
               request(one, snapshot(one), [selection(a, v1), selection(b, v1)])},
              {"set_zone_assignments",
               request(two, snapshot(two), [selection(b, v2), selection(a, v2)])}
            ],
            actor
          )

        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &match?({:error, %{code: "revision_conflict"}}, &1)) == 1

        assert Enum.sort([
                 length(snapshot(one)["assignments"]),
                 length(snapshot(two)["assignments"])
               ]) == [0, 2]
      after
        cleanup_committed([one, two], [a, b], actor)
      end

      assert receipts() == before_receipts
    end)
  end

  @tag :independent_connections
  test "a simultaneous Worker assignment always survives a competing bulk snapshot save" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      before_receipts = receipts()
      actor = Ecto.UUID.generate()
      {zone, version} = confirmed_zone("parallel-shared.example.test.", actor)
      a = worker_service("parallel-worker-a", actor)
      b = worker_service("parallel-worker-b", actor)
      before = snapshot(zone)

      try do
        [single, bulk] =
          concurrent_commands(
            [
              {"assign",
               %{
                 "worker_id" => a["worker_id"],
                 "service_id" => a["id"],
                 "resource_version_id" => version["id"],
                 "expected_revision" => a["worker_revision"]
               }},
              {"set_zone_assignments", request(zone, before, [selection(b, version)])}
            ],
            actor
          )

        assert {:ok, _} = single
        assert length(Domain.list_assignments(a["worker_id"])) == 1

        case bulk do
          {:ok, _} ->
            assert length(Domain.list_assignments(b["worker_id"])) == 1

          {:error, %{code: "revision_conflict"}} ->
            assert Domain.list_assignments(b["worker_id"]) == []
        end
      after
        cleanup_committed([zone], [a, b], actor)
      end

      assert receipts() == before_receipts
    end)
  end

  defp concurrent_commands(commands, actor) do
    owner = self()

    tasks =
      Enum.map(commands, fn {operation, request} ->
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(owner, {:connection_ready, self(), backend_pid})

            receive do
              :go ->
                Domain.mutate(operation, request, actor, actor <> ":" <> Ecto.UUID.generate())
            after
              5_000 -> flunk("Concurrent command did not receive its start signal")
            end
          end)
        end)
      end)

    backend_pids =
      Enum.map(tasks, fn _task ->
        assert_receive {:connection_ready, pid, backend_pid}, 5_000
        assert Enum.any?(tasks, &(&1.pid == pid))
        backend_pid
      end)

    assert length(Enum.uniq(backend_pids)) == length(tasks)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp cleanup_committed(zones, services, actor) do
    zone_ids = Enum.map(zones, & &1["id"])
    service_ids = Enum.map(services, & &1["id"])
    worker_ids = Enum.map(services, & &1["worker_id"])
    Repo.delete_all(from(a in YellowDog.Management.Assignment, where: a.zone_id in ^zone_ids))
    Repo.delete_all(from(v in YellowDog.Management.DnsView, where: v.service_id in ^service_ids))
    Repo.delete_all(from(s in YellowDog.Management.Service, where: s.id in ^service_ids))
    Repo.delete_all(from(w in YellowDog.Management.Worker, where: w.id in ^worker_ids))

    Enum.each(zones, fn zone ->
      mutate("delete_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]}, actor)
    end)

    key_prefix = actor <> ":%"

    # Committed concurrency fixtures cannot roll back. Keep immutable audits protected
    # during the test, then restore only its receipts with transactional trigger teardown.
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Repo.query!(
                 "ALTER TABLE management_audits DISABLE TRIGGER management_audits_immutable"
               )

               Repo.delete_all(from(a in YellowDog.Management.Audit, where: a.actor == ^actor))

               Repo.delete_all(
                 from(i in YellowDog.Management.Idempotency, where: like(i.key, ^key_prefix))
               )

               Repo.query!(
                 "ALTER TABLE management_audits ENABLE TRIGGER management_audits_immutable"
               )

               :ok
             end)
  end

  defp confirmed_zone(name \\ "example.test.", actor \\ "operator") do
    zone = mutate("create_zone", Fixtures.zone(name), actor)
    {zone, mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1}, actor)}
  end

  defp worker_service(id, actor \\ "operator") do
    worker = mutate("create_worker", %{"id" => id, "name" => id}, actor)
    mutate("put_service", Fixtures.service(id, worker["revision"]), actor)
  end

  defp selection(service, version),
    do: %{
      "worker_id" => service["worker_id"],
      "service_id" => service["id"],
      "resource_version_id" => version["id"]
    }

  defp receipts do
    assert %{rows: [["O"]]} =
             Repo.query!(
               "SELECT tgenabled FROM pg_trigger WHERE tgrelid = 'management_audits'::regclass AND tgname = 'management_audits_immutable'"
             )

    {Repo.all(YellowDog.Management.Audit) |> Enum.sort_by(& &1.id),
     Repo.all(YellowDog.Management.Idempotency) |> Enum.sort_by(& &1.key)}
  end

  defp snapshot(zone) do
    assert {:ok, snapshot} = Domain.get_zone_assignments(zone["id"])
    snapshot
  end

  defp request(zone, snapshot, selections),
    do: %{
      "zone_id" => zone["id"],
      "expected_assignment_token" => snapshot["assignment_token"],
      "expected_worker_revisions" => snapshot["worker_revisions"],
      "assignments" => selections
    }

  defp mutate(operation, request, actor \\ "operator") do
    assert {:ok, result} =
             Domain.mutate(operation, request, actor, actor <> ":" <> Ecto.UUID.generate())

    result
  end
end
