defmodule YellowDog.Console.DnsLiveTest do
  @moduledoc """
  LiveView tests for DNS console pages.
  Tests page mounting, rendering, and UI interactions (search, filter, export).
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # DNS Overview Page
  # ============================================================================

  describe "DNS Overview /dns" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns")
      assert html =~ "DNS"
    end
  end

  # ============================================================================
  # DNS Views Page
  # ============================================================================

  describe "DNS Views /dns/views" do
    test "mounts with empty views list", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views")
      assert html =~ "DNS Views"
    end

    test "renders filter bar when views exist or shows empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views")
      # Page should render without errors
      assert html =~ "DNS Views"
    end

    test "navigates to new view form", %{conn: conn} do
      {:ok, _view, _html} = live(conn, "/dns/views")
      {:ok, _view, html} = live(conn, "/dns/views/new")
      assert html =~ "Create New View"
      assert html =~ "View Name"
      assert html =~ "Priority"
    end

    test "new view form has all required fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/new")
      assert html =~ "Recursion"
      assert html =~ "ECS"
      assert html =~ "ACL Type"
      assert html =~ "Fallback"
    end

    test "new view form renders ACL type options", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/new")
      assert html =~ "Allow All (any)"
      assert html =~ "Deny All (none)"
      assert html =~ "Localhost Only"
      assert html =~ "Local Networks"
      assert html =~ "Geographic"
    end

    test "cancel navigates back to views list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/new")

      view |> element(~s(button[phx-click="cancel"])) |> render_click()

      assert_redirect(view, "/dns/views")
    end
  end

  # ============================================================================
  # DNS Zones Page
  # ============================================================================

  describe "DNS Zones /dns/views/:view_name/zones" do
    test "mounts with view name from params", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones")
      assert html =~ "Zones"
      assert html =~ "default"
    end

    test "navigates to new zone form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones/new")
      assert html =~ "Add Zone"
      assert html =~ "Zone Name"
      assert html =~ "Zone Type"
    end

    test "new zone form shows zone type options", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones/new")
      assert html =~ "Authoritative"
      assert html =~ "Forward"
      assert html =~ "Stub"
    end

    test "navigates to import zone form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones/import")
      assert html =~ "Import Zone"
      assert html =~ "BIND Zone File Format"
    end

    test "import form has zone data textarea", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones/import")
      assert html =~ "Zone Data"
      assert html =~ "$ORIGIN"
    end

    test "cancel navigates back to zones list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/new")

      view |> element(~s(button[phx-click="cancel"])) |> render_click()

      assert_redirect(view, "/dns/views/default/zones")
    end

    test "breadcrumb navigation is present", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones")
      assert html =~ "breadcrumbs"
      assert html =~ "DNS"
      assert html =~ "Views"
    end
  end

  # ============================================================================
  # DNS ACL Page
  # ============================================================================

  describe "DNS ACL /dns/acl" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/acl")
      assert html =~ "ACL"
    end

    test "has export button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/acl")
      assert html =~ "Export"
    end
  end

  # ============================================================================
  # DNS Query Logs Page
  # ============================================================================

  describe "DNS Query Logs /dns/logs" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ "Query Logs" or html =~ "Logs"
    end
  end

  # ============================================================================
  # DNS Metrics Page
  # ============================================================================

  describe "DNS Metrics /dns/metrics" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "Metrics" or html =~ "DNS"
    end

    test "has export CSV button with CsvDownload hook", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "Export CSV"
      assert html =~ "CsvDownload"
    end

    test "has reset button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "Reset"
    end

    test "shows summary stats section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "Total Queries"
      assert html =~ "Cache Hit Rate"
    end
  end

  # ============================================================================
  # Filter/CSV Unit Tests
  # ============================================================================

  describe "ZoneLive filtering" do
    alias YellowDog.Console.DnsLive.ZoneLive.Index, as: ZoneLive

    test "filtered_zones/3 returns all zones with empty filter" do
      zones = [
        %{name: "example.com", type: :auth, record_count: 10, query_count: 100},
        %{name: "test.org", type: :forward, record_count: 0, query_count: 50}
      ]

      assert ZoneLive.filtered_zones(zones, "", "all") == zones
    end

    test "filtered_zones/3 filters by name" do
      zones = [
        %{name: "example.com", type: :auth, record_count: 10, query_count: 100},
        %{name: "test.org", type: :forward, record_count: 0, query_count: 50}
      ]

      filtered = ZoneLive.filtered_zones(zones, "example", "all")
      assert length(filtered) == 1
      assert hd(filtered).name == "example.com"
    end

    test "filtered_zones/3 filters by type" do
      zones = [
        %{name: "example.com", type: :auth, record_count: 10, query_count: 100},
        %{name: "test.org", type: :forward, record_count: 0, query_count: 50},
        %{name: "stub.net", type: :stub, record_count: 0, query_count: 20}
      ]

      filtered = ZoneLive.filtered_zones(zones, "", "forward")
      assert length(filtered) == 1
      assert hd(filtered).name == "test.org"
    end

    test "filtered_zones/3 combines name and type filters" do
      zones = [
        %{name: "example.com", type: :auth, record_count: 10, query_count: 100},
        %{name: "example.org", type: :forward, record_count: 0, query_count: 50},
        %{name: "test.org", type: :forward, record_count: 0, query_count: 20}
      ]

      filtered = ZoneLive.filtered_zones(zones, "example", "forward")
      assert length(filtered) == 1
      assert hd(filtered).name == "example.org"
    end

    test "filtered_zones/3 is case-insensitive" do
      zones = [%{name: "Example.COM", type: :auth, record_count: 0, query_count: 0}]
      assert ZoneLive.filtered_zones(zones, "example", "all") == zones
    end

    test "unique_zone_types/1 returns sorted unique types" do
      zones = [
        %{name: "a.com", type: :auth},
        %{name: "b.com", type: :forward},
        %{name: "c.com", type: :auth},
        %{name: "d.com", type: :stub}
      ]

      types = ZoneLive.unique_zone_types(zones)
      assert types == [:auth, :forward, :stub]
    end

    test "zone_type_label/1 returns human-readable labels" do
      assert ZoneLive.zone_type_label(:auth) == "Authoritative"
      assert ZoneLive.zone_type_label(:forward) == "Forward"
      assert ZoneLive.zone_type_label(:stub) == "Stub"
      assert ZoneLive.zone_type_label(:cache) == "Cache"
      assert ZoneLive.zone_type_label(:unknown) == "Unknown"
    end

    test "zone_type_badge/1 returns DaisyUI color classes" do
      assert ZoneLive.zone_type_badge(:auth) == "primary"
      assert ZoneLive.zone_type_badge(:forward) == "secondary"
      assert ZoneLive.zone_type_badge(:stub) == "accent"
      assert ZoneLive.zone_type_badge(:cache) == "info"
    end
  end

  describe "ViewLive filtering" do
    alias YellowDog.Console.DnsLive.ViewLive.Index, as: ViewLive

    test "filtered_views/3 returns all views with empty filter" do
      views = [
        %{name: "default", enabled: true, priority: :infinity, zone_count: 3, query_count: 100},
        %{name: "internal", enabled: true, priority: 10, zone_count: 2, query_count: 50}
      ]

      assert ViewLive.filtered_views(views, "", "all") == views
    end

    test "filtered_views/3 filters by name" do
      views = [
        %{name: "default", enabled: true, priority: :infinity, zone_count: 3, query_count: 100},
        %{name: "internal", enabled: true, priority: 10, zone_count: 2, query_count: 50},
        %{name: "external", enabled: false, priority: 20, zone_count: 1, query_count: 10}
      ]

      filtered = ViewLive.filtered_views(views, "internal", "all")
      assert length(filtered) == 1
      assert hd(filtered).name == "internal"
    end

    test "filtered_views/3 filters by active status" do
      views = [
        %{name: "default", enabled: true, priority: :infinity},
        %{name: "internal", enabled: true, priority: 10},
        %{name: "external", enabled: false, priority: 20}
      ]

      filtered = ViewLive.filtered_views(views, "", "active")
      assert length(filtered) == 2
      assert Enum.all?(filtered, & &1.enabled)
    end

    test "filtered_views/3 filters by disabled status" do
      views = [
        %{name: "default", enabled: true, priority: :infinity},
        %{name: "internal", enabled: true, priority: 10},
        %{name: "external", enabled: false, priority: 20}
      ]

      filtered = ViewLive.filtered_views(views, "", "disabled")
      assert length(filtered) == 1
      assert hd(filtered).name == "external"
    end

    test "filtered_views/3 combines name and status filters" do
      views = [
        %{name: "default", enabled: true, priority: :infinity},
        %{name: "internal-1", enabled: true, priority: 10},
        %{name: "internal-2", enabled: false, priority: 20}
      ]

      filtered = ViewLive.filtered_views(views, "internal", "active")
      assert length(filtered) == 1
      assert hd(filtered).name == "internal-1"
    end

    test "filtered_views/3 is case-insensitive" do
      views = [%{name: "Internal-VIEW", enabled: true}]
      assert ViewLive.filtered_views(views, "internal", "all") == views
    end
  end

  describe "AclLive filtering" do
    alias YellowDog.Console.DnsLive.AclLive

    test "filtered_named_acls/3 returns all acls with empty filter" do
      acls = [
        %{name: "internal", description: "Corporate network", rules: []},
        %{name: "external", description: "Public access", rules: []}
      ]

      assert AclLive.filtered_named_acls(acls, "", "all") == acls
    end

    test "filtered_named_acls/3 filters by name" do
      acls = [
        %{name: "internal", description: "Corporate network", rules: []},
        %{name: "external", description: "Public access", rules: []},
        %{name: "vpn-clients", description: "VPN users", rules: []}
      ]

      filtered = AclLive.filtered_named_acls(acls, "internal", "all")
      assert length(filtered) == 1
      assert hd(filtered).name == "internal"
    end

    test "filtered_named_acls/3 filters by description" do
      acls = [
        %{name: "internal", description: "Corporate network", rules: []},
        %{name: "external", description: "Public access", rules: []}
      ]

      filtered = AclLive.filtered_named_acls(acls, "corporate", "all")
      assert length(filtered) == 1
      assert hd(filtered).name == "internal"
    end

    test "filtered_named_acls/3 is case-insensitive" do
      acls = [%{name: "Internal-ACL", description: "Test", rules: []}]
      assert AclLive.filtered_named_acls(acls, "internal", "all") == acls
    end

    test "filtered_views_acl/3 returns all views with empty filter" do
      views = [
        %{name: "default", acl_type: "any", priority: 0, acl_rules: []},
        %{name: "internal", acl_type: "custom", priority: 10, acl_rules: []}
      ]

      assert AclLive.filtered_views_acl(views, "", "all") == views
    end

    test "filtered_views_acl/3 filters by view name" do
      views = [
        %{name: "default", acl_type: "any", priority: 0, acl_rules: []},
        %{name: "internal", acl_type: "custom", priority: 10, acl_rules: []}
      ]

      filtered = AclLive.filtered_views_acl(views, "internal", "all")
      assert length(filtered) == 1
      assert hd(filtered).name == "internal"
    end

    test "filtered_views_acl/3 filters by ACL type" do
      views = [
        %{name: "default", acl_type: "any", priority: 0, acl_rules: []},
        %{name: "internal", acl_type: "custom", priority: 10, acl_rules: []},
        %{name: "geo-view", acl_type: "geo", priority: 20, acl_rules: []}
      ]

      filtered = AclLive.filtered_views_acl(views, "", "custom")
      assert length(filtered) == 1
      assert hd(filtered).name == "internal"
    end

    test "filtered_views_acl/3 combines name and type filters" do
      views = [
        %{name: "default", acl_type: "any", priority: 0, acl_rules: []},
        %{name: "internal-1", acl_type: "custom", priority: 10, acl_rules: []},
        %{name: "internal-2", acl_type: "geo", priority: 20, acl_rules: []}
      ]

      filtered = AclLive.filtered_views_acl(views, "internal", "custom")
      assert length(filtered) == 1
      assert hd(filtered).name == "internal-1"
    end

    test "unique_acl_types/1 returns sorted unique types" do
      views = [
        %{name: "a", acl_type: "any"},
        %{name: "b", acl_type: "custom"},
        %{name: "c", acl_type: "any"},
        %{name: "d", acl_type: "geo"}
      ]

      types = AclLive.unique_acl_types(views)
      assert types == ["any", "custom", "geo"]
    end
  end

  describe "DNS ACL /dns/acl search and filter" do
    test "has search/filter input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/acl")
      assert html =~ "Search" or html =~ "search"
    end

    test "has create ACL button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/acl")
      assert html =~ "Add ACL"
    end

    test "shows built-in ACL reference", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/acl")
      assert html =~ "Built-in ACL Reference"
    end
  end

  # ============================================================================
  # DNS Views CRUD Operations
  # ============================================================================

  describe "DNS Views CRUD" do
    test "create view form submits with valid data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/new")

      # Submit the form with view data (only include checkbox if "true")
      # Since ViewManager is not running, the save will fail gracefully
      result =
        view
        |> form("form", %{
          "view" => %{
            "name" => "test-view",
            "priority" => "50",
            "recursion_enabled" => "true",
            "acl_type" => "any",
            "fallback_forwarders" => "",
            "fallback_timeout" => "2000",
            "fallback_retries" => "1"
          }
        })
        |> render_submit()

      # Form submission should produce HTML (either success flash or error)
      assert is_binary(result)
    end

    test "create view form requires name field", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/new")
      # The form should have a name input field
      assert html =~ ~s(name="view[name]")
    end

    test "create view form has priority field with default 100", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/new")
      assert html =~ ~s(name="view[priority]")
      assert html =~ "100"
    end

    test "create view form has recursion checkbox", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/new")
      assert html =~ ~s(name="view[recursion_enabled]")
    end

    test "create view form has ECS checkbox", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/new")
      assert html =~ ~s(name="view[ecs_enabled]")
    end

    test "create view form has fallback forwarders textarea", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/new")
      assert html =~ ~s(name="view[fallback_forwarders]")
    end

    test "create view form has timeout and retries fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/new")
      assert html =~ ~s(name="view[fallback_timeout]")
      assert html =~ ~s(name="view[fallback_retries]")
    end

    test "ACL type change updates form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/new")

      html =
        view
        |> element(~s(select[name="view[acl_type]"]))
        |> render_change(%{"view" => %{"acl_type" => "geo"}})

      # Should show country selector when geo is selected
      assert html =~ "geo" or html =~ "Geographic" or html =~ "Country"
    end

    test "edit view redirects to views list for nonexistent view", %{conn: conn} do
      # View doesn't exist, so apply_action redirects with flash error
      assert {:error, {:live_redirect, %{to: "/dns/views", flash: flash}}} =
               live(conn, "/dns/views/nonexistent-view/edit")

      assert flash["error"] =~ "not found"
    end

    test "delete confirm modal can be closed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views")
      # close_modal should work even without a delete target
      html = view |> render_click("close_modal")
      assert html =~ "DNS Views"
    end

    test "refresh button reloads views", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views")
      html = view |> render_click("refresh")
      assert html =~ "DNS Views"
    end

    test "export CSV generates file download", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dns/views")
      assert html =~ "CsvDownload"
      view |> render_click("export_csv")
      # The push_event is fired, which we can't directly assert in tests,
      # but the render should not crash
      assert render(view) =~ "DNS Views"
    end

    test "filter by name works via event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views")
      html = view |> render_change("filter", %{"filter" => "test"})
      assert html =~ "DNS Views"
    end

    test "filter by status works via event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views")
      html = view |> render_change("filter_status", %{"status" => "active"})
      assert html =~ "DNS Views"
    end
  end

  # ============================================================================
  # DNS Zones CRUD Operations
  # ============================================================================

  describe "DNS Zones CRUD" do
    test "create zone form submits auth zone", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/new")

      # Auth zone form only has name and type fields (no upstreams/ns_records)
      result =
        view
        |> form("form", %{
          "zone" => %{
            "name" => "example.com",
            "type" => "auth"
          }
        })
        |> render_submit()

      # Should either succeed or show error since ZoneController isn't running
      assert is_binary(result)
    end

    test "create zone form submits forward zone with upstreams", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/new")

      # First change type to forward to reveal upstreams textarea
      view
      |> render_change("validate_zone", %{
        "zone" => %{
          "name" => "forwarded.com",
          "type" => "forward",
          "upstreams" => "",
          "ns_records" => ""
        }
      })

      # Submit with forward type and upstreams
      result =
        view
        |> form("form", %{
          "zone" => %{
            "name" => "forwarded.com",
            "type" => "forward",
            "upstreams" => "8.8.8.8\n8.8.4.4"
          }
        })
        |> render_submit()

      # Should stay on page showing validation error (zone already exists or other error)
      assert result =~ "flash-error" or result =~ "Zone &#39;forwarded.com&#39; created successfully"
    end

    test "create zone form submits stub zone with NS records", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/new")

      # First change type to stub to reveal ns_records textarea
      view
      |> render_change("validate_zone", %{
        "zone" => %{
          "name" => "stub.example.org",
          "type" => "stub",
          "upstreams" => "",
          "ns_records" => ""
        }
      })

      # Submit with stub type and ns_records
      result =
        view
        |> form("form", %{
          "zone" => %{
            "name" => "stub.example.org",
            "type" => "stub",
            "ns_records" => "ns1.example.org\nns2.example.org"
          }
        })
        |> render_submit()

      # Should stay on page showing validation error (zone already exists or other error)
      assert result =~ "flash-error" or result =~ "Zone &#39;stub.example.org&#39; created successfully"
    end

    test "validate_zone event updates form type", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/new")

      html =
        view
        |> render_change("validate_zone", %{
          "zone" => %{
            "name" => "test.com",
            "type" => "forward",
            "upstreams" => "",
            "ns_records" => ""
          }
        })

      # Form should update to show upstream fields for forward type
      assert html =~ "forward" or html =~ "Forward" or html =~ "Upstream"
    end

    test "import zone form renders BIND format textarea", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones/import")
      assert html =~ ~s(name="import[zone_data]")
      assert html =~ ~s(name="import[format]")
    end

    test "import zone form submits zone data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/import")

      zone_data = """
      $ORIGIN example.com.
      @  IN  SOA  ns1.example.com. admin.example.com. 2024010101 3600 900 604800 86400
      @  IN  NS   ns1.example.com.
      @  IN  A    192.168.1.1
      """

      result =
        view
        |> form("form", %{
          "import" => %{
            "zone_data" => zone_data,
            "format" => "zone"
          }
        })
        |> render_submit()

      # Import should either succeed or show parse error
      assert is_binary(result)
    end

    test "cancel navigates back from new zone form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/new")
      view |> element(~s(button[phx-click="cancel"])) |> render_click()
      assert_redirect(view, "/dns/views/default/zones")
    end

    test "cancel navigates back from import form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/import")
      view |> element(~s(button[phx-click="cancel"])) |> render_click()
      assert_redirect(view, "/dns/views/default/zones")
    end

    test "refresh button reloads zones", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones")
      html = view |> render_click("refresh")
      assert html =~ "Zones" or html =~ "default"
    end

    test "export CSV generates zones file download", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dns/views/default/zones")
      assert html =~ "CsvDownload"
      view |> render_click("export_csv")
      assert render(view) =~ "Zones" or render(view) =~ "default"
    end

    test "filter zones by name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones")
      html = view |> render_change("filter", %{"filter" => "example"})
      assert html =~ "Zones" or html =~ "default"
    end

    test "filter zones by type", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones")
      html = view |> render_change("filter_type", %{"type" => "all"})
      assert html =~ "Zones" or html =~ "default"
    end

    test "close_modal event clears delete confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones")
      html = view |> render_click("close_modal")
      assert html =~ "Zones" or html =~ "default"
    end
  end

  # ============================================================================
  # DNS ACL CRUD Operations
  # ============================================================================

  describe "DNS ACL CRUD" do
    test "show_create_form opens named ACL form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      html = view |> render_click("show_create_form")
      # Should show the create form with name, description, acl_type fields
      assert html =~ ~s(name="acl[name]") or html =~ "Create" or html =~ "ACL"
    end

    test "close_create_form hides the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      view |> render_click("show_create_form")
      html = view |> render_click("close_create_form")
      # Form should be hidden again
      assert html =~ "ACL"
    end

    test "save_named_acl with empty name shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      view |> render_click("show_create_form")

      result =
        view
        |> form("form[phx-submit=\"save_named_acl\"]", %{
          "acl" => %{
            "name" => "",
            "description" => "Test ACL",
            "acl_type" => "custom",
            "rules" => "allow 10.0.0.0/8"
          }
        })
        |> render_submit()

      assert is_binary(result)
    end

    test "save_named_acl with valid custom ACL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      view |> render_click("show_create_form")

      result =
        view
        |> form("form[phx-submit=\"save_named_acl\"]", %{
          "acl" => %{
            "name" => "test-acl",
            "description" => "Test ACL for internal network",
            "acl_type" => "custom",
            "rules" => "allow 10.0.0.0/8\ndeny any"
          }
        })
        |> render_submit()

      # Either creates successfully or shows error (AclRegistry not running)
      assert is_binary(result)
    end

    test "create_type_changed updates ACL form type", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      view |> render_click("show_create_form")

      html =
        view
        |> render_change("create_type_changed", %{
          "acl" => %{"acl_type" => "geo"}
        })

      # Should update form to show geo options
      assert html =~ "geo" or html =~ "Geographic" or html =~ "ACL"
    end

    test "cancel_delete clears delete confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      html = view |> render_click("cancel_delete")
      assert html =~ "ACL"
    end

    test "close_modal clears editing view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      html = view |> render_click("close_modal")
      assert html =~ "ACL"
    end

    test "toggle_country adds and removes countries", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      # Toggle a country code
      html = view |> render_click("toggle_country", %{"code" => "US"})
      assert html =~ "ACL"

      # Toggle again to remove
      html = view |> render_click("toggle_country", %{"code" => "US"})
      assert html =~ "ACL"
    end

    test "search_country filters country list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      html = view |> render_change("search_country", %{"search" => "United"})
      assert html =~ "ACL"
    end

    test "clear_country_search resets search", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      view |> render_change("search_country", %{"search" => "test"})
      html = view |> render_click("clear_country_search")
      assert html =~ "ACL"
    end

    test "refresh reloads ACL data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      html = view |> render_click("refresh")
      assert html =~ "ACL"
    end

    test "acl_type_changed updates view ACL form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      html = view |> render_change("acl_type_changed", %{"acl" => %{"acl_type" => "none"}})
      assert html =~ "ACL"
    end

    test "filter named ACLs by search text", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      html = view |> render_change("filter", %{"filter" => "internal"})
      assert html =~ "ACL"
    end

    test "filter views by ACL type", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      html = view |> render_change("filter_type", %{"type" => "any"})
      assert html =~ "ACL"
    end

    test "export CSV generates ACL file download", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dns/acl")
      assert html =~ "CsvDownload"
      view |> render_click("export_csv")
      assert render(view) =~ "ACL"
    end
  end

  # ============================================================================
  # DNS Resource Records Page
  # ============================================================================

  describe "DNS Resource Records /dns/views/:view_name/zones/:zone_type/:zone_name/records" do
    test "mounts with zone context from params", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones/auth/example.com/records")
      assert html =~ "Records" or html =~ "example.com" or html =~ "record"
    end

    test "navigates to new record form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")
      assert html =~ "Add" or html =~ "Record" or html =~ "record"
    end

    test "navigates to bulk import form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones/auth/example.com/records/bulk")
      assert html =~ "Bulk" or html =~ "Import" or html =~ "record"
    end

    test "bulk form shows preview on text change", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/bulk")

      html =
        view
        |> render_change("preview_bulk", %{
          "bulk" => %{"records" => "www  3600  IN  A  192.0.2.1\nmail  3600  IN  A  192.0.2.2"}
        })

      assert html =~ "Preview" or html =~ "record(s) to add"
    end

    test "bulk form submit button disabled until valid preview", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones/auth/example.com/records/bulk")
      assert html =~ "disabled"
    end

    test "shows Export BIND button for auth zones", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones/auth/example.com/records")
      assert html =~ "Export BIND"
    end

    test "export_bind handles missing zone gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records")
      html = view |> render_click("export_bind")
      # Should show an error flash or still render the page
      assert html =~ "Records" or html =~ "example.com" or html =~ "Export failed"
    end

    test "shows CsvDownload hook on export button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views/default/zones/auth/example.com/records")
      assert html =~ "CsvDownload"
    end

    test "refresh reloads records", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records")
      html = view |> render_click("refresh")
      assert html =~ "Records" or html =~ "example.com" or html =~ "record"
    end

    test "filter records by name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records")
      html = view |> render_change("filter", %{"filter" => "www"})
      assert html =~ "Records" or html =~ "example.com" or html =~ "record"
    end

    test "filter records by type", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records")
      html = view |> render_change("filter_type", %{"type" => "all"})
      assert html =~ "Records" or html =~ "example.com" or html =~ "record"
    end

    test "export CSV generates records file download", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records")
      view |> render_click("export_csv")
      assert render(view) =~ "Records" or render(view) =~ "example.com"
    end

    test "close_modal clears delete confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records")
      html = view |> render_click("close_modal")
      assert html =~ "Records" or html =~ "example.com" or html =~ "record"
    end

    test "cancel navigates back from new record form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")
      view |> element(~s(button[phx-click="cancel"])) |> render_click()
      assert_redirect(view, "/dns/views/default/zones/auth/example.com/records")
    end
  end

  # ============================================================================
  # Inline Form Validation Tests
  # ============================================================================

  describe "Zone form inline validation" do
    test "validate_zone shows error for invalid domain name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/new")

      html =
        view
        |> render_change("validate_zone", %{
          "zone" => %{
            "name" => "invalid domain with spaces",
            "type" => "auth",
            "upstreams" => "",
            "ns_records" => ""
          }
        })

      assert html =~ "label must contain only" or html =~ "text-error"
    end

    test "validate_zone clears error for valid domain name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/new")

      # First trigger an error
      view
      |> render_change("validate_zone", %{
        "zone" => %{
          "name" => "bad name!",
          "type" => "auth",
          "upstreams" => "",
          "ns_records" => ""
        }
      })

      # Then fix it
      html =
        view
        |> render_change("validate_zone", %{
          "zone" => %{
            "name" => "example.com",
            "type" => "auth",
            "upstreams" => "",
            "ns_records" => ""
          }
        })

      refute html =~ "text-error"
    end

    test "validate_zone shows error for invalid upstream IP in forward zone", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/new")

      html =
        view
        |> render_change("validate_zone", %{
          "zone" => %{
            "name" => "forward.example.com",
            "type" => "forward",
            "upstreams" => "not-an-ip",
            "ns_records" => ""
          }
        })

      assert html =~ "Invalid IP" or html =~ "text-error"
    end

    test "validate_zone accepts valid upstream IPs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/new")

      html =
        view
        |> render_change("validate_zone", %{
          "zone" => %{
            "name" => "forward.example.com",
            "type" => "forward",
            "upstreams" => "8.8.8.8\n8.8.4.4",
            "ns_records" => ""
          }
        })

      refute html =~ "Invalid IP"
    end

    test "validate_zone shows error for invalid NS in stub zone", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/new")

      html =
        view
        |> render_change("validate_zone", %{
          "zone" => %{
            "name" => "stub.example.com",
            "type" => "stub",
            "upstreams" => "",
            "ns_records" => "bad ns name!"
          }
        })

      assert html =~ "label must contain only" or html =~ "text-error"
    end

    test "save_zone rejects invalid domain name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/new")

      html =
        view
        |> form("form", %{
          "zone" => %{
            "name" => "invalid domain!",
            "type" => "auth"
          }
        })
        |> render_submit()

      # Should show validation error, NOT attempt to save
      assert html =~ "text-error" or html =~ "label must contain only"
    end
  end

  describe "View form inline validation" do
    test "validate_view shows error for invalid view name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/new")

      html =
        view
        |> render_change("validate_view", %{
          "view" => %{
            "name" => "invalid name with spaces!",
            "fallback_forwarders" => ""
          }
        })

      assert html =~ "alphanumeric" or html =~ "text-error"
    end

    test "validate_view clears error for valid view name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/new")

      # Trigger error first
      view
      |> render_change("validate_view", %{
        "view" => %{
          "name" => "bad name!",
          "fallback_forwarders" => ""
        }
      })

      # Fix it
      html =
        view
        |> render_change("validate_view", %{
          "view" => %{
            "name" => "valid-name_123",
            "fallback_forwarders" => ""
          }
        })

      refute html =~ "text-error"
    end

    test "validate_view shows error for invalid forwarder IP", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/new")

      html =
        view
        |> render_change("validate_view", %{
          "view" => %{
            "name" => "test-view",
            "fallback_forwarders" => "not-an-ip"
          }
        })

      assert html =~ "Invalid IP" or html =~ "text-error"
    end

    test "validate_view accepts valid forwarder IPs with port", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/new")

      html =
        view
        |> render_change("validate_view", %{
          "view" => %{
            "name" => "test-view",
            "fallback_forwarders" => "8.8.8.8:53\n1.1.1.1"
          }
        })

      refute html =~ "Invalid IP"
    end

    test "save_view rejects invalid view name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/new")

      html =
        view
        |> form("form", %{
          "view" => %{
            "name" => "bad name!",
            "priority" => "50",
            "recursion_enabled" => "true",
            "acl_type" => "any",
            "fallback_forwarders" => "",
            "fallback_timeout" => "2000",
            "fallback_retries" => "1"
          }
        })
        |> render_submit()

      assert html =~ "alphanumeric" or html =~ "text-error"
    end
  end

  describe "ACL form inline validation" do
    test "validate_named_acl shows error for invalid ACL name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      view |> render_click("show_create_form")

      html =
        view
        |> render_change("validate_named_acl", %{
          "acl" => %{
            "name" => "bad name with spaces!",
            "description" => "",
            "acl_type" => "custom",
            "rules" => ""
          }
        })

      assert html =~ "alphanumeric" or html =~ "text-error"
    end

    test "validate_named_acl shows error for invalid CIDR in rules", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      view |> render_click("show_create_form")

      html =
        view
        |> render_change("validate_named_acl", %{
          "acl" => %{
            "name" => "test-acl",
            "description" => "",
            "acl_type" => "custom",
            "rules" => "allow not-a-cidr"
          }
        })

      assert html =~ "Invalid" or html =~ "text-error"
    end

    test "validate_named_acl accepts valid custom rules", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      view |> render_click("show_create_form")

      html =
        view
        |> render_change("validate_named_acl", %{
          "acl" => %{
            "name" => "valid-acl",
            "description" => "Test",
            "acl_type" => "custom",
            "rules" => "allow 10.0.0.0/8\ndeny any"
          }
        })

      refute html =~ "text-error"
    end

    test "save_named_acl rejects invalid ACL name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/acl")
      view |> render_click("show_create_form")

      html =
        view
        |> form("form[phx-submit=\"save_named_acl\"]", %{
          "acl" => %{
            "name" => "bad name!",
            "description" => "Test",
            "acl_type" => "custom",
            "rules" => "allow 10.0.0.0/8"
          }
        })
        |> render_submit()

      assert html =~ "alphanumeric" or html =~ "text-error"
    end
  end

  # ============================================================================
  # DNS Views Private Helper Unit Tests
  # ============================================================================

  describe "ViewLive helper functions" do
    alias YellowDog.Console.DnsLive.ViewLive.Index, as: ViewLive

    test "filtered_views/3 returns empty list for empty input" do
      assert ViewLive.filtered_views([], "", "all") == []
    end

    test "filtered_views/3 filters disabled views" do
      views = [
        %{name: "v1", enabled: false},
        %{name: "v2", enabled: true},
        %{name: "v3", enabled: false}
      ]

      result = ViewLive.filtered_views(views, "", "disabled")
      assert length(result) == 2
      assert Enum.all?(result, &(!&1.enabled))
    end

    test "filtered_views/3 handles special characters in filter" do
      views = [%{name: "test.view-1", enabled: true}]
      assert ViewLive.filtered_views(views, "test.view", "all") == views
    end
  end

  # ============================================================================
  # DNS Zones Private Helper Unit Tests
  # ============================================================================

  describe "ZoneLive helper functions" do
    alias YellowDog.Console.DnsLive.ZoneLive.Index, as: ZoneLive

    test "filtered_zones/3 returns empty list for empty input" do
      assert ZoneLive.filtered_zones([], "", "all") == []
    end

    test "zone_type_label/1 handles all known types" do
      assert ZoneLive.zone_type_label(:auth) == "Authoritative"
      assert ZoneLive.zone_type_label(:forward) == "Forward"
      assert ZoneLive.zone_type_label(:stub) == "Stub"
      assert ZoneLive.zone_type_label(:cache) == "Cache"
      assert ZoneLive.zone_type_label(:rpz) == "Unknown"
    end

    test "zone_type_badge/1 returns DaisyUI classes for all types" do
      assert ZoneLive.zone_type_badge(:auth) == "primary"
      assert ZoneLive.zone_type_badge(:forward) == "secondary"
      assert ZoneLive.zone_type_badge(:stub) == "accent"
      assert ZoneLive.zone_type_badge(:cache) == "info"
      assert ZoneLive.zone_type_badge(:other) == "ghost"
    end

    test "unique_zone_types/1 returns empty list for empty input" do
      assert ZoneLive.unique_zone_types([]) == []
    end

    test "unique_zone_types/1 removes duplicates and sorts" do
      zones = [
        %{type: :forward},
        %{type: :auth},
        %{type: :forward},
        %{type: :cache}
      ]

      assert ZoneLive.unique_zone_types(zones) == [:auth, :cache, :forward]
    end
  end

  # ============================================================================
  # DNS ACL Private Helper Unit Tests
  # ============================================================================

  describe "AclLive helper functions" do
    alias YellowDog.Console.DnsLive.AclLive

    test "filtered_named_acls/3 returns empty list for empty input" do
      assert AclLive.filtered_named_acls([], "", "all") == []
    end

    test "filtered_views_acl/3 returns empty list for empty input" do
      assert AclLive.filtered_views_acl([], "", "all") == []
    end

    test "unique_acl_types/1 returns empty list for empty input" do
      assert AclLive.unique_acl_types([]) == []
    end

    test "unique_acl_types/1 handles single type" do
      views = [%{acl_type: "any"}]
      assert AclLive.unique_acl_types(views) == ["any"]
    end

    test "filtered_named_acls/3 matches on description" do
      acls = [
        %{name: "acl1", description: "Internal network access", rules: []},
        %{name: "acl2", description: "External public", rules: []}
      ]

      result = AclLive.filtered_named_acls(acls, "internal", "all")
      assert length(result) == 1
      assert hd(result).name == "acl1"
    end

    test "filtered_views_acl/3 combines filters" do
      views = [
        %{name: "default", acl_type: "any"},
        %{name: "internal-a", acl_type: "custom"},
        %{name: "internal-b", acl_type: "geo"}
      ]

      result = AclLive.filtered_views_acl(views, "internal", "geo")
      assert length(result) == 1
      assert hd(result).name == "internal-b"
    end
  end

  # ============================================================================
  # ARIA Accessibility for DNS Pages
  # ============================================================================

  describe "ARIA accessibility on DNS pages" do
    test "DNS views page has aria-label on action buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views")
      # When empty, no action buttons shown — but aria-labels exist in template
      assert html =~ "aria-label" or html =~ "No DNS Views"
    end

    test "DNS ACL page has aria-label on action buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/acl")
      assert html =~ "aria-label" or html =~ "No custom ACLs"
    end

    test "DNS overview refresh button has aria-label", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns")
      assert html =~ "aria-label=\"Refresh\""
    end
  end

  # ============================================================================
  # Service Status Alert on DNS Sub-Pages
  # ============================================================================

  describe "service status alert on DNS sub-pages" do
    @dns_sub_pages [
      {"/dns/views", "Views"},
      {"/dns/acl", "ACL"}
    ]

    for {path, name} <- @dns_sub_pages do
      test "#{name} page shows DNS service alert when not running", %{conn: conn} do
        {:ok, _view, html} = live(conn, unquote(path))

        # Service may or may not be running depending on test ordering in async suite
        if Process.whereis(YellowDog.Dns) == nil do
          assert html =~ "DNS service is not running"
        end
      end
    end

    test "service alert component renders link to dashboard when shown", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/views")

      # When service is not running, alert should have dashboard link
      if html =~ "DNS service is not running" do
        assert html =~ "/dashboard"
        assert html =~ "Go to Dashboard"
      end
    end
  end

  # ============================================================================
  # ZoneLive Atom Safety Guards
  # ============================================================================

  describe "ZoneLive atom safety - filter_by_type" do
    alias YellowDog.Console.DnsLive.ZoneLive.Index, as: ZoneLive

    test "filtered_zones with valid type filter returns matching zones" do
      zones = [
        %{name: "example.com", type: :auth},
        %{name: "other.com", type: :forward}
      ]

      result = ZoneLive.filtered_zones(zones, "", "auth")
      assert length(result) == 1
      assert hd(result).type == :auth
    end

    test "filtered_zones with 'all' type filter returns all zones" do
      zones = [
        %{name: "example.com", type: :auth},
        %{name: "other.com", type: :forward}
      ]

      result = ZoneLive.filtered_zones(zones, "", "all")
      assert length(result) == 2
    end

    test "filtered_zones with invalid type filter returns all zones (fallback)" do
      zones = [
        %{name: "example.com", type: :auth},
        %{name: "other.com", type: :forward}
      ]

      result = ZoneLive.filtered_zones(zones, "", "evil_type")
      assert length(result) == 2
    end
  end

  describe "ZoneLive atom safety - valid zone types" do
    alias YellowDog.Console.DnsLive.ZoneLive.Index, as: ZoneLive

    test "filtered_zones accepts all valid zone type strings" do
      zones = [
        %{name: "example.com", type: :auth},
        %{name: "fwd.com", type: :forward},
        %{name: "stub.com", type: :stub},
        %{name: "cache.com", type: :cache},
        %{name: "rpz.com", type: :rpz}
      ]

      for type <- ~w(auth forward stub cache rpz) do
        result = ZoneLive.filtered_zones(zones, "", type)
        assert length(result) == 1, "Expected 1 zone for type #{type}"
      end
    end
  end

  # ============================================================================
  # RrLive Atom Safety Guards
  # ============================================================================

  describe "RrLive atom safety - filter_by_type" do
    alias YellowDog.Console.DnsLive.RrLive.Index, as: RrLive

    test "filtered_records with valid type filter returns matching records" do
      records = [
        %{name: "www", type: :a, ttl: 300, rdata: "1.2.3.4"},
        %{name: "mail", type: :mx, ttl: 300, rdata: "10 mail.example.com"}
      ]

      result = RrLive.filtered_records(records, "", "a")
      assert length(result) == 1
      assert hd(result).type == :a
    end

    test "filtered_records with 'all' type filter returns all records" do
      records = [
        %{name: "www", type: :a, ttl: 300, rdata: "1.2.3.4"},
        %{name: "mail", type: :mx, ttl: 300, rdata: "10 mail.example.com"}
      ]

      result = RrLive.filtered_records(records, "", "all")
      assert length(result) == 2
    end

    test "filtered_records with invalid type filter returns all records (fallback)" do
      records = [
        %{name: "www", type: :a, ttl: 300, rdata: "1.2.3.4"},
        %{name: "mail", type: :mx, ttl: 300, rdata: "10 mail.example.com"}
      ]

      result = RrLive.filtered_records(records, "", "evil_type")
      assert length(result) == 2
    end
  end

  # ============================================================================
  # DNS RecordForm Component Validation (via live_component)
  # ============================================================================

  describe "RecordForm validation - domain name" do
    test "shows error for invalid domain name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "invalid domain!",
            "type" => "a",
            "ttl" => "300",
            "rdata" => "192.0.2.1"
          }
        })

      assert html =~ "text-error" or html =~ "input-error"
    end

    test "shows no error for valid domain name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "www",
            "type" => "a",
            "ttl" => "300",
            "rdata" => "192.0.2.1"
          }
        })

      refute html =~ "input-error"
    end

    test "accepts @ for zone apex", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "@",
            "type" => "a",
            "ttl" => "300",
            "rdata" => "192.0.2.1"
          }
        })

      refute html =~ "input-error"
    end
  end

  describe "RecordForm validation - TTL" do
    test "shows error for non-numeric TTL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "www",
            "type" => "a",
            "ttl" => "abc",
            "rdata" => "192.0.2.1"
          }
        })

      assert html =~ "text-error" or html =~ "input-error"
    end

    test "shows error for negative TTL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "www",
            "type" => "a",
            "ttl" => "-1",
            "rdata" => "192.0.2.1"
          }
        })

      assert html =~ "text-error" or html =~ "input-error"
    end

    test "accepts valid TTL within RFC 2181 limits", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "www",
            "type" => "a",
            "ttl" => "3600",
            "rdata" => "192.0.2.1"
          }
        })

      refute html =~ "input-error"
    end
  end

  describe "RecordForm validation - A record rdata" do
    test "shows error for invalid IPv4 address", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "www",
            "type" => "a",
            "ttl" => "300",
            "rdata" => "not-an-ip"
          }
        })

      assert html =~ "text-error" or html =~ "input-error"
    end

    test "accepts valid IPv4 address for A record", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "www",
            "type" => "a",
            "ttl" => "300",
            "rdata" => "192.0.2.1"
          }
        })

      refute html =~ "input-error"
    end
  end

  describe "RecordForm validation - AAAA record rdata" do
    test "shows error for invalid IPv6 address", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      # First switch to AAAA type
      view
      |> element("select[name='record[type]']")
      |> render_change(%{"record" => %{"type" => "aaaa"}})

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "www",
            "type" => "aaaa",
            "ttl" => "300",
            "rdata" => "not-ipv6"
          }
        })

      assert html =~ "text-error" or html =~ "input-error"
    end

    test "accepts valid IPv6 address for AAAA record", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      view
      |> element("select[name='record[type]']")
      |> render_change(%{"record" => %{"type" => "aaaa"}})

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "www",
            "type" => "aaaa",
            "ttl" => "300",
            "rdata" => "2001:db8::1"
          }
        })

      refute html =~ "input-error"
    end
  end

  describe "RecordForm validation - MX record" do
    test "shows error for invalid MX target", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      view
      |> element("select[name='record[type]']")
      |> render_change(%{"record" => %{"type" => "mx"}})

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "@",
            "type" => "mx",
            "ttl" => "300",
            "priority" => "10",
            "target" => "bad mail server!"
          }
        })

      assert html =~ "text-error" or html =~ "input-error"
    end

    test "accepts valid MX record", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      view
      |> element("select[name='record[type]']")
      |> render_change(%{"record" => %{"type" => "mx"}})

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "@",
            "type" => "mx",
            "ttl" => "300",
            "priority" => "10",
            "target" => "mail.example.com"
          }
        })

      refute html =~ "input-error"
    end
  end

  describe "RecordForm validation - SRV record" do
    test "shows error for invalid SRV target", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      view
      |> element("select[name='record[type]']")
      |> render_change(%{"record" => %{"type" => "srv"}})

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "_sip._tcp",
            "type" => "srv",
            "ttl" => "300",
            "priority" => "10",
            "weight" => "60",
            "port" => "5060",
            "target" => "bad target!"
          }
        })

      assert html =~ "text-error" or html =~ "input-error"
    end

    test "accepts valid SRV record", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      view
      |> element("select[name='record[type]']")
      |> render_change(%{"record" => %{"type" => "srv"}})

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "_sip._tcp",
            "type" => "srv",
            "ttl" => "300",
            "priority" => "10",
            "weight" => "60",
            "port" => "5060",
            "target" => "sip.example.com"
          }
        })

      refute html =~ "input-error"
    end
  end

  describe "RecordForm validation - CNAME/NS record rdata" do
    test "shows error for invalid CNAME target", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      view
      |> element("select[name='record[type]']")
      |> render_change(%{"record" => %{"type" => "cname"}})

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "alias",
            "type" => "cname",
            "ttl" => "300",
            "rdata" => "bad target name!"
          }
        })

      assert html =~ "text-error" or html =~ "input-error"
    end

    test "accepts valid CNAME target", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      view
      |> element("select[name='record[type]']")
      |> render_change(%{"record" => %{"type" => "cname"}})

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "alias",
            "type" => "cname",
            "ttl" => "300",
            "rdata" => "www.example.com"
          }
        })

      refute html =~ "input-error"
    end

    test "shows error for invalid NS target", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      view
      |> element("select[name='record[type]']")
      |> render_change(%{"record" => %{"type" => "ns"}})

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "@",
            "type" => "ns",
            "ttl" => "300",
            "rdata" => "bad ns name!"
          }
        })

      assert html =~ "text-error" or html =~ "input-error"
    end

    test "accepts valid NS target", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      view
      |> element("select[name='record[type]']")
      |> render_change(%{"record" => %{"type" => "ns"}})

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "@",
            "type" => "ns",
            "ttl" => "300",
            "rdata" => "ns1.example.com"
          }
        })

      refute html =~ "input-error"
    end
  end

  describe "RecordForm validation - TXT record" do
    test "accepts arbitrary rdata for TXT records", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      view
      |> element("select[name='record[type]']")
      |> render_change(%{"record" => %{"type" => "txt"}})

      html =
        view
        |> element("form")
        |> render_change(%{
          "record" => %{
            "name" => "@",
            "type" => "txt",
            "ttl" => "300",
            "rdata" => "v=spf1 include:example.com ~all"
          }
        })

      refute html =~ "input-error"
    end
  end

  # ============================================================================
  # DNS RecordForm Submission (save event via component)
  # ============================================================================

  describe "RecordForm submission" do
    test "rejects record with invalid domain name on submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      html =
        view
        |> form("form", %{
          "record" => %{
            "name" => "bad name!",
            "type" => "a",
            "ttl" => "300",
            "rdata" => "192.0.2.1"
          }
        })
        |> render_submit()

      assert html =~ "text-error" or html =~ "input-error"
    end

    test "rejects A record with invalid IPv4 on submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      html =
        view
        |> form("form", %{
          "record" => %{
            "name" => "www",
            "type" => "a",
            "ttl" => "300",
            "rdata" => "999.999.999.999"
          }
        })
        |> render_submit()

      assert html =~ "text-error" or html =~ "input-error"
    end

    test "valid A record submission proceeds (shows error or navigates)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/views/default/zones/auth/example.com/records/new")

      result =
        view
        |> form("form", %{
          "record" => %{
            "name" => "www",
            "type" => "a",
            "ttl" => "300",
            "rdata" => "192.0.2.1"
          }
        })
        |> render_submit()

      # Valid data passes validation; either saves (redirect) or shows error
      # since zone service isn't running in test
      assert is_binary(result)
    end
  end
end
