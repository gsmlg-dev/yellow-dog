defmodule YellowDog.Management.ZoneValidationLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.ConfigSpec

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

  test "a new incomplete Zone cannot be saved and opening it is read-only", %{conn: conn} do
    before_read = snapshot()
    {:ok, view, _html} = live(conn, "/management/zones/new")
    assert has_element?(view, "#zone-form[phx-change='validate']")
    assert has_element?(view, "#zone-save[disabled]")
    assert snapshot() == before_read
  end

  test "a valid stored Zone opens with Save enabled without writing", %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    before_read = snapshot()
    {:ok, view, _html} = live(conn, edit_path(zone))
    assert has_element?(view, "#zone-save")
    refute has_element?(view, "#zone-save[disabled]")
    refute has_element?(view, "#zone-validation-errors")
    assert snapshot() == before_read
  end

  test "invalid candidates show actual ConfigSpec paths/messages without writing", %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    before_read = snapshot()

    for failure <- ~w(apex address ttl soa outside_owner duplicate_soa)a do
      candidate = invalid_candidate(zone, failure)
      {:error, errors} = normalize(candidate)
      {:ok, view, _html} = live(conn, edit_path(zone))

      if failure == :duplicate_soa do
        view |> element("button[phx-click='add_record']") |> render_click()

        view
        |> form("#zone-form", zone: %{"records" => %{"3" => %{"type" => "SOA"}}})
        |> render_change()
      end

      change(view, candidate)
      assert_errors(view, errors)
      assert has_element?(view, "#zone-save[disabled]")
      assert has_element?(view, "#zone-name[value='#{candidate["name"]}']")
      assert {:ok, ^zone} = Domain.get_zone(zone["id"])
      assert snapshot() == before_read
    end
  end

  test "correcting input clears errors and creates exactly the canonical candidate", %{conn: conn} do
    candidate =
      DomainFixtures.zone("EXAMPLE.TEST")
      |> update_in(["records"], fn records ->
        Enum.map(records, fn record ->
          record = Map.put(record, "ttl", 600)

          if record["type"] == "A",
            do: put_in(record, ["data", "address"], "192.0.2.20"),
            else: record
        end)
      end)

    {:ok, expected} = normalize(candidate)
    before_read = snapshot()
    {:ok, view, _html} = live(conn, "/management/zones/new")
    view |> element("button[phx-click='add_record']") |> render_click()
    change(view, invalid_candidate(candidate, :address))
    assert has_element?(view, "#zone-save[disabled]")
    change(view, candidate)
    refute has_element?(view, "#zone-validation-errors")
    refute has_element?(view, "#zone-save[disabled]")
    assert snapshot() == before_read
    view |> form("#zone-form", zone: fields(candidate)) |> render_submit()
    [saved] = Domain.list_zones()
    assert_patch(view, edit_path(saved))
    assert saved["revision"] == 1
    assert saved["name"] == expected["content"]["name"]
    assert {:ok, canonical_saved} = normalize(saved)
    assert canonical_saved["content"] == expected["content"]
    assert canonical_saved["digest"] == expected["digest"]
    assert Domain.list_versions(saved["id"]) == []
    assert length(Repo.all(Audit)) == 1
    assert length(Repo.all(Idempotency)) == 1
  end

  test "adding and removing rows revalidate without losing unsaved name or record fields", %{
    conn: conn
  } do
    zone = mutate("create_zone", DomainFixtures.zone())

    candidate =
      zone
      |> Map.put("name", "EXAMPLE.TEST")
      |> update_in(["records"], fn records ->
        Enum.map(records, fn record ->
          if record["type"] == "A",
            do: put_in(record, ["data", "address"], "192.0.2.77"),
            else: record
        end)
      end)

    before_read = snapshot()
    {:ok, view, _html} = live(conn, edit_path(zone))
    change(view, candidate)
    view |> element("button[phx-click='add_record']") |> render_click()
    assert has_element?(view, "#zone-save[disabled]")
    assert has_element?(view, "#zone-validation-errors[role='alert']")
    assert has_element?(view, "#zone-name[value='EXAMPLE.TEST']")
    assert has_element?(view, "input[value='192.0.2.77']")
    assert has_element?(view, "#zone-record-3")
    view |> element("button[phx-click='remove_record'][phx-value-index='3']") |> render_click()
    refute has_element?(view, "#zone-save[disabled]")
    refute has_element?(view, "#zone-validation-errors")
    assert has_element?(view, "#zone-name[value='EXAMPLE.TEST']")
    assert has_element?(view, "input[value='192.0.2.77']")

    soa_index = Enum.find_index(candidate["records"], &(&1["type"] == "SOA"))

    view
    |> element("button[phx-click='remove_record'][phx-value-index='#{soa_index}']")
    |> render_click()

    missing_soa =
      Map.update!(
        candidate,
        "records",
        &Enum.reject(&1, fn record -> record["type"] == "SOA" end)
      )

    {:error, errors} = normalize(missing_soa)
    assert_errors(view, errors)
    assert has_element?(view, "#zone-save[disabled]")
    assert has_element?(view, "input[value='192.0.2.77']")
    assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    assert snapshot() == before_read
  end

  test "cancelling changed invalid input never writes or carries errors into New Zone", %{
    conn: conn
  } do
    zone = mutate("create_zone", DomainFixtures.zone())
    before_read = snapshot()
    {:ok, view, _html} = live(conn, edit_path(zone))
    change(view, invalid_candidate(zone, :address))
    assert has_element?(view, "#zone-validation-errors[role='alert']")
    view |> element("a", "Cancel") |> render_click()
    assert_patch(view, "/management/zones")
    refute has_element?(view, "#zone-validation-errors")
    view |> element("a", "New Zone") |> render_click()
    assert_patch(view, "/management/zones/new")
    assert has_element?(view, "#zone-name[value='']")
    assert has_element?(view, "#zone-save[disabled]")
    assert snapshot() == before_read
  end

  test "crafted invalid submissions cannot bypass Domain validation on create or edit", %{
    conn: conn
  } do
    zone = mutate("create_zone", DomainFixtures.zone())

    for {path, operation} <- [
          {"/management/zones/new", "create_zone"},
          {edit_path(zone), "update_zone"}
        ] do
      before_submit = snapshot()
      candidate = invalid_candidate(zone, :address)
      {:ok, view, _html} = live(conn, path)
      render_submit(view, "save", %{"zone" => fields(candidate), "_submission" => intent(view)})
      after_submit = snapshot()

      assert Map.drop(after_submit, [:audit, :idempotency]) ==
               Map.drop(before_submit, [:audit, :idempotency])

      assert [audit] = after_submit.audit -- before_submit.audit
      assert audit.operation == operation
      assert audit.result["error"]["code"] == "invalid_config"
      assert [receipt] = after_submit.idempotency -- before_submit.idempotency
      assert receipt.result["error"]["code"] == "invalid_config"
      assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    end
  end

  test "validation and history refresh never rebase an editor's original CAS or prepared export",
       %{
         conn: conn
       } do
    %{zone: zone, worker: worker, target: target, export: export, version: version} =
      prepared_fixture()

    candidate = change_address(zone, "192.0.2.77")
    before_change = snapshot()
    {:ok, view, _html} = live(conn, edit_path(zone))
    change(view, candidate)
    refute has_element?(view, "#zone-save[disabled]")
    assert snapshot() == before_change

    concurrent =
      mutate("update_zone", %{
        "id" => zone["id"],
        "expected_revision" => zone["revision"],
        "name" => zone["name"],
        "records" => change_address(zone, "192.0.2.88")["records"]
      })

    second_version =
      mutate("confirm_zone", %{
        "id" => zone["id"],
        "expected_revision" => concurrent["revision"]
      })

    before_refresh = snapshot()
    view |> element("#zone-refresh") |> render_click()
    assert has_element?(view, "input[value='192.0.2.77']")
    assert has_element?(view, "#zone-versions", second_version["digest"])
    assert render(view) =~ "Draft revision #{zone["revision"]}"
    assert snapshot() == before_refresh
    change(view, candidate)
    assert snapshot() == before_refresh

    assert render_submit(view, "save", %{
             "zone" => fields(candidate),
             "_submission" => intent(view)
           }) =~
             "revision"

    assert {:ok, ^concurrent} = Domain.get_zone(zone["id"])
    assert Domain.list_versions(zone["id"]) == [version, second_version]
    assert {:ok, ^worker} = Domain.get_worker(worker["id"])
    assert {:ok, ^target} = Domain.get_target(worker["id"])
    assert {:ok, ^export} = ConfigCompiler.export_target(worker["id"])
    after_submit = snapshot()

    assert Map.drop(after_submit, [:audit, :idempotency]) ==
             Map.drop(before_refresh, [:audit, :idempotency])

    assert [audit] = after_submit.audit -- before_refresh.audit
    assert audit.request["expected_revision"] == zone["revision"]
    assert audit.result["error"]["code"] == "revision_conflict"
  end

  test "a validated draft edit preserves assigned immutable history and exact prepared export", %{
    conn: conn
  } do
    %{zone: zone, worker: worker, target: target, export: export, version: version} =
      prepared_fixture()

    candidate = change_address(zone, "192.0.2.77")
    {:ok, expected} = normalize(candidate)
    before_read = snapshot()
    {:ok, view, _html} = live(conn, edit_path(zone))
    change(view, candidate)
    assert snapshot() == before_read
    refute has_element?(view, "#zone-validation-errors")
    refute has_element?(view, "#zone-save[disabled]")
    view |> form("#zone-form", zone: fields(candidate)) |> render_submit()
    assert_patch(view, edit_path(zone))
    assert {:ok, saved} = Domain.get_zone(zone["id"])
    assert saved["revision"] == zone["revision"] + 1
    assert {:ok, canonical_saved} = normalize(saved)
    assert canonical_saved["content"] == expected["content"]
    assert Domain.list_versions(zone["id"]) == [version]
    assert {:ok, ^worker} = Domain.get_worker(worker["id"])
    assert {:ok, ^target} = Domain.get_target(worker["id"])
    assert {:ok, ^export} = ConfigCompiler.export_target(worker["id"])

    for schema <- [Worker, Service, Assignment, ResourceVersion, Target] do
      assert snapshot()[schema] == before_read[schema]
    end
  end

  defp intent(view) do
    [token] =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#zone-form input[name='_submission']")
      |> LazyHTML.attribute("value")

    token
  end

  defp change(view, candidate),
    do: view |> form("#zone-form", zone: fields(candidate)) |> render_change()

  defp fields(candidate) do
    %{
      "name" => candidate["name"],
      "records" =>
        candidate["records"]
        |> Enum.with_index()
        |> Map.new(fn {record, index} -> {to_string(index), record} end)
    }
  end

  defp normalize(candidate) do
    ConfigSpec.normalize_resource(%{
      "schema_version" => 1,
      "id" => candidate["id"] || Ecto.UUID.generate(),
      "type" => "dns_zone",
      "version" => 1,
      "content" => Map.take(candidate, ~w(name records))
    })
  end

  defp assert_errors(view, errors) do
    assert has_element?(view, "#zone-validation-errors[role='alert']")

    text =
      view
      |> element("#zone-validation-errors")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text(separator: " ")

    for error <- errors do
      assert text =~ error.message
      path = Enum.map_join(error.path, "[^[:alnum:]_]+", &Regex.escape(to_string(&1)))
      assert text =~ Regex.compile!(path)
    end
  end

  defp invalid_candidate(candidate, :apex), do: Map.put(candidate, "name", "bad..test.")
  defp invalid_candidate(candidate, :address), do: change_address(candidate, "999.0.2.10")

  defp invalid_candidate(candidate, :ttl),
    do: change_record(candidate, "A", &Map.put(&1, "ttl", -1))

  defp invalid_candidate(candidate, :soa),
    do: change_record(candidate, "SOA", &put_in(&1, ["data", "serial"], -1))

  defp invalid_candidate(candidate, :outside_owner),
    do: change_record(candidate, "A", &Map.put(&1, "name", "outside.test."))

  defp invalid_candidate(candidate, :duplicate_soa) do
    duplicate =
      candidate["records"]
      |> Enum.find(&(&1["type"] == "SOA"))
      |> put_in(["data", "serial"], 2)

    Map.update!(candidate, "records", &(&1 ++ [duplicate]))
  end

  defp change_address(candidate, address),
    do: change_record(candidate, "A", &put_in(&1, ["data", "address"], address))

  defp change_record(candidate, type, update) do
    Map.update!(candidate, "records", fn records ->
      Enum.map(records, fn record ->
        if record["type"] == type, do: update.(record), else: record
      end)
    end)
  end

  defp prepared_fixture do
    zone = mutate("create_zone", DomainFixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    worker = mutate("create_worker", %{"id" => "zone-validation", "name" => "Zone Validation"})

    service =
      mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"], "stopped"))

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

    assert {:ok, worker} = Domain.get_worker(worker["id"])
    assert {:ok, target} = Domain.get_target(worker["id"])
    assert {:ok, export} = ConfigCompiler.export_target(worker["id"])
    %{zone: zone, worker: worker, target: target, export: export, version: version}
  end

  defp edit_path(zone), do: "/management/zones/#{zone["id"]}/edit"

  defp snapshot do
    business =
      Map.new([Worker, Service, Assignment, Zone, Rrset, ResourceVersion, Target], fn schema ->
        {schema, schema |> Repo.all() |> Enum.sort_by(& &1.id)}
      end)

    Map.merge(business, %{
      audit: Repo.all(Audit) |> Enum.sort_by(& &1.id),
      idempotency: Repo.all(Idempotency) |> Enum.sort_by(& &1.key)
    })
  end

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
