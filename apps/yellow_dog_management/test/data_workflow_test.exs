defmodule YellowDog.Management.DataWorkflowTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Test, only: [conn: 2]
  alias YellowDog.Management.{Domain, DomainFixtures, Repo, Web}
  @endpoint YellowDog.ManagementUI.Endpoint

  defmodule UnavailableRepo do
    use Ecto.Repo, otp_app: :yellow_dog_management, adapter: Ecto.Adapters.Postgres
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "catalog uses bounded SQL and metadata summaries without changing the complete read" do
    for n <- 1..23,
        do:
          mutate(
            "create_zone",
            DomainFixtures.zone("zone#{String.pad_leading(to_string(n), 2, "0")}.test.")
          )

    owner = self()
    id = "zone-catalog-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      id,
      [:yellow_dog, :management, :repo, :query],
      fn _, _, metadata, _ -> send(owner, {:sql, metadata.query}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    first = Domain.list_zone_catalog()
    assert length(first["zones"]) == 20
    assert first["total"] == 23
    assert first["has_next"]
    assert Enum.all?(first["zones"], &(not Map.has_key?(&1, "records")))
    assert Enum.all?(first["zones"], &(&1["record_count"] == 3))
    assert_receive {:sql, _}
    queries = drain_sql([])
    assert Enum.any?(queries, &(String.contains?(&1, "LIMIT") and String.contains?(&1, "OFFSET")))
    second = Domain.list_zone_catalog(%{"page" => "2"})
    assert length(second["zones"]) == 3
    refute second["has_next"]
    refute Enum.any?(second["zones"], &(&1 in first["zones"]))
    assert length(Domain.list_zones()) == 23
    assert Domain.list_zone_catalog(%{"search" => "ZONE23"})["matching_total"] == 1
    assert Domain.list_zone_catalog(%{"search" => "%"})["matching_total"] == 0
    response = conn(:get, "/api/zone-catalog?page=2") |> Web.call(Web.init([]))
    assert Jason.decode!(response.resp_body)["data"] == second
  end

  test "zero Worker saved-draft confirmation rejects unsaved input and preserves frozen versions",
       %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    {:ok, view, _} = live(conn, "/management/zones/#{zone["id"]}/edit")
    changed = Map.put(zone, "name", "unsaved.test.")
    view |> form("#zone-form", zone: fields(changed)) |> render_change()
    click(view, "confirm_zone", %{"id" => zone["id"]})
    assert Domain.list_versions(zone["id"]) == []
    assert render(view) =~ "Save or explicitly discard"
    assert has_element?(view, "#zone-name[value='unsaved.test.']")
    view |> element("button[phx-click='discard_content']") |> render_click()
    click(view, "confirm_zone", %{"id" => zone["id"]})
    assert [version] = Domain.list_versions(zone["id"])
    assert version["content"]["name"] == "example.test."
    assert Domain.list_workers() == []

    assert {:ok, _} =
             Domain.mutate(
               "update_zone",
               Map.merge(DomainFixtures.zone(), %{"id" => zone["id"], "expected_revision" => 1}),
               "operator",
               Ecto.UUID.generate()
             )

    assert Domain.list_versions(zone["id"]) == [version]
  end

  test "detail tab identity is route-owned and content save preserves proposed complete assignments",
       %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    worker = mutate("create_worker", %{"id" => "data-worker", "name" => "Data Worker"})
    service = mutate("put_service", DomainFixtures.service(worker["id"], 1, "stopped"))
    {:ok, view, _} = live(conn, "/management/zones/#{zone["id"]}/application?zone_id=wrong")
    view |> element("button[phx-click='add_assignment_worker']") |> render_click()
    assert has_element?(view, "#zone-assignments-form[data-editor-dirty='true']")
    assert has_element?(view, "option[value='#{service["id"]}'][selected]")
    view |> element("a", "Content") |> render_click()
    view |> form("#zone-form", zone: fields(zone)) |> render_submit()
    assert has_element?(view, "#zone-assignments-form[data-editor-dirty='true']")
    assert has_element?(view, "option[value='#{version["id"]}'][selected]")

    view
    |> form("#zone-form", zone: fields(Map.put(zone, "name", "pending.test.")))
    |> render_change()

    view |> element("a", "Application scope") |> render_click()
    view |> form("#zone-assignments-form") |> render_submit()
    assert has_element?(view, "#zone-name[value='pending.test.']")
    assert has_element?(view, "#zone-form[data-editor-dirty='true']")
    assert {:ok, snapshot} = Domain.get_zone_assignments(zone["id"])
    assert [%{"service_id" => service_id}] = snapshot["assignments"]
    assert service_id == service["id"]
    assert has_element?(view, "a[href='/server/data-worker/targets']")
  end

  test "pinned references use the frozen name after a global draft rename" do
    zone = mutate("create_zone", DomainFixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    worker = mutate("create_worker", %{"id" => "pinned-name", "name" => "Pinned"})
    service = mutate("put_service", DomainFixtures.service(worker["id"], 1, "stopped"))

    mutate("assign", %{
      "worker_id" => worker["id"],
      "service_id" => service["id"],
      "resource_version_id" => version["id"],
      "expected_revision" => service["worker_revision"]
    })

    mutate(
      "update_zone",
      Map.merge(DomainFixtures.zone("renamed.test."), %{
        "id" => zone["id"],
        "expected_revision" => 1
      })
    )

    assert {:ok, references} = Domain.list_service_references(worker["id"], service["id"])
    assert [%{"name" => "example.test.", "resource_version_id" => id}] = references["zones"]
    assert id == version["id"]
    assert {:ok, %{"name" => "renamed.test."}} = Domain.get_zone(zone["id"])
  end

  test "queued saves retain independent content and assignment submission identities", %{
    conn: conn
  } do
    zone = mutate("create_zone", DomainFixtures.zone())
    mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    worker = mutate("create_worker", %{"id" => "queued-data", "name" => "Queued"})
    service = mutate("put_service", DomainFixtures.service(worker["id"], 1, "stopped"))
    {:ok, view, _} = live(conn, "/management/zones/#{zone["id"]}/application")
    view |> element("button[phx-click='add_assignment_worker']") |> render_click()
    assignment_request = form_params(view, "zone-assignments-form")
    content_request = %{"zone" => fields(zone), "_submission" => form_token(view, "zone-form")}

    render_submit(view, "save", content_request)
    render_submit(view, "save_assignments", assignment_request)
    assert [%{"service_id" => service_id}] = Domain.list_assignments(worker["id"])
    assert service_id == service["id"]

    changed = fields(DomainFixtures.zone("queued-edit.test."))
    render_change(view, "validate", %{"zone" => changed})
    content_request = %{"zone" => changed, "_submission" => form_token(view, "zone-form")}
    assignment_request = form_params(view, "zone-assignments-form")
    render_submit(view, "save_assignments", assignment_request)
    render_submit(view, "save", content_request)
    assert {:ok, %{"name" => "queued-edit.test.", "revision" => 3}} = Domain.get_zone(zone["id"])
    receipts = Repo.all(YellowDog.Management.Idempotency)
    render_submit(view, "save_assignments", assignment_request)
    render_submit(view, "save", content_request)
    assert Repo.all(YellowDog.Management.Idempotency) == receipts
  end

  test "catalog URL parameters own history and filtering preserves the detail editor", %{
    conn: conn
  } do
    for n <- 1..21, do: mutate("create_zone", DomainFixtures.zone("history#{n}.test."))
    {:ok, view, _} = live(conn, "/management/zones?page=2&sort=revision")
    assert has_element?(view, "#zone-count[data-displayed='1']")
    render_patch(view, "/management/zones")
    assert has_element?(view, "#zone-count[data-displayed='20']")
    assert has_element?(view, "#zone-filter[value='']")

    zone = List.first(Domain.list_zones())
    render_patch(view, "/management/zones/#{zone["id"]}/edit")
    changed = fields(Map.put(zone, "name", "retained-history.test."))
    render_change(view, "validate", %{"zone" => changed})
    view |> form("#zones-filter-form", filter: %{name: "history1"}) |> render_change()
    expected = "/management/zones/#{zone["id"]}/edit?page=1&search=history1"
    assert_patch(view, expected)
    assert has_element?(view, "#zone-name[value='retained-history.test.']")
    assert has_element?(view, "#zone-form[data-editor-dirty='true']")
    {:ok, fresh, _} = live(build_conn(), expected)
    assert has_element?(fresh, "#zone-filter[value='history1']")
    assert has_element?(fresh, "#zone-count[data-displayed='11']")
    render_patch(view, "/management/zones/#{zone["id"]}/edit")
    assert has_element?(view, "#zone-filter[value='']")
    assert has_element?(view, "#zone-name[value='retained-history.test.']")
  end

  test "content save cannot rebase or replace a pending assignment retry", %{conn: conn} do
    zone = mutate("create_zone", DomainFixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    worker = mutate("create_worker", %{"id" => "retry-data", "name" => "Retry"})
    service = mutate("put_service", DomainFixtures.service(worker["id"], 1, "stopped"))

    assigned =
      mutate("assign", %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_version_id" => version["id"],
        "expected_revision" => service["worker_revision"]
      })

    {:ok, view, _} = live(conn, "/management/zones/#{zone["id"]}/application")
    request = form_params(view, "zone-assignments-form")

    mutate("update_worker", %{
      "id" => worker["id"],
      "name" => "Changed concurrently",
      "expected_revision" => assigned["worker_revision"]
    })

    render_submit(view, "save_assignments", request)
    assert has_element?(view, "#zone-assignment-error", "revision")

    render_submit(view, "save", %{
      "zone" => fields(zone),
      "_submission" => form_token(view, "zone-form")
    })

    receipts = Repo.all(YellowDog.Management.Idempotency)
    audits = Repo.all(YellowDog.Management.Audit)
    render_submit(view, "save_assignments", request)
    assert has_element?(view, "#zone-assignment-error", "revision")
    assert Repo.all(YellowDog.Management.Idempotency) == receipts
    assert Repo.all(YellowDog.Management.Audit) == audits
    assert [%{"resource_version_id" => version_id}] = Domain.list_assignments(worker["id"])
    assert version_id == version["id"]
  end

  test "a saved draft unavailable on canonical reread retains its request for retry", %{
    conn: conn
  } do
    Repo.query!("""
    CREATE FUNCTION pg_temp.hide_saved_zone() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.operation = 'create_zone' THEN
        UPDATE management_zones SET deleted_at = now()
          WHERE id = (NEW.result->>'id')::uuid;
      END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER fixture_hide_saved_zone AFTER INSERT ON management_audits FOR EACH ROW EXECUTE FUNCTION pg_temp.hide_saved_zone()"
    )

    {:ok, view, _} = live(conn, "/management/zones/new")
    render_click(view, "add_record")

    request = %{
      "zone" => fields(DomainFixtures.zone("reread.test.")),
      "_submission" => form_token(view, "zone-form")
    }

    render_submit(view, "save", request)
    assert render(view) =~ "saved, but its canonical draft could not be read"
    assert has_element?(view, "#zone-name[value='reread.test.']")
    assert form_token(view, "zone-form") == request["_submission"]
    assert [receipt] = Repo.all(YellowDog.Management.Idempotency)
    assert [audit] = Repo.all(YellowDog.Management.Audit)
    assert audit.operation == "create_zone"
    saved_id = audit.result["id"]
    Repo.query!("DROP TRIGGER fixture_hide_saved_zone ON management_audits")

    Repo.query!("UPDATE management_zones SET deleted_at = NULL WHERE id = $1", [
      Ecto.UUID.dump!(saved_id)
    ])

    render_submit(view, "save", request)
    assert_patch(view, "/management/zones/#{saved_id}/edit")
    assert Repo.all(YellowDog.Management.Idempotency) == [receipt]
    assert Repo.all(YellowDog.Management.Audit) == [audit]
    assert {:ok, %{"id" => ^saved_id, "revision" => 1}} = Domain.get_zone(saved_id)
  end

  test "assignment commit uses its canonical result when subsequent database reads are unavailable" do
    zone = mutate("create_zone", DomainFixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    worker = mutate("create_worker", %{"id" => "commit-data", "name" => "Commit"})
    service = mutate("put_service", DomainFixtures.service(worker["id"], 1, "stopped"))
    {:ok, snapshot} = Domain.get_zone_assignments(zone["id"])

    {:ok, socket} =
      YellowDog.ManagementUI.ZonesLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}},
        private: %{live_temp: %{}}
      })

    row = %{
      "key" => Ecto.UUID.generate(),
      "worker_id" => worker["id"],
      "service_id" => service["id"],
      "resource_version_id" => version["id"]
    }

    socket =
      Phoenix.Component.assign(socket,
        zone: zone,
        versions: [version],
        assignment_zone_id: zone["id"],
        assignment_rows: [row],
        assignment_token: snapshot["assignment_token"],
        assignment_worker_revisions: snapshot["worker_revisions"],
        assignments_dirty: true,
        content_dirty: true,
        form: Phoenix.Component.to_form(%{"name" => "unsaved-content.test."}, as: "zone")
      )

    unavailable =
      start_supervised!(
        {UnavailableRepo,
         [
           name: nil,
           pool: DBConnection.ConnectionPool,
           pool_size: 1,
           hostname: "127.0.0.1",
           port: 0,
           username: "postgres",
           database: "unavailable",
           connect_timeout: 10,
           timeout: 50,
           queue_target: 1,
           queue_interval: 1
         ]}
      )

    owner = self()
    hook = "assignment-postcommit-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      hook,
      [:yellow_dog, :management, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == owner and
             String.starts_with?(metadata.query, "UPDATE \"management_idempotency\"") do
          Repo.put_dynamic_repo(unavailable)
          send(owner, :postcommit_reads_unavailable)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(hook) end)
    previous = Repo.get_dynamic_repo()

    saved =
      try do
        assert {:noreply, saved} =
                 YellowDog.ManagementUI.ZonesLive.handle_event(
                   "save_assignments",
                   %{"_submission" => socket.assigns.assignment_submission_id},
                   socket
                 )

        saved
      after
        Repo.put_dynamic_repo(previous)
      end

    assert_receive :postcommit_reads_unavailable
    assert {:ok, canonical} = Domain.get_zone_assignments(zone["id"])
    assert saved.assigns.assignment_token == canonical["assignment_token"]
    assert saved.assigns.assignment_worker_revisions == canonical["worker_revisions"]

    assert Enum.map(saved.assigns.assignment_rows, &Map.delete(&1, "key")) ==
             canonical["assignments"]

    refute saved.assigns.assignments_dirty
    assert saved.assigns.content_dirty
    assert saved.assigns.form.params["name"] == "unsaved-content.test."
  end

  test "oversize canonical assignment sets are rejected without truncation or mutation", %{
    conn: conn
  } do
    zone = mutate("create_zone", DomainFixtures.zone())
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    worker = mutate("create_worker", %{"id" => "oversize-data", "name" => "Oversize"})
    now = DateTime.utc_now()

    for n <- 1..257 do
      service =
        Repo.insert!(%YellowDog.Management.Service{
          worker_id: worker["id"],
          instance_id: "dns-#{n}",
          type: "dns",
          desired_state: "stopped",
          config: %{"listen_address" => "127.0.0.1", "port" => 5300}
        })

      Repo.insert!(%YellowDog.Management.Assignment{
        service_id: service.id,
        zone_id: zone["id"],
        resource_version_id: version["id"],
        inserted_at: now,
        updated_at: now
      })
    end

    assert {:error, %{code: "assignment_limit"}} = Domain.get_zone_assignments(zone["id"])
    other = mutate("create_zone", DomainFixtures.zone("other-small.test."))
    other_version = mutate("confirm_zone", %{"id" => other["id"], "expected_revision" => 1})
    small = mutate("create_worker", %{"id" => "small-data", "name" => "Small"})
    service = mutate("put_service", DomainFixtures.service(small["id"], 1, "stopped"))

    mutate("assign", %{
      "worker_id" => small["id"],
      "service_id" => service["id"],
      "resource_version_id" => other_version["id"],
      "expected_revision" => service["worker_revision"]
    })

    {:ok, view, _} = live(conn, "/management/zones/#{other["id"]}/application")
    assert has_element?(view, "fieldset[data-worker-id='small-data']")
    render_patch(view, "/management/zones/#{zone["id"]}/application")
    refute has_element?(view, "fieldset[data-worker-id='small-data']")
    assert has_element?(view, "#zone-assignment-error", "more than 256")
    assert has_element?(view, "#zone-save-assignments[disabled]")
    assert length(Domain.list_assignments(worker["id"])) == 257
  end

  defp drain_sql(acc) do
    receive do
      {:sql, query} -> drain_sql([query | acc])
    after
      0 -> acc
    end
  end

  defp fields(zone),
    do: %{
      "name" => zone["name"],
      "records" =>
        zone["records"] |> Enum.with_index() |> Map.new(fn {r, n} -> {to_string(n), r} end)
    }

  defp form_token(view, id) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query("##{id} input[name='_submission']")
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp form_params(view, id) do
    fields = view |> render() |> LazyHTML.from_document() |> LazyHTML.query("##{id} fieldset")

    assignments =
      Map.new(fields, fn field ->
        [field_id] = LazyHTML.attribute(field, "id")
        key = String.replace_prefix(field_id, "zone-assignment-", "")

        selected = fn name ->
          field
          |> LazyHTML.query("select[name$='[#{name}]'] option[selected]")
          |> LazyHTML.attribute("value")
          |> List.first()
        end

        {key,
         %{
           "service_id" => selected.("service_id"),
           "resource_version_id" => selected.("resource_version_id")
         }}
      end)

    %{"assignments" => assignments, "_submission" => form_token(view, id)}
  end

  defp click(view, event, params) do
    [_, token] = Regex.run(~r/id="submission-intent"[^>]*value="([^"]+)"/, render(view))

    render_click(view, event, Map.put(params, "_submission", token))
  end

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
