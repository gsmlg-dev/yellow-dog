defmodule YellowDog.Management.WorkerSubmissionLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias YellowDog.Management.{Audit, Domain, DomainFixtures, Idempotency, Repo}

  alias YellowDog.ManagementUI.DnsSettings

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
    path = "/server/submission-worker/dns"
    {:ok, view, _} = live(conn, path)

    mutate("update_worker", %{
      "id" => worker["id"],
      "name" => "Concurrent",
      "expected_revision" => service["worker_revision"]
    })

    request = %{"service" => DnsSettings.form_params(service), "_submission" => intent(view)}

    render_submit(view, "save_service", request)
    failed = counts()
    render_patch(view, path)
    render_submit(view, "save_service", request)
    assert counts() == failed

    assert has_element?(
             view,
             "#dns-udp-settings input[type=number][value='#{service["config"]["port"]}']"
           )
  end

  test "invalid service ports preserve every typed field and make no database command", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/server/submission-worker/dns")

    before = counts()

    html =
      submit_event(view, "save_service", %{
        "service" => dns_fields("192.0.2.53", "invalid")
      })

    assert html =~ "UDP port must be an integer"
    refute html =~ "Configuration saved"

    assert has_element?(
             view,
             "#service-form textarea[name='service[addresses]']",
             "192.0.2.53"
           )

    assert has_element?(view, "#dns-udp-settings input[type=number][value='invalid']")

    assert has_element?(
             view,
             "#service-form input[type=checkbox][name='service[desired_state]'][checked]"
           )

    assert counts() == before
    assert Domain.list_services("submission-worker") == []
  end

  test "database-rejected service saves retain input and stable retry results", %{conn: conn} do
    {:ok, view, _} = live(conn, "/server/submission-worker/dns")
    reject_inserts("management_services", "reject_service_submission")

    request = %{"service" => dns_fields("127.0.0.2", "5302")}

    before = counts()
    html = submit_event(view, "save_service", request)
    assert html =~ "Database constraint"
    assert has_element?(view, "#dns-udp-settings input[type=number][value='5302']")

    assert has_element?(
             view,
             "#service-form input[type=checkbox][name='service[desired_state]'][checked]"
           )

    failed = counts()
    assert failed == increment(before)
    Repo.query!("DROP TRIGGER reject_service_submission ON management_services")
    submit_event(view, "save_service", request)
    assert counts() == failed
    assert Domain.list_services("submission-worker") == []

    html =
      submit_event(
        view,
        "save_service",
        put_in(request, ["service", "transports", "udp", "port"], "5303")
      )

    assert html =~ "Configuration saved"

    assert [%{"config" => %{"transports" => %{"udp" => %{"port" => 5303}}}}] =
             Domain.list_services("submission-worker")

    assert counts() == increment(failed)
  end

  test "service and target mutation controls prevent repeated submissions while pending", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/server/submission-worker/dashboard")
    assert has_element?(view, "#worker-edit-form button[type='submit'][phx-disable-with]")
    render_patch(view, "/server/submission-worker/dns")
    assert has_element?(view, "#service-form button[type='submit'][phx-disable-with]")
    render_patch(view, "/server/submission-worker/targets")
    refute has_element?(view, "button[phx-click='confirm_target']")
    view |> element("button[phx-click='preview']") |> render_click()

    assert has_element?(
             view,
             "button[phx-click='confirm_target'][phx-disable-with][data-confirm]"
           )
  end

  test "malformed validation events preserve Worker input without a command", %{conn: conn} do
    {:ok, view, _} = live(conn, "/server/submission-worker/dashboard")
    before = counts()

    for event <- ~w(validate_worker validate_service),
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

  defp dns_fields(address, port) do
    DnsSettings.form_params(nil)
    |> Map.merge(%{"mode" => "specific", "addresses" => address})
    |> put_in(["transports", "udp", "port"], port)
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

  defp reject_inserts(table, name) do
    Repo.query!(
      "CREATE FUNCTION pg_temp.#{name}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'submission rejected' USING ERRCODE = '23514'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER #{name} BEFORE INSERT ON #{table} FOR EACH ROW EXECUTE FUNCTION pg_temp.#{name}()"
    )
  end

  defp counts,
    do:
      {Repo.aggregate(Idempotency, :count),
       Repo.aggregate(from(a in Audit, where: fragment("?->>'source' = 'ui'", a.context)), :count)}

  defp increment({keys, audits}), do: {keys + 1, audits + 1}

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "fixture", Ecto.UUID.generate())
    result
  end
end
