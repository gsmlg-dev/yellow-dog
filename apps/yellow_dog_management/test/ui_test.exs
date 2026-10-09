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
    assert has_element?(view, "a[href='/management']", "Management")
    assert has_element?(view, "a[href='/server']", "Servers")
    assert has_element?(view, "a[href='/netman']", "Netman")
    assert has_element?(view, "a[href='/tool/geoip']", "Tools")
    assert has_element?(view, "a[href='/system/process-map']", "System")
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

  test "unmigrated System shortcuts keep their labels and pending state without dangling links",
       %{
         conn: conn
       } do
    {:ok, view, _html} = live(conn, "/system/logs")

    for {path, label} <- [
          {"/system/logs/dns-query", "DNS Query Logs"},
          {"/system/logs/dhcpv4-activity", "DHCPv4 Activity"},
          {"/system/logs/dhcpv6-activity", "DHCPv6 Activity"},
          {"/system/logs/netboot", "Netboot Log"},
          {"/system/logs/identity-audit", "Identity Audit"},
          {"/system/provider/cloud-dns", "Cloud DNS"},
          {"/system/fingerprint/devices", "Device Inventory"},
          {"/system/fingerprint/fingerprints", "Fingerprints"}
        ] do
      refute has_element?(view, "a[href='#{path}']")
      refute has_element?(view, ".yd-sidebar a", label)

      assert has_element?(
               view,
               ".yd-sidebar span[aria-disabled='true'][title='Not migrated']",
               label
             )
    end
  end

  test "Management overview counts PostgreSQL Netman nodes without claiming them online", %{
    conn: conn
  } do
    mutate("create_netman", %{"id" => "overview-node", "name" => "Overview Node"})
    {:ok, view, _html} = live(conn, "/management")
    assert has_element?(view, "#management-netman-count", "1")
    assert has_element?(view, "a[href='/management/netman']", "Manage Netman")
    assert has_element?(view, "#management-overview", "actual runtime state remains unknown")
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
    assert has_element?(view, "a[href='/server/ui-export/dns/zones']", "Zones")

    view
    |> form("#service-form",
      service: %{id: "dns", listen_address: "127.0.0.1", port: "5300", desired_state: "stopped"}
    )
    |> render_submit()

    assert has_element?(view, "#dns-services", "stopped")
    [service] = Domain.list_services(worker["id"])

    view
    |> form("#assignment-form",
      assignment: %{service_id: service["id"], resource_version_id: version["id"]}
    )
    |> render_submit()

    assert length(Domain.list_assignments(worker["id"])) == 1
    view |> element("button[phx-click='preview']") |> render_click()
    assert has_element?(view, "#target-preview", "prepared_preview")
    view |> element("button[phx-click='confirm_target']") |> render_click()
    assert {:ok, target} = Domain.get_target(worker["id"])
    assert target["status"] == "prepared"
    assert target["actual_state"] == "unknown"

    exported = get(conn, "/api/workers/#{worker["id"]}/targets/1/export")
    assert exported.status == 200
    assert exported.resp_body =~ "example.test."
    assert render(view) =~ "Export TOML revision 1"

    view |> element("button[phx-click='unassign']") |> render_click()
    assert Domain.list_assignments(worker["id"]) == []
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
    {:ok, view, _html} = live(conn, "/server/ui-service/dashboard")

    view
    |> element("button[phx-click='edit_service'][phx-value-id='#{service["id"]}']")
    |> render_click()

    assert has_element?(
             view,
             "select[name='service[desired_state]'] option[value='running'][selected]"
           )

    assert has_element?(view, "input[name='service[port]'][value='5300']")

    view |> form("#service-form", service: %{desired_state: "stopped"}) |> render_submit()

    assert [%{"desired_state" => "stopped", "actual_state" => "unknown"}] =
             Domain.list_services(worker["id"])
  end

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end

  test "logical Worker selection follows the Domain ID contract", %{conn: conn} do
    mutate("create_worker", %{"id" => "settings", "name" => "Settings Worker"})
    {:ok, view, _html} = live(conn, "/server/settings/dashboard")
    assert has_element?(view, "#server-selection-form-select option[value='settings'][selected]")
    assert has_element?(view, "a[href='/server/settings/dns/zones']", "Zones")
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
    assert has_element?(view, "a[href='/server/settings/dns']", "Overview")
  end

  test "DNS overview preserves the requested Worker selection", %{conn: conn} do
    mutate("create_worker", %{"id" => "settings", "name" => "Settings Worker"})
    {:ok, view, _html} = live(conn, "/server/settings/dns")
    assert has_element?(view, "#server-selection-form-select option[value='settings'][selected]")
    assert has_element?(view, "a[href='/server/settings/dns/zones']", "Zones")
  end
end
