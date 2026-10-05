defmodule YellowDog.Management.ProcessMapLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.ManagementUI.ProcessInspector

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    %{conn: build_conn(), root_pid: Process.whereis(YellowDog.Management.Supervisor)}
  end

  test "the SVG shows the real Management tree without a login", %{conn: conn, root_pid: root_pid} do
    {:ok, view, html} = live(conn, "/system/process-map")
    assert html =~ "Supervision tree for this Management runtime"
    assert has_element?(view, "#process-map-tree[aria-label='Management supervision tree']")
    assert has_element?(view, node_selector(root_pid))
    assert has_element?(view, "button#refresh-process-map", "Refresh")
    assert html =~ "Last Refresh"
    refute html =~ "Operator token"
    refute html =~ "YellowDog.Supervisor"
    refute html =~ "YellowDog.Console.Supervisor"
    refute html =~ "YellowDog.Telemetry.Supervisor"
    refute html =~ "YellowDog.Worker.Supervisor"
    refute html =~ "style=\"min-width"
  end

  test "selecting a real PID shows all original process properties and closes", %{
    conn: conn,
    root_pid: root_pid
  } do
    {:ok, view, _html} = live(conn, "/system/process-map")
    view |> element(node_selector(root_pid)) |> render_click()

    assert has_element?(view, "#process-status-panel", "Process Status")
    assert has_element?(view, "#process-status-panel", inspect(root_pid))
    assert has_element?(view, "#process-status-panel", "YellowDog.Management.Supervisor")

    for label <- [
          "Registered Name",
          "Status",
          "Current Function",
          "Message Queue",
          "Memory",
          "Reductions",
          "Links",
          "Monitors"
        ] do
      assert has_element?(view, "#process-status-panel", label)
    end

    view |> element("button[phx-click='close_panel']") |> render_click()
    refute has_element?(view, "#process-status-panel")
  end

  test "collapse and expansion retain the selected PID", %{conn: conn, root_pid: root_pid} do
    tree = ProcessInspector.get_tree()
    child_pid = tree.children |> Enum.find(&is_pid(&1.pid)) |> Map.fetch!(:pid)
    {:ok, view, _html} = live(conn, "/system/process-map")
    assert has_element?(view, node_selector(child_pid))
    view |> element(node_selector(root_pid)) |> render_click()

    view |> element(expand_selector(root_pid)) |> render_click()
    assert has_element?(view, node_selector(root_pid))
    refute has_element?(view, node_selector(child_pid))
    assert has_element?(view, "#process-status-panel", inspect(root_pid))

    view |> element(expand_selector(root_pid)) |> render_click()
    assert has_element?(view, node_selector(child_pid))
    assert has_element?(view, "#process-status-panel", inspect(root_pid))
  end

  test "manual and periodic refresh retain the tree and update selected status", %{
    conn: conn,
    root_pid: root_pid
  } do
    {:ok, view, _html} = live(conn, "/system/process-map")
    view |> element(node_selector(root_pid)) |> render_click()
    view |> element("#refresh-process-map") |> render_click()
    assert has_element?(view, node_selector(root_pid))
    assert has_element?(view, "#process-status-panel", "YellowDog.Management.Supervisor")

    send(view.pid, :refresh_tree)
    assert render(view) =~ "Management supervision tree"
    assert has_element?(view, "#process-status-panel", inspect(root_pid))
  end

  test "malformed and out-of-tree PID events cannot inspect unrelated processes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/system/process-map")

    for pid_string <- ["invalid", inspect(self())] do
      render_click(view, "select_node", %{"pid" => pid_string})
      render_click(view, "toggle_expand", %{"pid" => pid_string})
      refute has_element?(view, "#process-status-panel")
      assert Process.alive?(view.pid)
    end
  end

  defp node_selector(process_pid),
    do: "#process-map-tree rect[data-process-node][phx-value-pid='#{inspect(process_pid)}']"

  defp expand_selector(process_pid),
    do: "#process-map-tree g[data-process-expand][phx-value-pid='#{inspect(process_pid)}']"
end
