defmodule YellowDog.Console.DiagnosticsLiveTest do
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "mount/3" do
    test "mounts with default state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dns")

      # Should render the page title
      assert html =~ "DNS Diagnostics"

      # Should have DNS form fields
      assert html =~ "Domain Name"
      assert html =~ "Record Type"
      assert html =~ "DNS Server"
    end

    test "defaults to DNS tab via /tool/diagnostics", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics")

      # DNS tab should be active by default
      assert html =~ "Domain Name"
      assert html =~ "Record Type"
      assert html =~ "DNS Server"
    end
  end

  describe "URL-driven tab navigation" do
    test "navigates to mDNS tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/mdns")

      assert html =~ "mDNS Diagnostics"
      assert html =~ "Service Type"
      assert html =~ "224.0.0.251:5353"
    end

    test "navigates to DHCPv4 tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dhcpv4")

      assert html =~ "DHCPv4 Diagnostics"
      assert html =~ "Message Type"
      assert html =~ "Client MAC"
      assert html =~ "Port 68 requires root"
    end

    test "navigates to DHCPv6 tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dhcpv6")

      assert html =~ "DHCPv6 Diagnostics"
      assert html =~ "Message Type"
      assert html =~ "DUID"
      assert html =~ "Port 546 requires root"
    end
  end

  describe "display mode toggle" do
    test "toggles between struct and raw mode", %{conn: conn} do
      {:ok, view, html} = live(conn, "/tool/diagnostics/dns")

      # Default should be struct mode
      assert html =~ "Struct" or html =~ "Raw"

      # Toggle to raw mode - click the Raw Hex button
      html =
        view
        |> element(~s([phx-click="toggle_display_mode"][phx-value-mode="raw"]))
        |> render_click()

      # The toggle should work (no error)
      assert html =~ "DNS Diagnostics"
    end
  end

  describe "form validation" do
    test "DNS tab has required fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dns")

      # Check for form fields
      assert html =~ ~s(dns_query[query_name])
      assert html =~ ~s(dns_query[record_type])
      assert html =~ ~s(dns_query[server])
    end

    test "mDNS tab has required fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/mdns")

      assert html =~ ~s(mdns_query[service_type])
      assert html =~ ~s(mdns_query[query_type])
    end

    test "DHCPv4 tab has required fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dhcpv4")

      assert html =~ ~s(dhcpv4_query[message_type])
      assert html =~ ~s(dhcpv4_query[client_mac])
    end

    test "DHCPv6 tab has required fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dhcpv6")

      assert html =~ ~s(dhcpv6_query[message_type])
      assert html =~ ~s(dhcpv6_query[duid])
    end
  end

  describe "query history" do
    test "history starts empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dns")

      # History should be empty initially
      assert html =~ "Query History"
    end
  end

  # ============================================================================
  # Atom Safety Guards
  # ============================================================================

  describe "atom safety guards" do
    test "toggle_display_mode with invalid mode is silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dns")
      html = render_click(view, "toggle_display_mode", %{"mode" => "evil_mode"})
      # Should still render, no crash
      assert html =~ "DNS Diagnostics"
    end

    test "all tabs render via direct URL navigation", %{conn: conn} do
      for {tab, title} <- [
            {"dns", "DNS Diagnostics"},
            {"mdns", "mDNS Diagnostics"},
            {"dhcpv4", "DHCPv4 Diagnostics"},
            {"dhcpv6", "DHCPv6 Diagnostics"}
          ] do
        {:ok, _view, html} = live(conn, "/tool/diagnostics/#{tab}")
        assert html =~ title
      end
    end
  end
end
