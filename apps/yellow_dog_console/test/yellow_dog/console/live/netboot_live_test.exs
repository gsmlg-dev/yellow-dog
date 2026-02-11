defmodule YellowDog.Console.NetbootLiveTest do
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "Netboot Dashboard page" do
    test "mounts with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot")

      assert html =~ "Netboot Dashboard"
      assert html =~ "Network boot provisioning"
    end

    test "shows state summary cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot")

      assert html =~ "Discovered"
      assert html =~ "Booting"
      assert html =~ "Installing"
      assert html =~ "Installed"
      assert html =~ "Failed"
    end

    test "shows TFTP server card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot")

      assert html =~ "TFTP Server"
    end

    test "shows boot profiles card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot")

      assert html =~ "Boot Profiles"
    end

    test "shows recent devices table", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot")

      assert has_element?(view, "table")
    end
  end

  describe "Netboot Devices page" do
    test "mounts with title and search", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices")

      assert html =~ "Netboot Devices"
      assert html =~ "Search by MAC"
    end

    test "shows stats cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices")

      assert html =~ "Total Devices"
      assert html =~ "Installed"
      assert html =~ "Failed"
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      assert has_element?(view, "button#export-csv")
    end

    test "renders device table", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      assert has_element?(view, "table")
    end

    test "search filters devices", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      html = view |> element("input[name=search]") |> render_change(%{"search" => "test"})
      assert html =~ "Netboot Devices"
    end

    test "state filter works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices")

      html = view |> element("select[name=state]") |> render_change(%{"state" => "all"})
      assert html =~ "Netboot Devices"
    end
  end

  describe "Netboot Device Detail page" do
    test "mounts with MAC title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices/AA:BB:CC:DD:EE:FF")

      assert html =~ "AA:BB:CC:DD:EE:FF"
    end

    test "shows device not found for unknown MAC", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/devices/FF:FF:FF:FF:FF:FF")

      assert html =~ "Device not found"
    end

    test "has back link to devices list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/devices/AA:BB:CC:DD:EE:FF")

      assert has_element?(view, "a[href='/netboot/devices']")
    end
  end

  describe "Boot Profiles page" do
    test "mounts with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/profiles")

      assert html =~ "Boot Profiles"
      assert html =~ "Configured netboot profiles"
    end

    test "shows stats cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/profiles")

      assert html =~ "Total Profiles"
      assert html =~ "Default Profile"
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles")

      assert has_element?(view, "button#export-csv")
    end

    test "search filters profiles", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/profiles")

      html = view |> element("input[name=search]") |> render_change(%{"search" => "nixos"})
      assert html =~ "Boot Profiles"
    end
  end

  describe "TFTP Server page" do
    test "mounts with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "TFTP Server"
      assert html =~ "Boot file serving"
    end

    test "shows status cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "Status"
      assert html =~ "Port"
      assert html =~ "Files Indexed"
    end

    test "shows configuration card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "Configuration"
      assert html =~ "Root Directory"
    end

    test "shows file browser card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/tftp")

      assert html =~ "File Browser"
    end

    test "has rescan button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/tftp")

      assert has_element?(view, "button", "Rescan Files")
    end
  end

  describe "Boot Log page" do
    test "mounts with title", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/netboot/log")

      assert html =~ "Boot Log"
      assert html =~ "Real-time netboot activity"
    end

    test "has pause/resume button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      assert has_element?(view, "button", "Pause")
    end

    test "has clear button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      assert has_element?(view, "button", "Clear")
    end

    test "has export CSV button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      assert has_element?(view, "button#export-csv")
    end

    test "toggle pause works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      html = view |> element("button", "Pause") |> render_click()
      assert html =~ "Resume"
    end

    test "clear log works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      html = view |> element("button", "Clear") |> render_click()
      assert html =~ "Boot Log"
    end

    test "search filters entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      html = view |> element("input[name=search]") |> render_change(%{"search" => "test"})
      assert html =~ "Boot Log"
    end

    test "type filter works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/netboot/log")

      html = view |> element("select[name=type]") |> render_change(%{"type" => "device"})
      assert html =~ "Boot Log"
    end
  end
end
