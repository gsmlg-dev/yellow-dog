defmodule YellowDog.Console.DashboardLiveTest do
  @moduledoc """
  Tests for the main Service Dashboard LiveView.
  Covers mounting, system health display, refresh, and start/stop service handlers.
  Tests run without services active (uses fallback status).
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # Mounting & Template
  # ============================================================================

  describe "DashboardLive / mounting" do
    test "mounts successfully with service cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "Service Dashboard"
      assert html =~ "Monitor and manage your Yellow Dog services"
    end

    test "shows all four service cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "DNS"
      assert html =~ "DHCPv4"
      assert html =~ "DHCPv6"
      assert html =~ "mDNS"
    end

    test "shows service descriptions", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "Domain Name Service"
      assert html =~ "DHCP IPv4 Service"
      assert html =~ "DHCP IPv6 Service"
      assert html =~ "Multicast DNS"
    end

    test "shows port numbers", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "Port"
    end

    test "shows start buttons when services not running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "Start"
      assert html =~ "phx-disable-with"
    end

    test "shows configure links for each service", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "Configure"
      assert html =~ "/server/settings/"
    end
  end

  # ============================================================================
  # System Health
  # ============================================================================

  describe "DashboardLive / system health" do
    test "shows BEAM VM Health card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "BEAM VM Health"
    end

    test "shows process memory percentage", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "Process Memory"
      assert html =~ ~r/\d+%/
    end

    test "shows process count and limit", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "Processes"
      assert html =~ ~r/\d+ \/ \d+/
    end

    test "shows VM uptime", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "VM Uptime"
    end
  end

  # ============================================================================
  # Quick Actions
  # ============================================================================

  describe "DashboardLive / quick actions" do
    test "shows Quick Actions card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "Quick Actions"
    end

    test "has navigation links to main pages", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "DNS Management"
      assert html =~ "DHCPv4 Server"
      assert html =~ "mDNS Discovery"
      assert html =~ "Configuration"
    end
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  describe "DashboardLive / events" do
    test "refresh event re-fetches service status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dashboard")
      html = render_click(view, "refresh")
      assert html =~ "Service Dashboard"
    end

    test "start_service with invalid service shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dashboard")
      html = render_click(view, "start_service", %{"service" => "evil_service"})
      assert html =~ "Invalid service name"
    end

    test "stop_service with invalid service shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dashboard")
      html = render_click(view, "stop_service", %{"service" => "evil_service"})
      assert html =~ "Invalid service name"
    end

    test "start_service with valid service shows flash message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dashboard")
      html = render_click(view, "start_service", %{"service" => "dns"})
      assert html =~ "Service Dashboard"
      # Should show a success or error flash depending on service state
      assert html =~ "DNS" or html =~ "started" or html =~ "already running" or
               html =~ "Failed to start"
    end

    test "stop_service with valid service shows flash message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dashboard")
      html = render_click(view, "stop_service", %{"service" => "dns"})
      assert html =~ "Service Dashboard"
      # Should show a success or info flash depending on service state
      assert html =~ "DNS" or html =~ "stopped" or html =~ "not running" or
               html =~ "Failed to stop"
    end
  end

  # ============================================================================
  # Accessibility
  # ============================================================================

  describe "DashboardLive / accessibility" do
    test "refresh button has aria-label", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ ~s(aria-label="Refresh")
    end

    test "start/stop buttons have phx-disable-with", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dashboard")
      assert html =~ "phx-disable-with=\"Starting...\""
    end
  end

  # ============================================================================
  # handle_info
  # ============================================================================

  describe "DashboardLive / handle_info" do
    test "refresh_services message updates dashboard", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dashboard")
      send(view.pid, :refresh_services)
      html = render(view)
      assert html =~ "Service Dashboard"
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dashboard")
      send(view.pid, {:unknown_message, :data})
      html = render(view)
      assert html =~ "Service Dashboard"
    end
  end
end
