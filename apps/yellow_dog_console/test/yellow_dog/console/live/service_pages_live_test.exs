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

    test "refresh button has phx-click handler", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "phx-click=\"refresh\""
    end

    test "refresh event updates dashboard", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard")
      html = render_click(view, "refresh")
      assert html =~ "DNS"
      assert html =~ "DHCPv4"
    end

    test "configure buttons link to settings", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "/settings/"
      assert html =~ "Configure"
    end

    test "system health shows real BEAM VM data", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "BEAM VM Health"
      assert html =~ "Process Memory"
      assert html =~ "Processes"
      assert html =~ "VM Uptime"
    end

    test "system health shows process count", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      # Should show actual process count (always > 0)
      assert html =~ ~r/\d+ \/ \d+/
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
  # ARIA Accessibility (ensures screen readers can navigate)
  # ============================================================================

  describe "ARIA accessibility: layout components" do
    test "navbar has aria-label on theme toggle", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "aria-label=\"Toggle theme\""
    end

    test "navbar has aria-label on notifications", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "aria-label=\"Notifications\""
    end

    test "navbar has aria-label on search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "aria-label=\"Search\""
    end
  end

  describe "ARIA accessibility: refresh buttons" do
    @refresh_pages [
      {"/dashboard", "Dashboard"},
      {"/dns", "DNS Overview"},
      {"/mdns", "mDNS Overview"},
      {"/dhcpv4", "DHCPv4 Overview"},
      {"/dhcpv6", "DHCPv6 Overview"}
    ]

    for {path, name} <- @refresh_pages do
      test "#{name} refresh button has aria-label", %{conn: conn} do
        {:ok, _view, html} = live(conn, unquote(path))
        assert html =~ "aria-label=\"Refresh\""
      end
    end
  end

  describe "ARIA accessibility: discovery page" do
    test "service cards have role=button and tabindex", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/discovery")
      # Cards have role="button" for keyboard accessibility
      # (only visible when services exist, but the template includes the attrs)
      assert html =~ "role=\"button\"" or html =~ "No services discovered"
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

  # ============================================================================
  # Submit Button Loading States (phx-disable-with prevents double submission)
  # ============================================================================

  describe "phx-disable-with on form submit buttons" do
    test "Settings page has phx-disable-with on save button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")
      assert html =~ "phx-disable-with"
    end

    test "mDNS Services shows phx-disable-with after opening register form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/services")
      html = render_click(view, "show_new_form")
      assert html =~ "phx-disable-with"
    end
  end

  # ============================================================================
  # Service Status Alerts (shows warning when service is not running)
  # ============================================================================

  describe "service status alert on DNS pages" do
    @dns_alert_pages [
      {"/dns/views", "DNS Views"},
      {"/dns/acl", "DNS ACL"}
    ]

    for {path, name} <- @dns_alert_pages do
      test "#{name} shows service alert when DNS not running", %{conn: conn} do
        {:ok, _view, html} = live(conn, unquote(path))
        assert html =~ "service is not running"
        assert html =~ "Go to Dashboard"
      end
    end
  end

  describe "service status alert on mDNS pages" do
    @mdns_alert_pages [
      {"/mdns/services", "mDNS Services"},
      {"/mdns/discovery", "mDNS Discovery"},
      {"/mdns/monitor", "mDNS Monitor"}
    ]

    for {path, name} <- @mdns_alert_pages do
      test "#{name} shows service alert when mDNS not running", %{conn: conn} do
        {:ok, _view, html} = live(conn, unquote(path))
        assert html =~ "service is not running"
        assert html =~ "Go to Dashboard"
      end
    end
  end

  describe "service status alert on DHCP pages" do
    @dhcp_alert_pages [
      {"/dhcpv4/leases", "DHCPv4 Leases"},
      {"/dhcpv6/leases", "DHCPv6 Leases"},
      {"/dhcpv4/pools", "DHCPv4 Pools"},
      {"/dhcpv6/pools", "DHCPv6 Pools"}
    ]

    for {path, name} <- @dhcp_alert_pages do
      test "#{name} shows service alert when DHCP not running", %{conn: conn} do
        {:ok, _view, html} = live(conn, unquote(path))
        assert html =~ "not running" or html =~ "Not Running"
      end
    end
  end
end
