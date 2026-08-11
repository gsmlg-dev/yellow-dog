defmodule YellowDog.Console.ServerDnsScopeLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Console.TestManagementTransport
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  @revision_a String.duplicate("a", 64)
  @revision_b String.duplicate("b", 64)
  @revision_c String.duplicate("c", 64)
  @observed_at "2026-08-11T03:04:05Z"

  setup do
    previous =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-console-server-dns-#{System.unique_integer([:positive])}"
      )

    Application.stop(:yellow_dog_management_core)
    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)

    Application.put_env(
      :yellow_dog_management_core,
      :transport_module,
      TestManagementTransport
    )

    Application.put_env(:yellow_dog_management_core, :request_timeout, 50)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
    start_supervised!(TestManagementTransport)

    register_server("server-a", "Alpha Server", :online)
    register_server("server-b", "Beta Server", :online)
    :ok = TestManagementTransport.connect(:server, "server-a")
    :ok = TestManagementTransport.connect(:server, "server-b")

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)

    :ok
  end

  test "overview and navigation read only the explicitly selected Server", %{conn: conn} do
    {:ok, alpha, _html} =
      mount_with(conn, "/server/server-a/dns", [view_list("alpha"), metrics("alpha")])

    alpha_html = alpha |> element("#server-dns-overview") |> render()
    assert alpha_html =~ "Alpha Server"
    assert alpha_html =~ "alpha-view"
    assert alpha_html =~ "17"
    refute alpha_html =~ "beta-view"

    for suffix <- ["views", "zones", "acl", "logs", "metrics", "providers"] do
      assert has_element?(alpha, "a[href='/server/server-a/dns/#{suffix}']")
    end

    {:ok, beta, _html} =
      mount_with(conn, "/server/server-b/dns", [view_list("beta"), metrics("beta")])

    beta_html = beta |> element("#server-dns-overview") |> render()
    assert beta_html =~ "Beta Server"
    assert beta_html =~ "beta-view"
    assert beta_html =~ "29"
    refute beta_html =~ "alpha-view"

    assert Enum.map(request_envelopes(), & &1.target_id) ==
             List.duplicate("server-a", 2) ++ List.duplicate("server-b", 2)
  end

  test "zones, records, ACLs, providers, metrics, and logs remain isolated", %{conn: conn} do
    for prefix <- ["alpha", "beta"] do
      server_id = if prefix == "alpha", do: "server-a", else: "server-b"

      {:ok, zones_view, _html} =
        mount_with(conn, "/server/#{server_id}/dns/zones?view_name=#{prefix}-view", [
          zone_list(prefix),
          provider_list(prefix)
        ])

      zones_html = render(zones_view)
      assert zones_html =~ "#{prefix}.example"
      assert zones_html =~ "#{prefix}-provider"

      assert has_element?(
               zones_view,
               "a[href='/server/#{server_id}/dns/zones/#{prefix}.example/records?view_name=#{prefix}-view']"
             )

      {:ok, records_view, _html} =
        mount_with(
          conn,
          "/server/#{server_id}/dns/zones/#{prefix}.example/records?view_name=#{prefix}-view",
          [record_list(prefix)]
        )

      assert render(records_view) =~ "192.0.2.#{if(prefix == "alpha", do: 10, else: 20)}"

      {:ok, acl_view, _html} =
        mount_with(conn, "/server/#{server_id}/dns/acl", [acl_list(prefix)])

      assert render(acl_view) =~ "#{prefix}-clients"
      assert has_element?(acl_view, "a[href='/server/#{server_id}/dns']")

      {:ok, provider_view, _html} =
        mount_with(conn, "/server/#{server_id}/dns/providers", [provider_list(prefix)])

      assert render(provider_view) =~ "#{prefix}-provider"

      assert has_element?(
               provider_view,
               "a[href='/server/#{server_id}/dns/providers/#{prefix}-provider']"
             )

      {:ok, metrics_view, _html} =
        mount_with(conn, "/server/#{server_id}/dns/metrics", [metrics(prefix)])

      assert render(metrics_view) =~ if(prefix == "alpha", do: "17", else: "29")
      assert has_element?(metrics_view, "a[href='/server/#{server_id}/dns']")

      {:ok, logs_view, _html} =
        mount_with(conn, "/server/#{server_id}/dns/logs?view_name=#{prefix}-view", [
          log_list(prefix)
        ])

      assert render(logs_view) =~ "query.#{prefix}.example"
      assert has_element?(logs_view, "a[href='/server/#{server_id}/dns']")
    end

    assert Enum.all?(request_envelopes(), fn envelope ->
             String.starts_with?(envelope.target_id, "server-")
           end)
  end

  test "nested DNS routes select and prefill the addressed resource", %{conn: conn} do
    {:ok, view_new, _html} =
      mount_with(conn, "/server/server-a/dns/views/new", [view_list("alpha")])

    assert has_element?(view_new, "#create-view-form")
    refute has_element?(view_new, "#update-view-form")

    {:ok, view_edit, _html} =
      mount_with(conn, "/server/server-a/dns/views/alpha-view/edit", [view_list("alpha")])

    assert has_element?(
             view_edit,
             "#update-view-form input[name='view[view_name]'][value='alpha-view']"
           )

    assert has_element?(
             view_edit,
             "#update-view-form input[name='view[match_clients]'][value='192.0.2.0/24']"
           )

    refute has_element?(view_edit, "#create-view-form")

    {:ok, zones, _html} =
      mount_with(conn, "/server/server-a/dns/zones?view_name=alpha-view", [
        zone_list("alpha"),
        provider_list("alpha")
      ])

    assert has_element?(
             zones,
             "a[href='/server/server-a/dns/zones/new?view_name=alpha-view']"
           )

    assert has_element?(
             zones,
             "a[href='/server/server-a/dns/zones/alpha.example/edit?view_name=alpha-view']"
           )

    {:ok, zone_new, _html} =
      mount_with(conn, "/server/server-a/dns/zones/new?view_name=alpha-view", [
        zone_list("alpha"),
        provider_list("alpha")
      ])

    assert has_element?(zone_new, "#zone-form input[name='zone[view_name]'][value='alpha-view']")
    refute has_element?(zone_new, "#zone-update-form")

    {:ok, zone_edit, _html} =
      mount_with(conn, "/server/server-a/dns/zones/alpha.example/edit?view_name=alpha-view", [
        zone_list("alpha"),
        provider_list("alpha")
      ])

    assert has_element?(
             zone_edit,
             "#zone-update-form input[name='zone[zone_name]'][value='alpha.example']"
           )

    assert has_element?(
             zone_edit,
             "#zone-update-form input[name='zone[view_name]'][value='alpha-view']"
           )

    refute has_element?(zone_edit, "#zone-form")

    {:ok, record_edit, _html} =
      mount_with(
        conn,
        "/server/server-a/dns/zones/alpha.example/records/www-a/edit?view_name=alpha-view",
        [record_list("alpha")]
      )

    assert has_element?(
             record_edit,
             "#update-record-form input[name='record[record_id]'][value='www-a']"
           )

    assert has_element?(
             record_edit,
             "#update-record-form textarea[name='record[values]']",
             "192.0.2.10"
           )

    refute has_element?(record_edit, "#create-record-form")

    {:ok, record_bulk, _html} =
      mount_with(
        conn,
        "/server/server-a/dns/zones/alpha.example/records/bulk?view_name=alpha-view",
        [record_list("alpha")]
      )

    assert has_element?(record_bulk, "#record-bulk-unavailable")
    refute has_element?(record_bulk, "#create-record-form")
    refute has_element?(record_bulk, "#update-record-form")
  end

  test "nested DNS updates derive resource identity from the route", %{conn: conn} do
    view = dns_view("alpha")

    {:ok, view_edit, _html} =
      mount_with(conn, "/server/server-a/dns/views/alpha-view/edit", [
        view_list("alpha"),
        {:ok, revisioned("dns_view", "alpha-view", view)}
      ])

    assert render_submit(view_edit, "update_view", %{
             "view" => %{
               "view_name" => "tampered-view",
               "match_clients" => "192.0.2.0/24",
               "recursion" => "false"
             }
           }) =~ "View updated"

    assert %{payload: %{"view_name" => "alpha-view"}, expected_revision: view_revision} =
             List.last(request_envelopes())

    assert view_revision == digest!(view)

    zone = dns_zone("alpha")

    {:ok, zone_edit, _html} =
      mount_with(conn, "/server/server-a/dns/zones/alpha.example/edit?view_name=alpha-view", [
        zone_list("alpha"),
        provider_list("alpha"),
        {:ok, revisioned("dns_zone", "alpha.example", zone)}
      ])

    assert render_submit(zone_edit, "update_zone", %{
             "zone" => %{
               "view_name" => "tampered-view",
               "zone_name" => "tampered.example",
               "zone_type" => "forward",
               "provider_id" => "alpha-provider"
             }
           }) =~ "Zone updated"

    assert %{
             payload: %{
               "view_name" => "alpha-view",
               "zone_name" => "alpha.example",
               "zone_type" => "forward"
             },
             expected_revision: zone_revision
           } = List.last(request_envelopes())

    assert zone_revision == digest!(zone)

    record = dns_record("alpha")

    {:ok, record_edit, _html} =
      mount_with(
        conn,
        "/server/server-a/dns/zones/alpha.example/records/www-a/edit?view_name=alpha-view",
        [
          record_list("alpha"),
          {:ok, revisioned("dns_record", "www-a", record)}
        ]
      )

    assert render_submit(record_edit, "update_record", %{
             "record" => %{
               "record_id" => "tampered-record",
               "name" => "www",
               "type" => "AAAA",
               "ttl" => "600",
               "values" => "2001:db8::10"
             }
           }) =~ "Record updated"

    assert %{
             payload: %{
               "view_name" => "alpha-view",
               "zone_name" => "alpha.example",
               "record_id" => "www-a",
               "type" => "AAAA"
             },
             expected_revision: record_revision
           } = List.last(request_envelopes())

    assert record_revision == digest!(record)
  end

  test "view CRUD uses typed selected-Server commands and exposes conflicts", %{conn: conn} do
    view = dns_view("alpha")

    :ok =
      TestManagementTransport.script_request([
        view_list("alpha"),
        {:ok, revisioned("dns_view", "alpha-new", Map.put(view, "view_name", "alpha-new"))}
      ])

    {:ok, create_view, _html} = live(conn, "/server/server-a/dns/views/new")

    assert has_element?(create_view, "#create-view-form")

    create_html =
      render_submit(create_view, "create_view", %{
        "view" => %{
          "view_name" => "alpha-new",
          "match_clients" => "192.0.2.0/24",
          "recursion" => "true"
        }
      })

    assert create_html =~ "View created"

    :ok =
      TestManagementTransport.script_request([
        view_list("alpha"),
        {:error,
         Error.new(:conflict, "View changed on the selected Server", %{
           "current_revision" => @revision_c
         })}
      ])

    {:ok, edit_view, _html} =
      live(conn, "/server/server-a/dns/views/alpha-view/edit")

    conflict_html =
      render_submit(edit_view, "update_view", %{
        "view" => %{
          "view_name" => "alpha-view",
          "match_clients" => "192.0.2.0/24",
          "recursion" => "false"
        }
      })

    assert conflict_html =~ "View changed on the selected Server"
    assert conflict_html =~ @revision_c

    :ok =
      TestManagementTransport.script_request([
        view_list("alpha"),
        {:ok, deleted("dns_view", "alpha-view", %{"view_name" => "alpha-view"})}
      ])

    {:ok, views, _html} = live(conn, "/server/server-a/dns/views")

    assert has_element?(views, "a[href='/server/server-a/dns/views/new']")
    assert has_element?(views, "a[href='/server/server-a/dns/views/alpha-view/edit']")

    assert render_click(views, "delete_view", %{
             "view_name" => "alpha-view"
           }) =~ "View deleted"

    assert_selected_operations([
      "server.dns.views.list",
      "server.dns.views.create",
      "server.dns.views.list",
      "server.dns.views.update",
      "server.dns.views.list",
      "server.dns.views.delete"
    ])

    assert_expected_revision("server.dns.views.create", nil)
    assert_expected_revision("server.dns.views.update", digest!(view))
    assert_expected_revision("server.dns.views.delete", digest!(view))
  end

  test "zone CRUD and sync use typed selected-Server commands while import stays unavailable", %{
    conn: conn
  } do
    zone = dns_zone("alpha")

    :ok =
      TestManagementTransport.script_request([
        zone_list("alpha"),
        provider_list("alpha"),
        {:ok,
         revisioned("dns_zone", "new.alpha.example", %{zone | "zone_name" => "new.alpha.example"})}
      ])

    {:ok, create_zone, _html} =
      live(conn, "/server/server-a/dns/zones/new?view_name=alpha-view")

    assert render_submit(create_zone, "create_zone", %{
             "zone" => %{
               "view_name" => "tampered-view",
               "zone_name" => "new.alpha.example",
               "zone_type" => "authoritative",
               "provider_id" => "alpha-provider"
             }
           }) =~ "Zone created"

    assert %{"view_name" => "alpha-view"} = List.last(request_envelopes()).payload

    :ok =
      TestManagementTransport.script_request([
        zone_list("alpha"),
        provider_list("alpha"),
        {:ok, revisioned("dns_zone", "alpha.example", zone)}
      ])

    {:ok, update_zone, _html} =
      live(
        conn,
        "/server/server-a/dns/zones/alpha.example/edit?view_name=alpha-view"
      )

    assert render_submit(update_zone, "update_zone", %{"zone" => zone}) =~ "Zone updated"

    :ok =
      TestManagementTransport.script_request([
        zone_list("alpha"),
        provider_list("alpha"),
        {:ok,
         %{
           "view_name" => "alpha-view",
           "zone_name" => "alpha.example",
           "changed_records" => 2,
           "revision" => @revision_c
         }},
        {:ok, deleted("dns_zone", "alpha.example", zone_ref("alpha"))}
      ])

    {:ok, live_view, _html} = live(conn, "/server/server-a/dns/zones?view_name=alpha-view")

    assert has_element?(
             live_view,
             "a[href='/server/server-a/dns/zones/new?view_name=alpha-view']"
           )

    assert has_element?(
             live_view,
             "a[href='/server/server-a/dns/zones/import?view_name=alpha-view']"
           )

    assert has_element?(
             live_view,
             "a[href='/server/server-a/dns/zones/alpha.example/edit?view_name=alpha-view']"
           )

    assert render_click(live_view, "sync_zone", %{
             "view_name" => "alpha-view",
             "zone_name" => "alpha.example",
             "provider_id" => "alpha-provider"
           }) =~ "Synchronized 2 records"

    assert render_click(live_view, "delete_zone", zone_ref("alpha")) =~ "Zone deleted"

    :ok = TestManagementTransport.script_request([zone_list("alpha"), provider_list("alpha")])

    {:ok, import_view, _html} =
      live(conn, "/server/server-a/dns/zones/import?view_name=alpha-view")

    before_import = length(request_envelopes())
    assert has_element?(import_view, "#zone-import-form button[disabled]")

    assert render_submit(import_view, "import_zone", %{
             "import" => %{
               "view_name" => "alpha-view",
               "zone_name" => "import.alpha.example",
               "source_type" => "provider",
               "source_id" => "alpha-provider",
               "source_revision" => @revision_a
             }
           }) =~ "revision is not exposed"

    assert length(request_envelopes()) == before_import

    assert_selected_operations([
      "server.dns.zones.list",
      "server.dns.providers.list",
      "server.dns.zones.create",
      "server.dns.zones.list",
      "server.dns.providers.list",
      "server.dns.zones.update",
      "server.dns.zones.list",
      "server.dns.providers.list",
      "server.dns.zones.sync",
      "server.dns.zones.delete",
      "server.dns.zones.list",
      "server.dns.providers.list"
    ])

    assert_expected_revision("server.dns.zones.create", nil)
    assert_expected_revision("server.dns.zones.update", digest!(zone))
    assert_expected_revision("server.dns.zones.sync", digest!(zone))
    assert_expected_revision("server.dns.zones.delete", digest!(zone))
  end

  test "record CRUD uses zone context and preserves scoped links", %{conn: conn} do
    record = dns_record("alpha")

    :ok =
      TestManagementTransport.script_request([
        record_list("alpha"),
        {:ok,
         revisioned("dns_record", "api-a", %{record | "record_id" => "api-a", "name" => "api"})}
      ])

    {:ok, create_record, _html} =
      live(
        conn,
        "/server/server-a/dns/zones/alpha.example/records/new?view_name=alpha-view"
      )

    assert render_submit(create_record, "create_record", %{
             "record" => %{
               "record_id" => "api-a",
               "name" => "api",
               "type" => "A",
               "ttl" => "300",
               "values" => "192.0.2.30"
             }
           }) =~ "Record created"

    :ok =
      TestManagementTransport.script_request([
        record_list("alpha"),
        {:ok, revisioned("dns_record", "www-a", record)}
      ])

    {:ok, update_record, _html} =
      live(
        conn,
        "/server/server-a/dns/zones/alpha.example/records/www-a/edit?view_name=alpha-view"
      )

    assert render_submit(update_record, "update_record", %{
             "record" => %{
               "record_id" => "www-a",
               "name" => "www",
               "type" => "A",
               "ttl" => "300",
               "values" => "192.0.2.10"
             }
           }) =~ "Record updated"

    :ok =
      TestManagementTransport.script_request([
        record_list("alpha"),
        {:ok, deleted("dns_record", "www-a", record_ref("alpha"))}
      ])

    {:ok, live_view, _html} =
      live(
        conn,
        "/server/server-a/dns/zones/alpha.example/records?view_name=alpha-view"
      )

    assert has_element?(
             live_view,
             "#server-dns-records a[href='/server/server-a/dns/zones?view_name=alpha-view']"
           )

    assert has_element?(
             live_view,
             "a[href='/server/server-a/dns/zones/alpha.example/records/new?view_name=alpha-view']"
           )

    assert has_element?(
             live_view,
             "a[href='/server/server-a/dns/zones/alpha.example/records/bulk?view_name=alpha-view']"
           )

    assert has_element?(
             live_view,
             "a[href='/server/server-a/dns/zones/alpha.example/records/www-a/edit?view_name=alpha-view']"
           )

    assert render_click(live_view, "delete_record", record_ref("alpha")) =~
             "Record deleted"

    assert_selected_operations([
      "server.dns.records.list",
      "server.dns.records.create",
      "server.dns.records.list",
      "server.dns.records.update",
      "server.dns.records.list",
      "server.dns.records.delete"
    ])

    assert_expected_revision("server.dns.records.create", nil)
    assert_expected_revision("server.dns.records.update", digest!(record))
    assert_expected_revision("server.dns.records.delete", digest!(record))
  end

  test "ACL CRUD uses typed selected-Server commands", %{conn: conn} do
    acl = dns_acl("alpha")

    :ok =
      TestManagementTransport.script_request([
        acl_list("alpha"),
        {:ok, revisioned("dns_acl", "alpha-new", %{acl | "acl_id" => "alpha-new"})},
        {:ok, revisioned("dns_acl", "alpha-clients", acl)},
        {:ok, deleted("dns_acl", "alpha-clients", %{"acl_id" => "alpha-clients"})}
      ])

    {:ok, live_view, _html} = live(conn, "/server/server-a/dns/acl")

    assert render_submit(live_view, "create_acl", %{
             "acl" => %{
               "acl_id" => "alpha-new",
               "networks" => "192.0.2.0/24",
               "action" => "allow"
             }
           }) =~ "ACL created"

    assert render_submit(live_view, "update_acl", %{
             "acl" => %{
               "acl_id" => "alpha-clients",
               "networks" => "192.0.2.0/24",
               "action" => "deny"
             }
           }) =~ "ACL updated"

    assert render_click(live_view, "delete_acl", %{
             "acl_id" => "alpha-clients"
           }) =~ "ACL deleted"

    assert_selected_operations([
      "server.dns.acls.list",
      "server.dns.acls.create",
      "server.dns.acls.update",
      "server.dns.acls.delete"
    ])

    assert_expected_revision("server.dns.acls.create", nil)
    assert_expected_revision("server.dns.acls.update", digest!(acl))
    assert_expected_revision("server.dns.acls.delete", digest!(acl))
  end

  test "supported provider mutations stay scoped while credential mutations and conflicts are unavailable",
       %{
         conn: conn
       } do
    provider = dns_provider("alpha")

    :ok =
      TestManagementTransport.script_request([
        provider_list("alpha"),
        {:ok, deleted("dns_provider", "alpha-provider", %{"provider_id" => "alpha-provider"})}
      ])

    {:ok, index, _html} = live(conn, "/server/server-a/dns/providers")

    refute has_element?(index, "a[href='/server/server-a/dns/providers/new']")
    assert has_element?(index, "#provider-create-unavailable")

    before_create = length(request_envelopes())

    assert render_submit(index, "create_provider", %{
             "provider" => %{
               "provider_id" => "alpha-new",
               "provider_type" => "cloudflare",
               "endpoint" => "https://api.cloudflare.com",
               "credential_ref" => "alpha-secret"
             }
           }) =~ "credential references cannot yet be materialized"

    assert length(request_envelopes()) == before_create

    assert render_click(index, "delete_provider", %{
             "provider_id" => "alpha-provider"
           }) =~ "Provider deleted"

    :ok =
      TestManagementTransport.script_request([
        provider_list("alpha"),
        zone_list("alpha"),
        {:ok,
         %{
           "view_name" => "alpha-view",
           "zone_name" => "alpha.example",
           "changed_records" => 1,
           "revision" => @revision_b
         }}
      ])

    {:ok, show, _html} =
      live(conn, "/server/server-a/dns/providers/alpha-provider?view_name=alpha-view")

    assert has_element?(show, "a[href='/server/server-a/dns/providers/alpha-provider/conflicts']")
    refute has_element?(show, "a[href='/server/server-a/dns/providers/alpha-provider/edit']")
    assert has_element?(show, "#provider-update-unavailable")

    before_update = length(request_envelopes())

    assert render_submit(show, "update_provider", %{
             "provider" => provider
           }) =~ "credential references cannot yet be materialized"

    assert length(request_envelopes()) == before_update

    assert render_click(show, "sync_zone", %{
             "view_name" => "alpha-view",
             "zone_name" => "alpha.example"
           }) =~ "Synchronized 1 record"

    :ok = TestManagementTransport.script_request([provider_list("alpha")])

    {:ok, conflicts, _html} =
      live(conn, "/server/server-a/dns/providers/alpha-provider/conflicts")

    assert has_element?(conflicts, "a[href='/server/server-a/dns/providers/alpha-provider']")

    before_resolution = length(request_envelopes())
    assert has_element?(conflicts, "#conflict-resolution-form button[disabled]")

    assert render_submit(conflicts, "resolve_conflict", %{
             "conflict" => %{
               "conflict_id" => "conflict-1",
               "resolution" => "use_cloud"
             }
           }) =~ "revision is not exposed"

    assert length(request_envelopes()) == before_resolution

    assert_selected_operations([
      "server.dns.providers.list",
      "server.dns.providers.delete",
      "server.dns.providers.list",
      "server.dns.zones.list",
      "server.dns.zones.sync",
      "server.dns.providers.list"
    ])

    assert_expected_revision("server.dns.providers.delete", digest!(provider))
    assert_expected_revision("server.dns.zones.sync", digest!(dns_zone("alpha")))
  end

  test "legacy cloud-provider page uses selected Server providers and scoped destinations", %{
    conn: conn
  } do
    {:ok, live_view, _html} =
      mount_with(conn, "/server/server-a/dns/cloud-provider", [provider_list("alpha")])

    html = render(live_view)
    assert html =~ "alpha-provider"
    assert has_element?(live_view, "a[href='/server/server-a/dns/providers']")
    assert has_element?(live_view, "a[href='/server/server-a/dns/providers/alpha-provider']")
    assert Enum.all?(request_envelopes(), &(&1.target_id == "server-a"))
  end

  test "offline cached reads show observation time and block mutations without queueing", %{
    conn: conn
  } do
    :ok = TestManagementTransport.script_request([provider_list("alpha")])

    assert %{status: :ok} =
             YellowDog.Console.ServerManagement.dns_providers_list("server-a")

    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)
    before = length(TestManagementTransport.recorded())

    {:ok, live_view, _html} = live(conn, "/server/server-a/dns/providers")
    html = render(live_view)

    assert html =~ "Offline cached snapshot"
    assert html =~ "Observed"
    assert html =~ "2026-08-11 03:04:05 UTC"
    assert html =~ "alpha-provider"
    assert has_element?(live_view, "button[phx-click='delete_provider'][disabled]")

    assert render_click(live_view, "delete_provider", %{"provider_id" => "alpha-provider"}) =~
             "offline"

    assert length(TestManagementTransport.recorded()) == before
  end

  test "matching reconnect refreshes the selected page and other Server events are ignored", %{
    conn: conn
  } do
    :ok = TestManagementTransport.script_request([provider_list("alpha")])

    assert %{status: :ok} =
             YellowDog.Console.ServerManagement.dns_providers_list("server-a")

    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)
    {:ok, live_view, _html} = live(conn, "/server/server-a/dns/providers")
    assert render(live_view) =~ "Offline cached snapshot"

    :ok = TestManagementTransport.connect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :online)
    :ok = TestManagementTransport.script_request([provider_list("reconnected")])

    send(live_view.pid, {:server_connection, :online, %{server_id: "server-a"}})
    assert render(live_view) =~ "reconnected-provider"

    send(live_view.pid, {:server_connection, :online, %{server_id: "server-b"}})
    assert render(live_view) =~ "reconnected-provider"
  end

  defp mount_with(conn, path, responses) do
    :ok = TestManagementTransport.script_request(responses)
    live(conn, path)
  end

  defp register_server(id, name, status) do
    assert {:ok, _server} =
             ManagementCore.register_server(%{
               id: id,
               name: name,
               profile: :custom,
               status: status,
               last_seen_at: ~U[2026-08-11 03:04:05Z]
             })
  end

  defp view_list(prefix), do: {:ok, list_result([dns_view(prefix)])}
  defp zone_list(prefix), do: {:ok, list_result([dns_zone(prefix)])}
  defp record_list(prefix), do: {:ok, list_result([dns_record(prefix)])}
  defp acl_list(prefix), do: {:ok, list_result([dns_acl(prefix)])}
  defp provider_list(prefix), do: {:ok, list_result([dns_provider(prefix)])}
  defp log_list(prefix), do: {:ok, list_result([dns_log(prefix)])}

  defp metrics("alpha"), do: {:ok, %{"queries" => 17, "failures" => 2}}
  defp metrics(_prefix), do: {:ok, %{"queries" => 29, "failures" => 3}}

  defp dns_view(prefix) do
    %{
      "view_name" => "#{prefix}-view",
      "match_clients" => [if(prefix == "alpha", do: "192.0.2.0/24", else: "198.51.100.0/24")],
      "recursion" => prefix == "alpha"
    }
  end

  defp dns_zone(prefix) do
    %{
      "view_name" => "#{prefix}-view",
      "zone_name" => "#{prefix}.example",
      "zone_type" => "authoritative",
      "provider_id" => "#{prefix}-provider"
    }
  end

  defp dns_record(prefix) do
    %{
      "view_name" => "#{prefix}-view",
      "zone_name" => "#{prefix}.example",
      "record_id" => "www-#{String.first(prefix)}",
      "name" => "www",
      "type" => "A",
      "ttl" => 300,
      "values" => [if(prefix == "alpha", do: "192.0.2.10", else: "192.0.2.20")]
    }
  end

  defp dns_acl(prefix) do
    %{
      "acl_id" => "#{prefix}-clients",
      "networks" => [if(prefix == "alpha", do: "192.0.2.0/24", else: "198.51.100.0/24")],
      "action" => "allow"
    }
  end

  defp dns_provider(prefix) do
    %{
      "provider_id" => "#{prefix}-provider",
      "provider_type" => "cloudflare",
      "endpoint" => "https://api.cloudflare.com",
      "credential_ref" => "#{prefix}-secret"
    }
  end

  defp dns_log(prefix) do
    %{
      "log_id" => "#{prefix}-log",
      "query_name" => "query.#{prefix}.example",
      "action" => "answered",
      "occurred_at" => @observed_at
    }
  end

  defp zone_ref(prefix) do
    %{"view_name" => "#{prefix}-view", "zone_name" => "#{prefix}.example"}
  end

  defp record_ref(prefix) do
    Map.put(zone_ref(prefix), "record_id", "www-#{String.first(prefix)}")
  end

  defp list_result(items) do
    %{"items" => items, "revision" => @revision_a, "observed_at" => @observed_at}
  end

  defp revisioned(resource_type, resource_id, resource) do
    %{
      "resource_type" => resource_type,
      "resource_id" => resource_id,
      "resource" => resource,
      "revision" => @revision_b
    }
  end

  defp deleted(resource_type, resource_id, resource_ref) do
    %{
      "resource_type" => resource_type,
      "resource_id" => resource_id,
      "resource_ref" => resource_ref,
      "revision" => @revision_b
    }
  end

  defp request_envelopes do
    for {:request, envelope, _timeout} <- TestManagementTransport.recorded(), do: envelope
  end

  defp assert_selected_operations(expected) do
    envelopes = request_envelopes()
    assert Enum.map(envelopes, & &1.operation) == expected
    assert Enum.all?(envelopes, &(&1.target_id == "server-a"))
    assert_command_keys()
  end

  defp assert_command_keys do
    query_suffixes = [".list", ".get"]

    command_envelopes =
      Enum.reject(request_envelopes(), fn envelope ->
        Enum.any?(query_suffixes, &String.ends_with?(envelope.operation, &1))
      end)

    assert command_envelopes != []

    assert Enum.all?(command_envelopes, fn envelope ->
             match?({:ok, _uuid}, Ecto.UUID.cast(envelope.idempotency_key))
           end)
  end

  defp assert_expected_revision(operation, expected_revision) do
    assert %{expected_revision: ^expected_revision} =
             Enum.find(request_envelopes(), &(&1.operation == operation))
  end

  defp digest!(resource) do
    assert {:ok, revision} = Digest.calculate(resource)
    revision
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
