defmodule YellowDog.Management.DnsAclsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias YellowDog.Management.{
    Assignment,
    Audit,
    DnsAcl,
    DnsAcls,
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

  test "zero Workers and unknown scope are unavailable without mutations", %{conn: conn} do
    before_read = snapshot()

    for path <- ["/server/missing/dns/acl", "/server/missing/dns/acl/#{Ecto.UUID.generate()}"] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#dns-acl-error")
      refute has_element?(view, "#dns-acl-form")

      render_submit(view, "save", %{
        "acl" => fields("forged", "")
      })

      render_click(view, "confirm_delete", %{"id" => Ecto.UUID.generate()})
    end

    assert snapshot() == before_read
  end

  test "even one Service requires explicit selection and ignores query identities", %{conn: conn} do
    %{worker: worker, service: service} = scope()
    before_read = snapshot()

    {:ok, view, html} =
      live(conn, selector_path(worker) <> "?service_id=#{service["id"]}&server_id=missing")

    assert has_element?(
             view,
             "#dns-acl-service-selector a[data-service-id='#{service["id"]}'][href='#{path(worker, service)}']"
           )

    refute has_element?(view, "#dns-acl-form")
    assert html =~ "Select a DNS Service explicitly"
    assert get_resp_header(get(conn, selector_path(worker)), "www-authenticate") == []
    assert snapshot() == before_read

    view
    |> element("#dns-acl-service-selector a[data-service-id='#{service["id"]}']")
    |> render_click()

    assert_patch(view, path(worker, service))
    assert has_element?(view, "#dns-acl-form[phx-hook='ResetForm']")
  end

  test "Worker without DNS Services does not offer an inferred or editable scope", %{conn: conn} do
    worker = mutate("create_worker", %{"id" => "acl-empty", "name" => "Empty Worker"})
    {:ok, view, html} = live(conn, selector_path(worker))
    assert html =~ "No DNS Services configured"
    refute has_element?(view, "#dns-acl-service-selector a[data-service-id]")
    refute has_element?(view, "#dns-acl-form")
  end

  test "list is scoped by both explicit Worker and native Service UUID", %{conn: conn} do
    primary = scope()
    alternate = scope(primary.worker["id"], "dns-alternate")
    other = scope("acl-other")
    acl = create_acl(primary, "primary")
    alternate_acl = create_acl(alternate, "alternate")
    other_acl = create_acl(other, "other")

    {:ok, view, _html} = live(conn, path(primary.worker, primary.service))
    assert has_element?(view, "#dns-acl-#{acl["id"]}[data-acl-name='primary']")
    refute has_element?(view, "#dns-acl-#{alternate_acl["id"]}")
    refute has_element?(view, "#dns-acl-#{other_acl["id"]}")
    render_click(view, "edit", %{"id" => other_acl["id"]})
    assert has_element?(view, "#dns-acl-error")
    assert has_element?(view, "#dns-acl-form input[name='acl[name]'][value='']")
  end

  test "create normalizes CIDRs, resets the form and preserves DNS history and export", %{
    conn: conn
  } do
    selected = scope()
    zone = mutate("create_zone", DomainFixtures.zone("acl.test."))

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
    preserved = business_snapshot()
    {:ok, view, _html} = live(conn, path(selected.worker, selected.service))

    submit(
      view,
      "office",
      "deny networks 192.0.2.123/24, 2001:db8::123/64\nallow countries US, CA, US\ndeny any",
      "Office 办公室"
    )

    assert {:ok, [acl]} = Domain.list_dns_acls(worker["id"], selected.service["id"])
    assert acl["description"] == "Office 办公室"

    assert acl["rules"] == [
             %{
               "action" => "deny",
               "kind" => "networks",
               "networks" => ["192.0.2.0/24", "2001:db8::/64"]
             },
             %{"action" => "allow", "kind" => "countries", "countries" => ["CA", "US"]},
             %{"action" => "deny", "kind" => "any"}
           ]

    assert acl["revision"] == 1

    assert has_element?(
             view,
             "#dns-acl-#{acl["id"]}[data-acl-description='Office 办公室'][data-acl-revision='1']"
           )

    assert has_element?(view, "#dns-acl-form input[name='acl[name]'][value='']")
    assert_push_event(view, "reset_form", %{id: "dns-acl-form"})
    assert render(view) =~ "Desired ACL saved; not enforced/exported"

    view |> element("#dns-acl-#{acl["id"]} button[phx-click='edit']") |> render_click()

    assert rules_text(view) ==
             "deny networks 192.0.2.0/24, 2001:db8::/64\nallow countries CA, US\ndeny any"

    submit(view, "renamed", "allow networks", "Renamed description")
    assert {:ok, renamed} = Domain.get_dns_acl(worker["id"], selected.service["id"], acl["id"])
    assert renamed["id"] == acl["id"]
    assert renamed["name"] == "renamed"
    assert renamed["description"] == "Renamed description"
    assert renamed["rules"] == [%{"action" => "allow", "kind" => "networks", "networks" => []}]
    assert renamed["revision"] == 2
    assert has_element?(view, "#dns-acl-#{acl["id"]}", "allow networks")
    assert_push_event(view, "reset_form", %{id: "dns-acl-form"})

    view |> element("#dns-acl-#{acl["id"]} button[phx-click='delete']") |> render_click()
    view |> element("#dns-acl-confirm-delete") |> render_click()
    assert {:ok, []} = Domain.list_dns_acls(worker["id"], selected.service["id"])
    assert business_snapshot() == preserved
    assert get(conn, export_path).resp_body == export_before
  end

  test "invalid fields and CIDRs fail without creating ACLs and retain entered values", %{
    conn: conn
  } do
    selected = scope()
    {:ok, view, _html} = live(conn, path(selected.worker, selected.service))

    for {name, rules, description} <- [
          {"bad name", "allow any", ""},
          {"office", "allow networks not-a-cidr", ""},
          {"office", "allow networks 192.0.2.0/24,,2001:db8::/64", ""},
          {"office", "allow networks " <> Enum.join(List.duplicate("192.0.2.0/24", 129), ","),
           ""},
          {"office", Enum.join(List.duplicate("allow any", 129), "\n"), ""},
          {"office", "observe any", ""},
          {"office", "allow countries ZZ", ""},
          {"office", "allow countries us", ""},
          {"office", "deny countries", ""},
          {"office", "allow any trailing-data", ""},
          {["office"], "", ""},
          {"office", ["allow any"], ""},
          {"office", "", ["description"]},
          {"office", "", String.duplicate("e\u0301", 128)},
          {"office", "", "nul" <> <<0>>}
        ] do
      render_submit(view, "save", %{
        "acl" => fields(name, rules, description)
      })

      assert has_element?(view, "#dns-acl-error")
      assert {:ok, []} = Domain.list_dns_acls(selected.worker["id"], selected.service["id"])
    end

    render_submit(view, "save", %{
      "acl" => fields("retained", "allow networks bad-cidr", "Preserved")
    })

    assert has_element?(view, "#dns-acl-form input[name='acl[name]'][value='retained']")
    assert rules_text(view) == "allow networks bad-cidr"
    assert has_element?(view, "#dns-acl-form input[name='acl[description]'][value='Preserved']")
  end

  test "cancel clears the UUID editor and subsequent submission creates a new ACL", %{conn: conn} do
    selected = scope()
    acl = create_acl(selected, "original")
    {:ok, view, _html} = live(conn, path(selected.worker, selected.service))
    view |> element("#dns-acl-#{acl["id"]} button[phx-click='edit']") |> render_click()
    assert has_element?(view, "#dns-acl-form input[name='acl[name]'][value='original']")
    view |> element("#dns-acl-cancel") |> render_click()
    assert_push_event(view, "reset_form", %{id: "dns-acl-form"})
    assert has_element?(view, "#dns-acl-form input[name='acl[name]'][value='']")
    submit(view, "new-acl", "")

    assert {:ok, ^acl} =
             Domain.get_dns_acl(selected.worker["id"], selected.service["id"], acl["id"])

    assert {:ok, acls} = Domain.list_dns_acls(selected.worker["id"], selected.service["id"])
    assert length(acls) == 2
  end

  test "stale ACL editor cannot overwrite a concurrent rename and refresh is read-only", %{
    conn: conn
  } do
    selected = scope()
    acl = create_acl(selected, "original")
    {:ok, view, _html} = live(conn, path(selected.worker, selected.service))
    view |> element("#dns-acl-#{acl["id"]} button[phx-click='edit']") |> render_click()
    concurrent = update_acl(selected, acl, "concurrent")
    submit(view, "stale", "deny any")
    assert has_element?(view, "#dns-acl-error")

    assert {:ok, ^concurrent} =
             Domain.get_dns_acl(selected.worker["id"], selected.service["id"], acl["id"])

    before_read = snapshot()
    view |> element("#dns-acl-refresh") |> render_click()
    assert has_element?(view, "#dns-acl-#{acl["id"]}[data-acl-name='concurrent']")
    assert has_element?(view, "#dns-acl-form input[name='acl[name]'][value='']")
    assert snapshot() == before_read

    assert {:ok, [^concurrent]} =
             Domain.list_dns_acls(selected.worker["id"], selected.service["id"])
  end

  test "delete requires confirmation, supports cancellation and rejects a stale confirmation", %{
    conn: conn
  } do
    selected = scope()
    acl = create_acl(selected, "original")
    {:ok, view, _html} = live(conn, path(selected.worker, selected.service))
    before_read = snapshot()
    render_click(view, "confirm_delete", %{"id" => acl["id"]})
    assert snapshot() == before_read
    view |> element("#dns-acl-#{acl["id"]} button[phx-click='delete']") |> render_click()
    assert has_element?(view, "#dns-acl-confirm-delete")
    refute has_element?(view, "#dns-acl-confirm-delete[data-confirm]")
    assert snapshot() == before_read
    view |> element("#dns-acl-cancel-delete") |> render_click()
    refute has_element?(view, "#dns-acl-confirm-delete")
    assert snapshot() == before_read
    view |> element("#dns-acl-#{acl["id"]} button[phx-click='delete']") |> render_click()
    concurrent = update_acl(selected, acl, "concurrent")
    view |> element("#dns-acl-confirm-delete") |> render_click()
    assert has_element?(view, "#dns-acl-error")

    assert {:ok, ^concurrent} =
             Domain.get_dns_acl(selected.worker["id"], selected.service["id"], acl["id"])
  end

  test "matched route scope overrides query and submitted Worker, Service, ACL and revision IDs",
       %{conn: conn} do
    selected = scope()
    other = scope("acl-other")
    other_acl = create_acl(other, "other")

    query =
      "?server_id=acl-other&worker_id[]=acl-other&service_id=#{other.service["id"]}&id=#{other_acl["id"]}"

    {:ok, view, _html} = live(conn, path(selected.worker, selected.service) <> query)

    render_submit(view, "save", %{
      "acl" => %{
        "name" => "route-authoritative",
        "description" => "Explicit route",
        "rules" => "deny any",
        "worker_id" => other.worker["id"],
        "service_id" => other.service["id"],
        "id" => other_acl["id"],
        "expected_revision" => other_acl["revision"]
      },
      "worker_id" => other.worker["id"],
      "service_id" => other.service["id"]
    })

    assert {:ok, [created]} = Domain.list_dns_acls(selected.worker["id"], selected.service["id"])
    assert created["name"] == "route-authoritative"
    assert created["worker_id"] == selected.worker["id"]
    assert created["service_id"] == selected.service["id"]
    assert {:ok, [^other_acl]} = Domain.list_dns_acls(other.worker["id"], other.service["id"])
  end

  test "scope patches clear both editor and pending deletion", %{conn: conn} do
    selected = scope()
    alternate = scope(selected.worker["id"], "dns-alternate")
    acl = create_acl(selected, "original")
    {:ok, view, _html} = live(conn, path(selected.worker, selected.service))
    view |> element("#dns-acl-#{acl["id"]} button[phx-click='edit']") |> render_click()
    view |> element("#dns-acl-#{acl["id"]} button[phx-click='delete']") |> render_click()

    view
    |> element("#dns-acl-service-selector a[data-service-id='#{alternate.service["id"]}']")
    |> render_click()

    assert_patch(view, path(alternate.worker, alternate.service))
    assert has_element?(view, "#dns-acl-form input[name='acl[name]'][value='']")
    refute has_element?(view, "#dns-acl-confirm-delete")
    render_click(view, "confirm_delete", %{"id" => acl["id"]})
    submit(view, "alternate", "")

    assert {:ok, ^acl} =
             Domain.get_dns_acl(selected.worker["id"], selected.service["id"], acl["id"])

    assert {:ok, [%{"name" => "alternate"}]} =
             Domain.list_dns_acls(alternate.worker["id"], alternate.service["id"])
  end

  test "malformed, unknown and cross-Worker Service paths cannot expose forms or mutate", %{
    conn: conn
  } do
    selected = scope()
    other = scope("acl-other")
    before_read = snapshot()

    for route <- [
          "/server/bad!worker/dns/acl",
          selector_path(selected.worker) <> "/dns",
          selector_path(selected.worker) <> "/0123456789abcdef",
          selector_path(selected.worker) <> "/#{Ecto.UUID.generate()}",
          path(selected.worker, other.service)
        ] do
      {:ok, view, _html} = live(conn, route)
      assert has_element?(view, "#dns-acl-error")
      refute has_element?(view, "#dns-acl-form")

      render_submit(view, "save", %{
        "acl" => fields("forged", "")
      })

      render_click(view, "edit", %{"id" => "not-a-uuid"})
      render_click(view, "edit", %{"id" => "0123456789abcdef"})
      render_click(view, "delete", %{"id" => Ecto.UUID.generate()})
    end

    assert snapshot() == before_read
    assert {:ok, []} = Domain.list_dns_acls(selected.worker["id"], selected.service["id"])
  end

  test "inline validation counts description codepoints, rejects NUL and never writes", %{
    conn: conn
  } do
    selected = scope()
    {:ok, view, _html} = live(conn, path(selected.worker, selected.service))
    before_read = snapshot()
    render_change(view, "validate", %{"acl" => fields("valid", "allow networks 192.0.2.1/99")})
    assert has_element?(view, "#dns-acl-rules-error")

    render_change(view, "validate", %{
      "acl" => fields("valid", "", String.duplicate("e\u0301", 128))
    })

    assert has_element?(view, "#dns-acl-description-error")
    render_change(view, "validate", %{"acl" => fields("valid", "", "bad" <> <<0>>)})
    assert has_element?(view, "#dns-acl-description-error")
    render_change(view, "validate", %{"acl" => fields("valid", "", String.duplicate("😀", 255))})
    refute has_element?(view, "#dns-acl-description-error")
    assert snapshot() == before_read
    submit(view, "unicode", "", String.duplicate("😀", 255))

    assert {:ok, [%{"description" => description, "rules" => []}]} =
             Domain.list_dns_acls(selected.worker["id"], selected.service["id"])

    assert description == String.duplicate("😀", 255)
  end

  test "exact IPs normalize and editing saves mixed rule order without loss", %{conn: conn} do
    selected = scope()
    {:ok, view, _html} = live(conn, path(selected.worker, selected.service))

    submit(
      view,
      "ordered",
      "deny networks 192.0.2.1, 2001:db8::1\nallow countries JP, CA, JP\nallow any\ndeny networks",
      "Mixed rules"
    )

    assert {:ok, [acl]} = Domain.list_dns_acls(selected.worker["id"], selected.service["id"])

    assert acl["rules"] == [
             %{
               "action" => "deny",
               "kind" => "networks",
               "networks" => ["192.0.2.1/32", "2001:db8::1/128"]
             },
             %{"action" => "allow", "kind" => "countries", "countries" => ["CA", "JP"]},
             %{"action" => "allow", "kind" => "any"},
             %{"action" => "deny", "kind" => "networks", "networks" => []}
           ]

    view |> element("#dns-acl-#{acl["id"]} button[phx-click='edit']") |> render_click()
    submit(view, "ordered-renamed", rules_text(view), "Mixed rules retained")

    assert {:ok, renamed} =
             Domain.get_dns_acl(selected.worker["id"], selected.service["id"], acl["id"])

    assert renamed["rules"] == acl["rules"]
    assert renamed["id"] == acl["id"]
  end

  test "all four presets populate only empty editors without silent replacement", %{conn: conn} do
    selected = scope()
    {:ok, view, _html} = live(conn, path(selected.worker, selected.service))

    for preset <- ~w(any none localhost localnets) do
      before_read = snapshot()

      render_submit(view, "save", %{
        "acl" => fields("preset-#{preset}", ""),
        "operation" => "apply_preset",
        "preset" => preset
      })

      assert snapshot() == before_read
      {:ok, expected} = DnsAcls.preset_rules(preset)
      submit(view, "preset-#{preset}", rules_text(view))
      assert {:ok, acls} = Domain.list_dns_acls(selected.worker["id"], selected.service["id"])
      assert Enum.find(acls, &(&1["name"] == "preset-#{preset}"))["rules"] == expected
    end

    before_read = snapshot()

    render_submit(view, "save", %{
      "acl" => fields("retained", "deny any", "Typed description"),
      "operation" => "apply_preset",
      "preset" => "any"
    })

    assert has_element?(view, "#dns-acl-error", "existing rules were retained")
    assert rules_text(view) == "deny any"
    assert has_element?(view, "input[name='acl[description]'][value='Typed description']")

    render_submit(view, "save", %{
      "acl" => fields("unknown", ""),
      "operation" => "apply_preset",
      "preset" => "unknown"
    })

    assert has_element?(view, "#dns-acl-error")
    assert rules_text(view) == ""
    assert snapshot() == before_read
  end

  test "country search retains selections and append uses latest submitted text without saving",
       %{conn: conn} do
    selected = scope()
    {:ok, view, _html} = live(conn, path(selected.worker, selected.service))
    before_read = snapshot()
    view |> element("#dns-acl-country-US") |> render_click()

    render_change(view, "validate", %{
      "acl" => fields("countries", "deny any"),
      "country_search" => "canada"
    })

    assert has_element?(view, "#dns-acl-country-CA")
    refute has_element?(view, "#dns-acl-country-US")
    assert has_element?(view, "[data-selected-country-code='US']")
    view |> element("#dns-acl-country-CA") |> render_click()
    view |> element("button[phx-click='clear_country_search']") |> render_click()
    assert has_element?(view, "#dns-acl-country-US[checked]")
    assert has_element?(view, "#dns-acl-country-CA[checked]")

    render_submit(view, "save", %{
      "acl" => fields("countries", "deny networks 192.0.2.1", "Latest typed fields"),
      "operation" => "append_countries",
      "country_action" => "deny"
    })

    assert rules_text(view) == "deny networks 192.0.2.1\ndeny countries CA, US"
    assert has_element?(view, "input[name='acl[description]'][value='Latest typed fields']")
    refute has_element?(view, "[data-selected-country-code]")
    assert snapshot() == before_read
    submit(view, "countries", rules_text(view), "Latest typed fields")
    assert {:ok, [acl]} = Domain.list_dns_acls(selected.worker["id"], selected.service["id"])

    assert List.last(acl["rules"]) == %{
             "action" => "deny",
             "kind" => "countries",
             "countries" => ["CA", "US"]
           }
  end

  test "invalid or empty country selections do not append or fabricate rules", %{conn: conn} do
    selected = scope()
    {:ok, view, _html} = live(conn, path(selected.worker, selected.service))
    before_read = snapshot()
    render_click(view, "toggle_country", %{"code" => "XX"})
    assert has_element?(view, "#dns-acl-error", "Unknown ISO")

    render_submit(view, "save", %{
      "acl" => fields("empty", "deny any"),
      "operation" => "append_countries",
      "country_action" => "allow"
    })

    assert has_element?(view, "#dns-acl-error", "Select countries")
    assert rules_text(view) == "deny any"
    assert snapshot() == before_read
  end

  test "name and description filters are read-only and CSV exports all current scoped ACLs safely",
       %{conn: conn} do
    selected = scope()
    other = scope("acl-other")
    create_acl(other, "excluded")

    first =
      create_acl(selected, "first", "=HYPERLINK(\"x\"),line\nnext", [
        %{"action" => "deny", "kind" => "any"}
      ])

    second = create_acl(selected, "second", "Find by DESCRIPTION")
    {:ok, view, _html} = live(conn, path(selected.worker, selected.service))
    before_read = snapshot()
    render_change(view, "filter", %{"filter" => "description"})
    refute has_element?(view, "#dns-acl-#{first["id"]}")
    assert has_element?(view, "#dns-acl-#{second["id"]}")
    assert snapshot() == before_read
    create_acl(selected, "new-after-mount")
    before_export = snapshot()
    assert has_element?(view, "#dns-acl-export[phx-hook='CsvDownload']")
    view |> element("#dns-acl-export") |> render_click()
    assert_push_event(view, "download_csv", %{content: csv, filename: filename})
    assert csv =~ "Name,Description,Rules\r\n"
    assert csv =~ "first,\"'=HYPERLINK(\"\"x\"\"),line\nnext\",deny any\r\n"
    assert csv =~ "second,Find by DESCRIPTION,\r\n"
    assert csv =~ "new-after-mount,,\r\n"
    refute csv =~ "excluded"
    assert filename =~ selected.service["id"]
    assert snapshot() == before_export
  end

  defp submit(view, name, rules, description \\ "") do
    view
    |> form("#dns-acl-form", acl: %{name: name, rules: rules, description: description})
    |> render_submit()
  end

  defp fields(name, rules, description \\ ""),
    do: %{"name" => name, "description" => description, "rules" => rules}

  defp rules_text(view),
    do:
      view
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#dns-acl-rules")
      |> LazyHTML.text()

  defp scope(worker_id \\ "acl-worker", instance_id \\ "dns") do
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

  defp create_acl(selected, name, description \\ "", rules \\ []) do
    mutate("create_dns_acl", %{
      "worker_id" => selected.worker["id"],
      "service_id" => selected.service["id"],
      "name" => name,
      "description" => description,
      "rules" => rules
    })
  end

  defp update_acl(selected, acl, name) do
    mutate("update_dns_acl", %{
      "worker_id" => selected.worker["id"],
      "service_id" => selected.service["id"],
      "id" => acl["id"],
      "expected_revision" => acl["revision"],
      "name" => name,
      "description" => acl["description"],
      "rules" => acl["rules"]
    })
  end

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "acl-ui-test", Ecto.UUID.generate())
    result
  end

  defp selector_path(worker), do: "/server/#{worker["id"]}/dns/acl"
  defp path(worker, service), do: selector_path(worker) <> "/#{service["id"]}"

  defp business_snapshot do
    for schema <- [Worker, Service, Assignment, Zone, Rrset, ResourceVersion, Target],
        into: %{},
        do: {schema, Repo.all(schema) |> Enum.sort_by(& &1.id)}
  end

  defp snapshot do
    Map.merge(business_snapshot(), %{
      acls: Repo.all(DnsAcl) |> Enum.sort_by(& &1.id),
      audit: Repo.all(Audit),
      idempotency: Repo.all(Idempotency)
    })
  end
end
