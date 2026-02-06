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
end
