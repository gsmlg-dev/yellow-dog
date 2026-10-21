defmodule YellowDog.Management.NodeWorkflowLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Domain, DomainFixtures, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    worker = mutate("create_worker", %{"id" => "node-a", "name" => "Node A"})
    mutate("create_worker", %{"id" => "node-b", "name" => "Node B"})
    %{conn: build_conn(), worker: worker}
  end

  test "four tabs load directly and reads never publish or fabricate service state", %{conn: conn} do
    for suffix <- ~w(dashboard connection services targets dns) do
      {:ok, view, html} = live(conn, "/server/node-a/#{suffix}")
      assert has_element?(view, "#worker-tabs a", "Basic information")
      assert has_element?(view, "#worker-tabs a", "Authentication & connection")
      assert has_element?(view, "#worker-tabs a", "Services")
      assert has_element?(view, "#worker-tabs a", "Configuration target")
      assert html =~ "Actual runtime state is unknown"
      refute has_element?(view, "#assignment-form")
      assert {:error, %{code: "not_found"}} = Domain.get_target("node-a")
    end
  end

  test "create and edit persist offline desired configuration without publishing", %{conn: conn} do
    {:ok, view, _} = live(conn, "/server/node-a/services/new")
    request = %{"service" => fields("dns-main", "stopped", "5301"), "_submission" => intent(view)}
    render_submit(view, "save_service", request)
    render_submit(view, "save_service", request)
    [service] = Domain.list_services("node-a")
    assert service["desired_state"] == "stopped"
    assert {:error, %{code: "not_found"}} = Domain.get_target("node-a")
    assert Domain.list_services("node-b") == []

    {:ok, fresh, _} = live(build_conn(), "/server/node-a/services/#{service["id"]}/edit")
    assert has_element?(fresh, "input[name='service[id]'][readonly][value='dns-main']")
    submit(fresh, "save_service", %{"service" => fields("dns-main", "running", "5302")})

    assert [%{"config" => %{"port" => 5302}, "desired_state" => "running"}] =
             Domain.list_services("node-a")

    assert {:error, %{code: "not_found"}} = Domain.get_target("node-a")
    response = get(build_conn(), "/api/workers/node-a")
    assert response.status == 200
    assert response.resp_body =~ "5302"
  end

  test "duplicate create and forged instance rename retain fields and cannot overwrite", %{
    conn: conn,
    worker: worker
  } do
    service =
      mutate("put_service", DomainFixtures.service("node-a", worker["revision"], "stopped"))

    {:ok, view, _} = live(conn, "/server/node-a/services/new")

    assert submit(view, "save_service", %{
             "service" => fields(service["instance_id"], "running", "5399")
           }) =~ "conflict: Service instance ID already exists in Worker"

    assert has_element?(view, "input[name='service[port]'][value='5399']")
    assert {:ok, persisted} = Domain.get_service("node-a", service["id"])
    assert persisted == Map.delete(service, "worker_revision")

    {:ok, edit, _} = live(build_conn(), "/server/node-a/services/#{service["id"]}/edit")

    assert submit(edit, "save_service", %{"service" => fields("forged-rename", "running", "5399")}) =~
             "invalid_request: Service instance ID cannot be changed"

    assert {:ok, persisted} = Domain.get_service("node-a", service["id"])
    assert persisted == Map.delete(service, "worker_revision")
    assert {:ok, _} = Domain.get_worker("node-b")

    assert {:error, {:live_redirect, %{to: "/server/node-b/services"}}} =
             live(build_conn(), "/server/node-b/services/#{service["id"]}/edit")
  end

  test "polling retains dirty fields and original revision; conflict reload is explicit", %{
    conn: conn,
    worker: worker
  } do
    {:ok, view, _} = live(conn, "/server/node-a/dashboard")

    render_change(view, "validate_worker", %{
      "worker" => %{"name" => "Unsaved", "profile_name" => "custom"}
    })

    mutate("update_worker", %{
      "id" => "node-a",
      "name" => "API write",
      "expected_revision" => worker["revision"]
    })

    send(view.pid, :refresh_connection)
    assert has_element?(view, "#node-workflow[data-dirty='true']")
    assert has_element?(view, "input[name='worker[name]'][value='Unsaved']")

    assert submit(view, "save_worker", %{
             "worker" => %{"name" => "Unsaved", "profile_name" => "custom"}
           }) =~ "revision_conflict"

    assert has_element?(view, "input[name='worker[name]'][value='Unsaved']")
    view |> element("button[phx-click='reload'][data-confirm]") |> render_click()
    assert has_element?(view, "input[name='worker[name]'][value='API write']")
    assert has_element?(view, "#node-workflow[data-dirty='false']")
  end

  test "target publication requires reviewed revision and rejects concurrent changes after polling",
       %{conn: conn, worker: worker} do
    service =
      mutate("put_service", DomainFixtures.service("node-a", worker["revision"], "stopped"))

    {:ok, view, _} = live(conn, "/server/node-a/targets")
    token = intent(view)
    render_click(view, "confirm_target", %{"_submission" => token})
    assert {:error, %{code: "not_found"}} = Domain.get_target("node-a")
    view |> element("button[phx-click='preview']") |> render_click()
    assert has_element?(view, "#target-preview", "Bound saved configuration revision: 2")

    mutate("put_service", %{
      DomainFixtures.service("node-a", service["worker_revision"], "running")
      | "config" => %{"listen_address" => "127.0.0.1", "port" => 5398}
    })

    send(view.pid, :refresh_connection)
    html = view |> element("button[phx-click='confirm_target']") |> render_click()
    assert html =~ "revision_conflict"
    assert {:error, %{code: "not_found"}} = Domain.get_target("node-a")
    view |> element("button[phx-click='preview']") |> render_click()
    publish = %{"_submission" => intent(view)}
    render_click(view, "confirm_target", publish)
    render_click(view, "confirm_target", publish)
    assert [%{"revision" => 1}] = Domain.list_worker_target_history("node-a")
    assert has_element?(view, "#selected-target", "Immutable published target revision 1")
    assert has_element?(view, "#worker-applied-revision", "None")
  end

  test "scoped references link to Data editors and historical exports stay immutable", %{
    conn: conn,
    worker: worker
  } do
    service =
      mutate("put_service", DomainFixtures.service("node-a", worker["revision"], "stopped"))

    zone = mutate("create_zone", DomainFixtures.zone("node-reference.test."))

    version =
      mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})

    mutate("assign", %{
      "worker_id" => "node-a",
      "service_id" => service["id"],
      "resource_version_id" => version["id"],
      "expected_revision" => service["worker_revision"]
    })

    {:ok, view, _} = live(conn, "/server/node-a/services/#{service["id"]}/edit")
    assert has_element?(view, "#service-references", "node-reference.test.")

    assert has_element?(
             view,
             "#service-references a[href='/server/node-a/dns/views/#{service["id"]}']"
           )

    assert has_element?(
             view,
             "#service-references a[href='/server/node-a/dns/acl/#{service["id"]}']"
           )

    refute has_element?(view, "#assignment-form")
    render_patch(view, "/server/node-a/targets")
    view |> element("button[phx-click='preview']") |> render_click()
    view |> element("button[phx-click='confirm_target']") |> render_click()
    export = get(build_conn(), "/api/workers/node-a/targets/1/export")
    assert export.status == 200
    {:ok, current} = Domain.get_worker("node-a")
    mutate("put_service", DomainFixtures.service("node-a", current["revision"], "running"))
    render_patch(view, "/server/node-a/targets")
    view |> element("button[phx-click='preview']") |> render_click()
    view |> element("button[phx-click='confirm_target']") |> render_click()
    {:ok, historical, _} = live(build_conn(), "/server/node-a/targets/1")
    assert has_element?(historical, "#selected-target", "revision 1")
    assert has_element?(historical, "a[href='/api/workers/node-a/targets/1/export']")
    assert get(build_conn(), "/api/workers/node-a/targets/1/export").resp_body == export.resp_body
    refute render(historical) =~ "node-b/targets"
  end

  defp fields(id, state, port),
    do: %{"id" => id, "desired_state" => state, "listen_address" => "127.0.0.1", "port" => port}

  defp submit(view, event, params),
    do: render_submit(view, event, Map.put(params, "_submission", intent(view)))

  defp intent(view),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#submission-intent")
      |> LazyHTML.attribute("value")
      |> hd()

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "fixture", Ecto.UUID.generate())
    result
  end
end
