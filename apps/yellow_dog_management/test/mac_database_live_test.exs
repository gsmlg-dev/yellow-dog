defmodule YellowDog.Management.MacDatabaseLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{MacDatabase, Repo}
  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    previous = Application.fetch_env(:yellow_dog_management, :mac_database_server)

    directory =
      Path.join(System.tmp_dir!(), "mac-database-ui-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)

    on_exit(fn ->
      case previous do
        {:ok, server} -> Application.put_env(:yellow_dog_management, :mac_database_server, server)
        :error -> Application.delete_env(:yellow_dog_management, :mac_database_server)
      end

      File.rm_rf!(directory)
    end)

    %{conn: build_conn(), directory: directory}
  end

  test "compiled database exposes real status and keeps download tasks unavailable", %{conn: conn} do
    server = database(nil)
    info = MacDatabase.info(server)
    {:ok, view, html} = live(conn, "/system/mac-database")

    assert has_element?(
             view,
             "#mac-database-status[data-source='compiled'][data-status='loaded']"
           )

    assert html =~ "Built-in (gsmlg_mac)"
    assert html =~ to_string(info.entry_count)
    assert info.entry_count > 0
    assert has_element?(view, "#mac-database-reload[disabled]")
    assert has_element?(view, "button[disabled]", "Queue MAC/OUI sync")
    assert html =~ "not migrated"
    assert html =~ "durable task storage authorization is pending"
    refute has_element?(view, "a[href='/system/tasks/mac']")
    render_click(view, "download", %{})
    assert has_element?(view, "#mac-database-error", "no job was queued")
    render_click(view, "reload", %{})
    assert has_element?(view, "#mac-database-error", "No MAC database file is configured")
  end

  test "configured database renders real file metadata and lookup results", %{
    conn: conn,
    directory: directory
  } do
    path = fixture(directory, "initial.manuf", "00:11:22\tUiVendor\tOriginal UI Vendor\n")
    server = database(path)
    info = MacDatabase.info(server)
    {:ok, view, html} = live(conn, "/system/mac-database")
    assert has_element?(view, "#mac-database-status[data-source='file'][data-status='loaded']")
    assert html =~ "Database Status"
    assert html =~ "last successfully loaded artifact"
    assert html =~ "an invalid replacement on disk may differ"

    for label <- [
          "Source",
          "Entries",
          "Loaded At",
          "Configured",
          "File Size",
          "File Modified",
          "File Path",
          "Test Lookup"
        ] do
      assert html =~ label
    end

    assert html =~ path
    assert html =~ "#{info.file_info.size} B"
    assert html =~ Calendar.strftime(info.loaded_at, "%Y-%m-%d %H:%M:%S UTC")

    assert html =~
             Calendar.strftime(DateTime.from_unix!(info.file_info.mtime), "%Y-%m-%d %H:%M:%S UTC")

    entered = " 00:11:22:33:44:55 "
    view |> form("#mac-database-lookup-form", mac: entered) |> render_submit()
    assert has_element?(view, "#mac-database-lookup-result", "Original UI Vendor")
    assert has_element?(view, "#mac-database-lookup-result", "UiVendor")
    assert has_element?(view, "input[name='mac'][value='#{entered}']")
    view |> element("#mac-database-refresh") |> render_click()
    assert has_element?(view, "input[name='mac'][value='#{entered}']")
  end

  test "invalid input and a valid unknown prefix have distinct real outcomes", %{
    conn: conn,
    directory: directory
  } do
    server = database(fixture(directory, "lookup.manuf", "00:11:22\tUiVendor\tUI Vendor\n"))
    assert {:error, :invalid_mac} = MacDatabase.lookup("invalid <script>", server)
    assert :error = MacDatabase.lookup("DA:DB:DC:00:00:01", server)
    {:ok, view, _html} = live(conn, "/system/mac-database")
    html = view |> form("#mac-database-lookup-form", mac: "invalid <script>") |> render_submit()
    assert has_element?(view, "#mac-database-lookup-error", "Invalid MAC address")
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
    view |> form("#mac-database-lookup-form", mac: "DA:DB:DC:00:00:01") |> render_submit()
    assert has_element?(view, "#mac-database-lookup-error", "No vendor found")
    refute has_element?(view, "#mac-database-lookup-result")
    view |> form("#mac-database-lookup-form", mac: "") |> render_submit()
    assert has_element?(view, "#mac-database-lookup-error", "Invalid MAC address")
  end

  test "async reload uses only the configured file and escapes vendor text", %{
    conn: conn,
    directory: directory
  } do
    path = fixture(directory, "reload.manuf", "00:11:22\tOldVendor\tOriginal Vendor\n")
    other_path = fixture(directory, "untrusted.manuf", "00:11:22\tUntrusted\tUntrusted Vendor\n")
    server = database(path)
    {:ok, view, _html} = live(conn, "/system/mac-database")
    view |> form("#mac-database-lookup-form", mac: "00:11:22:33:44:55") |> render_submit()

    File.write!(
      path,
      "00:11:22\tNewVendor\tUpdated <script>vendor</script> & Company\n00:11:23\tSecond\tSecond Vendor\n"
    )

    render_click(view, "reload", %{"path" => other_path})
    render_async(view)
    assert MacDatabase.info(server).path == path
    assert MacDatabase.info(server).entry_count == 2
    assert has_element?(view, "#mac-database-status[data-entry-count='2']")
    assert has_element?(view, "#mac-database-status[data-source='file'][data-status='loaded']")
    assert has_element?(view, "input[name='mac'][value='00:11:22:33:44:55']")
    refute has_element?(view, "#mac-database-operation")
    refute has_element?(view, "#mac-database-error")
    html = view |> form("#mac-database-lookup-form", mac: "00:11:22:33:44:55") |> render_submit()

    assert has_element?(
             view,
             "#mac-database-lookup-result",
             "Updated <script>vendor</script> & Company"
           )

    assert html =~ "&lt;script&gt;vendor&lt;/script&gt;"
    refute has_element?(view, "#mac-database-lookup-result script")
    refute html =~ "Untrusted Vendor"
  end

  test "reload failures and refresh expose actual backend errors", %{
    conn: conn,
    directory: directory
  } do
    path = fixture(directory, "failure.manuf", "00:11:22\tUiVendor\tUI Vendor\n")
    server = database(path)
    {:ok, view, _html} = live(conn, "/system/mac-database")
    view |> form("#mac-database-lookup-form", mac: "00:11:22:33:44:55") |> render_submit()
    File.rm!(path)
    view |> element("#mac-database-reload") |> render_click()
    render_async(view)
    assert MacDatabase.info(server).last_error != nil
    assert has_element?(view, "#mac-database-error", "Reload failed")
    assert has_element?(view, "input[name='mac'][value='00:11:22:33:44:55']")
    view |> element("#mac-database-refresh") |> render_click()
    assert has_element?(view, "#mac-database-error", "Last load failed")
    info = MacDatabase.info(server)
    assert has_element?(view, "#mac-database-status[data-status='#{info.status}']")
    assert {:ok, "UiVendor", "UI Vendor"} = MacDatabase.lookup("00:11:22:33:44:55", server)
    view |> form("#mac-database-lookup-form", mac: "00:11:22:33:44:55") |> render_submit()
    assert has_element?(view, "#mac-database-lookup-result", "UI Vendor")
    File.write!(path, "00:11:22\tRestored\tRestored Vendor\n")
    view |> element("#mac-database-reload") |> render_click()
    render_async(view)
    assert has_element?(view, "#mac-database-status[data-status='loaded'][data-entry-count='1']")
    refute has_element?(view, "#mac-database-error")
  end

  test "initial configured-file errors render without a fabricated load", %{
    conn: conn,
    directory: directory
  } do
    path = Path.join(directory, "missing.manuf")
    server = database(path)
    info = MacDatabase.info(server)
    {:ok, view, html} = live(conn, "/system/mac-database")
    assert info.last_error != nil
    assert has_element?(view, "#mac-database-error", "Last load failed")

    assert has_element?(
             view,
             "#mac-database-status[data-source='#{info.source}'][data-status='#{info.status}']"
           )

    assert html =~ path
  end

  test "unavailable backend produces useful errors rather than crashing", %{conn: conn} do
    database(nil)
    {:ok, view, _html} = live(conn, "/system/mac-database")
    stop_supervised!(MacDatabase)
    view |> element("#mac-database-refresh") |> render_click()
    assert has_element?(view, "#mac-database-error", "Database service unavailable")
    refute has_element?(view, "#mac-database-status")
    view |> form("#mac-database-lookup-form", mac: "00:11:22:33:44:55") |> render_submit()
    assert has_element?(view, "#mac-database-lookup-error", "database_unavailable")
    refute has_element?(view, "#mac-database-lookup-error", "No vendor found")
  end

  defp fixture(directory, name, contents) do
    path = Path.join(directory, name)
    File.write!(path, contents)
    path
  end

  defp database(path) do
    server = start_supervised!({MacDatabase, name: nil, path: path})
    Application.put_env(:yellow_dog_management, :mac_database_server, server)
    await_loaded(server)
    server
  end

  defp await_loaded(server, remaining \\ 200)

  defp await_loaded(server, 0) do
    refute MacDatabase.info(server).status == :loading
  end

  defp await_loaded(server, remaining) do
    if MacDatabase.info(server).status == :loading do
      Process.sleep(10)
      await_loaded(server, remaining - 1)
    end
  end
end
