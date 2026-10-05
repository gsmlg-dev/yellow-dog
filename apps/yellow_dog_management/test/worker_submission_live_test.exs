defmodule YellowDog.Management.WorkerSubmissionLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias YellowDog.Management.{Audit, Domain, DomainFixtures, Idempotency, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    worker = mutate("create_worker", %{"id" => "submission-worker", "name" => "Before"})
    %{conn: build_conn(), worker: worker}
  end

  test "stale Worker input survives retries and edited payloads receive new request identities",
       %{conn: conn, worker: worker} do
    {:ok, view, _} = live(conn, "/server/submission-worker/dashboard")

    mutate("update_worker", %{
      "id" => worker["id"],
      "name" => "Concurrent",
      "expected_revision" => worker["revision"]
    })

    request = %{"worker" => %{"name" => "Unsaved", "profile_name" => "dns_only"}}
    before = counts()
    html = render_submit(view, "save_worker", request)
    assert html =~ "revision"
    assert has_element?(view, "#worker-edit-form input[name='worker[name]'][value='Unsaved']")
    assert has_element?(view, "#worker-edit-profile option[value='dns_only'][selected]")
    failed = counts()
    assert failed == increment(before)
    render_submit(view, "save_worker", request)
    assert counts() == failed
    render_submit(view, "save_worker", put_in(request, ["worker", "name"], "Edited unsaved"))
    assert counts() == increment(failed)
    assert has_element?(view, "#worker-edit-form input[value='Edited unsaved']")
    assert {:ok, %{"name" => "Concurrent", "revision" => 2}} = Domain.get_worker(worker["id"])
  end

  test "invalid service ports preserve every typed field and make no database command", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/server/submission-worker/dashboard")

    assert render_submit(view, "save_worker", %{
             "worker" => %{"name" => "Saved before validation", "profile_name" => "dns_only"}
           }) =~ "Configuration saved"

    before = counts()

    html =
      render_submit(view, "save_service", %{
        "service" => %{
          "id" => "typed-dns",
          "listen_address" => "192.0.2.53",
          "port" => "invalid",
          "desired_state" => "running"
        }
      })

    assert html =~ "Port must be an integer"
    refute html =~ "Configuration saved"
    assert has_element?(view, "#service-form input[name='service[id]'][value='typed-dns']")

    assert has_element?(
             view,
             "#service-form input[name='service[listen_address]'][value='192.0.2.53']"
           )

    assert has_element?(view, "#service-form input[name='service[port]'][value='invalid']")
    assert has_element?(view, "#service-form option[value='running'][selected]")
    assert counts() == before
    assert Domain.list_services("submission-worker") == []
  end

  test "database-rejected service saves retain input and stable retry results", %{conn: conn} do
    {:ok, view, _} = live(conn, "/server/submission-worker/dashboard")
    reject_inserts("management_services", "reject_service_submission")

    request = %{
      "service" => %{
        "id" => "typed-dns",
        "listen_address" => "127.0.0.2",
        "port" => "5302",
        "desired_state" => "running"
      }
    }

    before = counts()
    html = render_submit(view, "save_service", request)
    assert html =~ "Database constraint"
    assert has_element?(view, "#service-form input[name='service[id]'][value='typed-dns']")
    assert has_element?(view, "#service-form input[name='service[port]'][value='5302']")
    assert has_element?(view, "#service-form option[value='running'][selected]")
    failed = counts()
    assert failed == increment(before)
    Repo.query!("DROP TRIGGER reject_service_submission ON management_services")
    render_submit(view, "save_service", request)
    assert counts() == failed
    assert Domain.list_services("submission-worker") == []
    html = render_submit(view, "save_service", put_in(request, ["service", "port"], "5303"))
    assert html =~ "Configuration saved"
    assert [%{"config" => %{"port" => 5303}}] = Domain.list_services("submission-worker")
    assert counts() == increment(failed)
  end

  test "failed assignment selections persist, retries are stable and edited saves survive fresh sessions",
       %{conn: conn, worker: worker} do
    service = mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"]))
    first = confirmed_zone("first.example.test.")
    second = confirmed_zone("second.example.test.")
    {:ok, view, _} = live(conn, "/server/submission-worker/dashboard")
    reject_inserts("management_assignments", "reject_assignment_submission")

    request = %{
      "assignment" => %{"service_id" => service["id"], "resource_version_id" => second["id"]}
    }

    before = counts()
    html = render_submit(view, "assign", request)
    assert html =~ "Database constraint"

    assert has_element?(
             view,
             "#assignment-form select[name='assignment[service_id]'] option[value='#{service["id"]}'][selected]"
           )

    assert has_element?(
             view,
             "#assignment-form select[name='assignment[resource_version_id]'] option[value='#{second["id"]}'][selected]"
           )

    failed = counts()
    assert failed == increment(before)
    Repo.query!("DROP TRIGGER reject_assignment_submission ON management_assignments")
    render_submit(view, "assign", request)
    assert counts() == failed
    assert Domain.list_assignments(worker["id"]) == []

    html =
      render_submit(
        view,
        "assign",
        put_in(request, ["assignment", "resource_version_id"], first["id"])
      )

    assert html =~ "Assignment saved"
    assert counts() == increment(failed)
    assert [%{"resource_version_id" => version_id}] = Domain.list_assignments(worker["id"])
    assert version_id == first["id"]
    {:ok, fresh, _} = live(build_conn(), "/server/submission-worker/dashboard")
    assert has_element?(fresh, "#resource-assignments", first["resource_id"])
    html = fresh |> element("button[phx-click='confirm_target']") |> render_click()
    assert html =~ "Target prepared"

    assert {:ok, %{"status" => "prepared", "actual_state" => "unknown"}} =
             Domain.get_target(worker["id"])

    {:ok, fresh, _} = live(build_conn(), "/server/submission-worker/dashboard")
    assert has_element?(fresh, "a[href='/api/workers/submission-worker/targets/1/export']")
    html = fresh |> element("button[phx-click='unassign']") |> render_click()
    assert html =~ "Assignment removed"
    assert Domain.list_assignments(worker["id"]) == []
  end

  test "mutation controls disable duplicate submissions while pending", %{
    conn: conn,
    worker: worker
  } do
    service = mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"]))
    version = confirmed_zone("controls.example.test.")

    mutate("assign", %{
      "worker_id" => worker["id"],
      "service_id" => service["id"],
      "resource_version_id" => version["id"],
      "expected_revision" => service["worker_revision"]
    })

    {:ok, view, _} = live(conn, "/server/submission-worker/dashboard")

    for selector <- [
          "#worker-edit-form button[type='submit']",
          "#service-form button[type='submit']",
          "#assignment-form button[type='submit']",
          "button[phx-click='unassign']",
          "button[phx-click='confirm_target']"
        ] do
      assert has_element?(view, selector <> "[phx-disable-with]")
    end
  end

  defp confirmed_zone(name) do
    zone = mutate("create_zone", DomainFixtures.zone(name))
    mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})
  end

  defp reject_inserts(table, name) do
    Repo.query!(
      "CREATE FUNCTION pg_temp.#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'submission rejected'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER #{name} BEFORE INSERT ON #{table} FOR EACH ROW EXECUTE FUNCTION pg_temp.#{name}()"
    )
  end

  defp counts,
    do:
      {Repo.aggregate(Idempotency, :count),
       Repo.aggregate(from(a in Audit, where: a.actor == "operator"), :count)}

  defp increment({keys, audits}), do: {keys + 1, audits + 1}

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "fixture", Ecto.UUID.generate())
    result
  end
end
