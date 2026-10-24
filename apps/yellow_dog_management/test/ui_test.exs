defmodule YellowDog.Management.UITest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias YellowDog.Management.{Domain, DomainFixtures, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "Management navigation renders without login", %{conn: conn} do
    {:ok, view, html} = live(conn, "/management")
    assert html =~ "yd-layout"
    assert html =~ "management-live.js"
    assert html =~ "management.css"

    for {id, label, path} <- [
          {"nodes", "Node Management", "/management/servers"},
          {"data", "Data Configuration", "/management/zones"},
          {"monitoring", "Monitoring", "/management"},
          {"system", "System Configuration", "/system/process-map"}
        ] do
      assert has_element?(
               view,
               "nav[aria-label='Main navigation'] a[data-section='#{id}'][href='#{path}']",
               label
             )
    end

    assert has_element?(view, "#workspace a[href='/management/config']", "Manage Configuration")
    assert html =~ "Actual runtime state is unknown"
    refute html =~ "Operator token"
    assert get_resp_header(get(conn, "/management"), "www-authenticate") == []
    [policy] = get_resp_header(get(conn, "/management"), "content-security-policy")
    assert policy =~ "script-src 'self';"

    assert policy =~
             "script-src-attr 'unsafe-hashes' 'sha256-NaIeMghFEg+ph81F//6Bd2P0/9dHc/y2X7leoJ7MLmA='"

    assert policy =~ "style-src-attr 'unsafe-inline'"
  end

  test "unavailable monitoring shortcuts are planned without dangling links", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/logs")

    for label <- ["Node status", "Service status", "Configuration delivery"] do
      refute has_element?(view, "#app-sidebar-navigation a", label)
      assert has_element?(view, "#app-sidebar-navigation [aria-disabled='true']", label)
      assert has_element?(view, "#app-sidebar-navigation [aria-disabled='true']", "Planned")
    end
  end

  test "name-only registration persists a generated Worker and shows its connection configuration",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/server")

    view
    |> form("#worker-form", worker: %{name: "UI Worker"})
    |> render_submit()

    assert [worker] = Domain.list_workers()
    assert {:ok, _} = Ecto.UUID.cast(worker["id"])
    assert has_element?(view, "#server-selector-#{worker["id"]}", "UI Worker")
    assert_push_event(view, "reset_form", %{id: "worker-form"})
    assert has_element?(view, "#worker-form input[name='worker[name]'][value='']")
    refute has_element?(view, "#worker-form input[name='worker[id]']")

    assert {:ok, %{"name" => "UI Worker", "actual_state" => "unknown"}} =
             Domain.get_worker(worker["id"])

    assert worker["connection_status"] == "not_yet_connected"
    assert has_element?(view, "#server-selector-#{worker["id"]}", "Not connected")
    assert has_element?(view, "#worker-bootstrap[readonly]")
    assert has_element?(view, "#worker-bootstrap-copy[phx-hook='CopyToClipboard']")

    assert {:ok, config} =
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#worker-bootstrap")
             |> LazyHTML.text()
             |> Toml.decode()

    assert config["worker_id"] == worker["id"]
    assert byte_size(config["token"]) == 43
    assert config["data_dir"] == "data"
    assert config["poll_interval_ms"] == 10_000
    refute Jason.encode!(Domain.list_audit()) =~ config["token"]
    render_click(view, "dismiss_connection")
    refute has_element?(view, "#worker-bootstrap")
  end

  test "Worker service, version assignment, preview and export use PostgreSQL", %{conn: conn} do
    worker =
      mutate("create_worker", %{
        "id" => "ui-export",
        "name" => "Export Worker",
        "expected_capabilities" => ["dns"]
      })

    zone = mutate("create_zone", DomainFixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    {:ok, view, _html} = live(conn, "/server/#{worker["id"]}/dashboard")
    assert has_element?(view, "#server-selection-form-select option[value='ui-export'][selected]")

    assert has_element?(
             view,
             "#app-sidebar-navigation a[data-nav-item='worker_services'][aria-current='page']"
           )

    refute has_element?(view, "#service-form")
    view |> element("#worker-tabs a[href='/server/ui-export/services']") |> render_click()
    assert_patch(view, "/server/ui-export/services")
    view |> element("a[href='/server/ui-export/services/new']") |> render_click()
    assert_patch(view, "/server/ui-export/services/new")

    view
    |> form("#service-form",
      service: %{id: "dns", listen_address: "127.0.0.1", port: "5300", desired_state: "stopped"}
    )
    |> render_submit()

    assert has_element?(view, "#dns-services", "stopped")
    [service] = Domain.list_services(worker["id"])

    view
    |> element("#dns-services a[href='/server/ui-export/services/#{service["id"]}/edit']")
    |> render_click()

    assert_patch(view, "/server/ui-export/services/#{service["id"]}/edit")
    refute has_element?(view, "#assignment-form")

    {:ok, data, _html} =
      view
      |> element("#service-references a[href='/server/ui-export/dns/zones']")
      |> render_click()
      |> follow_redirect(conn, "/server/ui-export/dns/zones")

    assert has_element?(data, "#server-selection-form-select option[value='ui-export'][selected]")

    assert has_element?(
             data,
             "nav[aria-label='Main navigation'] a[data-section='data'][aria-current='page']"
           )

    data
    |> element("#zone-#{zone["id"]} a[href='/server/ui-export/dns/zones/#{zone["id"]}/edit']")
    |> render_click()

    assert_patch(data, "/server/ui-export/dns/zones/#{zone["id"]}/edit")

    data
    |> element("a[href='/server/ui-export/dns/zones/#{zone["id"]}/application']")
    |> render_click()

    data
    |> element("button[phx-click='add_assignment_worker'][phx-value-id='ui-export']")
    |> render_click()

    data |> form("#zone-assignments-form") |> render_submit()

    assert [assignment] = Domain.list_assignments(worker["id"])
    assert assignment["service_id"] == service["id"]
    assert assignment["resource_version_id"] == version["id"]
    {:ok, view, _html} = live(conn, "/server/ui-export/targets")
    view |> element("button[phx-click='preview']") |> render_click()
    assert has_element?(view, "#target-preview", "Bound saved configuration revision")
    assert has_element?(view, "#target-preview", "example.test.")
    view |> element("button[phx-click='confirm_target']") |> render_click()
    assert {:ok, target} = Domain.get_target(worker["id"])
    assert target["status"] == "prepared"
    assert target["actual_state"] == "unknown"

    exported = get(conn, "/api/workers/#{worker["id"]}/targets/1/export")
    assert exported.status == 200
    assert exported.resp_body =~ "example.test."
    assert render(view) =~ "Export TOML revision 1"

    # Publication advanced the Worker revision, so refresh the assignment preconditions.
    data |> element("button[phx-click='refresh_assignments']") |> render_click()

    data
    |> element("button[phx-click='remove_assignment_row'][phx-value-key='#{assignment["id"]}']")
    |> render_click()

    data |> form("#zone-assignments-form") |> render_submit()
    assert Domain.list_assignments(worker["id"]) == []

    # Later assignment changes cannot change an earlier immutable export.
    earlier_export = get(conn, "/api/workers/ui-export/targets/1/export")
    assert earlier_export.status == 200
    assert earlier_export.resp_body == exported.resp_body
  end

  test "stale forms report conflicts rather than overwrite concurrent edits", %{conn: conn} do
    worker =
      mutate("create_worker", %{
        "id" => "ui-stale",
        "name" => "Before",
        "expected_capabilities" => ["dns"]
      })

    {:ok, view, _html} = live(conn, "/server/ui-stale/dashboard")

    mutate("update_worker", %{
      "id" => worker["id"],
      "name" => "Concurrent",
      "expected_revision" => 1
    })

    html = view |> form("#worker-edit-form", worker: %{name: "Stale"}) |> render_submit()
    assert html =~ "revision"
    assert {:ok, %{"name" => "Concurrent"}} = Domain.get_worker(worker["id"])
  end

  test "business API rejects malformed request bodies", %{conn: conn} do
    assert get(conn, "/api/workers").status == 200

    response =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/api/commands/create_worker", "{")

    assert response.status == 400
  end

  test "Phoenix serves the local compiled DuskMoon stylesheet", %{conn: conn} do
    response = get(conn, "/management.css")
    assert response.status == 200

    assert Enum.any?(
             get_resp_header(response, "content-type"),
             &String.starts_with?(&1, "text/css")
           )

    assert response.resp_body =~ "--color-primary"
    assert response.resp_body =~ ".btn"
    refute response.resp_body =~ ~r/@(?:import|theme|plugin|apply|utility)\b/
  end

  test "Management events read durable audit entries and expose their details", %{conn: conn} do
    mutate("create_worker", %{"id" => "ui-audit", "name" => "Audited Worker"})
    assert [%{"id" => audit_id}] = Domain.list_audit()
    {:ok, view, _html} = live(conn, "/management/events")
    assert has_element?(view, "#management-events", "create_worker")

    view
    |> element("#management-events button[phx-click='show'][phx-value-id='#{audit_id}']")
    |> render_click()

    assert has_element?(view, "#event-details", "Audited Worker")
    assert has_element?(view, "#event-details", "operator")
  end

  test "editing a desired service preserves its fields until explicitly changed", %{conn: conn} do
    worker =
      mutate("create_worker", %{
        "id" => "ui-service",
        "name" => "Service Worker",
        "expected_capabilities" => ["dns"]
      })

    service = mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"]))
    {:ok, view, _html} = live(conn, "/server/ui-service/services")

    view
    |> element("#dns-services a[href='/server/ui-service/services/#{service["id"]}/edit']")
    |> render_click()

    assert_patch(view, "/server/ui-service/services/#{service["id"]}/edit")
    assert has_element?(view, "input[name='service[id]'][value='dns'][readonly]")
    assert has_element?(view, "input[name='service[listen_address]'][value='127.0.0.1']")

    assert has_element?(
             view,
             "select[name='service[desired_state]'] option[value='running'][selected]"
           )

    assert has_element?(view, "input[name='service[port]'][value='5300']")

    view |> form("#service-form", service: %{desired_state: "stopped"}) |> render_submit()

    assert [%{"desired_state" => "stopped", "actual_state" => "unknown"} = persisted] =
             Domain.list_services(worker["id"])

    assert persisted["id"] == service["id"]
    assert persisted["instance_id"] == service["instance_id"]
    assert persisted["config"] == service["config"]
  end

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end

  test "logical Worker selection follows the Domain ID contract", %{conn: conn} do
    worker = mutate("create_worker", %{"id" => "settings", "name" => "Settings Worker"})
    service = mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"]))
    {:ok, view, _html} = live(conn, "/server/settings/dashboard")
    assert has_element?(view, "#server-selection-form-select option[value='settings'][selected]")
    view |> element("#worker-tabs a[href='/server/settings/services']") |> render_click()
    assert_patch(view, "/server/settings/services")

    view
    |> element("#dns-services a[href='/server/settings/services/#{service["id"]}/edit']")
    |> render_click()

    assert_patch(view, "/server/settings/services/#{service["id"]}/edit")

    {:ok, data, _html} =
      view
      |> element("#service-references a[href='/server/settings/dns/zones']")
      |> render_click()
      |> follow_redirect(conn, "/server/settings/dns/zones")

    assert has_element?(data, "#server-selection-form-select option[value='settings'][selected]")

    assert has_element?(
             data,
             "#app-sidebar-navigation a[data-nav-item='dns_zones'][href='/server/settings/dns/zones'][aria-current='page']"
           )
  end

  test "Worker IDs with service-like names retain explicit scoped links", %{conn: conn} do
    mutate("create_worker", %{"id" => "settings", "name" => "Settings Worker"})
    mutate("create_worker", %{"id" => "dns", "name" => "DNS Worker"})
    {:ok, selector, _html} = live(conn, "/server")

    assert has_element?(
             selector,
             "#server-selector-settings a[href='/server/settings/dashboard']",
             "Manage"
           )

    assert has_element?(
             selector,
             "#server-selector-dns a[href='/server/dns/dashboard']",
             "Manage"
           )

    {:ok, view, _html} = live(conn, "/server/settings/dashboard")

    assert has_element?(
             view,
             "#app-sidebar-navigation a[href='/server/settings/dashboard'][data-nav-item='worker_services']",
             "Selected Worker"
           )
  end

  test "DNS overview preserves the requested Worker selection", %{conn: conn} do
    worker = mutate("create_worker", %{"id" => "settings", "name" => "Settings Worker"})
    other = mutate("create_worker", %{"id" => "dns", "name" => "DNS Worker"})
    service = mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"]))
    mutate("put_service", DomainFixtures.service(other["id"], other["revision"]))
    {:ok, view, _html} = live(conn, "/server/settings/dns?server_id=dns")
    assert has_element?(view, "#server-selection-form-select option[value='settings'][selected]")

    assert has_element?(
             view,
             "#worker-tabs a[href='/server/settings/services'][aria-current='page']"
           )

    view
    |> element("#dns-services a[href='/server/settings/services/#{service["id"]}/edit']")
    |> render_click()

    assert_patch(view, "/server/settings/services/#{service["id"]}/edit")

    assert has_element?(
             view,
             "#service-references a[href='/server/settings/dns/zones']",
             "Edit Zone data and assignments"
           )

    refute has_element?(view, "#service-references a[href='/server/dns/dns/zones']")
  end
end
