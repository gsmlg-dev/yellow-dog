defmodule YellowDog.Console.ServicePagesLiveTest do
  @moduledoc """
  Shared smoke and accessibility coverage for unscoped Console pages.

  Selected-Server service behavior belongs to the management-focused scope suites.
  """

  use YellowDog.Console.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "Diagnostics /diagnostics" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dns")
      assert html =~ "DNS Diagnostics"
    end
  end

  describe "Logs /logs" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "Log" or html =~ "log"
    end

    test "has search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "Search log messages"
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "Export CSV"
    end

    test "has pause/resume button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "Pause"
    end

    test "has level filter buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "debug"
      assert html =~ "info"
      assert html =~ "warning"
      assert html =~ "error"
    end

    test "has module filter badges", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "DNS"
      assert html =~ "DHCPv4"
      assert html =~ "mDNS"
    end

    test "toggle_pause switches to paused state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      assert render_click(view, "toggle_pause") =~ "Resume"
    end

    test "toggle_pause back to streaming", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      render_click(view, "toggle_pause")
      assert render_click(view, "toggle_pause") =~ "Pause"
    end

    test "set_level changes minimum log level", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      assert render_click(view, "set_level", %{"level" => "warning"}) =~ "warning"
    end

    test "clear removes all logs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      assert render_click(view, "clear") =~ "Showing 0"
    end

    test "select_all_apps and select_no_apps toggle module filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      assert render_click(view, "select_all_apps") =~ "Showing:"
      refute render_click(view, "select_no_apps") =~ "Showing:"
    end
  end

  describe "Process Map /process-map" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/process-map")
      assert html =~ "Process" or html =~ "process"
    end
  end

  describe "ARIA accessibility: layout components" do
    test "navbar uses primary appbar styling", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server")
      assert html =~ ~s(class="navbar appbar-primary appbar-bordered")
    end

    test "navbar orders product sections by hierarchy", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server")

      top_menu_paths =
        view
        |> element(".navbar ul")
        |> render()
        |> then(&Regex.scan(~r/href="([^"]+)"/, &1, capture: :all_but_first))
        |> List.flatten()

      assert top_menu_paths == [
               "/management",
               "/server",
               "/netman",
               "/tool/geoip",
               "/system/process-map"
             ]
    end

    test "navbar has theme switcher component", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server")
      assert html =~ "theme-toggle" or html =~ "theme-switcher" or html =~ "dm_theme_switcher"
    end

    test "navbar has aria-label on notifications", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server")
      assert html =~ "aria-label=\"Notifications\""
    end

    test "navbar has aria-label on mobile menu", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server")
      assert html =~ "aria-label=\"Open menu\""
    end
  end

  describe "CsvDownload hook on export pages" do
    test "Logs page has CsvDownload hook", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system/logs")
      assert html =~ "CsvDownload"
    end
  end

  describe "Logs atom safety guards" do
    test "toggle_app with invalid app is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      html = render_click(view, "toggle_app", %{"app" => "nonexistent_app"})
      assert html =~ "Log" or html =~ "log"
    end

    test "set_level with invalid level is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      html = render_click(view, "set_level", %{"level" => "nonexistent_level"})
      assert html =~ "Log" or html =~ "log"
    end
  end

  describe "active sidebar highlighting" do
    test "sidebar renders as a sticky scroll-preserving LiveComponent", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system/logs")
      html = render(view)

      assert html =~ ~s(id="app-sidebar")
      assert html =~ ~r/data-phx-component="\d+"/
      assert html =~ ~s(phx-hook="PreserveScroll")
      assert html =~ ~s(data-scroll-key="sidebar:System")
      assert html =~ ~s(yd-sidebar-sticky)
    end

    @active_pages ["/system/logs", "/tool/diagnostics/dns", "/system/process-map"]

    for path <- @active_pages do
      test "sidebar has active class on #{path}", %{conn: conn} do
        {:ok, view, _html} = live(conn, unquote(path))
        assert render(view) =~ ~r/class="[^"]*active[^"]*"/
      end
    end
  end
end
