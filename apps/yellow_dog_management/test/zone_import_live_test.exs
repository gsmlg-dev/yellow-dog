defmodule YellowDog.Management.ZoneImportLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.ConfigSpec
  alias YellowDog.Management.{ConfigCompiler, Domain, DomainFixtures, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint
  @max_toml_bytes 1_048_576

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "a multiline WorkerPlan creates an audited draft with zero Workers", %{conn: conn} do
    toml = worker_plan(["fixture.test."])
    assert toml =~ "\nworker_id"
    assert Domain.list_workers() == []
    {:ok, plan} = ConfigSpec.decode(toml)
    [resource] = plan["resources"]
    {:ok, view, _html} = live(conn, "/management/zones/import")

    preview(view, toml)
    assert has_element?(view, "#zone-import-toml", "schema_version = 1")
    assert has_element?(view, "#zone-import-preview", "fixture.test.")
    assert has_element?(view, "#zone-import-preview", "SOA")
    assert has_element?(view, "#zone-import-preview", resource["digest"])
    assert Domain.list_zones() == []
    import_resource(view, resource["id"])

    [zone] = Domain.list_zones()
    assert zone["id"] != resource["id"]
    assert zone["revision"] == 1
    assert canonical_content(zone) == resource["content"]
    assert Domain.list_versions(zone["id"]) == []
    assert Domain.list_workers() == []
    assert has_element?(view, "#zone-import-result", "draft revision 1")

    assert has_element?(
             view,
             "#zone-import-result a[href='/management/zones/#{zone["id"]}/edit']"
           )

    [audit] = Domain.list_audit()
    assert audit["operation"] == "create_zone"
    assert audit["actor"] == "operator"
    assert audit["request"] == %{"content" => resource["content"]}
    assert audit["result"]["id"] == zone["id"]
  end

  test "an actual ConfigCompiler export imports unchanged after its draft is unassigned and deleted",
       %{conn: conn} do
    {export, source_zone, source_version, worker} = actual_export()
    [resource] = export["plan"]["resources"]
    assert resource["id"] == source_zone["id"]
    assert Domain.list_zones() == []
    {:ok, before_import} = Domain.get_worker(worker["id"])
    {:ok, view, _html} = live(conn, "/management/zones/import")

    preview(view, export["toml"])
    import_resource(view, resource["id"])

    [imported] = Domain.list_zones()
    assert imported["id"] != source_zone["id"]
    assert imported["revision"] == 1
    assert canonical_content(imported) == resource["content"]
    assert Domain.list_versions(imported["id"]) == []
    assert Domain.list_versions(source_zone["id"]) == [source_version]
    assert {:ok, ^before_import} = Domain.get_worker(worker["id"])
    assert {:ok, ^export} = ConfigCompiler.export_target(worker["id"])
  end

  test "multiple resources can each be selected, previewed and imported independently", %{
    conn: conn
  } do
    toml = worker_plan(["first.test.", "second.test."])
    {:ok, view, _html} = live(conn, "/management/zones/import")
    preview(view, toml)

    assert has_element?(
             view,
             "#zone-import-resource option[value='fixture-zone-0']",
             "first.test."
           )

    assert has_element?(
             view,
             "#zone-import-resource option[value='fixture-zone-1']",
             "second.test."
           )

    view
    |> form("#zone-import-selection-form", import: %{resource_id: "fixture-zone-1"})
    |> render_change()

    assert has_element?(view, "#zone-import-preview", "second.test.")
    refute has_element?(view, "#zone-import-preview", "first.test.")
    import_resource(view, "fixture-zone-1")
    assert Enum.map(Domain.list_zones(), & &1["name"]) == ["second.test."]

    view
    |> form("#zone-import-selection-form", import: %{resource_id: "fixture-zone-0"})
    |> render_change()

    import_resource(view, "fixture-zone-0")
    assert Enum.map(Domain.list_zones(), & &1["name"]) == ["first.test.", "second.test."]
  end

  test "invalid TOML, schema versions and unsupported content invalidate the entire preview", %{
    conn: conn
  } do
    toml = worker_plan(["invalid.test."])
    {:ok, view, _html} = live(conn, "/management/zones/import")

    for invalid <- [
          "schema_version = [",
          String.replace(toml, "schema_version = 1", "schema_version = 2"),
          String.replace(toml, "type = \"A\"", "type = \"AAAA\""),
          toml <> "unsupported = true\n"
        ] do
      preview(view, toml)
      assert has_element?(view, "#zone-import-preview")
      preview(view, invalid)
      assert has_element?(view, "#zone-import-errors")
      refute has_element?(view, "#zone-import-preview")
      refute has_element?(view, "#zone-import-selection-form")
      assert Domain.list_zones() == []
      assert Domain.list_audit() == []
    end
  end

  test "a valid WorkerPlan with no DNS resources explains why there is nothing to import", %{
    conn: conn
  } do
    {:ok, toml} =
      ConfigSpec.encode(%{
        "schema_version" => 1,
        "worker_id" => "empty-plan",
        "revision" => 1,
        "services" => [],
        "resources" => []
      })

    {:ok, view, _html} = live(conn, "/management/zones/import")
    preview(view, toml)
    assert has_element?(view, "#zone-import-errors", "no DNS resources")
    refute has_element?(view, "#zone-import-selection-form")
    assert Domain.list_audit() == []
  end

  test "duplicate names are reported by Domain without overwriting an existing Zone", %{
    conn: conn
  } do
    existing = mutate("create_zone", DomainFixtures.zone("duplicate.test."))
    {:ok, view, _html} = live(conn, "/management/zones/import")
    preview(view, worker_plan(["duplicate.test."]))
    import_resource(view, "fixture-zone-0")

    assert has_element?(view, "#zone-import-errors", "Active Zone name already exists")
    assert {:ok, ^existing} = Domain.get_zone(existing["id"])
    assert Domain.list_zones() == [existing]
    assert Domain.list_versions(existing["id"]) == []
    refute has_element?(view, "#zone-import-result")
  end

  test "unvalidated and malformed selections never mutate or create audit entries", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/management/zones/import")
    render_submit(view, "import_zone", %{"import" => %{"resource_id" => "fixture-zone-0"}})
    assert has_element?(view, "#zone-import-errors", "validated WorkerPlan")
    preview(view, worker_plan(["selection.test."]))

    for invalid_id <- ["missing", "", nil, 0, %{"id" => "fixture-zone-0"}, ["fixture-zone-0"]] do
      render_submit(view, "import_zone", %{"import" => %{"resource_id" => invalid_id}})
      assert has_element?(view, "#zone-import-errors", "validated WorkerPlan")
      assert Domain.list_zones() == []
      assert Domain.list_audit() == []
    end

    render_change(view, "select_resource", %{"import" => %{"resource_id" => "missing"}})
    refute has_element?(view, "#zone-import-preview")
    assert has_element?(view, "#import-zone-draft[disabled]")
  end

  test "client-provided resource content and type cannot replace validated server-side data", %{
    conn: conn
  } do
    toml = worker_plan(["trusted.test."])
    {:ok, plan} = ConfigSpec.decode(toml)
    [resource] = plan["resources"]
    {:ok, view, _html} = live(conn, "/management/zones/import")
    preview(view, toml)

    render_submit(view, "import_zone", %{
      "import" => %{
        "resource_id" => resource["id"],
        "type" => "different_type",
        "content" =>
          DomainFixtures.zone("forged.test.")
          |> Map.update!("records", fn records ->
            records
            |> Enum.with_index()
            |> Map.new(fn {record, index} -> {to_string(index), record} end)
          end),
        "name" => "forged.test.",
        "records" => []
      }
    })

    [zone] = Domain.list_zones()
    assert canonical_content(zone) == resource["content"]
    assert zone["name"] == "trusted.test."
    [audit] = Domain.list_audit()
    assert audit["request"] == %{"content" => resource["content"]}
  end

  test "the 1 MiB limit is inclusive and measured in bytes", %{conn: conn} do
    toml = worker_plan(["bounded.test."])
    exactly_at_limit = toml <> String.duplicate(" ", @max_toml_bytes - byte_size(toml))
    assert byte_size(exactly_at_limit) == @max_toml_bytes
    {:ok, view, _html} = live(conn, "/management/zones/import")
    preview(view, exactly_at_limit)
    assert has_element?(view, "#zone-import-preview", "bounded.test.")

    for oversized <- [exactly_at_limit <> " ", String.duplicate("é", div(@max_toml_bytes, 2) + 1)] do
      preview(view, oversized)
      assert has_element?(view, "#zone-import-errors", "at most 1 MiB")
      refute has_element?(view, "#zone-import-preview")
      refute has_element?(view, "#zone-import-toml", "schema_version")
      assert Domain.list_zones() == []
      assert Domain.list_audit() == []
    end
  end

  test "changing the source invalidates cached selection before another preview", %{conn: conn} do
    toml = worker_plan(["stale-source.test."])
    {:ok, view, _html} = live(conn, "/management/zones/import")
    preview(view, toml)
    assert has_element?(view, "#zone-import-preview")

    view |> form("#zone-import-form", import: %{toml: toml <> "# edited\n"}) |> render_change()
    refute has_element?(view, "#zone-import-preview")
    render_submit(view, "import_zone", %{"import" => %{"resource_id" => "fixture-zone-0"}})
    assert Domain.list_zones() == []
    assert Domain.list_audit() == []
  end

  test "unknown selected Workers block all import mutations even for forged events", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/server/missing-worker/dns/zones/import")
    assert has_element?(view, "#zone-import-scope-error", "Worker not found")
    assert has_element?(view, "#validate-zone-import[disabled]")

    render_submit(view, "preview_import", %{
      "import" => %{"toml" => worker_plan(["blocked.test."])}
    })

    assert has_element?(view, "#import-zone-draft[disabled]")
    render_submit(view, "import_zone", %{"import" => %{"resource_id" => "fixture-zone-0"}})
    assert has_element?(view, "#zone-import-errors", "Worker not found")
    assert Domain.list_zones() == []
    assert Domain.list_workers() == []
    assert Domain.list_audit() == []
  end

  test "a selected logical Worker is navigation context only, not an assignment target", %{
    conn: conn
  } do
    worker = mutate("create_worker", %{"id" => "import-worker", "name" => "Import Worker"})
    {:ok, before_import} = Domain.get_worker(worker["id"])
    {:ok, view, _html} = live(conn, "/server/import-worker/dns/zones/import")
    preview(view, worker_plan(["scoped.test."]))
    import_resource(view, "fixture-zone-0")

    [zone] = Domain.list_zones()

    assert has_element?(
             view,
             "#zone-import-result a[href='/server/import-worker/dns/zones/#{zone["id"]}/edit']"
           )

    assert has_element?(view, "a[href='/server/import-worker/dns/zones']", "Cancel")
    assert {:ok, ^before_import} = Domain.get_worker(worker["id"])
    assert Domain.list_versions(zone["id"]) == []
    assert Domain.list_assignments(worker["id"]) == []
  end

  test "repeated submissions of one validated resource are idempotent", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/management/zones/import")
    preview(view, worker_plan(["idempotent.test."]))
    import_resource(view, "fixture-zone-0")
    [zone] = Domain.list_zones()
    import_resource(view, "fixture-zone-0")
    assert Domain.list_zones() == [zone]
    assert length(Domain.list_audit()) == 1
    assert has_element?(view, "#zone-import-result", "idempotent.test.")
  end

  for {label, query} <- [
        {"known Worker", "server_id=scope-worker"},
        {"missing Worker", "server_id=missing"},
        {"array", "server_id[]=scope-worker"},
        {"map", "server_id[id]=scope-worker"}
      ] do
    @scope_query query
    @tag :scope_regression
    test "global Zone import ignores a #{label} server_id query", %{conn: conn} do
      mutate("create_worker", %{"id" => "scope-worker", "name" => "Scope Worker"})
      before_visit = {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()}
      {:ok, view, _html} = live(conn, "/management/zones/import?" <> @scope_query)
      assert has_element?(view, "a[href='/management/zones']", "Cancel")
      refute has_element?(view, "#zone-import-scope-error")
      refute has_element?(view, "#validate-zone-import[disabled]")
      assert {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()} == before_visit

      preview(view, worker_plan(["query-import.test."]))
      assert {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()} == before_visit
      import_resource(view, "fixture-zone-0")
      [zone] = Domain.list_zones()
      assert zone["name"] == "query-import.test."

      assert has_element?(
               view,
               "#zone-import-result a[href='/management/zones/#{zone["id"]}/edit']"
             )

      assert Domain.list_versions(zone["id"]) == []
      assert Domain.list_assignments("scope-worker") == []
    end
  end

  @tag :scope_regression
  test "scoped Zone import uses only the path Worker when query identities conflict", %{
    conn: conn
  } do
    mutate("create_worker", %{"id" => "Scope.Worker_1", "name" => "Path Worker"})
    mutate("create_worker", %{"id" => "other-worker", "name" => "Other Worker"})
    before_visit = {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()}

    for query <- [
          "server_id=other-worker",
          "server_id[]=other-worker",
          "server_id[id]=other-worker"
        ] do
      {:ok, view, _html} = live(conn, "/server/Scope.Worker_1/dns/zones/import?" <> query)
      assert has_element?(view, "a[href='/server/Scope.Worker_1/dns/zones']", "Cancel")
      refute has_element?(view, "#zone-import-scope-error")
      preview(view, worker_plan(["scoped-preview.test."]))
      assert has_element?(view, "#zone-import-preview", "scoped-preview.test.")
      assert {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()} == before_visit
    end
  end

  @tag :scope_regression
  test "unknown scoped imports stay blocked when queries name a registered Worker", %{conn: conn} do
    mutate("create_worker", %{"id" => "scope-worker", "name" => "Scope Worker"})
    before_visit = {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()}

    for worker_id <- ["missing", "invalid!"],
        query <- [
          "server_id=scope-worker",
          "server_id[]=scope-worker",
          "server_id[id]=scope-worker"
        ] do
      {:ok, view, _html} = live(conn, "/server/#{worker_id}/dns/zones/import?#{query}")
      assert has_element?(view, "#zone-import-scope-error", "Worker not found")
      assert has_element?(view, "#validate-zone-import[disabled]")

      render_submit(view, "preview_import", %{
        "import" => %{"toml" => worker_plan(["blocked.test."])}
      })

      render_submit(view, "import_zone", %{"import" => %{"resource_id" => "fixture-zone-0"}})
      assert has_element?(view, "#zone-import-errors", "Worker not found")
      assert {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()} == before_visit
    end
  end

  defp preview(view, toml),
    do: view |> form("#zone-import-form", import: %{toml: toml}) |> render_submit()

  defp import_resource(view, resource_id),
    do:
      view
      |> form("#zone-import-selection-form", import: %{resource_id: resource_id})
      |> render_submit()

  defp worker_plan(names) do
    resources =
      names
      |> Enum.with_index()
      |> Enum.map(fn {name, index} ->
        %{
          "id" => "fixture-zone-#{index}",
          "type" => "dns_zone",
          "schema_version" => 1,
          "version" => 3,
          "content" => DomainFixtures.zone(name)
        }
      end)

    {:ok, toml} =
      ConfigSpec.encode(%{
        "schema_version" => 1,
        "worker_id" => "fixture-export",
        "revision" => 7,
        "services" => [
          %{
            "id" => "dns",
            "type" => "dns",
            "desired_state" => "stopped",
            "config" => %{"listen_address" => "127.0.0.1", "port" => 5300},
            "resources" => Enum.map(resources, & &1["id"])
          }
        ],
        "resources" => resources
      })

    toml
  end

  defp canonical_content(zone) do
    {:ok, resource} =
      ConfigSpec.normalize_resource(%{
        "id" => zone["id"],
        "type" => "dns_zone",
        "schema_version" => 1,
        "version" => 1,
        "content" => Map.take(zone, ~w(name records))
      })

    resource["content"]
  end

  defp actual_export do
    zone = mutate("create_zone", DomainFixtures.zone("compiler-export.test."))
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    worker = mutate("create_worker", %{"id" => "compiler-worker", "name" => "Compiler Worker"})

    service =
      mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"], "stopped"))

    assignment =
      mutate("assign", %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_version_id" => version["id"],
        "expected_revision" => service["worker_revision"]
      })

    target =
      mutate("confirm_target", %{
        "worker_id" => worker["id"],
        "expected_revision" => assignment["worker_revision"]
      })

    {:ok, export} = ConfigCompiler.export_target(worker["id"], target["revision"])

    mutate("unassign", %{
      "worker_id" => worker["id"],
      "service_id" => service["id"],
      "resource_id" => zone["id"],
      "expected_revision" => target["worker_revision"]
    })

    mutate("delete_zone", %{"id" => zone["id"], "expected_revision" => 1})
    {export, zone, version, worker}
  end

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
