defmodule YellowDog.Console.ServicePagesLiveTest do
  @moduledoc """
  LiveView tests for service pages: Dashboard, mDNS, DHCPv4, DHCPv6.
  Tests page mounting and basic rendering when services are not running.
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # Dashboard
  # ============================================================================

  describe "Dashboard /dashboard" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "Dashboard" or html =~ "YellowDog"
    end

    test "shows service status cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "DNS"
      assert html =~ "mDNS"
      assert html =~ "DHCPv4"
      assert html =~ "DHCPv6"
    end

    test "shows stopped status when services not running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "Stopped"
    end

    test "shows port numbers for services", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "53" or html =~ "67" or html =~ "547" or html =~ "5353"
    end
  end

  # ============================================================================
  # mDNS Pages
  # ============================================================================

  describe "mDNS Overview /mdns" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns")
      assert html =~ "mDNS"
    end
  end

  describe "mDNS Services /mdns/services" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/services")
      assert html =~ "Service" or html =~ "mDNS"
    end

    test "has export button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/services")
      assert html =~ "Export"
    end
  end

  describe "mDNS Discovery /mdns/discovery" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/discovery")
      assert html =~ "Discovery" or html =~ "Discover"
    end

    test "has search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/discovery")
      assert html =~ "search" or html =~ "Search" or html =~ "Filter"
    end

    test "has export button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/discovery")
      assert html =~ "Export"
    end
  end

  describe "mDNS Monitor /mdns/monitor" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "Monitor" or html =~ "Network"
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "Export CSV"
    end

    test "has search input for queries", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "Search queries"
    end

    test "has auto-refresh toggle", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "Auto-Refresh"
    end

    test "toggle_auto_refresh switches state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      html = render_click(view, "toggle_auto_refresh")
      assert html =~ "Auto-Refresh Off"
    end

    test "has query limit selector", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "50 queries"
      assert html =~ "100 queries"
    end

    test "shows network statistics", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "Total Queries"
      assert html =~ "Total Responses"
      assert html =~ "Unique Hosts"
    end
  end

  # ============================================================================
  # DHCPv4 Pages
  # ============================================================================

  describe "DHCPv4 Overview /dhcpv4" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4")
      assert html =~ "DHCPv4" or html =~ "DHCP"
    end
  end

  describe "DHCPv4 Leases /dhcpv4/leases" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/leases")
      assert html =~ "Lease" or html =~ "DHCPv4"
    end

    test "has export button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/leases")
      assert html =~ "Export"
    end

    test "has search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/leases")
      assert html =~ "search" or html =~ "Search"
    end

    test "has state filter", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/leases")
      assert html =~ "All States" or html =~ "state"
    end
  end

  describe "DHCPv4 Pools /dhcpv4/pools" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/pools")
      assert html =~ "Pool" or html =~ "DHCPv4"
    end

    test "has search filter input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/pools")
      assert html =~ "Search pools"
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/pools")
      assert html =~ "Export CSV"
    end
  end

  # ============================================================================
  # DHCPv6 Pages
  # ============================================================================

  describe "DHCPv6 Overview /dhcpv6" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6")
      assert html =~ "DHCPv6" or html =~ "DHCP"
    end
  end

  describe "DHCPv6 Leases /dhcpv6/leases" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/leases")
      assert html =~ "Lease" or html =~ "DHCPv6"
    end

    test "has export button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/leases")
      assert html =~ "Export"
    end

    test "has search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/leases")
      assert html =~ "search" or html =~ "Search"
    end

    test "has state filter", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/leases")
      assert html =~ "All States" or html =~ "state"
    end
  end

  describe "DHCPv6 Pools /dhcpv6/pools" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/pools")
      assert html =~ "Pool" or html =~ "DHCPv6"
    end

    test "has search filter input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/pools")
      assert html =~ "Search pools"
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/pools")
      assert html =~ "Export CSV"
    end
  end

  # ============================================================================
  # Other Pages
  # ============================================================================

  describe "Diagnostics /diagnostics" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/diagnostics")
      assert html =~ "Diagnostics"
    end
  end

  describe "Logs /logs" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/logs")
      assert html =~ "Log" or html =~ "log"
    end

    test "has search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/logs")
      assert html =~ "Search log messages"
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/logs")
      assert html =~ "Export CSV"
    end

    test "has pause/resume button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/logs")
      assert html =~ "Pause"
    end

    test "has level filter buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/logs")
      assert html =~ "debug"
      assert html =~ "info"
      assert html =~ "warning"
      assert html =~ "error"
    end

    test "has module filter badges", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/logs")
      assert html =~ "DNS"
      assert html =~ "DHCPv4"
      assert html =~ "mDNS"
    end

    test "toggle_pause switches to paused state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/logs")
      html = render_click(view, "toggle_pause")
      assert html =~ "Resume"
    end

    test "toggle_pause back to streaming", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/logs")
      render_click(view, "toggle_pause")
      html = render_click(view, "toggle_pause")
      assert html =~ "Pause"
    end

    test "set_level changes minimum log level", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/logs")
      html = render_click(view, "set_level", %{"level" => "warning"})
      assert html =~ "warning"
    end

    test "clear removes all logs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/logs")
      html = render_click(view, "clear")
      assert html =~ "Showing 0"
    end

    test "select_all_apps and select_no_apps toggle module filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/logs")
      html = render_click(view, "select_all_apps")
      assert html =~ "Showing:"
      html = render_click(view, "select_no_apps")
      refute html =~ "Showing:"
    end
  end

  describe "Process Map /process-map" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/process-map")
      assert html =~ "Process" or html =~ "process"
    end
  end

  describe "Settings /settings" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")
      assert html =~ "Settings" or html =~ "Configuration"
    end
  end

  # ============================================================================
  # CsvDownload Hook Presence (ensures export buttons work)
  # ============================================================================

  describe "CsvDownload hook on export pages" do
    @csv_pages [
      {"/mdns/services", "mDNS Services"},
      {"/mdns/discovery", "mDNS Discovery"},
      {"/mdns/monitor", "mDNS Monitor"},
      {"/dhcpv4/leases", "DHCPv4 Leases"},
      {"/dhcpv4/pools", "DHCPv4 Pools"},
      {"/dhcpv6/leases", "DHCPv6 Leases"},
      {"/dhcpv6/pools", "DHCPv6 Pools"},
      {"/logs", "Logs"}
    ]

    for {path, name} <- @csv_pages do
      test "#{name} page has CsvDownload hook", %{conn: conn} do
        {:ok, _view, html} = live(conn, unquote(path))
        assert html =~ "CsvDownload"
      end
    end
  end
end
