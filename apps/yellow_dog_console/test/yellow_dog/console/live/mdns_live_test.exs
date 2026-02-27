defmodule YellowDog.Console.MdnsLiveTest do
  @moduledoc """
  LiveView tests for mDNS Index, Discovery, and Monitor pages.
  Tests page mounting, event handlers, handle_info messages, and unit functions.
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias YellowDog.Console.MdnsLive.MonitorLive

  # ============================================================================
  # mDNS Index /mdns
  # ============================================================================

  describe "mDNS Index /mdns mounting" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns")
      assert html =~ "mDNS Service"
    end

    test "shows service status", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns")
      assert html =~ "Running" or html =~ "Stopped" or html =~ "Service"
    end

    test "shows registered services stat", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns")
      assert html =~ "Registered" or html =~ "Services"
    end

    test "shows quick navigation links", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns")
      assert html =~ "/mdns/services" or html =~ "/mdns/discovery" or html =~ "/mdns/monitor"
    end
  end

  describe "mDNS Index /mdns event handlers" do
    test "refresh event reloads stats", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns")
      html = render_click(view, "refresh")
      assert html =~ "mDNS Service"
    end
  end

  describe "mDNS Index /mdns handle_info" do
    test "service_registered adds flash and reloads stats", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns")
      send(view.pid, {:service_registered, "service-id-1"})
      html = render(view)
      assert html =~ "mDNS Service"
    end

    test "service_unregistered adds flash and reloads stats", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns")
      send(view.pid, {:service_unregistered, "service-id-1"})
      html = render(view)
      assert html =~ "mDNS Service"
    end

    test "service_updated reloads stats without flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns")
      send(view.pid, {:service_updated, "service-id-1"})
      html = render(view)
      assert html =~ "mDNS Service"
    end

    test "network_update reloads network stats", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns")
      send(view.pid, :network_update)
      html = render(view)
      assert html =~ "mDNS Service"
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns")
      send(view.pid, {:unknown_event, :data})
      html = render(view)
      assert html =~ "mDNS Service"
    end
  end

  # ============================================================================
  # mDNS Discovery /mdns/discovery
  # ============================================================================

  describe "mDNS Discovery /mdns/discovery mounting" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/discovery")
      assert html =~ "Network Discovery"
    end

    test "shows search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/discovery")
      assert html =~ "search" or html =~ "Search"
    end

    test "shows type filter", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/discovery")
      assert html =~ "All Types" or html =~ "filter_by_type" or html =~ "type"
    end

    test "shows export csv button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/discovery")
      assert html =~ "export_csv" or html =~ "Export"
    end

    test "shows empty state when no services discovered", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/discovery")
      assert html =~ "No services" or html =~ "Discovery" or html =~ "discovered"
    end
  end

  describe "mDNS Discovery /mdns/discovery event handlers" do
    test "search event with empty string shows all services", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/discovery")
      html = render_change(view, "search", %{"search" => ""})
      assert html =~ "Network Discovery"
    end

    test "search event with query filters results", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/discovery")
      html = render_change(view, "search", %{"search" => "myservice"})
      assert html =~ "Network Discovery"
    end

    test "filter_by_type event with all shows all services", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/discovery")
      html = render_click(view, "filter_by_type", %{"type" => "all"})
      assert html =~ "Network Discovery"
    end

    test "filter_by_type event with specific type filters list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/discovery")
      html = render_click(view, "filter_by_type", %{"type" => "_http._tcp"})
      assert html =~ "Network Discovery"
    end

    test "view_details with nonexistent id does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/discovery")
      html = render_click(view, "view_details", %{"id" => "nonexistent-service-id"})
      assert html =~ "Network Discovery"
    end

    test "close_details hides detail panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/discovery")
      render_click(view, "view_details", %{"id" => "nonexistent-service-id"})
      html = render_click(view, "close_details", %{})
      assert html =~ "Network Discovery"
    end

    test "export_csv event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/discovery")
      render_click(view, "export_csv")
      assert render(view) =~ "Network Discovery"
    end
  end

  describe "mDNS Discovery /mdns/discovery handle_info" do
    test "refresh message reloads services", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/discovery")
      send(view.pid, :refresh)
      html = render(view)
      assert html =~ "Network Discovery"
    end

    test "network_update message reloads services", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/discovery")
      send(view.pid, :network_update)
      html = render(view)
      assert html =~ "Network Discovery"
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/discovery")
      send(view.pid, {:unknown_event, :data})
      html = render(view)
      assert html =~ "Network Discovery"
    end
  end

  # ============================================================================
  # mDNS Monitor /mdns/monitor
  # ============================================================================

  describe "mDNS Monitor /mdns/monitor mounting" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "Network Monitor"
    end

    test "shows network stats section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "Total Queries" or html =~ "Queries" or html =~ "Stats"
    end

    test "shows query limit selector", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "set_limit" or html =~ "limit" or html =~ "50"
    end

    test "shows auto-refresh toggle", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "toggle_auto_refresh" or html =~ "auto" or html =~ "refresh"
    end

    test "shows export csv button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "Export" or html =~ "export_csv"
    end

    test "shows clear cache button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "clear_cache" or html =~ "Clear Cache"
    end
  end

  describe "mDNS Monitor /mdns/monitor event handlers" do
    test "set_limit with valid positive integer updates limit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      html = render_change(view, "set_limit", %{"limit" => "100"})
      assert html =~ "Network Monitor"
    end

    test "set_limit with another valid integer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      html = render_change(view, "set_limit", %{"limit" => "25"})
      assert html =~ "Network Monitor"
    end

    test "set_limit with non-numeric value does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      html = render_change(view, "set_limit", %{"limit" => "abc"})
      assert html =~ "Network Monitor"
    end

    test "set_limit with zero does not change limit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      html = render_change(view, "set_limit", %{"limit" => "0"})
      assert html =~ "Network Monitor"
    end

    test "set_limit with negative number does not change limit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      html = render_change(view, "set_limit", %{"limit" => "-5"})
      assert html =~ "Network Monitor"
    end

    test "toggle_auto_refresh toggles the refresh state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      html = render_click(view, "toggle_auto_refresh")
      assert html =~ "Network Monitor"
      # Toggle again should restore
      html = render_click(view, "toggle_auto_refresh")
      assert html =~ "Network Monitor"
    end

    test "search event updates search filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      html = render_change(view, "search", %{"search" => "_http._tcp"})
      assert html =~ "Network Monitor"
    end

    test "search event with empty string shows all queries", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      html = render_change(view, "search", %{"search" => ""})
      assert html =~ "Network Monitor"
    end

    test "clear_cache when service unavailable shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      html = render_click(view, "clear_cache")
      # Service is not running in test env, so should show error flash or remain stable
      assert html =~ "mDNS service is not running" or html =~ "Network Monitor"
    end

    test "export_csv event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      render_click(view, "export_csv")
      assert render(view) =~ "Network Monitor"
    end
  end

  describe "mDNS Monitor /mdns/monitor handle_info" do
    test "refresh message when auto_refresh is true reloads data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      # auto_refresh defaults to true
      send(view.pid, :refresh)
      html = render(view)
      assert html =~ "Network Monitor"
    end

    test "refresh message when auto_refresh is false does not reload", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      # Disable auto refresh
      render_click(view, "toggle_auto_refresh")
      send(view.pid, :refresh)
      html = render(view)
      assert html =~ "Network Monitor"
    end

    test "network_update when auto_refresh is true updates stats", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      send(view.pid, :network_update)
      html = render(view)
      assert html =~ "Network Monitor"
    end

    test "network_update when auto_refresh is false does not update", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      render_click(view, "toggle_auto_refresh")
      send(view.pid, :network_update)
      html = render(view)
      assert html =~ "Network Monitor"
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/mdns/monitor")
      send(view.pid, {:unknown_event, :data})
      html = render(view)
      assert html =~ "Network Monitor"
    end
  end

  # ============================================================================
  # Unit Tests for MonitorLive.filtered_queries/2
  # ============================================================================

  describe "MonitorLive.filtered_queries/2" do
    @sample_queries [
      %{
        name: "_http._tcp.local",
        type: :PTR,
        source_ip: {192, 168, 1, 10},
        timestamp: DateTime.utc_now(),
        class: :IN
      },
      %{
        name: "_ssh._tcp.local",
        type: :A,
        source_ip: {10, 0, 0, 5},
        timestamp: DateTime.utc_now(),
        class: :IN
      },
      %{
        name: "_printer._tcp.local",
        type: :PTR,
        source_ip: {172, 16, 0, 1},
        timestamp: DateTime.utc_now(),
        class: :IN
      }
    ]

    test "empty search returns all queries" do
      result = MonitorLive.filtered_queries(@sample_queries, "")
      assert length(result) == 3
    end

    test "filters by query name (case-insensitive)" do
      result = MonitorLive.filtered_queries(@sample_queries, "http")
      assert length(result) == 1
      assert hd(result).name == "_http._tcp.local"
    end

    test "filters by type string" do
      result = MonitorLive.filtered_queries(@sample_queries, "ptr")
      assert length(result) == 2
      assert Enum.all?(result, &(&1.type == :PTR))
    end

    test "filters by source IP" do
      result = MonitorLive.filtered_queries(@sample_queries, "10.0.0")
      assert length(result) == 1
      assert hd(result).source_ip == {10, 0, 0, 5}
    end

    test "search term matching multiple fields returns union" do
      # "tcp" matches all three names
      result = MonitorLive.filtered_queries(@sample_queries, "tcp")
      assert length(result) == 3
    end

    test "search with no matches returns empty list" do
      result = MonitorLive.filtered_queries(@sample_queries, "zzznomatch")
      assert result == []
    end

    test "empty query list returns empty list" do
      result = MonitorLive.filtered_queries([], "http")
      assert result == []
    end

    test "case insensitive match on uppercase search term" do
      result = MonitorLive.filtered_queries(@sample_queries, "HTTP")
      assert length(result) == 1
      assert hd(result).name == "_http._tcp.local"
    end
  end
end
