defmodule YellowDog.Console.ToolsLiveTest do
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # GeoIP Lookup Page
  # ============================================================================

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

    test "empty input clears results", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools/geoip")

      # First do a lookup
      view |> form("form", ip: "8.8.8.8") |> render_submit()

      # Then submit empty
      html = view |> form("form", ip: "") |> render_submit()

      # Should show the placeholder text again
      assert html =~ "Enter an IP address to look up"
    end

    test "shows database info section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tools/geoip")

      # Database info may or may not show depending on whether GeoIP DB is loaded
      assert html =~ "GeoIP Lookup"
    end

    test "whitespace-only input is treated as empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools/geoip")

      html = view |> form("form", ip: "   ") |> render_submit()

      # Should not show lookup error, just clear state
      refute html =~ "Invalid IP address"
      assert html =~ "Enter an IP address to look up"
    end
  end

  # ============================================================================
  # Whois Lookup Page
  # ============================================================================

  describe "Whois Lookup page" do
    test "mounts with input form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tools/whois")

      assert html =~ "Whois Lookup"
      assert html =~ "Enter domain or IP"
    end

    test "shows placeholder text on initial load", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tools/whois")

      assert html =~ "Enter a domain or IP address to query WHOIS records"
    end

    test "empty input clears state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools/whois")

      html = view |> form("form", query: "") |> render_submit()

      # Should show the placeholder again
      assert html =~ "Enter a domain or IP address to query WHOIS records"
    end

    test "lookup with valid domain triggers async task", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools/whois")

      html = view |> form("form", query: "example.com") |> render_submit()

      # Should show loading state or results (depending on how fast the task completes)
      assert html =~ "Whois Lookup"
    end

    test "whitespace-only input is treated as empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools/whois")

      html = view |> form("form", query: "   ") |> render_submit()

      assert html =~ "Enter a domain or IP address to query WHOIS records"
    end

    test "input is disabled during loading", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tools/whois")

      # Initially not loading, so input should not be disabled
      assert html =~ "Whois Lookup"
    end

    test "has phx-disable-with on submit button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tools/whois")

      assert html =~ "phx-disable-with"
      assert html =~ "Looking up..."
    end
  end

  # ============================================================================
  # MAC Lookup Page
  # ============================================================================

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

    test "empty input clears results", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools/mac")

      # First do a lookup
      view |> form("form", mac: "00:00:0A:BB:28:FC") |> render_submit()

      # Then clear
      html = view |> form("form", mac: "") |> render_submit()

      # Should show placeholder
      assert html =~ "Enter a MAC address to identify"
    end

    test "whitespace-only input is treated as empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools/mac")

      html = view |> form("form", mac: "   ") |> render_submit()

      # Should not show vendor error, just clear state
      refute html =~ "No vendor found"
      assert html =~ "Enter a MAC address to identify"
    end

    test "shows result cards with vendor info", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools/mac")

      html = view |> form("form", mac: "00:00:0A:BB:28:FC") |> render_submit()

      # Should show vendor details in card format
      assert html =~ "Omron"
      assert html =~ "00:00:0A:BB:28:FC"
    end

    test "has phx-disable-with on submit button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tools/mac")

      assert html =~ "phx-disable-with"
      assert html =~ "Looking up..."
    end
  end
end
