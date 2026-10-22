defmodule YellowDog.Management.ZoneCatalogRouteTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias YellowDog.Management.{Domain, DomainFixtures, Repo, ZoneAssignmentChoices}
  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "catalog mount and scoped route use identity metadata independent of unrelated fleet size",
       %{conn: conn} do
    for n <- 1..23 do
      mutate(
        "create_zone",
        DomainFixtures.zone("catalog#{String.pad_leading(to_string(n), 2, "0")}.test.")
      )
    end

    content = DomainFixtures.zone("large-version.test.")

    records =
      for n <- 1..1000,
          do: %{
            "name" => "host#{n}.large-version.test.",
            "type" => "A",
            "ttl" => 300,
            "data" => %{"address" => "192.0.2.10"}
          }

    zone = mutate("create_zone", Map.update!(content, "records", &(&1 ++ records)))
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    assert byte_size(Jason.encode!(version["content"])) > 90_000
    initial = service("fleet-initial")
    assign_version(initial, version)

    routes = ["/management/zones", "/server/fleet-initial/dns/zones"]

    before =
      Map.new(routes, fn route ->
        {view, queries} = catalog_mount(conn, route)
        assert has_element?(view, "#zone-count[data-displayed='20'][data-total='24']")
        assert_lightweight(queries)
        {route, queries}
      end)

    for n <- 1..12, do: assign_version(service("unrelated-#{n}"), version)

    for route <- routes do
      {view, queries} = catalog_mount(build_conn(), route)
      assert has_element?(view, "#zone-count[data-displayed='20'][data-total='24']")
      refute has_element?(view, "#zone-assignment-candidates")
      assert_lightweight(queries)
      assert length(queries) == length(before[route])
    end

    catalog = Domain.list_zone_catalog()
    assert length(catalog["zones"]) == 20
    assert Enum.all?(catalog["zones"], &(&1["record_count"] == 3))

    refute Enum.any?(
             catalog["zones"],
             &(Map.has_key?(&1, "content") or Map.has_key?(&1, "records"))
           )
  end

  test "candidate pages and search never hide or replace canonical and proposed selections", %{
    conn: conn
  } do
    zone = mutate("create_zone", DomainFixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    selected = service("zz-selected")
    assign_version(selected, version)
    candidates = for n <- 1..25, do: service("choice-#{String.pad_leading(to_string(n), 2, "0")}")
    first = hd(candidates)
    {:ok, view, _} = live(conn, "/management/zones/#{zone["id"]}/edit")
    refute has_element?(view, "#zone-assignment-candidates")
    view |> element("a", "Application scope") |> render_click()
    assert has_element?(view, "#zone-assignment-candidate-count[data-displayed='20']")
    refute has_element?(view, "#zone-assignment-candidates button[phx-value-id='zz-selected']")
    assert_selected(view, selected)

    view
    |> element("button[phx-click='add_assignment_worker'][phx-value-id='#{first["worker_id"]}']")
    |> render_click()

    assert_selected(view, first)
    search(view, "choice-25")
    assert has_element?(view, "#zone-assignment-candidate-count[data-displayed='1']")
    assert_selected(view, selected)
    assert_selected(view, first)
    view |> form("#zone-assignments-form") |> render_submit()
    assert {:ok, snapshot} = Domain.get_zone_assignments(zone["id"])

    assert Enum.sort(Enum.map(snapshot["assignments"], & &1["service_id"])) ==
             Enum.sort([selected["id"], first["id"]])

    search(view, "")
    initial_ids = candidate_ids(view)

    view
    |> element("button[phx-click='assignment_candidates_page']", "Next choices")
    |> render_click()

    assert has_element?(view, "#zone-assignment-candidate-count[data-displayed='6']")
    refute Enum.any?(candidate_ids(view), &(&1 in initial_ids))
    assert_selected(view, selected)
    assert_selected(view, first)

    view
    |> element("button[phx-click='assignment_candidates_page']", "Previous choices")
    |> render_click()

    assert candidate_ids(view) == initial_ids
    search(view, "%")
    assert has_element?(view, "#zone-assignment-candidate-count[data-displayed='0']")
    assert_selected(view, selected)
    assert_selected(view, first)
  end

  test "service choices are bounded with stable paging even for one Worker", %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    initial = service("many-services")

    services =
      for n <- 2..25 do
        mutate(
          "put_service",
          DomainFixtures.service(initial["worker_id"], n, "stopped")
          |> Map.put("id", "dns-#{String.pad_leading(to_string(n), 2, "0")}")
        )
      end

    {:ok, view, _} = live(conn, "/management/zones/#{zone["id"]}/application")
    assert has_element?(view, "#zone-assignment-candidate-count[data-displayed='20']")
    view |> element("button[phx-click='add_assignment_worker']") |> render_click()

    assert has_element?(
             view,
             "fieldset[data-worker-id='many-services'] option[value=''][selected]"
           )

    assert length(
             LazyHTML.from_document(render(view))
             |> LazyHTML.query(
               "fieldset[data-worker-id='many-services'] select[name$='[service_id]'] option"
             )
             |> LazyHTML.attribute("value")
           ) == 21

    last = List.last(services)
    search(view, last["instance_id"])
    assert has_element?(view, "option[value='#{last["id"]}']")

    assert has_element?(
             view,
             "fieldset[data-worker-id='many-services'] option[value=''][selected]"
           )

    [row_key] =
      LazyHTML.from_document(render(view))
      |> LazyHTML.query("fieldset[data-worker-id='many-services']")
      |> LazyHTML.attribute("id")

    key = String.replace_prefix(row_key, "zone-assignment-", "")

    view
    |> form("#zone-assignments-form", assignments: %{key => %{"service_id" => last["id"]}})
    |> render_change()

    search(view, "no-match")
    assert_selected(view, last)
    view |> form("#zone-assignments-form") |> render_submit()
    assert [%{"service_id" => id}] = Domain.list_assignments(initial["worker_id"])
    assert id == last["id"]
  end

  test "zero Worker Application scope remains editable without fabricating choices", %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    {:ok, view, _} = live(conn, "/management/zones/#{zone["id"]}/application")
    assert render(view) =~ "No logical Workers are registered"
    assert has_element?(view, "#zone-assignment-candidate-count[data-displayed='0']")
    refute has_element?(view, "#zone-save-assignments[disabled]")
    view |> form("#zone-assignments-form") |> render_submit()
    assert {:ok, %{"assignments" => []}} = Domain.get_zone_assignments(zone["id"])
    assert ZoneAssignmentChoices.candidates(%{"page" => "-1"})["page"] == 1
  end

  defp catalog_mount(conn, route) do
    owner = self()
    handler = "catalog-route-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:yellow_dog, :management, :repo, :query],
      fn _, _, metadata, _ -> send(owner, {:catalog_sql, metadata.query}) end,
      nil
    )

    try do
      {:ok, view, _} = live(conn, route)
      render(view)
      {view, drain_sql([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp assert_lightweight(queries) do
    assert Enum.any?(queries, &String.contains?(&1, "LIMIT"))
    refute Enum.any?(queries, &String.contains?(&1, "\"content\""))
    refute Enum.any?(queries, &String.contains?(&1, "\"config\""))
    refute Enum.any?(queries, &String.contains?(&1, "FOR SHARE"))
    refute Enum.any?(queries, &String.contains?(&1, "\"connection_token_hash\""))

    for query <- queries, String.contains?(query, "FROM \"management_services\"") do
      flunk("Catalog must not load assignment service candidates: #{query}")
    end

    for query <- queries, String.contains?(query, "FROM \"management_resource_versions\"") do
      assert String.contains?(query, "max(")
    end

    for query <- queries, String.contains?(query, "FROM \"management_rrsets\"") do
      assert String.contains?(query, "sum(cardinality(")
    end

    for query <- queries, String.contains?(query, "FROM \"management_workers\"") do
      assert Regex.match?(~r/SELECT \w+\."id", \w+\."name" FROM "management_workers"/, query)
    end
  end

  defp drain_sql(queries) do
    receive do
      {:catalog_sql, query} -> drain_sql([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp candidate_ids(view) do
    LazyHTML.from_document(render(view))
    |> LazyHTML.query("#zone-assignment-candidates button")
    |> LazyHTML.attribute("phx-value-id")
  end

  defp search(view, value),
    do:
      view
      |> form("#zone-assignment-candidates-filter", candidates: %{search: value})
      |> render_change()

  defp assert_selected(view, service) do
    assert has_element?(
             view,
             "fieldset[data-worker-id='#{service["worker_id"]}'] option[value='#{service["id"]}'][selected]"
           )
  end

  defp service(id) do
    mutate("create_worker", %{"id" => id, "name" => id})
    mutate("put_service", DomainFixtures.service(id, 1, "stopped"))
  end

  defp assign_version(service, version) do
    mutate("assign", %{
      "worker_id" => service["worker_id"],
      "service_id" => service["id"],
      "resource_version_id" => version["id"],
      "expected_revision" => service["worker_revision"]
    })
  end

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
