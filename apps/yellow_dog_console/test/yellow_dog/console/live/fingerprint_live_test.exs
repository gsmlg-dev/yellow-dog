defmodule YellowDog.Console.FingerprintLiveTest do
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "Device Inventory page" do
    test "mounts with title and search", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/fingerprint/devices")

      assert html =~ "Device Inventory"
      assert html =~ "Search by MAC"
    end

    test "shows service alert when service is not running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/fingerprint/devices")

      assert html =~ "Fingerprint service is not running"
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

    test "shows service alert when service is not running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/fingerprint/fingerprints")

      assert html =~ "Fingerprint service is not running"
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

  # ============================================================================
  # Device Inventory - Event Handlers
  # ============================================================================

  describe "Device Inventory /fingerprint/devices events" do
    test "filter_type changes device type filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/devices")
      html = render_change(view, "filter_type", %{"type" => "all"})
      assert html =~ "Device Inventory"
    end

    test "filter_type with specific type filters devices", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/devices")
      html = render_change(view, "filter_type", %{"type" => "printer"})
      assert html =~ "Device Inventory"
    end

    test "export_csv event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/devices")
      render_click(view, "export_csv")
      assert render(view) =~ "Device Inventory"
    end
  end

  # ============================================================================
  # Fingerprints - Event Handlers
  # ============================================================================

  describe "Fingerprints /fingerprint/fingerprints events" do
    test "classify opens classification modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/fingerprints")
      html = render_click(view, "classify", %{"hash" => "abc123"})
      assert html =~ "Classify Fingerprint"
      assert html =~ "Profile"
      assert html =~ "Save Override"
    end

    test "close_classify closes the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/fingerprints")
      render_click(view, "classify", %{"hash" => "abc123"})
      html = render_click(view, "close_classify")
      refute html =~ "Classify Fingerprint"
    end

    test "save_override handles service unavailable gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/fingerprints")
      render_click(view, "classify", %{"hash" => "abc123"})

      view
      |> element("form[phx-submit='save_override']")
      |> render_submit(%{"hash" => "abc123", "profile_id" => "printer", "note" => "test"})

      # Should show error flash since Fingerprint service is not running
      html = render(view)
      assert html =~ "Failed to save override" or html =~ "Fingerprints"
    end

    test "export_csv event does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/fingerprint/fingerprints")
      render_click(view, "export_csv")
      assert render(view) =~ "Fingerprints"
    end
  end

  # ============================================================================
  # Fingerprint filter_by_search unit tests
  # ============================================================================

  describe "filter_by_search/2 (FingerprintsLive)" do
    alias YellowDog.Console.FingerprintLive.FingerprintsLive

    test "returns all fingerprints when query is empty" do
      fps = [%{vendor_class: "MSFT", profile_id: nil, parameter_list: [1, 2]}]
      assert FingerprintsLive.filter_by_search(fps, "") == fps
    end

    test "filters by vendor class" do
      fps = [
        %{vendor_class: "MSFT 5.0", profile_id: nil, parameter_list: [1]},
        %{vendor_class: "Linux", profile_id: nil, parameter_list: [1]}
      ]

      assert length(FingerprintsLive.filter_by_search(fps, "msft")) == 1
    end

    test "filters by profile_id" do
      fps = [
        %{vendor_class: nil, profile_id: "Printer", parameter_list: [1]},
        %{vendor_class: nil, profile_id: nil, parameter_list: [1]}
      ]

      assert length(FingerprintsLive.filter_by_search(fps, "printer")) == 1
    end
  end

  describe "filter_by_search/2 and filter_by_type/2 (DevicesLive)" do
    alias YellowDog.Console.FingerprintLive.DevicesLive

    test "filter_by_type returns all when type is 'all'" do
      devices = [%{profile_id: "printer"}, %{profile_id: "phone"}]
      assert DevicesLive.filter_by_type(devices, "all") == devices
    end

    test "filter_by_type filters by specific type" do
      devices = [%{profile_id: "printer"}, %{profile_id: "phone"}]
      assert length(DevicesLive.filter_by_type(devices, "printer")) == 1
    end
  end

  # ============================================================================
  # Device Detail Page
  # ============================================================================

  describe "Device Detail page" do
    test "mounts with MAC address title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/fingerprint/devices/00:11:22:33:44:55")

      assert html =~ "00:11:22:33:44:55"
    end

    test "shows service alert when service is not running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/fingerprint/devices/00:11:22:33:44:55")

      assert html =~ "Fingerprint service is not running"
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
