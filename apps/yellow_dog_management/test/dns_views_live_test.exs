defmodule YellowDog.Management.DnsViewsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias YellowDog.Management.{
    Assignment,
    Audit,
    DnsView,
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

  defmodule UnavailableRepo do
    use Ecto.Repo, otp_app: :yellow_dog_management, adapter: Ecto.Adapters.Postgres
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "same mounted editor recreates an identical deleted View with a new identity", %{
    conn: conn
  } do
    selected = scope("view-recreate")
    {:ok, view, _} = live(conn, path(selected))
    before = snapshot()
    input = fields("office")
    submit(view, input)
    first = find_view(selected, "office")
    click_event(view, "delete", %{"id" => first["id"]})
    click_event(view, "confirm_delete", %{"id" => first["id"]})
    refute Enum.any?(list(selected), &(&1["id"] == first["id"]))
    submit(view, input)
    second = find_view(selected, "office")
    refute second["id"] == first["id"]
    assert length(snapshot().idempotency -- before.idempotency) == 3
    assert length(snapshot().audit -- before.audit) == 3
    {:ok, fresh, _} = live(build_conn(), path(selected))
    assert has_element?(fresh, "tr", "office")
  end

  test "completed and delayed create/update events cannot write or replace a new editor", %{
    conn: conn
  } do
    selected = scope("view-duplicates")
    {:ok, view, _} = live(conn, path(selected))
    input = fields("office")
    original = %{"view" => input, "_submission" => intent(view)}
    before = snapshot()
    render_submit(view, "save", original)
    created = find_view(selected, "office")
    after_create = snapshot()
    assert length(after_create.audit -- before.audit) == 1
    assert length(after_create.idempotency -- before.idempotency) == 1
    render_submit(view, "save", original)
    assert snapshot() == after_create
    assert has_element?(view, "input[name='view[name]'][value='']")

    click_event(view, "edit", %{"id" => created["id"]})
    update = %{"view" => fields("office", %{"priority" => "42"}), "_submission" => intent(view)}
    render_submit(view, "save", update)
    updated = find_view(selected, "office")
    assert updated["id"] == created["id"]
    assert updated["revision"] == 2
    assert updated["priority"] == 42
    after_update = snapshot()
    render_change(view, "validate", %{"view" => fields("new unsaved")})
    render_submit(view, "save", update)
    render_submit(view, "save", original)
    render_submit(view, "save", %{"view" => input})
    assert snapshot() == after_update
    assert has_element?(view, "input[name='view[name]'][value='new unsaved']")
    {:ok, fresh, _} = live(build_conn(), path(selected))
    assert has_element?(fresh, "tr", "office")
    assert find_view(selected, "office")["priority"] == 42
  end

  test "scope changes retire pending events before they can replace fields or write", %{
    conn: conn
  } do
    first = scope("view-old-intent")
    second = scope("view-new-intent")
    {:ok, view, _} = live(conn, path(first))
    create_view(first, "office")
    pending = %{"view" => fields("office"), "_submission" => intent(view)}
    render_submit(view, "save", pending)
    assert has_element?(view, "#dns-view-error", "already exists")
    render_change(view, "select_worker", %{"scope" => %{"worker_id" => second.worker["id"]}})
    click_event(view, "confirm_scope")
    assert_patch(view, selector(second))
    render_change(view, "validate", %{"view" => fields("new scope unsaved")})
    before = snapshot()
    render_submit(view, "save", pending)
    assert snapshot() == before
    assert has_element?(view, "input[name='view[name]'][value='new scope unsaved']")
    submit(view, fields("office"))
    assert find_view(second, "office")["service_id"] == second.service["id"]
    assert Enum.count(list(first), &(&1["name"] == "office")) == 1
  end

  test "malformed current-intent submissions fail closed without dropping editor fields", %{
    conn: conn
  } do
    selected = scope("view-malformed-intent")
    {:ok, view, _} = live(conn, path(selected))
    render_change(view, "validate", %{"view" => fields("typed")})
    before = snapshot()
    assert render_submit(view, "save", %{"_submission" => intent(view)}) =~ "Invalid View action"
    assert snapshot() == before
    assert has_element?(view, "input[name='view[name]'][value='typed']")
  end

  test "pipelined edit and submit accept changed input before the new token reaches the browser",
       %{conn: conn} do
    selected = scope("view-pipelined")
    create_view(selected, "taken")
    {:ok, view, _} = live(conn, path(selected))
    original = %{"view" => fields("taken"), "_submission" => intent(view)}
    render_submit(view, "save", original)
    assert has_element?(view, "#dns-view-error", "already exists")
    before_edit = snapshot()
    changed = Map.put(original, "view", fields("pipelined"))
    render_change(view, "validate", changed)
    render_submit(view, "save", original)
    assert snapshot() == before_edit
    assert has_element?(view, "input[name='view[name]'][value='pipelined']")
    render_submit(view, "save", changed)
    assert find_view(selected, "pipelined")
    assert length(snapshot().idempotency -- before_edit.idempotency) == 1
    assert length(snapshot().audit -- before_edit.audit) == 1
    saved = snapshot()
    render_submit(view, "save", changed)
    render_submit(view, "save", original)
    assert snapshot() == saved
  end

  test "edit then revert cannot turn an old duplicate into an independent submission", %{
    conn: conn
  } do
    selected = scope("view-edit-revert")

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_reverted_view() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'fixture database failure'; END $$"
    )

    Repo.query!(
      "CREATE TRIGGER reject_reverted_view BEFORE INSERT ON management_dns_views FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_reverted_view()"
    )

    {:ok, view, _} = live(conn, path(selected))
    original = %{"view" => fields("office"), "_submission" => intent(view)}
    before = snapshot()
    render_submit(view, "save", original)
    assert has_element?(view, "#dns-view-error", "Database constraint rejected")
    failed = snapshot()
    assert [original_receipt] = failed.idempotency -- before.idempotency
    render_change(view, "validate", %{"view" => fields("temporary")})
    render_change(view, "validate", %{"view" => fields("office")})
    refute intent(view) == original["_submission"]
    render_submit(view, "save", original)
    assert snapshot() == failed
    assert has_element?(view, "input[name='view[name]'][value='office']")
    Repo.query!("DROP TRIGGER reject_reverted_view ON management_dns_views")
    submit(view, fields("office"))
    assert find_view(selected, "office")
    assert [new_receipt] = snapshot().idempotency -- failed.idempotency
    refute new_receipt.key == original_receipt.key
    assert length(snapshot().audit -- failed.audit) == 1
    saved = snapshot()
    render_submit(view, "save", original)
    assert snapshot() == saved
    {:ok, fresh, _} = live(build_conn(), path(selected))
    assert has_element?(fresh, "tr", "office")
  end

  test "unconfirmed database outcome preserves fields and the pending request for a confirmed retry" do
    selected = scope("view-unconfirmed")

    {:ok, socket} =
      YellowDog.ManagementUI.DnsViewsLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}},
        private: %{live_temp: %{}}
      })

    socket =
      Phoenix.Component.assign(socket,
        worker: selected.worker,
        service: selected.service,
        scope_params: %{
          "server_id" => selected.worker["id"],
          "service_id" => selected.service["id"]
        }
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
         ]},
        id: :unavailable_repo
      )

    previous_repo = Repo.get_dynamic_repo()
    input = %{"view" => fields("unconfirmed"), "_submission" => socket.assigns.submission_id}
    before = snapshot()

    failed =
      try do
        Repo.put_dynamic_repo(unavailable)

        assert {:noreply, failed} =
                 YellowDog.ManagementUI.DnsViewsLive.handle_event("save", input, socket)

        failed
      after
        Repo.put_dynamic_repo(previous_repo)
      end

    assert failed.assigns.error =~ "submission was not confirmed"
    assert failed.assigns.form.params["name"] == "unconfirmed"
    assert failed.assigns.submission_id == socket.assigns.submission_id
    assert {_params, key} = failed.assigns.submissions["create_dns_view"]
    assert snapshot() == before

    assert {:noreply, saved} =
             YellowDog.ManagementUI.DnsViewsLive.handle_event("save", input, failed)

    assert saved.assigns.submission_id != failed.assigns.submission_id
    assert find_view(selected, "unconfirmed")
    assert [receipt] = snapshot().idempotency -- before.idempotency
    assert receipt.key == key
    assert length(snapshot().audit -- before.audit) == 1

    assert {:noreply, ^saved} =
             YellowDog.ManagementUI.DnsViewsLive.handle_event("save", input, saved)

    assert length(snapshot().idempotency -- before.idempotency) == 1
  end

  test "pipelined View updates match real browser fields with read-only fields omitted", %{
    conn: conn
  } do
    for default? <- [false, true] do
      selected = scope("view-browser-fields-#{default?}")

      record =
        if default?, do: find_view(selected, "default"), else: create_view(selected, "office")

      {:ok, view, _} = live(conn, path(selected))
      click_event(view, "edit", %{"id" => record["id"]})
      update_view(selected, record, %{"enabled" => false})
      omitted = if default?, do: ~w(name priority client_rules), else: ~w(name)
      input = fields(record["name"]) |> Map.drop(omitted)
      request = %{"view" => input, "_submission" => intent(view)}
      render_submit(view, "save", request)
      assert has_element?(view, "#dns-view-error", "revision")
      before_edit = snapshot()
      changed = put_in(request, ["view", "recursion_enabled"], "false")
      render_change(view, "validate", changed)
      render_submit(view, "save", request)
      assert snapshot() == before_edit
      render_submit(view, "save", changed)
      assert length(snapshot().audit -- before_edit.audit) == 1
      assert length(snapshot().idempotency -- before_edit.idempotency) == 1

      assert has_element?(
               view,
               "select[name='view[recursion_enabled]'] option[value='false'][selected]"
             )
    end
  end

  test "database failure retains View fields; retries are stable and edits use a new command", %{
    conn: conn
  } do
    selected = scope("view-db-failure")

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_view_draft() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'fixture database failure'; END $$
    """)

    Repo.query!(
      "CREATE TRIGGER fixture_reject_view BEFORE INSERT ON management_dns_views FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_view_draft()"
    )

    {:ok, view, _} = live(conn, path(selected))
    input = fields("retained", %{"client_rules" => "allow countries US"})
    submit(view, input)
    assert has_element?(view, "#dns-view-error", "Database constraint rejected")
    assert has_element?(view, "input[name='view[name]'][value='retained']")
    assert textarea(view, "#dns-view-rules") == "allow countries US"
    rejected = snapshot()
    submit(view, input)
    assert snapshot() == rejected
    submit(view, fields("edited"))
    assert length(Repo.all(Idempotency)) == length(rejected.idempotency) + 1
    Repo.query!("DROP TRIGGER fixture_reject_view ON management_dns_views")
    submit(view, fields("accepted"))
    assert find_view(selected, "accepted")["name"] == "accepted"
    {:ok, fresh, _} = live(build_conn(), path(selected))
    assert has_element?(fresh, "tr", "accepted")
  end

  test "unknown Worker, malformed scope and zero Workers fail closed", %{conn: conn} do
    before_read = snapshot()

    for path <- [
          "/server/missing/dns/views",
          "/server/missing/dns/views/#{Ecto.UUID.generate()}",
          "/server/%20/dns/views"
        ] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#dns-view-error")
      refute has_element?(view, "#dns-view-form")
      submit_event(view, "save", %{"view" => fields("forged")})
      click_event(view, "confirm_delete", %{"id" => Ecto.UUID.generate()})
    end

    assert snapshot() == before_read
  end

  test "single DNS Service preselects and multiple Services require a choice without query inference",
       %{
         conn: conn
       } do
    selected = scope()
    before_read = snapshot()

    {:ok, view, html} =
      live(conn, selector(selected) <> "?service_id=#{selected.service["id"]}&server_id=missing")

    assert html =~ "DNS Service:"
    assert has_element?(view, "#dns-view-form")

    assert has_element?(
             view,
             "#dns-view-service-selector button[data-service-id='#{selected.service["id"]}']"
           )

    assert snapshot() == before_read
    assert get_resp_header(get(conn, selector(selected)), "www-authenticate") == []

    assert has_element?(view, "#dns-view-form[phx-hook='ResetForm']")
    alternate = scope(selected.worker["id"], "dns-second")
    {:ok, selector_view, _html} = live(conn, selector(selected))
    refute has_element?(selector_view, "#dns-view-form")
    assert has_element?(selector_view, "button[data-service-id='#{alternate.service["id"]}']")

    selector_view
    |> element("button[data-service-id='#{alternate.service["id"]}']")
    |> render_click()

    assert_patch(selector_view, path(alternate))
  end

  test "global Worker selector includes disconnected Workers and confirms discarding unsaved scope",
       %{conn: conn} do
    first = scope("view-selected")
    second = scope("view-disconnected")
    {:ok, view, html} = live(conn, "/management/dns/views")
    assert html =~ second.worker["name"]
    refute has_element?(view, "#dns-view-form")

    render_change(view, "select_worker", %{"scope" => %{"worker_id" => first.worker["id"]}})
    assert_patch(view, selector(first))
    assert has_element?(view, "#dns-view-form")
    render_change(view, "validate", %{"view" => fields("unsaved")})
    render_change(view, "select_worker", %{"scope" => %{"worker_id" => second.worker["id"]}})
    assert has_element?(view, "#dns-view-unsaved-scope")
    assert has_element?(view, "input[name='view[name]'][value='unsaved']")
    click_event(view, "cancel_scope")
    refute has_element?(view, "#dns-view-unsaved-scope")
    assert has_element?(view, "input[name='view[name]'][value='unsaved']")

    render_change(view, "select_worker", %{"scope" => %{"worker_id" => second.worker["id"]}})
    click_event(view, "confirm_scope")
    assert_patch(view, selector(second))
    assert has_element?(view, "input[name='view[name]'][value='']")

    refute Enum.any?(
             elem(Domain.list_dns_views(first.worker["id"], first.service["id"]), 1),
             &(&1["name"] == "unsaved")
           )

    assert has_element?(view, "#dns-views-table")
  end

  test "Worker without DNS and malformed or foreign Service IDs cannot mutate", %{conn: conn} do
    empty = mutate("create_worker", %{"id" => "view-empty", "name" => "Empty"})
    {:ok, view, html} = live(conn, "/server/#{empty["id"]}/dns/views")
    assert html =~ "No DNS Services configured"
    refute has_element?(view, "#dns-view-form")
    selected = scope()
    other = scope("view-other")
    before_read = snapshot()

    for id <- ["not-a-uuid", Ecto.UUID.generate(), other.service["id"]] do
      {:ok, view, _html} = live(conn, selector(selected) <> "/#{id}")
      assert has_element?(view, "#dns-view-error")
      refute has_element?(view, "#dns-view-form")
      submit_event(view, "save", %{"view" => fields("forged")})
    end

    assert snapshot() == before_read
  end

  test "full create canonicalizes ordered rules and endpoints without changing DNS history or export",
       %{conn: conn} do
    selected = scope()
    zone = mutate("create_zone", DomainFixtures.zone("view.test."))

    version =
      mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})

    {:ok, worker} = Domain.get_worker(selected.worker["id"])

    mutate("assign", %{
      "worker_id" => worker["id"],
      "service_id" => selected.service["id"],
      "resource_version_id" => version["id"],
      "expected_revision" => worker["revision"]
    })

    {:ok, worker} = Domain.get_worker(worker["id"])

    target =
      mutate("confirm_target", %{
        "worker_id" => worker["id"],
        "expected_revision" => worker["revision"]
      })

    export_path = "/api/workers/#{worker["id"]}/targets/#{target["revision"]}/export"
    export_before = get(conn, export_path).resp_body
    before_save = business_snapshot()

    {:ok, view, _html} =
      live(conn, path(selected) <> "?server_id=missing&service_id=#{Ecto.UUID.generate()}")

    submit(
      view,
      fields("office", %{
        "priority" => "7",
        "enabled" => "false",
        "recursion_enabled" => "false",
        "ecs_enabled" => "true",
        "client_rules" =>
          "deny networks 192.0.2.99/24, 2001:db8::123/64\nallow countries US, CA, US\ndeny any",
        "fallback_forwarders" =>
          "192.0.2.53\n198.51.100.53:5353\n2001:db8::53\n[2001:db8::54]:5354",
        "fallback_timeout" => "100",
        "fallback_retries" => "5",
        "worker_id" => "missing",
        "service_id" => Ecto.UUID.generate(),
        "id" => Ecto.UUID.generate(),
        "expected_revision" => 99
      })
    )

    saved = find_view(selected, "office")
    assert saved["priority"] == 7
    assert saved["enabled"] == false
    assert saved["recursion_enabled"] == false
    assert saved["ecs_enabled"] == true

    assert saved["client_rules"] == [
             %{
               "action" => "deny",
               "kind" => "networks",
               "networks" => ["192.0.2.0/24", "2001:db8::/64"]
             },
             %{"action" => "allow", "kind" => "countries", "countries" => ["CA", "US"]},
             %{"action" => "deny", "kind" => "any"}
           ]

    assert saved["fallback_forwarders"] == [
             %{"address" => "192.0.2.53", "port" => 53},
             %{"address" => "198.51.100.53", "port" => 5353},
             %{"address" => "2001:db8::53", "port" => 53},
             %{"address" => "2001:db8::54", "port" => 5354}
           ]

    assert saved["fallback_timeout"] == 100
    assert saved["fallback_retries"] == 5
    assert saved["worker_id"] == worker["id"]
    assert saved["service_id"] == selected.service["id"]
    assert has_element?(view, "input[name='view[name]'][value='']")
    assert_push_event(view, "set_form_values", %{id: "dns-view-form", values: values})
    assert values == Map.new(fields(""), fn {field, value} -> {"view[#{field}]", value} end)
    assert render(view) =~ "not executed/exported"
    assert business_snapshot() == before_save
    assert get(conn, export_path).resp_body == export_before
  end

  test "new form has full defaults and Save is the first submitter", %{conn: conn} do
    selected = scope()
    {:ok, view, _html} = live(conn, path(selected))
    assert textarea(view, "#dns-view-rules") == "allow any"
    assert has_element?(view, "input[name='view[priority]'][value='100']")
    assert has_element?(view, "input[name='view[fallback_timeout]'][value='2000']")
    assert has_element?(view, "input[name='view[fallback_retries]'][value='1']")
    assert has_element?(view, "select[name='view[enabled]'] option[value='true'][selected]")

    assert has_element?(
             view,
             "select[name='view[recursion_enabled]'] option[value='true'][selected]"
           )

    assert has_element?(view, "select[name='view[ecs_enabled]'] option[value='false'][selected]")

    assert view
           |> render()
           |> LazyHTML.from_document()
           |> LazyHTML.query("#dns-view-form button[type=submit]")
           |> LazyHTML.attribute("id")
           |> hd() == "dns-view-save"

    submit(view, fields("defaults"))
    saved = find_view(selected, "defaults")
    assert saved["priority"] == 100
    assert saved["client_rules"] == [%{"action" => "allow", "kind" => "any"}]
    assert saved["fallback_forwarders"] == []
  end

  test "edit round-trips rich fields, immutable name and zero-rule versus empty-network semantics",
       %{conn: conn} do
    selected = scope()

    saved =
      create_view(selected, "office", %{
        "enabled" => false,
        "ecs_enabled" => true,
        "client_rules" => [
          %{"action" => "deny", "kind" => "countries", "countries" => ["US"]},
          %{"action" => "allow", "kind" => "networks", "networks" => []}
        ],
        "fallback_forwarders" => [%{"address" => "2001:db8::53", "port" => 5353}]
      })

    {:ok, view, _html} = live(conn, path(selected))
    click_event(view, "edit", %{"id" => saved["id"]})
    assert textarea(view, "#dns-view-rules") == "deny countries US\nallow networks"
    assert textarea(view, "#dns-view-forwarders") == "[2001:db8::53]:5353"

    assert_push_event(view, "set_form_values", %{
      id: "dns-view-form",
      values: %{"view[name]" => "office"} = values
    })

    assert values["view[name]"] == "office"
    assert values["view[client_rules]"] == "deny countries US\nallow networks"
    assert values["view[fallback_forwarders]"] == "[2001:db8::53]:5353"
    assert values["view[enabled]"] == "false"
    assert has_element?(view, "input[name='view[name]'][disabled][value='office']")

    submit(
      view,
      fields("forged-rename", %{
        "client_rules" => "",
        "priority" => "0",
        "recursion_enabled" => "false",
        "ecs_enabled" => "true",
        "fallback_forwarders" => "[2001:db8::53]:5353"
      })
    )

    updated = find_view(selected, "office")
    assert updated["id"] == saved["id"]
    assert updated["name"] == "office"
    assert updated["revision"] == saved["revision"] + 1
    assert updated["client_rules"] == []
    assert updated["priority"] == 0
    assert updated["recursion_enabled"] == false
    assert updated["ecs_enabled"] == true
    refute Enum.any?(list(selected), &(&1["name"] == "forged-rename"))
  end

  test "default sorts last, cannot delete, and priority/client rules remain readonly while other fields edit",
       %{conn: conn} do
    selected = scope()
    default = find_view(selected, "default")
    custom = create_view(selected, "last-custom", %{"priority" => 9_223_372_036_854_775_807})
    {:ok, view, _html} = live(conn, path(selected))

    names =
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#dns-views-table tbody tr")
      |> LazyHTML.attribute("data-view-name")

    assert names == [custom["name"], "default"]
    refute has_element?(view, "#dns-view-#{default["id"]} [phx-click='delete']")
    before_delete = snapshot()
    click_event(view, "delete", %{"id" => default["id"]})
    click_event(view, "confirm_delete", %{"id" => default["id"]})
    assert snapshot() == before_delete
    click_event(view, "edit", %{"id" => default["id"]})
    assert has_element?(view, "#dns-view-rules[readonly]")
    refute has_element?(view, "input[name='view[priority]']")
    refute has_element?(view, "#dns-view-apply-preset")

    submit(
      view,
      fields("forged", %{
        "priority" => "1",
        "client_rules" => "deny any",
        "enabled" => "false",
        "recursion_enabled" => "false",
        "ecs_enabled" => "true",
        "fallback_forwarders" => "::1",
        "fallback_timeout" => "30000",
        "fallback_retries" => "0"
      })
    )

    updated = find_view(selected, "default")
    assert updated["priority"] == nil
    assert updated["client_rules"] == default["client_rules"]
    assert updated["name"] == "default"
    assert updated["enabled"] == false
    assert updated["ecs_enabled"] == true
    assert updated["fallback_forwarders"] == [%{"address" => "::1", "port" => 53}]
    click_event(view, "toggle_enabled", %{"id" => updated["id"]})
    toggled = find_view(selected, "default")
    assert toggled["enabled"] == true

    assert Map.drop(toggled, ~w(enabled revision updated_at)) ==
             Map.drop(updated, ~w(enabled revision updated_at))
  end

  test "status-only toggle preserves hidden policy and does not silently retry stale CAS", %{
    conn: conn
  } do
    selected = scope()

    saved =
      create_view(selected, "toggle", %{
        "fallback_timeout" => 777,
        "ecs_enabled" => true,
        "client_rules" => [%{"action" => "deny", "kind" => "any"}]
      })

    {:ok, view, _html} = live(conn, path(selected))
    click_event(view, "toggle_enabled", %{"id" => saved["id"]})
    toggled = find_view(selected, "toggle")
    assert toggled["enabled"] == false

    assert Map.drop(toggled, ~w(enabled revision updated_at)) ==
             Map.drop(saved, ~w(enabled revision updated_at))

    concurrent = update_view(selected, toggled, %{"priority" => 9})
    before_stale = snapshot()
    click_event(view, "toggle_enabled", %{"id" => saved["id"]})
    assert has_element?(view, "#dns-view-error")
    assert find_view(selected, "toggle") == concurrent
    assert_rejected_command(before_stale, "update_dns_view")
  end

  test "stale edits retain entered rules, preserve business data and record rejection", %{
    conn: conn
  } do
    selected = scope()
    saved = create_view(selected, "stale")
    {:ok, view, _html} = live(conn, path(selected))
    click_event(view, "edit", %{"id" => saved["id"]})

    concurrent =
      update_view(selected, saved, %{
        "priority" => 8,
        "client_rules" => [%{"action" => "deny", "kind" => "any"}]
      })

    before_stale = snapshot()
    submit(view, fields("stale", %{"client_rules" => "allow countries US", "priority" => "9"}))
    assert has_element?(view, "#dns-view-error")
    assert textarea(view, "#dns-view-rules") == "allow countries US"
    assert find_view(selected, "stale") == concurrent
    assert_rejected_command(before_stale, "update_dns_view")
    click_event(view, "refresh")
    assert has_element?(view, "input[name='view[name]'][value='']")

    assert has_element?(
             view,
             "#dns-view-#{saved["id"]}[data-view-revision='#{concurrent["revision"]}']"
           )
  end

  test "delete requires matching confirmation, cancellation is readonly and stale confirmation fails",
       %{conn: conn} do
    selected = scope()
    saved = create_view(selected, "delete-me")
    other = create_view(selected, "keep")
    {:ok, view, _html} = live(conn, path(selected))
    before_delete = snapshot()
    click_event(view, "confirm_delete", %{"id" => saved["id"]})
    assert snapshot() == before_delete
    click_event(view, "delete", %{"id" => saved["id"]})
    assert has_element?(view, "#dns-view-delete-modal[role='dialog']")
    click_event(view, "confirm_delete", %{"id" => other["id"]})
    assert snapshot() == before_delete
    click_event(view, "cancel_delete")
    refute has_element?(view, "#dns-view-confirm-delete")
    assert snapshot() == before_delete
    click_event(view, "delete", %{"id" => saved["id"]})
    current = update_view(selected, saved, %{"fallback_retries" => 4})
    before_stale = snapshot()
    click_event(view, "confirm_delete", %{"id" => saved["id"]})
    assert_rejected_command(before_stale, "delete_dns_view")
    assert find_view(selected, "delete-me") == current
    click_event(view, "refresh")
    click_event(view, "delete", %{"id" => saved["id"]})
    click_event(view, "confirm_delete", %{"id" => saved["id"]})

    assert {:error, %{code: "not_found"}} =
             Domain.get_dns_view(selected.worker["id"], selected.service["id"], saved["id"])

    assert find_view(selected, "keep") == other
  end

  test "invalid numeric, country, network, name and strict fallback inputs have no mutations", %{
    conn: conn
  } do
    selected = scope()
    {:ok, view, _html} = live(conn, path(selected))

    for {field, value} <- [
          {"name", "default"},
          {"name", String.duplicate("a", 64)},
          {"name", "bad.name"},
          {"priority", "-1"},
          {"priority", "1junk"},
          {"priority", "9223372036854775808"},
          {"fallback_timeout", "99"},
          {"fallback_timeout", "30001"},
          {"fallback_retries", "6"},
          {"client_rules", "allow networks invalid"},
          {"client_rules", "allow countries XX"},
          {"client_rules", "allow countries"},
          {"fallback_forwarders", "example.com"},
          {"fallback_forwarders", "127.1"},
          {"fallback_forwarders", "192.0.2.1:0"},
          {"fallback_forwarders", "[::1]:65536"},
          {"fallback_forwarders", "[192.0.2.1]:53"},
          {"fallback_forwarders", "[::1]:53junk"},
          {"fallback_forwarders", Enum.map_join(1..129, "\n", fn _index -> "192.0.2.1" end)}
        ] do
      click_event(view, "cancel")
      before_invalid = snapshot()
      submit_event(view, "save", %{"view" => fields("invalid", %{field => value})})
      assert has_element?(view, "#dns-view-#{field}-error")
      assert snapshot() == before_invalid
    end

    click_event(view, "cancel")
    submit(view, fields("max-priority", %{"priority" => "9223372036854775807"}))
    assert find_view(selected, "max-priority")["priority"] == 9_223_372_036_854_775_807
  end

  test "foreign payload arrays and malformed event identities do not crash", %{conn: conn} do
    selected = scope()
    {:ok, view, _html} = live(conn, path(selected))
    before_invalid = snapshot()

    for field <-
          ~w(name priority enabled recursion_enabled ecs_enabled client_rules fallback_forwarders fallback_timeout fallback_retries) do
      click_event(view, "cancel")
      submit_event(view, "save", %{"view" => fields("arrays", %{field => ["foreign"]})})
      assert has_element?(view, "#dns-view-error")
    end

    for event <- ~w(edit delete toggle_enabled confirm_delete) do
      click_event(view, event, %{"id" => ["not-an-id"]})
    end

    click_event(view, "toggle_country", %{"code" => "XX"})
    assert snapshot() == before_invalid
    assert Process.alive?(view.pid)
  end

  test "all four presets fill only an empty editor without persisting or replacing typed rules",
       %{conn: conn} do
    selected = scope()
    {:ok, view, _html} = live(conn, path(selected))

    for preset <- ~w(any none localhost localnets) do
      click_event(view, "cancel")
      before_editor = snapshot()

      submit_event(view, "save", %{
        "operation" => "apply_preset",
        "preset" => preset,
        "view" => fields("preset-#{preset}", %{"client_rules" => ""})
      })

      assert {:ok, rules} = YellowDog.Management.DnsAcls.preset_rules(preset)

      assert textarea(view, "#dns-view-rules") ==
               YellowDog.ManagementUI.DnsRulesText.format(rules)

      assert snapshot() == before_editor

      submit(
        view,
        fields("preset-#{preset}", %{"client_rules" => textarea(view, "#dns-view-rules")})
      )

      assert find_view(selected, "preset-#{preset}")["client_rules"] == rules
    end

    submit_event(view, "save", %{
      "operation" => "apply_preset",
      "preset" => "any",
      "view" => fields("typed", %{"client_rules" => "deny any"})
    })

    assert textarea(view, "#dns-view-rules") == "deny any"
    assert has_element?(view, "#dns-view-error", "retained")
  end

  test "country search retains selections and append preserves latest typed ordered rules and fields",
       %{conn: conn} do
    selected = scope()
    {:ok, view, _html} = live(conn, path(selected))
    before_editor = snapshot()
    click_event(view, "toggle_country", %{"code" => "US"})

    render_change(view, "validate", %{
      "view" => fields("typed", %{"client_rules" => "deny networks ::1"}),
      "country_search" => "Canada"
    })

    assert has_element?(view, "[data-selected-country-code='US']")
    refute has_element?(view, "#dns-view-country-US")
    click_event(view, "toggle_country", %{"code" => "CA"})
    click_event(view, "clear_country_search")
    assert has_element?(view, "#dns-view-country-US[checked]")
    assert has_element?(view, "#dns-view-country-CA[checked]")
    click_event(view, "toggle_country", %{"code" => "US"})
    refute has_element?(view, "#dns-view-country-US[checked]")
    click_event(view, "toggle_country", %{"code" => "US"})

    params =
      fields("latest", %{
        "client_rules" => "deny networks ::1\nallow networks 192.0.2.7",
        "fallback_forwarders" => "[::1]:5353",
        "priority" => "3"
      })

    submit_event(view, "save", %{
      "operation" => "append_countries",
      "view" => params,
      "country_action" => "deny"
    })

    assert textarea(view, "#dns-view-rules") ==
             "deny networks ::1\nallow networks 192.0.2.7\ndeny countries CA, US"

    assert textarea(view, "#dns-view-forwarders") == "[::1]:5353"
    assert has_element?(view, "input[name='view[name]'][value='latest']")
    refute has_element?(view, "[data-selected-country-code]")
    assert snapshot() == before_editor
    submit(view, Map.put(params, "client_rules", textarea(view, "#dns-view-rules")))
    saved = find_view(selected, "latest")

    assert saved["client_rules"] == [
             %{"action" => "deny", "kind" => "networks", "networks" => ["::1/128"]},
             %{"action" => "allow", "kind" => "networks", "networks" => ["192.0.2.7/32"]},
             %{"action" => "deny", "kind" => "countries", "countries" => ["CA", "US"]}
           ]
  end

  test "scope switch clears editor and foreign View IDs cannot retarget mutations", %{conn: conn} do
    selected = scope()
    other = scope("view-other")
    saved = create_view(selected, "office")
    foreign = create_view(other, "foreign")
    {:ok, view, _html} = live(conn, path(selected))
    refute has_element?(view, "#dns-view-#{foreign["id"]}")
    before_scope = snapshot()
    click_event(view, "edit", %{"id" => foreign["id"]})
    click_event(view, "toggle_enabled", %{"id" => foreign["id"]})
    assert snapshot() == before_scope
    click_event(view, "edit", %{"id" => saved["id"]})
    click_event(view, "toggle_country", %{"code" => "US"})
    render_patch(view, path(other))
    assert has_element?(view, "input[name='view[name]'][value='']")
    refute has_element?(view, "[data-selected-country-code]")
    click_event(view, "edit", %{"id" => saved["id"]})
    assert has_element?(view, "#dns-view-error")
    assert snapshot() == before_scope
  end

  test "filtered CSV matches visible name/status subset and refresh/cancel are readonly", %{
    conn: conn
  } do
    selected = scope()
    office = create_view(selected, "office", %{"enabled" => false, "ecs_enabled" => true})
    create_view(selected, "office-active")
    other = scope("view-other")
    create_view(other, "office-foreign")
    {:ok, view, _html} = live(conn, path(selected))
    before_read = snapshot()
    render_change(view, "filter", %{"filter" => "OFFICE", "status" => "disabled"})
    assert has_element?(view, "#dns-view-count", "Showing 1 of 3")
    assert has_element?(view, "#dns-view-#{office["id"]}")
    click_event(view, "export_csv")
    assert_push_event(view, "download_csv", %{content: csv})

    assert csv ==
             "View Name,Status,Priority,Recursion,ECS\r\noffice,Disabled,100,Enabled,Enabled\r\n"

    click_event(view, "edit", %{"id" => office["id"]})
    click_event(view, "cancel")
    click_event(view, "refresh")
    assert has_element?(view, "#dns-view-count", "Showing 1 of 3")
    assert snapshot() == before_read
    render_change(view, "filter", %{"filter" => "", "status" => "all"})
    click_event(view, "export_csv")
    assert_push_event(view, "download_csv", %{content: csv})
    assert csv =~ "default,Active,infinity,Enabled,Disabled\r\n"
    refute csv =~ "foreign"
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

  defp click_event(view, event, params \\ %{}) do
    render_click(view, event, Map.put(params, "_submission", intent(view)))
  end

  defp fields(name, overrides \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "priority" => "100",
        "enabled" => "true",
        "recursion_enabled" => "true",
        "ecs_enabled" => "false",
        "client_rules" => "allow any",
        "fallback_forwarders" => "",
        "fallback_timeout" => "2000",
        "fallback_retries" => "1"
      },
      overrides
    )
  end

  defp submit(view, params), do: submit_event(view, "save", %{"view" => params})

  defp textarea(view, selector),
    do:
      view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> LazyHTML.text()

  defp selector(selected), do: "/server/#{selected.worker["id"]}/dns/views"
  defp path(selected), do: selector(selected) <> "/#{selected.service["id"]}"

  defp scope(worker_id \\ "view-worker", instance_id \\ "dns") do
    worker =
      case Domain.get_worker(worker_id) do
        {:ok, worker} -> worker
        {:error, _error} -> mutate("create_worker", %{"id" => worker_id, "name" => worker_id})
      end

    service =
      mutate(
        "put_service",
        DomainFixtures.service(worker_id, worker["revision"], "stopped")
        |> Map.put("id", instance_id)
      )

    %{worker: worker, service: service}
  end

  defp create_view(selected, name, fields \\ %{}),
    do:
      mutate(
        "create_dns_view",
        Map.merge(fields, %{
          "worker_id" => selected.worker["id"],
          "service_id" => selected.service["id"],
          "name" => name
        })
      )

  defp update_view(selected, view, fields),
    do:
      mutate(
        "update_dns_view",
        Map.merge(fields, %{
          "worker_id" => selected.worker["id"],
          "service_id" => selected.service["id"],
          "id" => view["id"],
          "expected_revision" => view["revision"]
        })
      )

  defp list(selected) do
    assert {:ok, views} = Domain.list_dns_views(selected.worker["id"], selected.service["id"])
    views
  end

  defp find_view(selected, name) do
    view = Enum.find(list(selected), &(&1["name"] == name))
    assert view, "Expected persisted View #{name}"
    view
  end

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "view-ui-test", Ecto.UUID.generate())
    result
  end

  defp business_snapshot do
    for schema <- [Worker, Service, Assignment, Zone, Rrset, ResourceVersion, Target],
        into: %{},
        do: {schema, Repo.all(schema) |> Enum.sort_by(& &1.id)}
  end

  defp snapshot do
    Map.merge(business_snapshot(), %{
      views: Repo.all(DnsView) |> Enum.sort_by(& &1.id),
      audit: Repo.all(Audit),
      idempotency: Repo.all(Idempotency)
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
end
