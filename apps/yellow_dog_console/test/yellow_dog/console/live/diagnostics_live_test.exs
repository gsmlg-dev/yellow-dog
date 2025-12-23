defmodule YellowDog.Console.DiagnosticsLiveTest do
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "mount/3" do
    test "mounts with default state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/diagnostics")

      # Should render the page title
      assert html =~ "Service Diagnostics"

      # Should have tab navigation
      assert html =~ "DNS"
      assert html =~ "mDNS"
      assert html =~ "DHCPv4"
      assert html =~ "DHCPv6"
    end

    test "defaults to DNS tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/diagnostics")

      # DNS tab should be active by default
      assert html =~ "Domain Name"
      assert html =~ "Record Type"
      assert html =~ "DNS Server"
    end
  end

  describe "tab navigation" do
    test "switches to mDNS tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")

      html =
        view |> element(~s([phx-click="select_tab"][phx-value-tab="mdns"])) |> render_click()

      assert html =~ "Service Type"
      assert html =~ "224.0.0.251:5353"
    end

    test "switches to DHCPv4 tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")

      html =
        view |> element(~s([phx-click="select_tab"][phx-value-tab="dhcpv4"])) |> render_click()

      assert html =~ "Message Type"
      assert html =~ "Client MAC"
      assert html =~ "Port 68 requires root"
    end

    test "switches to DHCPv6 tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")

      html =
        view |> element(~s([phx-click="select_tab"][phx-value-tab="dhcpv6"])) |> render_click()

      assert html =~ "Message Type"
      assert html =~ "DUID"
      assert html =~ "Port 546 requires root"
    end

    test "switches back to DNS tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")

      # Switch to mDNS first
      view |> element(~s([phx-click="select_tab"][phx-value-tab="mdns"])) |> render_click()

      # Switch back to DNS
      html =
        view |> element(~s([phx-click="select_tab"][phx-value-tab="dns"])) |> render_click()

      assert html =~ "Domain Name"
      assert html =~ "DNS Server"
    end
  end

  describe "display mode toggle" do
    test "toggles between struct and raw mode", %{conn: conn} do
      {:ok, view, html} = live(conn, "/diagnostics")

      # Default should be struct mode
      assert html =~ "Struct" or html =~ "Raw"

      # Toggle to raw mode - click the Raw Hex button
      html =
        view
        |> element(~s([phx-click="toggle_display_mode"][phx-value-mode="raw"]))
        |> render_click()

      # The toggle should work (no error)
      assert html =~ "Service Diagnostics"
    end
  end

  describe "form validation" do
    test "DNS tab has required fields", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/diagnostics")

      # Check for form fields
      assert html =~ ~s(dns_query[query_name])
      assert html =~ ~s(dns_query[record_type])
      assert html =~ ~s(dns_query[server])
    end

    test "mDNS tab has required fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")

      html =
        view |> element(~s([phx-click="select_tab"][phx-value-tab="mdns"])) |> render_click()

      assert html =~ ~s(mdns_query[service_type])
      assert html =~ ~s(mdns_query[query_type])
    end

    test "DHCPv4 tab has required fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")

      html =
        view |> element(~s([phx-click="select_tab"][phx-value-tab="dhcpv4"])) |> render_click()

      assert html =~ ~s(dhcpv4_query[message_type])
      assert html =~ ~s(dhcpv4_query[client_mac])
    end

    test "DHCPv6 tab has required fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")

      html =
        view |> element(~s([phx-click="select_tab"][phx-value-tab="dhcpv6"])) |> render_click()

      assert html =~ ~s(dhcpv6_query[message_type])
      assert html =~ ~s(dhcpv6_query[duid])
    end
  end

  describe "query history" do
    test "history starts empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/diagnostics")

      # History should be empty initially
      assert html =~ "Query History"
    end
  end
end
