defmodule YellowDog.Management.WorkerProfilesLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias YellowDog.Management.{
    Assignment,
    Audit,
    Domain,
    DomainFixtures,
    Idempotency,
    ProfileCatalog,
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

  test "Worker management has a name-only form and reads without writes", %{conn: conn} do
    before_read = read_snapshot()

    for path <- ["/server", "/management/servers"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#worker-form[phx-hook='ResetForm']")
      assert has_element?(view, "#worker-form input[name='worker[name]']")
      refute has_element?(view, "#worker-form input[name='worker[id]']")
      refute has_element?(view, "#worker-profile")
      assert has_element?(view, "#server-selector-records")
      refute has_element?(view, "#worker-bootstrap")
      assert get_resp_header(get(conn, path), "www-authenticate") == []
    end

    assert read_snapshot() == before_read
  end

  test "name-only creation generates identity and one-time bootstrap without enabling services",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/management/servers")
    before_side_effects = non_worker_snapshot()
    name = "<script>alert('name')</script> & Worker"
    view |> form("#worker-form", worker: %{name: name}) |> render_submit()

    assert_push_event(view, "reset_form", %{id: "worker-form"})
    assert has_element?(view, "#worker-form input[name='worker[name]'][value='']")
    [worker] = Domain.list_workers()
    assert {:ok, _} = Ecto.UUID.cast(worker["id"])
    assert worker["name"] == name
    assert {:ok, detail} = Domain.get_worker(worker["id"])
    assert detail["services"] == []
    assert detail["assignments"] == []
    assert detail["actual_state"] == "unknown"
    assert worker["connection_status"] == "not_yet_connected"
    assert {:error, %{code: "not_found"}} = Domain.get_target(worker["id"])
    assert non_worker_snapshot() == before_side_effects
    row = "#server-selector-#{worker["id"]}"
    assert has_element?(view, "#{row} a[href='/server/#{worker["id"]}/dashboard']", "Manage")
    refute has_element?(view, "#{row} script")
    assert render(view) =~ "&lt;script&gt;"
    assert {:ok, config} = Toml.decode(text(view, "#worker-bootstrap"))
    assert config["worker_id"] == worker["id"]
    assert config["management_url"] == "http://www.example.com"
    assert byte_size(config["token"]) == 43
    refute Jason.encode!(Domain.list_workers()) =~ config["token"]
    refute Jason.encode!(Domain.list_audit()) =~ config["token"]
    {:ok, fresh, _} = live(conn, "/management/servers")
    refute has_element?(fresh, "#worker-bootstrap")
  end

  test "forged registration identity, profile and enablement are ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/management/servers")
    before_side_effects = non_worker_snapshot()

    [intent] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#worker-form input[name='_submission']")
      |> LazyHTML.attribute("value")

    request = %{
      "worker" => %{
        "id" => "forged-id",
        "name" => "Name only",
        "profile_name" => "dhcp_only",
        "expected_capabilities" => ["dhcpv4"],
        "services" => %{"dhcpv4" => %{"desired_state" => "running"}}
      },
      "_submission" => intent
    }

    render_submit(view, "save", request)
    render_submit(view, "save", request)
    [worker] = Domain.list_workers()
    assert worker["id"] != "forged-id"
    assert worker["profile_name"] == "custom"
    assert worker["expected_capabilities"] == ["dns"]
    assert non_worker_snapshot() == before_side_effects
  end

  test "name and profile edits preserve DNS, assignments, immutable targets and export bytes", %{
    conn: conn
  } do
    %{worker: worker, target: target} = configured_worker("profile-edit")
    before_read = read_snapshot()
    preserved = non_worker_snapshot()
    export_path = "/api/workers/#{worker["id"]}/targets/#{target["revision"]}/export"
    exported = get(conn, export_path)
    assert exported.status == 200
    {:ok, view, html} = live(conn, "/server/#{worker["id"]}/dashboard")
    assert_catalog(view, "worker-edit-profile", "dns_only")
    assert has_element?(view, "#worker-edit-form button", "Save name and profile")
    assert has_element?(view, "#service-form")
    assert has_element?(view, "#assignment-form")
    assert has_element?(view, "a[href='#{export_path}']", "Export TOML")
    assert has_element?(view, "a[href='/server/#{worker["id"]}/dns/zones']", "DNS Zones")
    assert html =~ "Actual runtime state is unknown"
    assert html =~ "not service enablement"
    assert read_snapshot() == before_read

    view
    |> form("#worker-edit-form", worker: %{name: "Renamed", profile_name: "dhcp_only"})
    |> render_submit()

    assert {:ok, updated} = Domain.get_worker(worker["id"])
    assert updated["name"] == "Renamed"
    assert updated["profile_name"] == "dhcp_only"
    assert updated["revision"] == worker["revision"] + 1

    assert Map.drop(updated, ~w(name profile_name revision)) ==
             Map.drop(worker, ~w(name profile_name revision))

    assert_catalog(view, "worker-edit-profile", "dhcp_only")
    assert {:ok, ^target} = Domain.get_target(worker["id"])
    assert get(conn, export_path).resp_body == exported.resp_body
    assert non_worker_snapshot() == preserved

    render_submit(view, "save_worker", %{
      "worker" => %{"name" => "Name only"},
      "_submission" => intent(view)
    })

    assert {:ok, name_only} = Domain.get_worker(worker["id"])
    assert name_only["name"] == "Name only"
    assert name_only["profile_name"] == "dhcp_only"
    assert name_only["revision"] == updated["revision"] + 1
    refute Map.has_key?(hd(Domain.list_audit())["request"], "profile_name")
    assert non_worker_snapshot() == preserved
    assert get(conn, export_path).resp_body == exported.resp_body
  end

  test "a stale profile form cannot overwrite a concurrent metadata change", %{conn: conn} do
    %{worker: worker} = configured_worker("profile-stale")
    {:ok, view, _html} = live(conn, "/server/#{worker["id"]}/dashboard")
    preserved = non_worker_snapshot()

    mutate("update_worker", %{
      "id" => worker["id"],
      "expected_revision" => worker["revision"],
      "name" => "Concurrent name",
      "profile_name" => "netboot_only"
    })

    assert {:ok, concurrent} = Domain.get_worker(worker["id"])

    assert view
           |> form("#worker-edit-form", worker: %{name: "Stale", profile_name: "dhcp_only"})
           |> render_submit() =~ "Expected revision does not match current revision"

    assert {:ok, ^concurrent} = Domain.get_worker(worker["id"])
    assert hd(Domain.list_audit())["result"]["error"]["code"] == "revision_conflict"
    assert non_worker_snapshot() == preserved
  end

  test "invalid profile edits reject atomically with an actionable error", %{
    conn: conn
  } do
    %{worker: worker} = configured_worker("profile-invalid")
    {:ok, edit, _html} = live(conn, "/server/#{worker["id"]}/dashboard")
    before_rejections = configuration_snapshot()

    for invalid <- ["unknown", "", nil, ["custom"], %{"name" => "custom"}] do
      assert render_submit(edit, "save_worker", %{
               "worker" => %{"name" => "Rejected rename", "profile_name" => invalid},
               "_submission" => intent(edit)
             }) =~ "Choose a known Server profile from the catalog"

      assert configuration_snapshot() == before_rejections
      assert {:ok, ^worker} = Domain.get_worker(worker["id"])
      assert {:error, %{code: "not_found"}} = Domain.get_worker("profile-rejected")
      assert hd(Domain.list_audit())["result"]["error"]["code"] == "invalid_request"
    end
  end

  test "query and forged event identities cannot retarget profile edits or override CAS", %{
    conn: conn
  } do
    %{worker: worker} = configured_worker("profile-selected")
    create_worker("profile-other", "cloud_dns")
    assert {:ok, other} = Domain.get_worker("profile-other")
    preserved = non_worker_snapshot()

    for query <- [
          "server_id=profile-other",
          "server_id[]=profile-other",
          "server_id[id]=profile-other"
        ] do
      before_read = read_snapshot()
      {:ok, view, _html} = live(conn, "/server/#{worker["id"]}/dashboard?#{query}")
      assert :sys.get_state(view.pid).socket.assigns.worker["id"] == worker["id"]

      assert has_element?(
               view,
               "#server-selection-form-select option[value='#{worker["id"]}'][selected]"
             )

      assert read_snapshot() == before_read
      assert {:ok, current} = Domain.get_worker(worker["id"])

      render_submit(view, "save_worker", %{
        "worker" => %{
          "id" => other["id"],
          "worker_id" => other["id"],
          "expected_revision" => -1,
          "name" => "Route-authoritative name",
          "profile_name" => "dhcp_only",
          "expected_capabilities" => ["dhcpv4"],
          "services" => [],
          "server_agent" => true
        },
        "_submission" => intent(view)
      })

      assert {:ok, updated} = Domain.get_worker(worker["id"])
      assert updated["name"] == "Route-authoritative name"
      assert updated["profile_name"] == "dhcp_only"
      assert updated["revision"] == current["revision"] + 1
      assert updated["expected_capabilities"] == current["expected_capabilities"]
      assert {:ok, ^other} = Domain.get_worker(other["id"])
      assert non_worker_snapshot() == preserved
      request = hd(Domain.list_audit())["request"]
      assert request["id"] == worker["id"]
      assert request["worker_id"] == worker["id"]
      assert request["expected_revision"] == current["revision"]
      refute Map.has_key?(request, "expected_capabilities")
      refute Map.has_key?(request, "services")
      refute Map.has_key?(request, "server_agent")
    end
  end

  test "missing route identity is not replaced by a known query identity", %{conn: conn} do
    create_worker("profile-known", "custom")
    before_read = read_snapshot()

    for query <- [
          "server_id=profile-known",
          "server_id[]=profile-known",
          "server_id[id]=profile-known"
        ] do
      assert {:error, {:live_redirect, %{to: "/server"}}} =
               live(conn, "/server/profile-missing/dashboard?#{query}")

      assert read_snapshot() == before_read
    end
  end

  defp intent(view) do
    [token] =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#worker-edit-form input[name='_submission']")
      |> LazyHTML.attribute("value")

    token
  end

  defp assert_catalog(view, select_id, selected) do
    profiles = ProfileCatalog.list_server_profiles()
    assert length(profiles) == 6
    html = view |> render() |> LazyHTML.from_fragment()

    assert html |> LazyHTML.query("##{select_id} option") |> LazyHTML.attribute("value") ==
             Enum.map(profiles, &to_string(&1.name))

    assert has_element?(
             view,
             "select##{select_id}[name='worker[profile_name]'] option[value='#{selected}'][selected]"
           )

    assert length(Enum.to_list(LazyHTML.query(html, "##{select_id} option[selected]"))) == 1

    for profile <- profiles do
      assert has_element?(
               view,
               "##{select_id} option[value='#{profile.name}']",
               profile.description
             )
    end
  end

  defp text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end

  defp create_worker(id, profile) do
    mutate("create_worker", %{
      "id" => id,
      "name" => id,
      "profile_name" => profile,
      "expected_capabilities" => ["dns"]
    })
  end

  defp configured_worker(id) do
    worker = create_worker(id, "dns_only")
    zone = mutate("create_zone", DomainFixtures.zone("#{id}.test."))

    version =
      mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})

    service = mutate("put_service", DomainFixtures.service(id, worker["revision"], "stopped"))

    mutate("assign", %{
      "worker_id" => id,
      "expected_revision" => service["worker_revision"],
      "service_id" => service["id"],
      "resource_version_id" => version["id"]
    })

    assert {:ok, current} = Domain.get_worker(id)
    mutate("confirm_target", %{"worker_id" => id, "expected_revision" => current["revision"]})
    assert {:ok, target} = Domain.get_target(id)
    assert {:ok, worker} = Domain.get_worker(id)
    %{worker: worker, target: target}
  end

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end

  defp records(schema), do: Repo.all(schema) |> Enum.sort_by(& &1.id)

  defp non_worker_snapshot do
    {
      Enum.map([Service, Assignment, Target, Zone, Rrset, ResourceVersion], &records/1),
      Domain.list_netmans(),
      Domain.list_tasks(),
      Repo.all(Oban.Job, prefix: "management_jobs") |> Enum.sort_by(& &1.id)
    }
  end

  defp configuration_snapshot, do: {records(Worker), non_worker_snapshot()}

  defp read_snapshot do
    {configuration_snapshot(), records(Audit), Repo.all(Idempotency) |> Enum.sort_by(& &1.key)}
  end
end
