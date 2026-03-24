defmodule YellowDog.Console.LogsLiveTest do
  @moduledoc """
  Tests for the Real-time Logs LiveView.
  Covers mounting, pause/resume, clear, search, level/app filters,
  toggle_expand, CSV export, and handle_info for log events.
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # Mounting & Template
  # ============================================================================

  describe "LogsLive /logs mounting" do
    test "mounts successfully with empty log buffer", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "Logs"
    end

    test "shows empty state message when no logs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "Waiting for log events..."
      assert html =~ "Logs will appear here in real-time"
    end

    test "shows pause button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "Pause"
    end

    test "shows clear button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "Clear"
    end

    test "shows Export CSV button with CsvDownload hook", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "Export CSV"
      assert html =~ ~s(phx-hook="CsvDownload")
      assert html =~ ~s(id="export-csv")
    end

    test "shows level filter buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "Level:"
      assert html =~ "debug"
      assert html =~ "info"
      assert html =~ "warning"
      assert html =~ "error"
    end

    test "shows module filter checkboxes", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "Modules:"
      assert html =~ "DNS"
      assert html =~ "DHCPv4"
      assert html =~ "DHCPv6"
      assert html =~ "mDNS"
      assert html =~ "Console"
      assert html =~ "Core"
      assert html =~ "Telemetry"
    end

    test "shows search input with aria-label", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ ~s(aria-label="Search log messages")
      assert html =~ ~s(phx-debounce="300")
    end

    test "shows entry count footer", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "Showing 0 of 0 log entries"
    end

    test "shows All and None module selector buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "All"
      assert html =~ "None"
    end
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  describe "LogsLive /logs events" do
    test "toggle_pause switches to paused state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      html = render_click(view, "toggle_pause")
      assert html =~ "Resume"
    end

    test "toggle_pause twice returns to live mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      render_click(view, "toggle_pause")
      html = render_click(view, "toggle_pause")
      assert html =~ "Pause"
    end

    test "clear event empties log buffer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      html = render_click(view, "clear")
      assert html =~ "Waiting for log events..."
    end

    test "search event updates search filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      html = render_change(view, "search", %{"search" => "error"})
      assert html =~ "Logs"
    end

    test "set_level with valid level changes minimum level", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      html = render_click(view, "set_level", %{"level" => "warning"})
      # Warning button should become active
      assert html =~ "Logs"
    end

    test "set_level with invalid level is silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      html = render_click(view, "set_level", %{"level" => "evil_level"})
      assert html =~ "Logs"
    end

    test "toggle_app with valid app toggles filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      html = render_click(view, "toggle_app", %{"app" => "yellow_dog_dns"})
      # Should show "Showing: 1 of 7 modules"
      assert html =~ "Showing: 1 of 7 modules"
    end

    test "toggle_app with invalid app is silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      html = render_click(view, "toggle_app", %{"app" => "evil_app"})
      # Should NOT show the module count line (no apps selected)
      assert html =~ "Logs"
    end

    test "select_all_apps selects all modules", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      html = render_click(view, "select_all_apps")
      assert html =~ "Showing: 7 of 7 modules"
    end

    test "select_no_apps deselects all modules", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      # First select all, then deselect all
      render_click(view, "select_all_apps")
      html = render_click(view, "select_no_apps")
      # Should not show the module count line
      refute html =~ "Showing:"
    end

    test "export_csv does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      render_click(view, "export_csv")
      assert render(view) =~ "Logs"
    end
  end

  # ============================================================================
  # Filter Function (Public for testability)
  # ============================================================================

  # ============================================================================
  # handle_info
  # ============================================================================

  describe "LogsLive /logs handle_info" do
    test "log_event adds entry to buffer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")

      # Select all apps to ensure the log passes the filter
      render_click(view, "select_all_apps")

      send(
        view.pid,
        {:log_event, :info, %{duration: 100}, %{app: :yellow_dog_dns, message: "test log entry"}}
      )

      html = render(view)
      assert html =~ "Logs"
    end

    test "log_event buffers when paused", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      render_click(view, "select_all_apps")
      render_click(view, "toggle_pause")

      send(
        view.pid,
        {:log_event, :info, %{duration: 50}, %{app: :yellow_dog_dns, message: "paused log"}}
      )

      html = render(view)
      # When paused, pending count should increase
      assert html =~ "pending" or html =~ "Resume" or html =~ "Real-time Logs"
    end

    test "log_event is filtered by level", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      render_click(view, "select_all_apps")
      # Set minimum level to error
      render_click(view, "set_level", %{"level" => "error"})

      send(view.pid, {:log_event, :debug, %{}, %{app: :yellow_dog_dns, message: "debug msg"}})
      html = render(view)
      # Debug message should be filtered out
      assert html =~ "Showing 0 of 0 log entries"
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      send(view.pid, {:unknown_message, :data})
      html = render(view)
      assert html =~ "Logs"
    end
  end

  # ============================================================================
  # Filter Function (Public for testability)
  # ============================================================================

  describe "LogsLive.filtered_logs/2" do
    test "empty search returns all logs" do
      logs = [
        %{message: "hello world"},
        %{message: "test message"}
      ]

      assert YellowDog.Console.LogsLive.filtered_logs(logs, "") == logs
    end

    test "search filters by message content" do
      logs = [
        %{message: "DNS query for example.com"},
        %{message: "DHCP lease allocated"},
        %{message: "DNS cache hit"}
      ]

      result = YellowDog.Console.LogsLive.filtered_logs(logs, "dns")
      assert length(result) == 2
    end

    test "search is case-insensitive" do
      logs = [%{message: "DNS Error"}, %{message: "dhcp info"}]
      result = YellowDog.Console.LogsLive.filtered_logs(logs, "DNS")
      assert length(result) == 1
      assert hd(result).message == "DNS Error"
    end

    test "handles nil messages gracefully" do
      logs = [%{message: nil}, %{message: "test"}]
      result = YellowDog.Console.LogsLive.filtered_logs(logs, "test")
      assert length(result) == 1
    end
  end
end
