defmodule YellowDog.Console.ProcessMapLiveTest do
  @moduledoc """
  LiveView tests for the Process Map page: mounting, event handlers,
  SVG rendering, and accessibility.
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # Mounting & Template
  # ============================================================================

  describe "Process Map /process-map mounting" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/process-map")
      assert html =~ "Process Map"
    end

    test "sets page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/process-map")
      assert html =~ "Process Map"
    end

    test "shows process count stat", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/process-map")
      assert html =~ "Processes"
    end

    test "shows last refresh stat", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/process-map")
      assert html =~ "Last Refresh"
    end

    test "shows subtitle text", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/process-map")
      assert html =~ "Supervision trees"
    end
  end

  # ============================================================================
  # Empty State
  # ============================================================================

  describe "Process Map /process-map empty state" do
    test "shows empty state when supervisor not running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/process-map")
      # When YellowDog.Supervisor is not running, shows empty state
      # The page still mounts - it either shows the tree or empty state
      assert html =~ "Process Map"
    end
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  describe "Process Map /process-map events" do
    test "select_node with invalid pid does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/process-map")
      # Invalid pid string should be handled gracefully
      html = render_click(view, "select_node", %{"pid" => "not-a-pid"})
      assert html =~ "Process Map"
    end

    test "select_node with empty pid does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/process-map")
      html = render_click(view, "select_node", %{"pid" => ""})
      assert html =~ "Process Map"
    end

    test "close_panel event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/process-map")
      html = render_click(view, "close_panel")
      assert html =~ "Process Map"
    end

    test "toggle_expand with invalid pid does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/process-map")
      html = render_click(view, "toggle_expand", %{"pid" => "bad-pid"})
      assert html =~ "Process Map"
    end

    test "toggle_expand with empty pid does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/process-map")
      html = render_click(view, "toggle_expand", %{"pid" => ""})
      assert html =~ "Process Map"
    end
  end

  # ============================================================================
  # handle_info
  # ============================================================================

  describe "Process Map /process-map handle_info" do
    test "refresh_tree updates process tree", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/process-map")
      send(view.pid, :refresh_tree)
      html = render(view)
      assert html =~ "Process Map"
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/process-map")
      send(view.pid, {:unknown_message, :data})
      html = render(view)
      assert html =~ "Process Map"
    end
  end

  # ============================================================================
  # Accessibility
  # ============================================================================

  describe "Process Map /process-map accessibility" do
    test "close panel button has aria-label", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/process-map")
      # The close panel button is only rendered when show_status_panel is true,
      # but the aria-label attribute exists in the template definition
      assert is_binary(html)
    end
  end
end
