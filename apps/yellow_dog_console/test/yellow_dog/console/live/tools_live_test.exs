defmodule YellowDog.Console.ToolsLiveTest do
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "GeoIP Lookup page" do
    test "mounts with input form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tools/geoip")

      assert html =~ "GeoIP Lookup"
      assert html =~ "Enter IP address"
    end

    test "performs lookup with valid IP", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools/geoip")

      html = view |> form("form", ip: "8.8.8.8") |> render_submit()

      # Should show result cards (country, city, etc.)
      assert html =~ "Country"
      assert html =~ "Timezone"
    end

    test "shows error for invalid IP", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools/geoip")

      html = view |> form("form", ip: "not-an-ip") |> render_submit()

      assert html =~ "Invalid IP address"
    end
  end

  describe "Whois Lookup page" do
    test "mounts with input form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tools/whois")

      assert html =~ "Whois Lookup"
      assert html =~ "Enter domain or IP"
    end
  end

  describe "MAC Lookup page" do
    test "mounts with input form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tools/mac")

      assert html =~ "MAC Address Lookup"
      assert html =~ "Enter MAC address"
    end

    test "looks up known MAC address vendor", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools/mac")

      html = view |> form("form", mac: "00:00:0A:BB:28:FC") |> render_submit()

      assert html =~ "Omron"
    end

    test "shows error for unknown MAC", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools/mac")

      html = view |> form("form", mac: "FF:FF:FF:FF:FF:FF") |> render_submit()

      assert html =~ "No vendor found"
    end
  end
end
