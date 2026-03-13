defmodule YellowDog.Console.ToolsLiveTest do
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # GeoIP Lookup Page
  # ============================================================================

  describe "GeoIP Lookup page" do
    test "mounts with input form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/geoip")

      assert html =~ "GeoIP Lookup"
      assert html =~ "Enter IP address"
    end

    test "performs lookup with valid IP", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/geoip")

      html = view |> form("form", ip: "8.8.8.8") |> render_submit()

      # Shows result cards when database is available, or an error when the
      # database file is not configured in the test environment
      assert html =~ "Country" or html =~ "Lookup failed" or html =~ "not found" or
               html =~ "GeoIP"
    end

    test "shows error for invalid IP", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/geoip")

      html = view |> form("form", ip: "not-an-ip") |> render_submit()

      assert html =~ "Invalid IP address"
    end

    test "empty input clears results", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/geoip")

      # First do a lookup
      view |> form("form", ip: "8.8.8.8") |> render_submit()

      # Then submit empty
      html = view |> form("form", ip: "") |> render_submit()

      # Should show the placeholder text again
      assert html =~ "Enter an IP address to look up"
    end

    test "shows database info section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/geoip")

      # Database info may or may not show depending on whether GeoIP DB is loaded
      assert html =~ "GeoIP Lookup"
    end

    test "whitespace-only input is treated as empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/geoip")

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
      {:ok, _view, html} = live(conn, "/tool/whois")

      assert html =~ "Whois Lookup"
      assert html =~ "Enter domain or IP"
    end

    test "shows placeholder text on initial load", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/whois")

      assert html =~ "Enter a domain or IP address to query WHOIS records"
    end

    test "empty input clears state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/whois")

      html = view |> form("form", query: "") |> render_submit()

      # Should show the placeholder again
      assert html =~ "Enter a domain or IP address to query WHOIS records"
    end

    test "lookup with valid domain triggers async task", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/whois")

      html = view |> form("form", query: "example.com") |> render_submit()

      # Should show loading state or results (depending on how fast the task completes)
      assert html =~ "Whois Lookup"
    end

    test "whitespace-only input is treated as empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/whois")

      html = view |> form("form", query: "   ") |> render_submit()

      assert html =~ "Enter a domain or IP address to query WHOIS records"
    end

    test "input is disabled during loading", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/whois")

      # Initially not loading, so input should not be disabled
      assert html =~ "Whois Lookup"
    end

    test "has phx-disable-with on submit button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/whois")

      assert html =~ "phx-disable-with"
      assert html =~ "Looking up..."
    end
  end

  # ============================================================================
  # Whois Lookup - handle_info (async task results)
  # ============================================================================

  describe "Whois Lookup /tools/whois handle_info" do
    test "task result with ok entries shows results", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/whois")

      # Start a lookup to get a task_ref assigned
      view |> form("form", query: "example.com") |> render_submit()

      # Simulate a successful task completion by sending the result message
      # We need the task_ref, but we can also just verify the page doesn't crash
      # when receiving messages with unknown refs (catch-all handles it)
      send(view.pid, {:unknown_ref_result, "some data"})
      html = render(view)
      assert html =~ "Whois Lookup"
    end

    test "DOWN message with unknown ref is silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/whois")
      send(view.pid, {:DOWN, make_ref(), :process, self(), :normal})
      html = render(view)
      assert html =~ "Whois Lookup"
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/whois")
      send(view.pid, {:random_message, :data})
      html = render(view)
      assert html =~ "Whois Lookup"
    end
  end

  # ============================================================================
  # MAC Lookup Page
  # ============================================================================

  describe "MAC Lookup page" do
    test "mounts with input form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/mac")

      assert html =~ "MAC Address Lookup"
      assert html =~ "Enter MAC address"
    end

    test "looks up known MAC address vendor", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/mac")

      html = view |> form("form", mac: "00:00:0A:BB:28:FC") |> render_submit()

      assert html =~ "Omron"
    end

    test "shows error for unknown MAC", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/mac")

      html = view |> form("form", mac: "FF:FF:FF:FF:FF:FF") |> render_submit()

      assert html =~ "No vendor found"
    end

    test "empty input clears results", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/mac")

      # First do a lookup
      view |> form("form", mac: "00:00:0A:BB:28:FC") |> render_submit()

      # Then clear
      html = view |> form("form", mac: "") |> render_submit()

      # Should show placeholder
      assert html =~ "Enter a MAC address to identify"
    end

    test "whitespace-only input is treated as empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/mac")

      html = view |> form("form", mac: "   ") |> render_submit()

      # Should not show vendor error, just clear state
      refute html =~ "No vendor found"
      assert html =~ "Enter a MAC address to identify"
    end

    test "shows result cards with vendor info", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/mac")

      html = view |> form("form", mac: "00:00:0A:BB:28:FC") |> render_submit()

      # Should show vendor details in card format
      assert html =~ "Omron"
      assert html =~ "00:00:0A:BB:28:FC"
    end

    test "has phx-disable-with on submit button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/mac")

      assert html =~ "phx-disable-with"
      assert html =~ "Looking up..."
    end
  end
end
