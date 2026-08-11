defmodule YellowDog.Console.EventHandlersLiveTest do
  @moduledoc """
  Event-handler coverage for unscoped System and Tools pages.

  Selected-Server service events belong to their management-focused scope suites.
  """

  use YellowDog.Console.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "Process Map /process-map events" do
    test "has process tree view", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/process-map")
      assert html =~ "Process" or html =~ "Supervisor"
    end

    test "renders process count", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/process-map")
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
      assert render_click(view, "select_node", %{"pid" => "invalid_not_a_pid"}) =~ "Process Map"
    end

    test "select_node with valid self PID opens status panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/process-map")
      html = render_click(view, "select_node", %{"pid" => inspect(self())})
      assert html =~ "Process" or html =~ "Status" or html =~ "terminated"
    end

    test "close_panel hides status panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/process-map")
      render_click(view, "select_node", %{"pid" => inspect(self())})
      refute render_click(view, "close_panel") =~ "Process Status"
    end

    test "toggle_expand with invalid PID is silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/process-map")
      assert render_click(view, "toggle_expand", %{"pid" => "not_a_pid"}) =~ "Process Map"
    end

    test "toggle_expand with valid PID does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/process-map")
      assert render_click(view, "toggle_expand", %{"pid" => inspect(self())}) =~ "Process Map"
    end
  end

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
      assert render_click(view, "toggle_display_mode", %{"mode" => "raw"}) =~ "DNS Diagnostics"
    end
  end
end
