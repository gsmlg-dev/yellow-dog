defmodule YellowDog.Management.RecordsLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Audit, Domain, DomainFixtures, Idempotency, Repo}
  alias YellowDog.ManagementUI.DnsRecordExports
  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    zone = mutate("create_zone", DomainFixtures.zone())
    %{conn: build_conn(), zone: zone, path: "/management/zones/#{zone["id"]}/records"}
  end

  test "zero Worker record creation, editing and deletion persist drafts", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    assert Domain.list_workers() == []
    {:ok, view, _html} = live(conn, path <> "/new")
    view |> form("#record-form", record: address("www", "192.0.2.20")) |> render_submit()
    assert_patch(view, path)
    assert {:ok, saved} = Domain.get_zone(zone["id"])
    assert saved["revision"] == 2
    index = Enum.find_index(saved["records"], &(&1["name"] == "www.example.test."))
    view |> element("#record-#{index} a", "Edit") |> render_click()
    assert_patch(view, path <> "/#{index}/edit")

    view
    |> form("#record-form", record: address("www.example.test.", "192.0.2.21"))
    |> render_submit()

    assert_patch(view, path)
    assert {:ok, edited} = Domain.get_zone(zone["id"])
    assert Enum.any?(edited["records"], &(&1["data"]["address"] == "192.0.2.21"))
    index = Enum.find_index(edited["records"], &(&1["name"] == "www.example.test."))
    view |> element("#record-#{index} button[phx-click='delete_record']") |> render_click()
    assert_patch(view, path)
    assert {:ok, deleted} = Domain.get_zone(zone["id"])
    assert deleted["records"] == zone["records"]
    assert deleted["revision"] == 4
    assert Domain.list_versions(zone["id"]) == [version]
  end

  test "SOA and NS use their own structured data fields", %{conn: conn, zone: zone, path: path} do
    soa_index = Enum.find_index(zone["records"], &(&1["type"] == "SOA"))
    {:ok, view, _html} = live(conn, path <> "/#{soa_index}/edit")
    assert has_element?(view, "input[name='record[data][mname]']")
    view |> form("#record-form", record: %{data: %{serial: "2"}}) |> render_submit()
    assert_patch(view, path)
    assert {:ok, saved} = Domain.get_zone(zone["id"])
    assert Enum.find(saved["records"], &(&1["type"] == "SOA"))["data"]["serial"] == 2
    view |> element("a", "New Record") |> render_click()
    view |> form("#record-form", record: %{type: "NS"}) |> render_change()
    assert has_element?(view, "input[name='record[data][host]']")
    refute has_element?(view, "input[name='record[data][address]']")

    view
    |> form("#record-form",
      record: %{name: "@", type: "NS", ttl: "300", data: %{host: "ns2.example.test."}}
    )
    |> render_submit()

    assert_patch(view, path)
    assert {:ok, saved} = Domain.get_zone(zone["id"])

    assert Enum.any?(
             saved["records"],
             &(&1["name"] == "example.test." and &1["data"]["host"] == "ns2.example.test.")
           )
  end

  test "bulk append is atomic and retains canonical JSON", %{conn: conn, zone: zone, path: path} do
    {:ok, view, _html} = live(conn, path <> "/bulk")

    records = [
      address("www.example.test.", "192.0.2.20"),
      address("mail.example.test.", "192.0.2.21")
    ]

    input = Jason.encode!(records)
    view |> form("#bulk-record-form", bulk: %{records: input}) |> render_change()
    view |> form("#bulk-record-form", bulk: %{records: input}) |> render_submit()
    assert_patch(view, path)
    assert {:ok, saved} = Domain.get_zone(zone["id"])
    assert saved["revision"] == 2
    assert length(saved["records"]) == 5
  end

  test "invalid bulk content never partially appends", %{conn: conn, zone: zone, path: path} do
    {:ok, view, _html} = live(conn, path <> "/bulk")

    invalid =
      Jason.encode!([
        address("www.example.test.", "192.0.2.20"),
        address("bad.example.test.", "invalid")
      ])

    view |> form("#bulk-record-form", bulk: %{records: invalid}) |> render_change()
    assert has_element?(view, "#record-error")
    assert has_element?(view, "#bulk-record-save[disabled]")

    assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    assert has_element?(view, "#bulk-record-form textarea", "invalid")

    for invalid <- [
          "{",
          "{}",
          "[]",
          "[1]",
          Jason.encode!([Map.put(address("www.example.test.", "192.0.2.20"), "type", "AAAA")])
        ] do
      view |> form("#bulk-record-form", bulk: %{records: invalid}) |> render_change()
      assert {:ok, ^zone} = Domain.get_zone(zone["id"])
      assert has_element?(view, "#record-error")
    end
  end

  test "bulk JSON is bounded to one MiB before decoding", %{conn: conn, zone: zone, path: path} do
    {:ok, view, _html} = live(conn, path <> "/bulk")
    oversized = String.duplicate(" ", 1_048_577)

    assert view |> form("#bulk-record-form", bulk: %{records: oversized}) |> render_change() =~
             "1 MiB"

    assert {:ok, ^zone} = Domain.get_zone(zone["id"])
  end

  test "stale single, bulk and deletion actions cannot overwrite concurrent drafts", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    {:ok, single, _html} = live(conn, path <> "/new")
    {:ok, bulk, _html} = live(conn, path <> "/bulk")
    {:ok, listing, _html} = live(conn, path)
    index = Enum.find_index(zone["records"], &(&1["type"] == "A"))
    {:ok, editing, _html} = live(conn, path <> "/#{index}/edit")
    bulk_input = Jason.encode!([address("www.example.test.", "192.0.2.20")])
    bulk |> form("#bulk-record-form", bulk: %{records: bulk_input}) |> render_change()

    concurrent =
      mutate("update_zone", %{
        "id" => zone["id"],
        "expected_revision" => 1,
        "name" => zone["name"],
        "records" => zone["records"] ++ [address("concurrent.example.test.", "192.0.2.30")]
      })

    assert single |> form("#record-form", record: address("www", "192.0.2.20")) |> render_submit() =~
             "revision"

    assert bulk
           |> form("#bulk-record-form",
             bulk: %{records: bulk_input}
           )
           |> render_submit() =~ "revision"

    assert listing |> element("#record-0 button[phx-click='delete_record']") |> render_click() =~
             "revision"

    assert editing
           |> form("#record-form", record: %{data: %{address: "192.0.2.40"}})
           |> render_submit() =~ "revision"

    assert {:ok, ^concurrent} = Domain.get_zone(zone["id"])
  end

  test "malformed and out-of-range ordinals render errors without mutation", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    for ordinal <- ["-1", "+1", "1x", "01", "999999999999999999999", "3"] do
      {:ok, view, html} = live(conn, path <> "/#{ordinal}/edit")
      assert html =~ "Invalid record ordinal"
      refute has_element?(view, "#record-form")
      render_click(view, "save", %{"record" => address("www", "192.0.2.20")})
      assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    end

    {:ok, view, _html} = live(conn, path)

    for ordinal <- ["-1", "1x", "01", "999999999999999999999", "3"] do
      assert render_click(view, "delete_record", %{"rr_index" => ordinal}) =~
               "Invalid record ordinal"

      assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    end
  end

  test "unknown Worker and unknown Zone scopes cannot mutate", %{conn: conn, zone: zone} do
    for suffix <- ["", "/new", "/bulk", "/0/edit"] do
      {:ok, view, html} = live(conn, "/server/missing/dns/zones/#{zone["id"]}/records" <> suffix)
      assert html =~ "Worker"
      assert has_element?(view, "#record-scope-error")
      render_click(view, "save", %{"record" => address("www", "192.0.2.20")})

      render_click(view, "save_bulk", %{
        "bulk" => %{"records" => Jason.encode!([address("www.example.test.", "192.0.2.20")])}
      })

      render_click(view, "delete_record", %{"rr_index" => "0"})
      assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    end

    for id <- [Ecto.UUID.generate(), "not-a-uuid"] do
      {:ok, view, _html} = live(conn, "/management/zones/#{id}/records/new")
      assert has_element?(view, "#record-scope-error")
      render_click(view, "save", %{"record" => address("www", "192.0.2.20")})
      assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    end
  end

  test "valid Worker routes retain scope and immutable versions stay unchanged", %{
    conn: conn,
    zone: zone
  } do
    mutate("create_worker", %{
      "id" => "records-worker",
      "name" => "Records Worker",
      "expected_capabilities" => ["dns"]
    })

    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    path = "/server/records-worker/dns/zones/#{zone["id"]}/records"
    {:ok, view, _html} = live(conn, path <> "/new")
    view |> form("#record-form", record: address("www", "192.0.2.20")) |> render_submit()
    assert_patch(view, path)
    assert has_element?(view, "a[href='#{path}/bulk']", "Bulk Add")
    assert Domain.list_versions(zone["id"]) == [version]
    assert render(view) =~ "runtime state is unknown"
  end

  test "contract failures on required record deletion leave the draft intact", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    {:ok, view, _html} = live(conn, path)
    soa_index = Enum.find_index(zone["records"], &(&1["type"] == "SOA"))

    assert view
           |> element("#record-#{soa_index} button[phx-click='delete_record']")
           |> render_click() =~ "validation failed"

    assert {:ok, ^zone} = Domain.get_zone(zone["id"])
  end

  test "malformed single-record payloads and wrong-route events fail without crashing", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    {:ok, view, _html} = live(conn, path <> "/new")

    assert render_submit(view, "save", %{
             "record" => %{"name" => "www", "type" => "A", "ttl" => "300", "data" => "invalid"}
           }) =~ "structured data"

    assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    assert render_submit(view, "save_bulk", %{"bulk" => %{"records" => "[]"}}) =~ "does not match"
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
    test "global Records routes ignore a #{label} server_id query", %{
      conn: conn,
      zone: zone,
      path: path
    } do
      mutate("create_worker", %{"id" => "scope-worker", "name" => "Scope Worker"})
      before_visit = {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()}

      for suffix <- ["", "/new", "/bulk", "/0/edit"] do
        {:ok, view, _html} = live(conn, path <> suffix <> "?" <> @scope_query)
        refute has_element?(view, "#record-scope-error")
        assert has_element?(view, "a[href='#{path}/new']", "New Record")
        assert has_element?(view, "a[href='/management/zones/#{zone["id"]}/edit']")
        assert {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()} == before_visit
      end
    end
  end

  @tag :scope_regression
  test "Records edit identity and navigation come only from path Worker, Zone and ordinal", %{
    conn: conn,
    zone: zone,
    path: global_path
  } do
    mutate("create_worker", %{"id" => "Scope.Worker_1", "name" => "Path Worker"})
    mutate("create_worker", %{"id" => "other-worker", "name" => "Other Worker"})
    other = mutate("create_zone", DomainFixtures.zone("other.test."))
    before_visit = {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()}
    index = Enum.find_index(zone["records"], &(&1["type"] == "A"))
    scoped_path = "/server/Scope.Worker_1/dns/zones/#{zone["id"]}/records"

    for path <- [global_path, scoped_path],
        query <- [
          "server_id=other-worker",
          "server_id[]=other-worker",
          "server_id[id]=other-worker"
        ] do
      uri = "#{path}/#{index}/edit?#{query}&zone_id[]=#{other["id"]}&rr_index[]=999"
      {:ok, view, _html} = live(conn, uri)

      assert has_element?(
               view,
               "#record-form input[name='record[data][address]'][value='192.0.2.10']"
             )

      assert has_element?(view, "a[href='#{path}/new']", "New Record")
      assert {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()} == before_visit
    end
  end

  @tag :scope_regression
  test "unknown scoped Records remain mutation-blocked despite query overrides", %{
    conn: conn,
    zone: zone
  } do
    mutate("create_worker", %{"id" => "scope-worker", "name" => "Scope Worker"})
    before_visit = {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()}

    for worker_id <- ["missing", "invalid!"],
        query <- [
          "server_id=scope-worker",
          "server_id[]=scope-worker",
          "server_id[id]=scope-worker"
        ] do
      path = "/server/#{worker_id}/dns/zones/#{zone["id"]}/records/new?#{query}"
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "#record-scope-error")
      render_click(view, "save", %{"record" => address("www", "192.0.2.20")})

      render_click(view, "save_bulk", %{
        "bulk" => %{"records" => Jason.encode!([address("www", "192.0.2.20")])}
      })

      render_click(view, "delete_record", %{"rr_index" => "0"})
      assert {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()} == before_visit
    end
  end

  test "owner and type filters preserve original ordinals and escape input without writes", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    before_read = read_snapshot()
    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#record-count", "Showing 3 of 3")
    index = Enum.find_index(zone["records"], &(&1["type"] == "A"))
    filter(view, "NS1.EXAMPLE", "A")
    assert has_element?(view, "#record-count", "Showing 1 of 3")

    assert has_element?(
             view,
             "#record-#{index}[data-rr-index='#{index}'] a[href='#{path}/#{index}/edit']"
           )

    assert has_element?(view, "#record-#{index} button[phx-value-rr_index='#{index}']")
    refute has_element?(view, "#record-0")

    for type <- ~w(SOA NS A) do
      filter(view, "", type)
      assert has_element?(view, "#record-count", "Showing 1 of 3")
      ordinal = Enum.find_index(zone["records"], &(&1["type"] == type))
      assert has_element?(view, "#record-#{ordinal}")
    end

    assert filter(view, "<img src=x onerror=alert(1)>", "all") =~ "&lt;img"
    refute has_element?(view, "img[src='x']")
    refute has_element?(view, "#records-table tbody tr")
    assert has_element?(view, "#record-empty")
    assert has_element?(view, "#record-count", "Showing 0 of 3")
    assert read_snapshot() == before_read
  end

  test "filtered edits and deletion act on full-candidate source ordinals", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    saved = append_record(zone, address("www.example.test.", "192.0.2.20"))
    index = Enum.find_index(saved["records"], &(&1["name"] == "www.example.test."))
    {:ok, view, _html} = live(conn, path)
    filter(view, "WWW", "A")
    view |> element("#record-#{index} a", "Edit") |> render_click()
    assert_patch(view, path <> "/#{index}/edit")

    assert has_element?(
             view,
             "#record-form input[name='record[data][address]'][value='192.0.2.20']"
           )

    view |> form("#record-form", record: %{data: %{address: "192.0.2.21"}}) |> render_submit()
    assert_patch(view, path)
    assert has_element?(view, "#record-owner-filter[value='WWW']")
    assert {:ok, edited} = Domain.get_zone(zone["id"])
    assert Enum.reject(edited["records"], &(&1["name"] == "www.example.test.")) == zone["records"]
    index = Enum.find_index(edited["records"], &(&1["name"] == "www.example.test."))
    view |> element("#record-#{index} button") |> render_click()
    assert_patch(view, path)
    assert {:ok, deleted} = Domain.get_zone(zone["id"])
    assert deleted["records"] == zone["records"]
    assert has_element?(view, "#record-count", "Showing 0 of 3")
  end

  test "refresh reads current source while retaining filters and writes no audit receipts", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    {:ok, view, _html} = live(conn, path)
    filter(view, "WWW", "A")
    current = append_record(zone, address("www.example.test.", "192.0.2.20"))
    before_read = read_snapshot()
    view |> element("#record-refresh") |> render_click()
    assert has_element?(view, "#record-owner-filter[value='WWW']")
    assert has_element?(view, "#record-type-filter option[value='A'][selected]")
    assert has_element?(view, "#record-count", "Showing 1 of 4")
    ordinal = Enum.find_index(current["records"], &(&1["name"] == "www.example.test."))
    assert has_element?(view, "#record-#{ordinal}")
    assert read_snapshot() == before_read
  end

  test "refresh never silently rebinds a stale editor to a shifted record ordinal", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    ordinal = Enum.find_index(zone["records"], &(&1["type"] == "A"))
    {:ok, view, _html} = live(conn, path <> "/#{ordinal}/edit")
    view |> form("#record-form", record: %{data: %{address: "192.0.2.40"}}) |> render_change()
    current = append_record(zone, address("aaa.example.test.", "192.0.2.30"))
    before_read = read_snapshot()
    assert view |> element("#record-refresh") |> render_click() =~ "reopen"

    assert has_element?(
             view,
             "#record-form input[name='record[data][address]'][value='192.0.2.40']"
           )

    assert has_element?(view, "#record-form button[type=submit][disabled]")
    render_submit(view, "save", %{"record" => address("ns1.example.test.", "192.0.2.40")})
    assert {:ok, ^current} = Domain.get_zone(zone["id"])
    assert read_snapshot() == before_read
    view |> element("a", "Records") |> render_click()
    assert_patch(view, path)
    assert has_element?(view, "#record-count", "Showing 4 of 4")
  end

  test "CSV contains filtered typed values while BIND remains complete even for an empty filter",
       %{conn: conn, zone: zone, path: path} do
    before_read = read_snapshot()
    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#record-export-csv[phx-hook='CsvDownload']")
    assert has_element?(view, "#record-export-bind[phx-hook='TextDownload']")
    filter(view, "ns1", "A")
    view |> element("#record-export-csv") |> render_click()

    csv_payload = %{
      content: DnsRecordExports.csv(Enum.filter(zone["records"], &(&1["type"] == "A"))),
      filename: "dns_records_#{zone["id"]}.csv"
    }

    assert_push_event(view, "download_csv", ^csv_payload)

    filter(view, "no-match", "SOA")
    view |> element("#record-export-csv") |> render_click()

    empty_csv = %{
      content: "Name,Type,TTL,Data\r\n",
      filename: "dns_records_#{zone["id"]}.csv"
    }

    assert_push_event(view, "download_csv", ^empty_csv)

    view |> element("#record-export-bind") |> render_click()

    bind_payload = %{
      content: DnsRecordExports.bind(zone),
      filename: "dns_zone_#{zone["id"]}.zone"
    }

    assert_push_event(view, "download_text", ^bind_payload)

    assert read_snapshot() == before_read
  end

  test "read controls cannot retarget query or event identities and reject invalid filters", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    other = mutate("create_zone", DomainFixtures.zone("other.test."))
    before_read = read_snapshot()
    {:ok, view, _html} = live(conn, path <> "?zone_id=#{other["id"]}&rr_index=999")
    render_click(view, "refresh", %{"id" => other["id"], "zone_id" => other["id"]})
    render_click(view, "export_bind", %{"zone_id" => other["id"]})

    bind_payload = %{
      content: DnsRecordExports.bind(zone),
      filename: "dns_zone_#{zone["id"]}.zone"
    }

    assert_push_event(view, "download_text", ^bind_payload)

    for params <- [
          %{"filter" => [], "type" => "all"},
          %{"filter" => "", "type" => "AAAA"},
          %{"filter" => String.duplicate("a", 513), "type" => "all"}
        ] do
      assert render_submit(view, "filter", params) =~ "Invalid record filter"
      assert has_element?(view, "#record-count", "Showing 3 of 3")
    end

    assert read_snapshot() == before_read
  end

  test "refresh invalidates a deleted Zone and keeps its history unchanged", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    version = mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => 1})
    {:ok, view, _html} = live(conn, path)
    mutate("delete_zone", %{"id" => zone["id"], "expected_revision" => 1})
    before_read = read_snapshot()
    view |> element("#record-refresh") |> render_click()
    assert has_element?(view, "#record-scope-error")
    refute has_element?(view, "#record-export-bind")
    render_click(view, "export_bind", %{})
    assert Domain.list_versions(zone["id"]) == [version]
    assert read_snapshot() == before_read
  end

  defp filter(view, owner, type) do
    view |> form("#record-filter-form", %{filter: owner, type: type}) |> render_submit()
  end

  defp append_record(zone, record) do
    mutate("update_zone", %{
      "id" => zone["id"],
      "expected_revision" => zone["revision"],
      "name" => zone["name"],
      "records" => zone["records"] ++ [record]
    })
  end

  defp read_snapshot do
    {Domain.list_workers(), Domain.list_zones(), Repo.all(Audit), Repo.all(Idempotency)}
  end

  defp address(name, value),
    do: %{"name" => name, "type" => "A", "ttl" => 300, "data" => %{"address" => value}}

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
