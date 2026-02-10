defmodule YellowDog.Console.FingerprintLiveTest do
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "Device Inventory page" do
    test "mounts with title and search", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/fingerprint/devices")

      assert html =~ "Device Inventory"
      assert html =~ "Search by MAC"
    end

    test "shows stats cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/fingerprint/devices")

      assert html =~ "Total Devices"
      assert html =~ "Identified"
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/devices")

      assert has_element?(view, "button#export-csv")
    end

    test "renders device table", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/devices")

      # Table is always rendered (empty state row or device rows)
      assert has_element?(view, "table")
    end

    test "search filters devices", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/devices")

      html = view |> element("input[name=search]") |> render_change(%{"search" => "test-query"})
      # Should still render without error
      assert html =~ "Device Inventory"
    end
  end

  describe "Fingerprints page" do
    test "mounts with title and tabs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/fingerprint/fingerprints")

      assert html =~ "Fingerprints"
      assert html =~ "Unknown"
      assert html =~ "Known"
    end

    test "shows fingerprint stats", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/fingerprint/fingerprints")

      assert html =~ "Known Fingerprints"
      assert html =~ "Unknown Fingerprints"
      assert html =~ "V4 Database"
      assert html =~ "V6 Database"
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/fingerprints")

      assert has_element?(view, "button#export-csv")
    end

    test "switches tabs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/fingerprints")

      html = view |> element("a", "Known") |> render_click()
      assert html =~ "tab-active"
    end

    test "search filters fingerprints", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/fingerprints")

      html = view |> element("input[name=search]") |> render_change(%{"search" => "MSFT"})
      assert html =~ "Fingerprints"
    end

    test "empty state shows no fingerprints message", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/fingerprint/fingerprints")

      assert html =~ "No fingerprints found"
    end
  end

  describe "Device Detail page" do
    test "mounts with MAC address title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/fingerprint/devices/00:11:22:33:44:55")

      assert html =~ "00:11:22:33:44:55"
    end

    test "shows device not found for unknown MAC", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/fingerprint/devices/ff:ff:ff:ff:ff:ff")

      assert html =~ "Device not found"
    end

    test "has back link to inventory", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/devices/00:11:22:33:44:55")

      assert has_element?(view, "a[href='/fingerprint/devices']")
    end
  end
end
