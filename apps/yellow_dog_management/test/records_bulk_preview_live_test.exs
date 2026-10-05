defmodule YellowDog.Management.RecordsBulkPreviewLiveTest do
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
    Service,
    Target,
    Worker
  }

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    zone = mutate("create_zone", DomainFixtures.zone())
    %{conn: build_conn(), zone: zone, path: "/management/zones/#{zone["id"]}/records/bulk"}
  end

  test "initial bulk form has no preview and cannot submit without one", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    before_read = snapshot()
    {:ok, view, _html} = live(conn, path)
    assert has_element?(view, "#bulk-record-form[phx-change='preview_bulk']")
    assert has_element?(view, "#bulk-record-form textarea[phx-debounce]")
    assert has_element?(view, "#bulk-record-save[disabled]")
    refute has_element?(view, "#bulk-record-preview")
    input = Jason.encode!([address("www.example.test.", "192.0.2.20")])
    assert render_submit(view, "save_bulk", %{"bulk" => %{"records" => input}}) =~ ~r/preview/i
    assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    assert snapshot() == before_read
    assert Plug.Conn.get_resp_header(get(conn, path), "www-authenticate") == []
  end

  test "preview shows canonical appended records, type counts and full-candidate totals without writes",
       %{conn: conn, zone: zone, path: path} do
    input =
      Jason.encode!([
        address("WWW.Example.Test", "192.0.2.20"),
        address("www.example.test.", "192.0.2.21"),
        %{
          "name" => "EXAMPLE.TEST",
          "type" => "NS",
          "ttl" => 300,
          "data" => %{"host" => "NS2.EXAMPLE.TEST"}
        }
      ])

    before_read = snapshot()
    {:ok, view, _html} = live(conn, path)
    preview(view, input)
    html = view |> element("#bulk-record-preview") |> render()
    assert html =~ "www.example.test."
    assert html =~ "ns2.example.test."
    assert html =~ "192.0.2.20"
    assert html =~ "192.0.2.21"
    refute html =~ "WWW.Example.Test"

    assert has_element?(
             view,
             "#bulk-record-count",
             "Append 3 records to 3 existing records; total 6. Draft revision 1"
           )

    assert has_element?(view, "#bulk-record-preview-table")
    assert preview_text(view, "#bulk-record-types") =~ ~r/\bA\D+2\b/
    assert preview_text(view, "#bulk-record-types") =~ ~r/\bNS\D+1\b/
    refute has_element?(view, "#bulk-record-save[disabled]")
    assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    assert snapshot() == before_read
  end

  test "save persists exactly the reviewed full candidate and preserves immutable history", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    version =
      mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})

    appended = [
      address("WWW.EXAMPLE.TEST", "192.0.2.20"),
      address("mail.example.test.", "192.0.2.21")
    ]

    input = Jason.encode!(appended)
    expected = normalized(zone, zone["records"] ++ appended)
    before_read = receipts()
    {:ok, view, _html} = live(conn, path)
    preview(view, input)
    assert receipts() == before_read
    view |> form("#bulk-record-form", bulk: %{records: input}) |> render_submit()
    assert_patch(view, records_path(zone))
    assert {:ok, saved} = Domain.get_zone(zone["id"])
    assert saved["revision"] == zone["revision"] + 1
    assert normalized(saved, saved["records"])["content"] == expected["content"]
    assert normalized(saved, saved["records"])["digest"] == expected["digest"]
    assert length(saved["records"]) == 5
    assert Domain.list_versions(zone["id"]) == [version]

    assert {length(Repo.all(Audit)), length(Repo.all(Idempotency))} ==
             {length(elem(before_read, 0)) + 1, length(elem(before_read, 1)) + 1}
  end

  test "bulk preview and append preserve a stopped service's assigned version and prepared export",
       %{
         conn: conn,
         zone: zone
       } do
    worker =
      mutate("create_worker", %{
        "id" => "bulk-export-worker",
        "name" => "Bulk Export Worker",
        "expected_capabilities" => ["dns"]
      })

    service =
      mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"], "stopped"))

    version =
      mutate("confirm_zone", %{"id" => zone["id"], "expected_revision" => zone["revision"]})

    assert {:ok, current_worker} = Domain.get_worker(worker["id"])

    assignment =
      mutate("assign", %{
        "worker_id" => worker["id"],
        "service_id" => service["id"],
        "resource_version_id" => version["id"],
        "expected_revision" => current_worker["revision"]
      })

    confirmation =
      mutate("confirm_target", %{
        "worker_id" => worker["id"],
        "expected_revision" => assignment["worker_revision"]
      })

    assert {:ok, prepared_worker} = Domain.get_worker(worker["id"])
    assert [stored_service] = prepared_worker["services"]
    assert stored_service["desired_state"] == "stopped"
    assert stored_service["actual_state"] == "unknown"
    assert [stored_assignment] = prepared_worker["assignments"]
    assert stored_assignment["service_id"] == service["id"]
    assert stored_assignment["resource_version_id"] == version["id"]
    assert {:ok, target} = Domain.get_target(worker["id"], confirmation["revision"])
    assert target["status"] == "prepared"
    assert {:ok, exported} = ConfigCompiler.export_target(worker["id"], target["revision"])
    assert exported["toml"] != ""
    assert exported["plan"] == target["plan"]
    assert exported["digest"] == target["digest"]
    before_prepared = prepared_snapshot()
    before_read = snapshot()
    records_path = "/server/#{worker["id"]}/dns/zones/#{zone["id"]}/records"
    appended = [address("www.example.test.", "192.0.2.20")]
    input = Jason.encode!(appended)
    expected = normalized(zone, zone["records"] ++ appended)
    {:ok, view, _html} = live(conn, records_path <> "/bulk")
    preview(view, input)
    assert has_element?(view, "#bulk-record-preview", "www.example.test.")
    assert snapshot() == before_read
    assert prepared_snapshot() == before_prepared
    assert {:ok, ^exported} = ConfigCompiler.export_target(worker["id"])

    view |> form("#bulk-record-form", bulk: %{records: input}) |> render_submit()
    assert_patch(view, records_path)
    assert {:ok, saved} = Domain.get_zone(zone["id"])
    assert saved["revision"] == zone["revision"] + 1
    assert normalized(saved, saved["records"])["content"] == expected["content"]
    assert Domain.list_versions(zone["id"]) == [version]
    assert {:ok, ^prepared_worker} = Domain.get_worker(worker["id"])
    assert prepared_snapshot() == before_prepared
    assert {:ok, ^target} = Domain.get_target(worker["id"])
    assert {:ok, ^exported} = ConfigCompiler.export_target(worker["id"], target["revision"])
    assert {:ok, ^exported} = ConfigCompiler.export_target(worker["id"])
  end

  test "submit cannot silently preview a changed source even with identical canonical meaning", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    records = [address("www.example.test.", "192.0.2.20")]
    input = Jason.encode!(records)
    different_source = Jason.encode!(records, pretty: true)
    assert input != different_source
    {:ok, view, _html} = live(conn, path)
    preview(view, input)
    before_read = snapshot()

    assert render_submit(view, "save_bulk", %{"bulk" => %{"records" => different_source}}) =~
             ~r/preview/i

    assert has_element?(view, "#bulk-record-save[disabled]")
    refute has_element?(view, "#bulk-record-preview")
    assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    assert snapshot() == before_read
  end

  test "valid input changes recalculate preview rather than retaining a prior candidate", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    first = Jason.encode!([address("first.example.test.", "192.0.2.20")])
    second = Jason.encode!([address("second.example.test.", "192.0.2.21")])
    {:ok, view, _html} = live(conn, path)
    before_read = snapshot()
    preview(view, first)
    assert has_element?(view, "#bulk-record-preview", "first.example.test.")
    preview(view, second)
    assert has_element?(view, "#bulk-record-preview", "second.example.test.")
    refute has_element?(view, "#bulk-record-preview", "first.example.test.")
    assert snapshot() == before_read
    view |> form("#bulk-record-form", bulk: %{records: second}) |> render_submit()
    assert_patch(view, records_path(zone))
    assert {:ok, saved} = Domain.get_zone(zone["id"])
    assert Enum.any?(saved["records"], &(&1["name"] == "second.example.test."))
    refute Enum.any?(saved["records"], &(&1["name"] == "first.example.test."))
  end

  test "malformed and invalid complete candidates clear preview and cannot partially write", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    valid = address("www.example.test.", "192.0.2.20")
    soa = Enum.find(zone["records"], &(&1["type"] == "SOA"))
    existing_address = Enum.find(zone["records"], &(&1["type"] == "A"))

    inputs = [
      "",
      "{",
      "{}",
      "[]",
      "[1]",
      "[null]",
      "[[]]",
      Jason.encode!([valid, address("bad.example.test.", "invalid")]),
      Jason.encode!([Map.put(valid, "type", "AAAA")]),
      Jason.encode!([Map.put(valid, "extra", true)]),
      Jason.encode!([address("outside.test.", "192.0.2.20")]),
      Jason.encode!([soa]),
      Jason.encode!([existing_address]),
      Jason.encode!([valid, valid]),
      Jason.encode!([Map.put(existing_address, "ttl", 600)]),
      Jason.encode!([Map.put(valid, "ttl", "300")]),
      Jason.encode!([Map.put(valid, "data", [])]),
      Jason.encode!([Map.put(valid, "name", "<img src=x onerror=alert(1)>")])
    ]

    {:ok, view, _html} = live(conn, path)
    before_read = snapshot()

    for input <- inputs do
      preview(view, Jason.encode!([valid]))
      preview(view, input)
      refute has_element?(view, "#bulk-record-preview")
      assert has_element?(view, "#bulk-record-save[disabled]")
      refute has_element?(view, "img[src='x']")
      assert render_submit(view, "save_bulk", %{"bulk" => %{"records" => input}}) =~ ~r/preview/i
      assert {:ok, ^zone} = Domain.get_zone(zone["id"])
      assert snapshot() == before_read
    end
  end

  test "the byte bound accepts one MiB and rejects larger input before any mutation", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    json = Jason.encode!([address("www.example.test.", "192.0.2.20")])
    bounded = String.duplicate(" ", 1_048_576 - byte_size(json)) <> json
    assert byte_size(bounded) == 1_048_576
    {:ok, view, _html} = live(conn, path)
    before_read = snapshot()
    preview(view, bounded)
    assert has_element?(view, "#bulk-record-preview")
    assert preview(view, " " <> bounded) =~ "1 MiB"
    refute has_element?(view, "#bulk-record-preview")
    assert has_element?(view, "#bulk-record-save[disabled]")
    assert {:ok, ^zone} = Domain.get_zone(zone["id"])
    assert snapshot() == before_read
  end

  test "the shared record limit applies to existing plus appended records", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    records =
      Enum.map(1..1022, fn index -> address("record#{index}.example.test.", "192.0.2.20") end)

    assert {:error, _errors} =
             ConfigSpec.normalize_resource(resource(zone, zone["records"] ++ records))

    {:ok, view, _html} = live(conn, path)
    before_read = snapshot()
    preview(view, Jason.encode!(records))
    assert has_element?(view, "#record-error")
    refute has_element?(view, "#bulk-record-preview")
    assert has_element?(view, "#bulk-record-save[disabled]")
    assert snapshot() == before_read
  end

  test "refresh detects a changed revision without rebasing entered source or the preview", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    input = Jason.encode!([address("www.example.test.", "192.0.2.20")])
    {:ok, view, _html} = live(conn, path)
    preview(view, input)
    current = append_concurrently(zone)
    before_read = snapshot()
    assert view |> element("#record-refresh") |> render_click() =~ "reopen"
    assert has_element?(view, "#bulk-record-form textarea", input)
    refute has_element?(view, "#bulk-record-preview")
    assert has_element?(view, "#bulk-record-save[disabled]")
    render_submit(view, "save_bulk", %{"bulk" => %{"records" => input}})
    assert {:ok, ^current} = Domain.get_zone(zone["id"])
    assert snapshot() == before_read
  end

  test "a reviewed candidate commits with original CAS and never retries a concurrent edit", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    input = Jason.encode!([address("www.example.test.", "192.0.2.20")])
    {:ok, view, _html} = live(conn, path)
    preview(view, input)
    current = append_concurrently(zone)
    before_receipts = receipts()
    assert render_submit(view, "save_bulk", %{"bulk" => %{"records" => input}}) =~ "revision"
    assert {:ok, ^current} = Domain.get_zone(zone["id"])
    audits = Repo.all(Audit) -- elem(before_receipts, 0)
    assert [audit] = audits
    assert audit.operation == "update_zone"
    assert audit.request["expected_revision"] == zone["revision"]
    assert audit.result["error"]["code"] == "revision_conflict"
    assert length(Repo.all(Idempotency)) == length(elem(before_receipts, 1)) + 1
  end

  test "leaving and reopening bulk clears source and preview without writing", %{
    conn: conn,
    zone: zone,
    path: path
  } do
    {:ok, view, _html} = live(conn, path)
    before_read = snapshot()
    preview(view, Jason.encode!([address("www.example.test.", "192.0.2.20")]))
    view |> element("a", "Records") |> render_click()
    assert_patch(view, records_path(zone))
    view |> element("a", "Bulk Add") |> render_click()
    assert_patch(view, path)
    refute has_element?(view, "#bulk-record-preview")
    assert has_element?(view, "#bulk-record-save[disabled]")
    refute has_element?(view, "#bulk-record-form textarea", "www.example.test.")
    assert snapshot() == before_read
  end

  test "unknown scopes and wrong-route previews cannot authorize any mutation", %{
    conn: conn,
    zone: zone
  } do
    input = Jason.encode!([address("www.example.test.", "192.0.2.20")])
    before_read = snapshot()

    for path <- [
          records_path(zone),
          records_path(zone) <> "/new",
          records_path(zone) <> "/0/edit",
          "/server/missing/dns/zones/#{zone["id"]}/records/bulk",
          "/management/zones/#{Ecto.UUID.generate()}/records/bulk"
        ] do
      {:ok, view, _html} = live(conn, path)
      render_change(view, "preview_bulk", %{"bulk" => %{"records" => input}})
      refute has_element?(view, "#bulk-record-preview")
      render_submit(view, "save_bulk", %{"bulk" => %{"records" => input}})
      assert snapshot() == before_read
    end
  end

  defp preview(view, input),
    do: view |> form("#bulk-record-form", bulk: %{records: input}) |> render_change()

  defp preview_text(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> LazyHTML.text(separator: " ")
  end

  defp normalized(zone, records) do
    {:ok, candidate} = ConfigSpec.normalize_resource(resource(zone, records))
    candidate
  end

  defp resource(zone, records),
    do: %{
      "schema_version" => 1,
      "id" => zone["id"],
      "type" => "dns_zone",
      "version" => 1,
      "content" => %{"name" => zone["name"], "records" => records}
    }

  defp append_concurrently(zone),
    do:
      mutate("update_zone", %{
        "id" => zone["id"],
        "expected_revision" => zone["revision"],
        "name" => zone["name"],
        "records" => zone["records"] ++ [address("concurrent.example.test.", "192.0.2.30")]
      })

  defp records_path(zone), do: "/management/zones/#{zone["id"]}/records"

  defp address(name, value),
    do: %{"name" => name, "type" => "A", "ttl" => 300, "data" => %{"address" => value}}

  defp receipts, do: {Repo.all(Audit), Repo.all(Idempotency)}

  defp prepared_snapshot do
    Enum.map([Worker, Service, Assignment, Target, ResourceVersion], fn schema ->
      schema |> Repo.all() |> Enum.sort_by(& &1.id)
    end)
  end

  defp snapshot,
    do: {Domain.list_workers(), Domain.list_zones(), Repo.all(ResourceVersion), receipts()}

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
