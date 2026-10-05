defmodule YellowDog.Management.LogsLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  require Logger

  alias YellowDog.Management.{LogStream, Repo}
  @endpoint YellowDog.ManagementUI.Endpoint
  @moduletag :capture_log

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)
    %{conn: build_conn(), marker: "logs-ui-#{System.unique_integer([:positive])}"}
  end

  test "navigation preserves original log categories without claiming Worker ingestion", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/system/logs")
    assert html =~ "Realtime Logs"

    for title <- [
          "Task Log",
          "DNS Query Logs",
          "DHCPv4 Activity",
          "DHCPv6 Activity",
          "Netboot Log",
          "Identity Audit"
        ] do
      assert html =~ title
    end

    assert html =~ "Worker logs are not ingested"
    assert html =~ "not available"
    view |> element("#logs-navigation a[href='/system/logs/realtime']") |> render_click()
    assert_patch(view, "/system/logs/realtime")
    assert has_element?(view, "#log-controls")
    assert has_element?(view, "#log-container[phx-hook='LogAutoScroll']")
    assert has_element?(view, "#export-logs[phx-hook='CsvDownload']")
  end

  test "genuine Logger snapshot and subscribed events deduplicate by id", %{
    conn: conn,
    marker: marker
  } do
    before_mount = emit(:warning, marker <> " snapshot", request_id: marker)
    {:ok, view, _html} = live(conn, "/system/logs/realtime")
    assert has_element?(view, "#log-row-#{before_mount.id}", marker <> " snapshot")
    incoming = emit(:info, marker <> " incoming", request_id: marker)
    await_row(view, incoming)
    send(view.pid, {:management_log, before_mount})
    send(view.pid, {:management_log, incoming})
    view |> form("#log-search-form", search: marker) |> render_change()
    assert render(view) =~ "Showing 2 of"
    assert has_element?(view, "input[phx-value-app='yellow_dog_management']")
    refute has_element?(view, "input[phx-value-app='yellow_dog_dns']")
    view |> element("#log-row-#{incoming.id} button[phx-click='toggle_expand']") |> render_click()
    assert has_element?(view, "#log-metadata-#{incoming.id}", marker)
  end

  test "app, severity and search filters apply to retained events and none means none", %{
    conn: conn,
    marker: marker
  } do
    {:ok, view, _html} = live(conn, "/system/logs/realtime")
    warning = emit(:warning, marker <> " warning")
    info = emit(:info, marker <> " info")
    other = emit(:warning, marker <> " phoenix", application: :phoenix)
    Enum.each([warning, info, other], &await_row(view, &1))
    view |> form("#log-search-form", search: String.upcase(marker)) |> render_change()
    assert has_element?(view, "#log-row-#{info.id}")
    render_click(view, "set_level", %{"level" => "warning"})
    refute has_element?(view, "#log-row-#{info.id}")
    assert has_element?(view, "#log-row-#{warning.id}")
    render_click(view, "select_no_apps")
    refute has_element?(view, "#log-container [id^='log-row-']")
    render_click(view, "toggle_app", %{"app" => "yellow_dog_management"})
    assert has_element?(view, "#log-row-#{warning.id}")
    refute has_element?(view, "#log-row-#{other.id}")
    render_click(view, "select_all_apps")
    assert has_element?(view, "#log-row-#{other.id}")
    render_click(view, "set_level", %{"level" => "debug"})
    assert has_element?(view, "#log-row-#{info.id}")
  end

  test "paused buffers retain filtered events and resume shows them newest first internally", %{
    conn: conn,
    marker: marker
  } do
    {:ok, view, _html} = live(conn, "/system/logs/realtime")
    render_click(view, "clear")
    render_click(view, "select_no_apps")
    render_click(view, "toggle_pause")
    first = emit(:info, marker <> " first")
    last = emit(:warning, marker <> " last")
    eventually(fn -> has_element?(view, "#log-buffer-status[data-pending='2']") end)
    refute has_element?(view, "#log-row-#{first.id}")
    render_click(view, "toggle_pause")
    refute has_element?(view, "#log-row-#{last.id}")
    render_click(view, "select_all_apps")
    await_row(view, first)
    await_row(view, last)
    assert has_element?(view, "#log-buffer-status[data-pending='0']")
    assert %{socket: %{assigns: %{logs: [latest, previous | _]}}} = :sys.get_state(view.pid)
    assert latest.id == last.id
    assert previous.id == first.id
  end

  test "pause buffer is bounded to 500 and reports dropped entries", %{conn: conn, marker: marker} do
    {:ok, view, _html} = live(conn, "/system/logs/realtime")
    render_click(view, "clear")
    render_click(view, "toggle_pause")

    for index <- 1..505 do
      Logger.warning(marker <> " burst #{index}", application: :yellow_dog_management)
    end

    Logger.flush()
    last = await_entry(marker <> " burst 505")
    eventually(fn -> has_element?(view, "#log-buffer-status[data-pending='500']") end)

    assert %{socket: %{assigns: %{pending_logs: pending, dropped_count: dropped}}} =
             :sys.get_state(view.pid)

    assert length(pending) == 500
    assert dropped >= 5
    render_click(view, "toggle_pause")
    await_row(view, last)
    first = await_entry(marker <> " burst 1")
    refute has_element?(view, "#log-row-#{first.id}")
  end

  test "clear affects only this view and route changes preserve controls", %{
    conn: conn,
    marker: marker
  } do
    entry = emit(:warning, marker)
    {:ok, view, _html} = live(conn, "/system/logs/realtime")
    assert has_element?(view, "#log-row-#{entry.id}")
    render_click(view, "clear")
    refute has_element?(view, "#log-row-#{entry.id}")
    assert Enum.any?(LogStream.snapshot(), &(&1.id == entry.id))
    send(view.pid, {:management_log, entry})
    refute has_element?(view, "#log-row-#{entry.id}")
    render_click(view, "set_level", %{"level" => "error"})
    view |> form("#log-search-form", search: marker) |> render_change()
    render_click(view, "select_no_apps")
    render_click(view, "toggle_pause")
    view |> element("a[href='/system/logs']", "Logs") |> render_click()
    assert_patch(view, "/system/logs")
    view |> element("#logs-navigation a[href='/system/logs/realtime']") |> render_click()
    assert_patch(view, "/system/logs/realtime")
    assert has_element?(view, "button[phx-value-level='error'][aria-pressed='true']")
    assert has_element?(view, "#log-search-form input[value='#{marker}']")
    assert has_element?(view, "#log-buffer-status[data-paused='true']")
    refute has_element?(view, "#log-container [id^='log-row-']")
  end

  test "CSV exports only visible logs, escapes fields and neutralizes formulas", %{
    conn: conn,
    marker: marker
  } do
    {:ok, view, _html} = live(conn, "/system/logs/realtime")
    entry = emit(:warning, "=SUM(1,2) \"#{marker}\"\nnext", request_id: marker)
    hidden = emit(:info, marker <> " excluded")
    await_row(view, entry)
    await_row(view, hidden)
    render_click(view, "set_level", %{"level" => "warning"})
    view |> form("#log-search-form", search: marker) |> render_change()
    view |> element("#export-logs") |> render_click()
    assert_push_event(view, "download_csv", %{content: csv, filename: filename})
    assert filename =~ ~r/\Amanagement_logs_.*\.csv\z/
    assert csv =~ "Timestamp,Level,App,Message,Metadata\r\n"
    assert csv =~ "\"'=SUM(1,2) \"\"#{marker}\"\"\nnext\""
    refute csv =~ "excluded"
    render_click(view, "select_no_apps")
    view |> element("#export-logs") |> render_click()

    assert_push_event(view, "download_csv", %{content: "Timestamp,Level,App,Message,Metadata\r\n"})
  end

  test "all OTP severity levels and unknown events are safe without atom creation", %{
    conn: conn,
    marker: marker
  } do
    {:ok, view, _html} = live(conn, "/system/logs/realtime")

    for level <- ~w(debug info notice warning error critical alert emergency) do
      assert has_element?(view, "button[phx-value-level='#{level}']")
    end

    entry = emit(:warning, marker)
    await_row(view, entry)
    unknown = "unknown-log-level-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    render_click(view, "set_level", %{"level" => unknown})
    render_click(view, "toggle_app", %{"app" => unknown})
    render_click(view, "toggle_expand", %{"id" => "-1"})
    render_click(view, "toggle_expand", %{"id" => "999999999999999999999999999"})
    render_click(view, "unknown", %{})
    send(view.pid, {:management_log, %{id: 1, level: :unknown}})
    send(view.pid, {:unrelated, marker})
    assert has_element?(view, "#log-row-#{entry.id}")
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  defp emit(level, message, metadata \\ []) do
    metadata = Keyword.merge([application: :yellow_dog_management], metadata)

    case level do
      :warning -> Logger.warning(message, metadata)
      :info -> Logger.info(message, metadata)
    end

    Logger.flush()
    await_entry(message)
  end

  defp await_entry(message) do
    eventually(fn -> Enum.find(LogStream.snapshot(), &(&1.message == message)) end)
  end

  defp await_row(view, entry),
    do: eventually(fn -> has_element?(view, "#log-row-#{entry.id}") end)

  defp eventually(callback, remaining \\ 200)

  defp eventually(callback, 0) do
    result = callback.()
    assert result
    result
  end

  defp eventually(callback, remaining) do
    case callback.() do
      result when result in [nil, false] ->
        Process.sleep(10)
        eventually(callback, remaining - 1)

      result ->
        result
    end
  end
end
