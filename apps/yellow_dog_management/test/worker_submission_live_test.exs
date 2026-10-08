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

  test "duplicate Worker saves cannot advance revisions or replace newly typed fields", %{
    conn: conn,
    worker: worker
  } do
    {:ok, view, _} = live(conn, "/server/submission-worker/dashboard")

    request = %{
      "worker" => %{"name" => "Saved", "profile_name" => "dns_only"},
      "_submission" => intent(view)
    }

    before = counts()
    render_submit(view, "save_worker", request)
    assert counts() == increment(before)
    assert {:ok, %{"name" => "Saved", "revision" => 2}} = Domain.get_worker(worker["id"])

    render_change(view, "validate_worker", %{
      "worker" => %{"name" => "New input", "profile_name" => "dns_only"}
    })

    render_submit(view, "save_worker", request)
    render_submit(view, "save_worker", Map.delete(request, "_submission"))
    assert counts() == increment(before)
    assert has_element?(view, "#worker-edit-form input[value='New input']")
    assert {:ok, %{"name" => "Saved", "revision" => 2}} = Domain.get_worker(worker["id"])
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
    html = submit_event(view, "save_worker", request)
    assert html =~ "revision"
    assert has_element?(view, "#worker-edit-form input[name='worker[name]'][value='Unsaved']")
    assert has_element?(view, "#worker-edit-profile option[value='dns_only'][selected]")
    failed = counts()
    assert failed == increment(before)
    submit_event(view, "save_worker", request)
    assert counts() == failed
    submit_event(view, "save_worker", put_in(request, ["worker", "name"], "Edited unsaved"))
    assert counts() == increment(failed)
    assert has_element?(view, "#worker-edit-form input[value='Edited unsaved']")
    assert {:ok, %{"name" => "Concurrent", "revision" => 2}} = Domain.get_worker(worker["id"])
  end

  test "pipelined Worker edits accept the previous token only for retained changed fields", %{
    conn: conn,
    worker: worker
  } do
    {:ok, view, _} = live(conn, "/server/submission-worker/dashboard")

    mutate("update_worker", %{
      "id" => worker["id"],
      "name" => "Concurrent",
      "expected_revision" => worker["revision"]
    })

    original = %{
      "worker" => %{"name" => "Rejected", "profile_name" => "dns_only"},
      "_submission" => intent(view)
    }

    render_submit(view, "save_worker", original)
    failed = counts()
    changed = put_in(original, ["worker", "name"], "Pipelined")
    render_change(view, "validate_worker", changed)
    render_submit(view, "save_worker", original)
    assert counts() == failed
    assert has_element?(view, "#worker-edit-form input[value='Pipelined']")
    render_submit(view, "save_worker", changed)
    assert counts() == increment(failed)
    render_submit(view, "save_worker", changed)
    assert counts() == increment(failed)
    assert {:ok, %{"name" => "Concurrent", "revision" => 2}} = Domain.get_worker(worker["id"])
  end

  test "explicitly reopening a Service retires an unresolved submit even with identical fields",
       %{conn: conn, worker: worker} do
    service = mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"]))
    {:ok, view, _} = live(conn, "/server/submission-worker/dashboard")

    mutate("update_worker", %{
      "id" => worker["id"],
      "name" => "Concurrent",
      "expected_revision" => service["worker_revision"]
    })

    request = %{
      "service" => %{
        "id" => service["instance_id"],
        "listen_address" => service["config"]["listen_address"],
        "port" => to_string(service["config"]["port"]),
        "desired_state" => service["desired_state"]
      },
      "_submission" => intent(view)
    }

    render_submit(view, "save_service", request)
    failed = counts()
    render_click(view, "edit_service", %{"id" => service["id"]})
    render_submit(view, "save_service", request)
    assert counts() == failed
    assert has_element?(view, "#service-form input[value='#{service["instance_id"]}']")
  end

  test "invalid service ports preserve every typed field and make no database command", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/server/submission-worker/dashboard")

    assert submit_event(view, "save_worker", %{
             "worker" => %{"name" => "Saved before validation", "profile_name" => "dns_only"}
           }) =~ "Configuration saved"

    before = counts()

    html =
      submit_event(view, "save_service", %{
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
    html = submit_event(view, "save_service", request)
    assert html =~ "Database constraint"
    assert has_element?(view, "#service-form input[name='service[id]'][value='typed-dns']")
    assert has_element?(view, "#service-form input[name='service[port]'][value='5302']")
    assert has_element?(view, "#service-form option[value='running'][selected]")
    failed = counts()
    assert failed == increment(before)
    Repo.query!("DROP TRIGGER reject_service_submission ON management_services")
    submit_event(view, "save_service", request)
    assert counts() == failed
    assert Domain.list_services("submission-worker") == []
    html = submit_event(view, "save_service", put_in(request, ["service", "port"], "5303"))
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
    html = submit_event(view, "assign", request)
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
    submit_event(view, "assign", request)
    assert counts() == failed
    assert Domain.list_assignments(worker["id"]) == []

    pipelined =
      request
      |> Map.put("_submission", intent(view))
      |> put_in(["assignment", "resource_version_id"], first["id"])

    render_change(view, "validate_assignment", pipelined)
    html = render_submit(view, "assign", pipelined)

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

    assert has_element?(
             fresh,
             "#target-export-scope",
             "DNS Views and IP database artifacts are not serialized"
           )

    assert has_element?(fresh, "#target-export-scope", "Valid drafts can still be saved")
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

  test "malformed validation events preserve Worker input without a command", %{conn: conn} do
    {:ok, view, _} = live(conn, "/server/submission-worker/dashboard")
    before = counts()

    for event <- ~w(validate_worker validate_service validate_assignment),
        params <- [
          %{},
          %{"worker" => nil, "service" => nil, "assignment" => nil},
          %{"worker" => [], "service" => [], "assignment" => []}
        ] do
      render_change(view, event, params)
    end

    assert counts() == before
    assert has_element?(view, "#worker-edit-form input[value='Before']")
  end

  defp intent(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("#submission-intent")
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp submit_event(view, event, params) do
    render_submit(view, event, Map.put(params, "_submission", intent(view)))
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
