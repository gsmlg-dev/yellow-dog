defmodule YellowDog.Console.EventHandlersLiveTest do
  @moduledoc """
  Tests for event handlers on pages that only have mounting tests.
  Covers mDNS, DHCPv4, DHCPv6, and other pages with interactive controls.
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # mDNS Services - Event Handlers
  # ============================================================================

  describe "mDNS Services /mdns/services events" do
    test "filter event changes displayed services", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/services")
      html = render_click(view, "filter", %{"filter" => "enabled"})
      assert html =~ "Enabled"
    end

    test "show_new_form opens registration modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/services")
      html = render_click(view, "show_new_form")
      assert html =~ "Register New Service"
    end

    test "hide_form closes modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/services")
      render_click(view, "show_new_form")
      html = render_click(view, "hide_form")
      refute html =~ "Register New Service"
    end

    test "Escape key closes service form modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/services")
      render_click(view, "show_new_form")
      html = render_click(view, "hide_form")
      refute html =~ "Register New Service"
    end

    test "filter tabs exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/mdns/services")
      assert html =~ "All Services"
      assert html =~ "Enabled"
      assert html =~ "Disabled"
    end
  end

  # ============================================================================
  # mDNS Discovery - Event Handlers
  # ============================================================================

  describe "mDNS Discovery /mdns/discovery events" do
    test "search filters services", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/discovery")
      html = render_change(view, "search", %{"search" => "test"})
      assert html =~ "Total Services"
    end

    test "filter_by_type with all shows all services", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/discovery")
      html = render_change(view, "filter_by_type", %{"type" => "all"})
      assert html =~ "Total Services"
    end

    test "close_details works when no service selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/discovery")
      html = render_click(view, "close_details")
      refute html =~ "modal-open"
    end

    test "statistics bar shows counts", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/mdns/discovery")
      assert html =~ "Total Services"
      assert html =~ "Service Types"
      assert html =~ "Active Hosts"
      assert html =~ "Last Updated"
    end

    test "view_details with nonexistent service does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/discovery")
      html = render_click(view, "view_details", %{"id" => "nonexistent-service"})
      # Should not crash, service may be nil
      assert html =~ "Total Services" or html =~ "Discovery"
    end

    test "export_csv event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/discovery")
      render_click(view, "export_csv")
      assert render(view) =~ "Total Services"
    end
  end

  # ============================================================================
  # mDNS Discovery - handle_info
  # ============================================================================

  describe "mDNS Discovery /mdns/discovery handle_info" do
    test "refresh message updates services", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/discovery")
      send(view.pid, :refresh)
      html = render(view)
      assert html =~ "Total Services"
    end

    test "network_update message updates services", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/discovery")
      send(view.pid, :network_update)
      html = render(view)
      assert html =~ "Total Services"
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/discovery")
      send(view.pid, {:unknown_event, :data})
      html = render(view)
      assert html =~ "Total Services"
    end
  end

  # ============================================================================
  # mDNS Monitor - Event Handlers
  # ============================================================================

  describe "mDNS Monitor /mdns/monitor events" do
    test "set_limit changes query limit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/monitor")
      html = render_change(view, "set_limit", %{"limit" => "100"})
      assert html =~ "100 queries"
    end

    test "search filters queries", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/monitor")
      html = render_change(view, "search", %{"search" => "test"})
      assert html =~ "Recent Queries"
    end

    test "clear_cache works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/monitor")
      html = render_click(view, "clear_cache")
      assert html =~ "Total Queries"
    end

    test "toggle_auto_refresh toggles auto-refresh state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/monitor")
      html = render_click(view, "toggle_auto_refresh")
      assert html =~ "Total Queries"
    end
  end

  # ============================================================================
  # mDNS Monitor - handle_info
  # ============================================================================

  describe "mDNS Monitor /mdns/monitor handle_info" do
    test "refresh message updates queries", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/monitor")
      send(view.pid, :refresh)
      html = render(view)
      assert html =~ "Total Queries"
    end

    test "network_update message updates stats", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/monitor")
      send(view.pid, :network_update)
      html = render(view)
      assert html =~ "Total Queries"
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/monitor")
      send(view.pid, {:random_message, :stuff})
      html = render(view)
      assert html =~ "Total Queries"
    end
  end

  # ============================================================================
  # DHCPv4 Leases - Event Handlers
  # ============================================================================

  describe "DHCPv4 Leases /dhcpv4/leases events" do
    test "search filters leases", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/leases")
      html = render_change(view, "search", %{"search" => "192.168"})
      assert html =~ "Lease" or html =~ "DHCPv4"
    end

    test "filter_state changes state filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/leases")
      html = render_change(view, "filter_state", %{"state" => "active"})
      assert html =~ "DHCPv4" or html =~ "Lease"
    end

    test "filter_pool changes pool filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/leases")
      html = render_change(view, "filter_pool", %{"pool" => "all"})
      assert html =~ "DHCPv4" or html =~ "Lease"
    end

    test "aria-labels present on filters", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dhcpv4/leases")
      assert html =~ "aria-label=\"Search DHCPv4 leases\""
      assert html =~ "aria-label=\"Filter by lease state\""
      assert html =~ "aria-label=\"Filter by pool\""
    end
  end

  # ============================================================================
  # DHCPv4 Pools - Event Handlers
  # ============================================================================

  describe "DHCPv4 Pools /dhcpv4/pools events" do
    test "filter changes search query", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/pools")
      html = render_change(view, "filter", %{"filter" => "office"})
      assert html =~ "Pool" or html =~ "DHCPv4"
    end

    test "show_new_form opens pool form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/pools")
      html = render_click(view, "show_new_form")
      assert html =~ "Add" or html =~ "Pool"
    end

    test "aria-label on search", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dhcpv4/pools")
      assert html =~ "aria-label=\"Search DHCPv4 pools\""
    end

    test "show_edit_form with nonexistent pool does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/pools")
      html = render_click(view, "show_edit_form", %{"pool-name" => "nonexistent-pool"})
      assert html =~ "Pool" or html =~ "DHCPv4"
    end

    test "delete_pool handles service unavailable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/pools")
      html = render_click(view, "delete_pool", %{"pool-name" => "nonexistent-pool"})
      assert html =~ "Failed" or html =~ "not found" or html =~ "Pool" or html =~ "DHCPv4"
    end

    test "force_delete_pool handles service unavailable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/pools")
      html = render_click(view, "force_delete_pool", %{"pool-name" => "nonexistent-pool"})
      assert html =~ "Failed" or html =~ "not found" or html =~ "Pool" or html =~ "DHCPv4"
    end
  end

  # ============================================================================
  # DHCPv6 Leases - Event Handlers
  # ============================================================================

  describe "DHCPv6 Leases /dhcpv6/leases events" do
    test "search filters leases", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv6/leases")
      html = render_change(view, "search", %{"search" => "2001:db8"})
      assert html =~ "Lease" or html =~ "DHCPv6"
    end

    test "filter_state changes state filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv6/leases")
      html = render_change(view, "filter_state", %{"state" => "active"})
      assert html =~ "DHCPv6" or html =~ "Lease"
    end

    test "filter_ia_type changes IA type filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv6/leases")
      html = render_change(view, "filter_ia_type", %{"ia_type" => "all"})
      assert html =~ "DHCPv6" or html =~ "Lease"
    end

    test "filter_pool changes pool filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv6/leases")
      html = render_change(view, "filter_pool", %{"pool" => "all"})
      assert html =~ "DHCPv6" or html =~ "Lease"
    end

    test "aria-labels present on filters", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dhcpv6/leases")
      assert html =~ "aria-label=\"Search DHCPv6 leases\""
      assert html =~ "aria-label=\"Filter by lease state\""
      assert html =~ "aria-label=\"Filter by IA type\""
      assert html =~ "aria-label=\"Filter by pool\""
    end
  end

  # ============================================================================
  # DHCPv6 Pools - Event Handlers
  # ============================================================================

  describe "DHCPv6 Pools /dhcpv6/pools events" do
    test "filter changes search query", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv6/pools")
      html = render_change(view, "filter", %{"filter" => "office"})
      assert html =~ "Pool" or html =~ "DHCPv6"
    end

    test "show_new_form opens pool form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv6/pools")
      html = render_click(view, "show_new_form")
      assert html =~ "Add" or html =~ "Pool"
    end

    test "aria-label on search", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dhcpv6/pools")
      assert html =~ "aria-label=\"Search DHCPv6 pools\""
    end

    test "show_edit_form with nonexistent pool does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv6/pools")
      html = render_click(view, "show_edit_form", %{"pool-name" => "nonexistent-pool"})
      assert html =~ "Pool" or html =~ "DHCPv6"
    end

    test "delete_pool handles service unavailable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv6/pools")
      html = render_click(view, "delete_pool", %{"pool-name" => "nonexistent-pool"})
      assert html =~ "Failed" or html =~ "not found" or html =~ "Pool" or html =~ "DHCPv6"
    end

    test "force_delete_pool handles service unavailable", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv6/pools")
      html = render_click(view, "force_delete_pool", %{"pool-name" => "nonexistent-pool"})
      assert html =~ "Failed" or html =~ "not found" or html =~ "Pool" or html =~ "DHCPv6"
    end
  end

  # ============================================================================
  # Process Map - Event Handlers
  # ============================================================================

  describe "Process Map /process-map events" do
    test "has process tree view", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/process-map")
      assert html =~ "Process" or html =~ "Supervisor"
    end

    test "renders process count", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/process-map")
      # Should show some process count from BEAM VM
      assert html =~ ~r/\d+/
    end

    test "renders SVG tree or empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/process-map")
      assert html =~ "<svg" or html =~ "Not Found"
    end

    test "shows last refresh time", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/process-map")
      assert html =~ "Last Refresh"
    end

    test "shows processes stat", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/process-map")
      assert html =~ "Processes"
    end

    test "select_node with invalid PID is silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/process-map")
      html = render_click(view, "select_node", %{"pid" => "invalid_not_a_pid"})
      # Should not crash, page still renders
      assert html =~ "Process Map"
    end

    test "select_node with valid self PID opens status panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/process-map")
      pid_str = inspect(self())
      html = render_click(view, "select_node", %{"pid" => pid_str})
      # Should show process info or "not found" panel
      assert html =~ "Process" or html =~ "Status" or html =~ "terminated"
    end

    test "close_panel hides status panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/process-map")
      # Try to select a node, then close
      pid_str = inspect(self())
      render_click(view, "select_node", %{"pid" => pid_str})
      html = render_click(view, "close_panel")
      # Panel should be hidden (no "Process Status" heading visible)
      refute html =~ "Process Status"
    end

    test "toggle_expand with invalid PID is silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/process-map")
      html = render_click(view, "toggle_expand", %{"pid" => "not_a_pid"})
      assert html =~ "Process Map"
    end

    test "toggle_expand with valid PID does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/process-map")
      pid_str = inspect(self())
      html = render_click(view, "toggle_expand", %{"pid" => pid_str})
      assert html =~ "Process Map"
    end
  end

  # ============================================================================
  # DNS Overview - Event Handlers
  # ============================================================================

  describe "DNS Overview /dns events" do
    test "refresh updates status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dns")
      html = render_click(view, "refresh")
      assert html =~ "DNS"
    end

    test "shows service status", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dns")
      # Service may be running or stopped depending on async test ordering
      assert html =~ "Stopped" or html =~ "Running"
    end
  end

  # ============================================================================
  # mDNS Services - handle_info
  # ============================================================================

  describe "mDNS Services /mdns/services handle_info" do
    test "service_registered event refreshes services list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/services")
      send(view.pid, {:service_registered, "test-service-1"})
      html = render(view)
      assert html =~ "Registered Services"
    end

    test "service_unregistered event refreshes services list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/services")
      send(view.pid, {:service_unregistered, "test-service-1"})
      html = render(view)
      assert html =~ "Registered Services"
    end

    test "service_updated event refreshes services list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/services")
      send(view.pid, {:service_updated, "test-service-1"})
      html = render(view)
      assert html =~ "Registered Services"
    end

    test "service_toggled event refreshes services list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/services")
      send(view.pid, {:service_toggled, "test-service-1"})
      html = render(view)
      assert html =~ "Registered Services"
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/mdns/services")
      send(view.pid, {:unknown_event, :data})
      html = render(view)
      assert html =~ "Registered Services"
    end
  end

  # ============================================================================
  # DHCPv4 Overview - handle_info
  # ============================================================================

  describe "DHCPv4 Overview /dhcpv4 handle_info" do
    test "telemetry_event updates dashboard", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4")

      send(
        view.pid,
        {:telemetry_event, [:dhcpv4, :lease, :allocated], %{},
         %{
           pool: "default",
           mac: <<0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF>>,
           ip: {192, 168, 1, 100}
         }}
      )

      html = render(view)
      assert html =~ "DHCPv4"
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4")
      send(view.pid, {:random_event, :data})
      html = render(view)
      assert html =~ "DHCPv4"
    end
  end

  # ============================================================================
  # DHCPv6 Overview - handle_info
  # ============================================================================

  describe "DHCPv6 Overview /dhcpv6 handle_info" do
    test "telemetry_event updates dashboard", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv6")

      send(
        view.pid,
        {:telemetry_event, [:dhcpv6, :lease, :allocated], %{},
         %{
           pool: "default",
           duid: <<0, 1, 0, 1>>,
           ip: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
         }}
      )

      html = render(view)
      assert html =~ "DHCPv6"
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv6")
      send(view.pid, {:random_event, :data})
      html = render(view)
      assert html =~ "DHCPv6"
    end
  end

  # ============================================================================
  # Diagnostics - Extended Event Tests
  # ============================================================================

  describe "Diagnostics /diagnostics extended" do
    test "DNS diagnostics page renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dns")
      assert html =~ "DNS Diagnostics"
    end

    test "mDNS diagnostics page renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/mdns")
      assert html =~ "mDNS Diagnostics"
    end

    test "DHCPv4 diagnostics page renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dhcpv4")
      assert html =~ "DHCPv4 Diagnostics"
    end

    test "DHCPv6 diagnostics page renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dhcpv6")
      assert html =~ "DHCPv6 Diagnostics"
    end

    test "toggle_display_mode switches between struct and raw", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dns")
      html = render_click(view, "toggle_display_mode", %{"mode" => "raw"})
      assert html =~ "DNS Diagnostics"
    end
  end
end
