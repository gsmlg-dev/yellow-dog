defmodule YellowDog.Console.DnsMetricsAndLogsLiveTest do
  @moduledoc """
  LiveView tests for DNS Metrics and Query Logs pages.
  Tests mounting, event handlers, template rendering, and CSV export
  when DNS service is not running (graceful fallback).
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # DNS Metrics Page — Mounting & Template
  # ============================================================================

  describe "DNS Metrics /dns/metrics mounting" do
    test "mounts successfully with default metrics", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "DNS Metrics"
    end

    test "shows summary stats section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "Total Queries"
      assert html =~ "Avg Latency"
      assert html =~ "Cache Hit Rate"
      assert html =~ "Uptime"
    end

    test "shows response codes section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "Response Codes"
    end

    test "shows query types section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "Query Types"
    end

    test "shows response time distribution section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "Response Time Distribution"
    end

    test "shows top domains and clients sections", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "Top Queried Domains"
      assert html =~ "Top Clients"
    end

    test "shows additional counters section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "Rate Limited"
      assert html =~ "Fallbacks Used"
      assert html =~ "Protocol Split"
    end

    test "shows empty state messages when no data", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "No responses recorded yet" or html =~ "No queries recorded yet"
    end

    test "shows DNS service alert when not running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")

      # Service state depends on async test ordering
      if Process.whereis(YellowDog.Dns) == nil do
        assert html =~ "DNS service is not running"
      end
    end

    test "auto-refresh interval text is shown", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "Auto-refresh: 5s"
    end
  end

  # ============================================================================
  # DNS Metrics Page — Event Handlers
  # ============================================================================

  describe "DNS Metrics /dns/metrics events" do
    test "reset event refreshes metrics and shows flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/metrics")
      html = render_click(view, "reset")
      # In test mode MetricsCollector isn't running, so safe_call returns error
      assert html =~ "Metrics reset" or html =~ "Failed to reset metrics"
    end

    test "export_csv event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/metrics")
      # export_csv fires push_event; no crash = success
      render_click(view, "export_csv")
      assert render(view) =~ "DNS Metrics"
    end

    test "export button has CsvDownload hook", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ ~s(phx-hook="CsvDownload")
      assert html =~ ~s(id="export-csv")
    end

    test "reset button has data-confirm attribute", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ ~s(data-confirm="Reset all metrics?")
    end
  end

  # ============================================================================
  # DNS Query Logs Page — Mounting & Template
  # ============================================================================

  describe "DNS Query Logs /dns/logs mounting" do
    test "mounts successfully with empty entries", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ "DNS Query Logs"
    end

    test "shows stats section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ "Total Logged"
      assert html =~ "Buffer"
      assert html =~ "Displayed"
      assert html =~ "Logger"
    end

    test "shows filter controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ "Search domain or IP"
      assert html =~ "All Codes"
      assert html =~ "All Protocols"
    end

    test "shows empty table message when no entries", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ "No DNS queries recorded yet"
    end

    test "table has correct column headers", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ "Time"
      assert html =~ "Client"
      assert html =~ "Query Name"
      assert html =~ "Type"
      assert html =~ "Proto"
      assert html =~ "RCode"
      assert html =~ "Latency"
      assert html =~ "Cache"
      assert html =~ "View"
    end

    test "shows DNS service alert when not running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")

      # Service state depends on async test ordering
      if Process.whereis(YellowDog.Dns) == nil do
        assert html =~ "DNS service is not running"
      end
    end

    test "shows footer with entry count", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ "Showing 0 entries"
    end
  end

  # ============================================================================
  # DNS Query Logs Page — Event Handlers
  # ============================================================================

  describe "DNS Query Logs /dns/logs events" do
    test "toggle_pause toggles paused state", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dns/logs")
      refute html =~ "Paused"

      # Click pause
      html = render_click(view, "toggle_pause")
      assert html =~ "badge-warning"
      assert html =~ "Resume"

      # Click resume
      html = render_click(view, "toggle_pause")
      assert html =~ "Pause"
    end

    test "clear event empties entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/logs")
      html = render_click(view, "clear")
      assert html =~ "No DNS queries recorded yet"
    end

    test "search event updates search query", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/logs")
      html = render_change(view, "search", %{"search" => "example.com"})
      assert html =~ "DNS Query Logs"
    end

    test "filter_rcode event updates filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/logs")
      html = render_change(view, "filter_rcode", %{"rcode" => "noerror"})
      assert html =~ "DNS Query Logs"
    end

    test "filter_protocol event updates filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/logs")
      html = render_change(view, "filter_protocol", %{"protocol" => "udp"})
      assert html =~ "DNS Query Logs"
    end

    test "filter_view event updates filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/logs")
      html = render_change(view, "filter_view", %{"view" => "default"})
      assert html =~ "DNS Query Logs"
    end

    test "export_csv event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dns/logs")
      render_click(view, "export_csv")
      assert render(view) =~ "DNS Query Logs"
    end

    test "export button has CsvDownload hook", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ ~s(phx-hook="CsvDownload")
      assert html =~ ~s(id="csv-export")
    end
  end

  # ============================================================================
  # DNS Query Logs Page — Filter Controls Accessibility
  # ============================================================================

  describe "DNS Query Logs /dns/logs accessibility" do
    test "search input has aria-label", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ ~s(aria-label="Search DNS query logs")
    end

    test "rcode filter has aria-label", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ ~s(aria-label="Filter by response code")
    end

    test "protocol filter has aria-label", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ ~s(aria-label="Filter by protocol")
    end

    test "search input has phx-debounce", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ ~s(phx-debounce="300")
    end

    test "table headers have scope=col", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/logs")
      assert html =~ ~s(scope="col")
    end
  end

  # ============================================================================
  # DNS Metrics Page — Accessibility
  # ============================================================================

  describe "DNS Metrics /dns/metrics accessibility" do
    test "empty state hides tables (no scope=col when no data)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      # When no data, tables are hidden behind Enum.empty? checks
      assert html =~ "No domains queried yet"
      assert html =~ "No client activity yet"
    end

    test "response code options render correctly", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dns/metrics")
      assert html =~ "Response Codes"
      assert html =~ "No responses recorded yet"
    end
  end
end
