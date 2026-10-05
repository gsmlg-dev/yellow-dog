defmodule YellowDog.Management.ZonesLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{
    Assignment,
    Audit,
    ConfigCompiler,
    Domain,
    DomainFixtures,
    Idempotency,
    Repo,
    ResourceVersion,
    Rrset,
    Service,
    Target,
    Worker,
    Zone
  }

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "database rejection retains draft input and retries the same command", %{conn: conn} do
    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_zone_draft() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'fixture database failure'; END $$
    """)

    Repo.query!(
      "CREATE TRIGGER fixture_reject_draft BEFORE INSERT ON management_zones FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_zone_draft()"
    )

    {:ok, view, _} = live(conn, "/management/zones/new")
    render_click(view, "add_record")
    input = fields(DomainFixtures.zone("retained.test."))
    view |> form("#zone-form", zone: input) |> render_submit()
    assert render(view) =~ "Database constraint rejected"
    assert has_element?(view, "#zone-name[value='retained.test.']")
    assert Domain.list_zones() == []
    rejected = snapshot()
    view |> form("#zone-form", zone: input) |> render_submit()
    assert snapshot() == rejected
    changed = fields(DomainFixtures.zone("edited.test."))
    view |> form("#zone-form", zone: changed) |> render_submit()
    assert length(Repo.all(Idempotency)) == length(rejected.idempotency) + 1
    assert Domain.list_zones() == []
    Repo.query!("DROP TRIGGER fixture_reject_draft ON management_zones")
    final = fields(DomainFixtures.zone("accepted.test."))
    view |> form("#zone-form", zone: final) |> render_submit()
    assert render(view) =~ "Zone draft saved"
    assert [zone] = Domain.list_zones()
    {:ok, fresh, _} = live(build_conn(), "/management/zones/#{zone["id"]}/edit")
    assert has_element?(fresh, "#zone-name[value='accepted.test.']")
  end

  test "Zone page saves shared assignments separately and both Worker pages agree", %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone("assignments.test."))

    version =
      mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})

    a = assignment_service("ui-assignment-a")
    b = assignment_service("ui-assignment-b")
    {:ok, view, _} = live(conn, "/management/zones/#{zone["id"]}/edit")
    render_click(view, "add_assignment_worker", %{"id" => a["worker_id"]})
    render_click(view, "add_assignment_worker", %{"id" => b["worker_id"]})
    assert Domain.list_assignments(a["worker_id"]) == []
    view |> form("#zone-assignments-form") |> render_submit()
    assert render(view) =~ "Worker assignments saved"
    assert {:ok, snapshot} = Domain.get_zone_assignments(zone["id"])
    assert length(snapshot["assignments"]) == 2

    for service <- [a, b] do
      assert [%{"resource_version_id" => version_id}] =
               Domain.list_assignments(service["worker_id"])

      assert version_id == version["id"]
      {:ok, worker_view, _} = live(build_conn(), "/server/#{service["worker_id"]}/dashboard")
      assert has_element?(worker_view, "#resource-assignments tbody tr", zone["id"])

      assert has_element?(
               worker_view,
               "#resource-assignments td:nth-child(2)",
               to_string(version["version"])
             )
    end

    changed = fields(zone)
    soa_index = Enum.find_index(zone["records"], &(&1["type"] == "SOA")) |> to_string()
    changed = put_in(changed, ["records", soa_index, "data", "serial"], 2)
    view |> form("#zone-form", zone: changed) |> render_submit()
    render_click(view, "confirm_zone", %{"id" => zone["id"]})
    assert length(Domain.list_versions(zone["id"])) == 2

    assert Enum.all?(
             Domain.list_assignments(a["worker_id"]),
             &(&1["resource_version_id"] == version["id"])
           )

    removed = Enum.find(snapshot["assignments"], &(&1["worker_id"] == a["worker_id"]))
    render_click(view, "remove_assignment_row", %{"key" => removed["id"]})
    view |> form("#zone-assignments-form") |> render_submit()
    assert Domain.list_assignments(a["worker_id"]) == []
    assert length(Domain.list_assignments(b["worker_id"])) == 1
    {:ok, fresh, _} = live(build_conn(), "/management/zones/#{zone["id"]}/edit")
    refute has_element?(fresh, "fieldset[data-worker-id='#{a["worker_id"]}']")
    assert has_element?(fresh, "fieldset[data-worker-id='#{b["worker_id"]}']")
  end

  test "stale assignment submissions retain their input and cannot erase another editor", %{
    conn: conn
  } do
    zone = mutate("create_zone", DomainFixtures.zone("stale-assignment.test."))

    version =
      mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})

    a = assignment_service("ui-stale-a")
    b = assignment_service("ui-stale-b")
    {:ok, view, _} = live(conn, "/management/zones/#{zone["id"]}/edit")
    render_click(view, "add_assignment_worker", %{"id" => a["worker_id"]})

    mutate("assign", %{
      "worker_id" => b["worker_id"],
      "service_id" => b["id"],
      "resource_version_id" => version["id"],
      "expected_revision" => b["worker_revision"]
    })

    view |> form("#zone-assignments-form") |> render_submit()
    assert has_element?(view, "#zone-assignment-error")
    assert has_element?(view, "fieldset[data-worker-id='#{a["worker_id"]}']")
    assert Domain.list_assignments(a["worker_id"]) == []
    assert length(Domain.list_assignments(b["worker_id"])) == 1
    rejected = snapshot()
    view |> form("#zone-assignments-form") |> render_submit()
    assert snapshot() == rejected
    assert has_element?(view, "#zone-assignment-error")
  end

  defp assignment_service(worker_id) do
    worker = mutate("create_worker", %{"id" => worker_id, "name" => worker_id})

    mutate("put_service", %{
      "worker_id" => worker["id"],
      "expected_revision" => worker["revision"],
      "id" => "dns",
      "type" => "dns",
      "desired_state" => "stopped",
      "config" => %{"listen_address" => "127.0.0.1", "port" => 5530}
    })
  end

  test "creates a Zone and edits records without Workers", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/management/zones/new")
    view |> element("button[phx-click='add_record']") |> render_click()
    view |> form("#zone-form", zone: fields(DomainFixtures.zone())) |> render_submit()
    [zone] = Domain.list_zones()
    assert Domain.list_workers() == []
    assert_patch(view, "/management/zones/#{zone["id"]}/edit")
    assert has_element?(view, "#zone-name[value='example.test.']")

    edited =
      update_in(zone, ["records"], fn records ->
        Enum.map(records, fn record ->
          if record["type"] == "A",
            do: put_in(record, ["data", "address"], "192.0.2.20"),
            else: record
        end)
      end)

    view |> form("#zone-form", zone: fields(edited)) |> render_submit()
    assert_patch(view, "/management/zones/#{zone["id"]}/edit")
    assert {:ok, saved} = Domain.get_zone(zone["id"])
    assert saved["revision"] == 2
    assert Enum.any?(saved["records"], &(&1["data"]["address"] == "192.0.2.20"))
  end

  test "new navigation clears the edited Zone identity", %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    {:ok, view, _html} = live(conn, "/management/zones/#{zone["id"]}/edit")
    view |> element("a", "New Zone") |> render_click()
    assert_patch(view, "/management/zones/new")
    assert has_element?(view, "#zone-name[value='']")
    view |> element("button[phx-click='add_record']") |> render_click()

    view
    |> form("#zone-form", zone: fields(DomainFixtures.zone("other.test.")))
    |> render_submit()

    assert length(Domain.list_zones()) == 2
    assert {:ok, unchanged} = Domain.get_zone(zone["id"])
    assert unchanged["revision"] == 1
  end

  test "confirmation is immutable and idempotent across draft edits", %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    {:ok, view, _html} = live(conn, "/management/zones/#{zone["id"]}/edit")
    view |> element("button[phx-click='confirm_zone']") |> render_click()
    view |> element("button[phx-click='confirm_zone']") |> render_click()
    [version] = Domain.list_versions(zone["id"])
    assert has_element?(view, "#zone-versions", version["digest"])

    edited =
      update_in(zone, ["records"], fn records -> Enum.map(records, &Map.put(&1, "ttl", 600)) end)

    view |> form("#zone-form", zone: fields(edited)) |> render_submit()
    assert_patch(view, "/management/zones/#{zone["id"]}/edit")
    assert Domain.list_versions(zone["id"]) == [version]
    view |> element("button[phx-click='confirm_zone']") |> render_click()
    assert [^version, %{"source_revision" => 2}] = Domain.list_versions(zone["id"])
  end

  test "invalid records and stale revision never overwrite the draft", %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    {:ok, view, _html} = live(conn, "/management/zones/#{zone["id"]}/edit")

    invalid =
      update_in(zone, ["records"], fn records -> Enum.map(records, &Map.put(&1, "ttl", -1)) end)

    html = view |> form("#zone-form", zone: fields(invalid)) |> render_submit()
    assert html =~ "validation failed"
    assert {:ok, ^zone} = Domain.get_zone(zone["id"])

    concurrent =
      mutate(
        "update_zone",
        Map.merge(DomainFixtures.zone(), %{"id" => zone["id"], "expected_revision" => 1})
      )

    html = view |> form("#zone-form", zone: fields(zone)) |> render_submit()
    assert html =~ "revision"
    assert {:ok, ^concurrent} = Domain.get_zone(zone["id"])
  end

  test "deleting an unassigned draft preserves confirmed versions", %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    {:ok, view, _html} = live(conn, "/management/zones/#{zone["id"]}/edit")
    refute has_element?(view, "button[phx-click='delete_zone'][data-confirm]")
    view |> element("button[phx-click='delete_zone']") |> render_click()
    assert has_element?(view, "#zone-delete-confirmation", "Historical versions will be retained")
    assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    view |> element("#zone-delete-confirm") |> render_click()
    assert_patch(view, "/management/zones")
    assert Domain.list_zones() == []
    assert Domain.list_versions(zone["id"]) == [version]
  end

  test "case-insensitive name filtering shows displayed and total counts without writing", %{
    conn: conn
  } do
    first = mutate("create_zone", DomainFixtures.zone("alpha.example.test."))
    second = mutate("create_zone", DomainFixtures.zone("beta.example.test."))
    {:ok, view, _html} = live(conn, "/management/zones")
    before_filter = snapshot()

    assert has_element?(view, "#zone-count[data-displayed='2'][data-total='2']")
    assert render(view) =~ "Global reusable Zone library"
    assert render(view) =~ "Forward, stub, cloud and additional record types remain pending"
    refute has_element?(view, "select[name='filter[type]']")
    filter(view, "ALPHA.EXAMPLE")
    assert has_element?(view, "#zone-filter[value='ALPHA.EXAMPLE']")
    assert has_element?(view, "#zone-count[data-displayed='1'][data-total='2']")
    assert has_element?(view, "#zone-#{first["id"]}")
    refute has_element?(view, "#zone-#{second["id"]}")
    filter(view, "missing")
    assert has_element?(view, "#zone-count[data-displayed='0'][data-total='2']")
    assert render(view) =~ "No Zone names match this filter"
    filter(view, "")
    assert has_element?(view, "#zone-count[data-displayed='2'][data-total='2']")
    assert snapshot() == before_filter
  end

  test "filtered CSV uses current draft records and honest unavailable query counts without effects",
       %{conn: conn} do
    history = history_fixture()
    included = mutate("create_zone", DomainFixtures.zone("csv.example.test."))
    {:ok, view, _html} = live(conn, "/management/zones")
    filter(view, "CSV.")

    changed =
      update_in(included, ["records"], fn records ->
        records ++
          [
            %{
              "name" => "extra.csv.example.test.",
              "type" => "A",
              "ttl" => 300,
              "data" => %{"address" => "192.0.2.30"}
            }
          ]
      end)

    mutate(
      "update_zone",
      Map.merge(changed, %{"id" => included["id"], "expected_revision" => 1})
      |> Map.take(~w(id expected_revision name records))
    )

    mutate("create_zone", DomainFixtures.zone("new.csv.example.test."))
    before_export = snapshot()

    assert has_element?(view, "#zone-export[phx-hook='CsvDownload']")
    view |> element("#zone-export") |> render_click()
    assert_push_event(view, "download_csv", %{content: csv, filename: "management_zones.csv"})

    assert csv ==
             "Name,Type,Record count,Query count\r\n" <>
               "csv.example.test.,Authoritative,4,Unavailable\r\n" <>
               "new.csv.example.test.,Authoritative,3,Unavailable\r\n"

    assert has_element?(view, "#zone-count[data-displayed='2'][data-total='3']")
    assert snapshot() == before_export
    assert ConfigCompiler.export_target(history.worker_id, 1) == history.export

    filter(view, "no-match")
    view |> element("#zone-export") |> render_click()
    assert_push_event(view, "download_csv", %{content: "Name,Type,Record count,Query count\r\n"})
    assert snapshot() == before_export
  end

  test "refresh retains filters and unsaved editor state and never advances its CAS revision",
       %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    {:ok, view, _html} = live(conn, "/management/zones/#{zone["id"]}/edit")
    filter(view, "EXAMPLE")
    pending = put_in(zone, ["name"], "unsaved.test.")
    view |> form("#zone-form", zone: fields(pending)) |> render_change()
    view |> element("button[phx-click='add_record']") |> render_click()

    changed =
      mutate(
        "update_zone",
        Map.merge(DomainFixtures.zone(), %{
          "id" => zone["id"],
          "expected_revision" => 1
        })
      )

    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 2})
    mutate("create_zone", DomainFixtures.zone("new.example.test."))
    before_refresh = snapshot()

    view |> element("#zone-refresh") |> render_click()
    assert has_element?(view, "#zone-name[value='unsaved.test.']")
    assert has_element?(view, "#zone-record-3")
    assert has_element?(view, "#zone-filter[value='EXAMPLE']")
    assert has_element?(view, "#zone-count[data-displayed='2'][data-total='2']")
    assert has_element?(view, "#zone-versions", version["digest"])
    assert render(view) =~ "Draft revision 1"
    refute has_element?(view, "#zones-table")
    assert snapshot() == before_refresh

    view |> element("button[phx-click='confirm_zone']") |> render_click()
    assert_rejected_command(before_refresh, "confirm_zone")
    assert Domain.list_versions(zone["id"]) == [version]
    assert {:ok, ^changed} = Domain.get_zone(zone["id"])
    assert has_element?(view, "#zone-name[value='unsaved.test.']")
  end

  test "refresh updates filtered list and clears an editor only when its draft disappeared",
       %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    {:ok, view, _html} = live(conn, "/management/zones")
    filter(view, "EXAMPLE")
    another = mutate("create_zone", DomainFixtures.zone("another.example.test."))
    before_refresh = snapshot()
    view |> element("#zone-refresh") |> render_click()
    assert has_element?(view, "#zone-#{another["id"]}")
    assert has_element?(view, "#zone-count[data-displayed='2'][data-total='2']")
    assert snapshot() == before_refresh

    view |> element("#zone-#{zone["id"]} a", "Edit") |> render_click()
    assert_patch(view, "/management/zones/#{zone["id"]}/edit")
    mutate("delete_zone", %{"id" => zone["id"], "expected_revision" => 1})
    before_refresh = snapshot()
    view |> element("#zone-refresh") |> render_click()
    assert_patch(view, "/management/zones")
    refute has_element?(view, "#zone-form")
    assert has_element?(view, "#zone-filter[value='EXAMPLE']")
    assert has_element?(view, "#zone-count[data-displayed='1'][data-total='1']")
    view |> element("a", "New Zone") |> render_click()
    assert_patch(view, "/management/zones/new")
    assert has_element?(view, "#zone-name[value='']")
    view |> form("#zone-form", zone: %{name: "typed.test."}) |> render_change()
    view |> element("#zone-refresh") |> render_click()
    assert has_element?(view, "#zone-name[value='typed.test.']")
    assert snapshot() == before_refresh
  end

  test "deletion selection cancellation and missing or mismatched confirmation never mutate",
       %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    other = mutate("create_zone", DomainFixtures.zone("other.test."))
    {:ok, view, _html} = live(conn, "/management/zones")
    before_selection = snapshot()

    render_click(view, "confirm_delete", %{"id" => zone["id"]})
    assert render(view) =~ "confirm its deletion first"
    render_click(view, "confirm_delete", %{})
    render_click(view, "delete_zone", %{"id" => "missing"})
    refute has_element?(view, "#zone-delete-confirmation")
    view |> element("#zone-#{zone["id"]} button[phx-click='delete_zone']") |> render_click()

    assert has_element?(
             view,
             "#zone-delete-confirmation[data-zone-id='#{zone["id"]}'][data-revision='1']"
           )

    render_click(view, "confirm_delete", %{"id" => other["id"]})
    assert has_element?(view, "#zone-delete-confirmation[data-zone-id='#{zone["id"]}']")
    view |> element("#zone-cancel-delete") |> render_click()
    refute has_element?(view, "#zone-delete-confirmation")
    assert snapshot() == before_selection

    view |> element("#zone-#{zone["id"]} button[phx-click='delete_zone']") |> render_click()
    view |> element("a", "New Zone") |> render_click()
    assert_patch(view, "/management/zones/new")
    refute has_element?(view, "#zone-delete-confirmation")
    render_click(view, "confirm_delete", %{"id" => zone["id"]})
    assert snapshot() == before_selection
  end

  test "stale delete confirmation retains its selected revision through refresh without retry",
       %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    {:ok, view, _html} = live(conn, "/management/zones")
    filter(view, "EXAMPLE")
    view |> element("#zone-#{zone["id"]} button[phx-click='delete_zone']") |> render_click()

    concurrent =
      mutate(
        "update_zone",
        Map.merge(DomainFixtures.zone(), %{
          "id" => zone["id"],
          "expected_revision" => 1
        })
      )

    before_confirm = snapshot()

    view |> element("#zone-delete-confirm") |> render_click()
    assert_rejected_command(before_confirm, "delete_zone")
    assert {:ok, ^concurrent} = Domain.get_zone(zone["id"])
    assert Domain.list_versions(zone["id"]) == [version]
    assert has_element?(view, "#zone-delete-confirmation[data-revision='1']")
    assert has_element?(view, "#zone-filter[value='EXAMPLE']")
    after_rejection = snapshot()
    view |> element("#zone-refresh") |> render_click()
    assert has_element?(view, "#zone-delete-confirmation[data-revision='1']")
    assert has_element?(view, "#zone-#{zone["id"]}", "2")
    assert snapshot() == after_rejection
    view |> element("#zone-delete-confirm") |> render_click()
    assert snapshot() == after_rejection
    assert {:ok, ^concurrent} = Domain.get_zone(zone["id"])

    view |> element("#zone-cancel-delete") |> render_click()
    view |> element("#zone-#{zone["id"]} button[phx-click='delete_zone']") |> render_click()
    assert has_element?(view, "#zone-delete-confirmation[data-revision='2']")
    view |> element("#zone-delete-confirm") |> render_click()
    refute has_element?(view, "#zone-delete-confirmation")
    assert has_element?(view, "#zone-count[data-displayed='0'][data-total='0']")
    assert Domain.list_versions(zone["id"]) == [version]
  end

  test "an edited draft keeps its own revision for deletion even after list refresh", %{
    conn: conn
  } do
    zone = mutate("create_zone", DomainFixtures.zone())
    {:ok, view, _html} = live(conn, "/management/zones/#{zone["id"]}/edit")

    view
    |> form("#zone-form", zone: fields(put_in(zone, ["name"], "unsaved.test.")))
    |> render_change()

    concurrent =
      mutate(
        "update_zone",
        Map.merge(DomainFixtures.zone(), %{
          "id" => zone["id"],
          "expected_revision" => 1
        })
      )

    view |> element("#zone-refresh") |> render_click()
    before_confirm = snapshot()
    view |> element("button[phx-click='delete_zone']") |> render_click()
    assert has_element?(view, "#zone-delete-confirmation[data-revision='1']")
    assert snapshot() == before_confirm
    view |> element("#zone-delete-confirm") |> render_click()
    assert_rejected_command(before_confirm, "delete_zone")
    assert has_element?(view, "#zone-name[value='unsaved.test.']")
    assert has_element?(view, "#zone-delete-confirmation[data-revision='1']")
    assert {:ok, ^concurrent} = Domain.get_zone(zone["id"])
  end

  test "record addition and removal stay local until saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/management/zones/new")
    view |> element("button[phx-click='add_record']") |> render_click()
    assert has_element?(view, "#zone-record-2")
    view |> element("#zone-record-2 button[phx-click='remove_record']") |> render_click()
    refute has_element?(view, "#zone-record-2")
    assert Domain.list_zones() == []
  end

  test "server-scoped navigation keeps the selected logical Worker", %{conn: conn} do
    mutate("create_worker", %{
      "id" => "zone-worker",
      "name" => "Zone Worker",
      "expected_capabilities" => ["dns"]
    })

    zone = mutate("create_zone", DomainFixtures.zone())
    {:ok, view, _html} = live(conn, "/server/zone-worker/dns/zones")
    assert has_element?(view, "a[href='/server/zone-worker/dns/zones/new']")
    assert has_element?(view, "a[href='/server/zone-worker/dns/zones/import']", "Import Zone")

    assert has_element?(
             view,
             "a[href='/server/zone-worker/dns/zones/#{zone["id"]}/records']",
             "Records"
           )

    view |> element("#zone-#{zone["id"]} a", "Edit") |> render_click()
    assert_patch(view, "/server/zone-worker/dns/zones/#{zone["id"]}/edit")
    assert has_element?(view, "a[href='/server/zone-worker/dns/zones']", "Cancel")
    assert render(view) =~ "runtime state is unknown"
  end

  test "unknown selected Worker cannot expose an editable Zone", %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())

    for path <- [
          "/server/missing/dns/zones",
          "/server/missing/dns/zones/new",
          "/server/missing/dns/zones/#{zone["id"]}/edit"
        ] do
      assert {:error, {:live_redirect, %{to: "/server", flash: %{"error" => "Worker not found"}}}} =
               live(conn, path)
    end

    assert {:ok, ^zone} = Domain.get_zone(zone["id"])
  end

  for {label, query} <- [
        {"known Worker", "server_id=scope-worker"},
        {"missing Worker", "server_id=missing"},
        {"array", "server_id[]=scope-worker"},
        {"map", "server_id[id]=scope-worker"}
      ] do
    @scope_query query
    @tag :scope_regression
    test "global Zone routes ignore a #{label} server_id query", %{conn: conn} do
      mutate("create_worker", %{"id" => "scope-worker", "name" => "Scope Worker"})
      zone = mutate("create_zone", DomainFixtures.zone())
      before_visit = {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()}

      for path <- [
            "/management/zones",
            "/management/zones/new",
            "/management/zones/#{zone["id"]}/edit"
          ] do
        {:ok, view, _html} = live(conn, path <> "?" <> @scope_query)
        assert has_element?(view, "a[href='/management/zones/new']", "New Zone")
        assert has_element?(view, "a[href='/management/zones/import']", "Import Zone")
        refute has_element?(view, "a[href='/server/scope-worker/dns/zones/new']")
        assert {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()} == before_visit
      end
    end
  end

  @tag :scope_regression
  test "matched route params exclude query identities and decode concrete path segments" do
    socket = %Phoenix.LiveView.Socket{router: YellowDog.ManagementUI.Router}
    hook = YellowDog.ManagementUI.Hooks.CurrentPath

    assert hook.route_path_params(socket, "http://www.example.com/management/zones?server_id[]=x") ==
             %{}

    uri =
      "http://www.example.com/server/%53cope.Worker_1/dns/zones/path-zone/records/2/edit" <>
        "?server_id=other&zone_id[]=other&rr_index[]=0"

    assert hook.route_path_params(socket, uri) == %{
             "server_id" => "Scope.Worker_1",
             "zone_id" => "path-zone",
             "rr_index" => "2"
           }
  end

  @tag :scope_regression
  test "scoped Zone routes keep the path Worker and Zone when query IDs conflict", %{conn: conn} do
    mutate("create_worker", %{"id" => "Scope.Worker_1", "name" => "Path Worker"})
    mutate("create_worker", %{"id" => "other-worker", "name" => "Other Worker"})
    zone = mutate("create_zone", DomainFixtures.zone())
    other = mutate("create_zone", DomainFixtures.zone("other.test."))
    before_visit = {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()}
    base = "/server/Scope.Worker_1/dns/zones"

    for query <- [
          "server_id=other-worker",
          "server_id[]=other-worker",
          "server_id[id]=other-worker"
        ] do
      {:ok, view, _html} =
        live(conn, "#{base}/#{zone["id"]}/edit?#{query}&zone_id=#{other["id"]}")

      assert has_element?(view, "#zone-name[value='example.test.']")
      assert has_element?(view, "a[href='#{base}']", "Cancel")
      assert {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()} == before_visit
    end
  end

  @tag :scope_regression
  test "unknown scoped Zone routes cannot become global through query overrides", %{conn: conn} do
    mutate("create_worker", %{"id" => "scope-worker", "name" => "Scope Worker"})
    zone = mutate("create_zone", DomainFixtures.zone())
    before_visit = {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()}

    for worker_id <- ["missing", "invalid!"],
        suffix <- ["", "/new", "/#{zone["id"]}/edit"],
        query <- [
          "server_id=scope-worker",
          "server_id[]=scope-worker",
          "server_id[id]=scope-worker"
        ] do
      path = "/server/#{worker_id}/dns/zones#{suffix}?#{query}"

      assert {:error, {:live_redirect, %{to: "/server"}}} = live(conn, path)
      assert {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()} == before_visit
    end
  end

  defp fields(zone) do
    %{
      "name" => zone["name"],
      "records" =>
        zone["records"]
        |> Enum.with_index()
        |> Map.new(fn {record, index} -> {to_string(index), record} end)
    }
  end

  defp filter(view, name) do
    view |> form("#zones-filter-form", filter: %{name: name}) |> render_change()
  end

  defp history_fixture do
    zone = mutate("create_zone", DomainFixtures.zone("history.test."))
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    worker = mutate("create_worker", %{"id" => "zone-history", "name" => "Zone History"})
    service = mutate("put_service", DomainFixtures.service(worker["id"], 1, "stopped"))

    assignment =
      mutate("assign", %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_version_id" => version["id"],
        "expected_revision" => service["worker_revision"]
      })

    mutate("confirm_target", %{
      "worker_id" => worker["id"],
      "expected_revision" => assignment["worker_revision"]
    })

    %{worker_id: worker["id"], export: ConfigCompiler.export_target(worker["id"], 1)}
  end

  defp snapshot do
    business =
      for schema <- [Worker, Service, Assignment, Zone, Rrset, ResourceVersion, Target],
          into: %{},
          do: {schema, Repo.all(schema) |> Enum.sort_by(& &1.id)}

    Map.merge(business, %{
      audit: Repo.all(Audit) |> Enum.sort_by(& &1.id),
      idempotency: Repo.all(Idempotency) |> Enum.sort_by(& &1.key)
    })
  end

  defp assert_rejected_command(before, operation) do
    after_rejection = snapshot()

    assert Map.drop(after_rejection, [:audit, :idempotency]) ==
             Map.drop(before, [:audit, :idempotency])

    assert Enum.all?(before.audit, &(&1 in after_rejection.audit))
    assert Enum.all?(before.idempotency, &(&1 in after_rejection.idempotency))
    assert [audit] = after_rejection.audit -- before.audit
    assert audit.operation == operation
    assert audit.result["error"]["code"] == "revision_conflict"
    assert [receipt] = after_rejection.idempotency -- before.idempotency
    assert receipt.result["error"]["code"] == "revision_conflict"
  end

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
