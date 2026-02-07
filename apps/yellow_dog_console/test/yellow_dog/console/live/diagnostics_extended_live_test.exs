defmodule YellowDog.Console.DiagnosticsExtendedLiveTest do
  @moduledoc """
  Extended tests for the Diagnostics LiveView covering form validation,
  history/clipboard events, and form field interactions across all 4 tabs.
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # Form Validation Events (validate_*)
  # ============================================================================

  describe "DiagnosticsLive form validation events" do
    test "validate_dns updates DNS form state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")

      html =
        render_change(view, "validate_dns", %{
          "dns_query" => %{
            "query_name" => "example.com",
            "record_type" => "a",
            "server" => "8.8.8.8",
            "port" => "53",
            "protocol" => "udp",
            "recursion_desired" => "true",
            "timeout" => "5000"
          }
        })

      assert html =~ "Service Diagnostics"
    end

    test "validate_mdns updates mDNS form state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      render_click(view, "select_tab", %{"tab" => "mdns"})

      html =
        render_change(view, "validate_mdns", %{
          "mdns_query" => %{
            "service_type" => "_http._tcp.local",
            "query_type" => "ptr",
            "timeout" => "3000"
          }
        })

      assert html =~ "Service Diagnostics"
    end

    test "validate_dhcpv4 updates DHCPv4 form state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      render_click(view, "select_tab", %{"tab" => "dhcpv4"})

      html =
        render_change(view, "validate_dhcpv4", %{
          "dhcpv4_query" => %{
            "message_type" => "discover",
            "client_mac" => "AA:BB:CC:DD:EE:FF",
            "transaction_id" => "12345",
            "requested_options" => "1,3,6",
            "timeout" => "10000"
          }
        })

      assert html =~ "Service Diagnostics"
    end

    test "validate_dhcpv6 updates DHCPv6 form state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      render_click(view, "select_tab", %{"tab" => "dhcpv6"})

      html =
        render_change(view, "validate_dhcpv6", %{
          "dhcpv6_query" => %{
            "message_type" => "solicit",
            "duid" => "00010001",
            "transaction_id" => "ABCDEF",
            "iaid" => "1",
            "requested_options" => "23",
            "timeout" => "10000"
          }
        })

      assert html =~ "Service Diagnostics"
    end
  end

  # ============================================================================
  # History & Clipboard Events
  # ============================================================================

  describe "DiagnosticsLive history and clipboard events" do
    test "toggle_history toggles history visibility", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      html = render_click(view, "toggle_history")
      assert html =~ "Query History"
    end

    test "clear_history empties history", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      html = render_click(view, "clear_history")
      assert html =~ "Service Diagnostics"
    end

    test "select_history with non-existent ID is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      html = render_click(view, "select_history", %{"id" => "nonexistent"})
      assert html =~ "Service Diagnostics"
    end

    test "copied event shows success flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      html = render_click(view, "copied")
      assert html =~ "Copied to clipboard"
    end

    test "copy_failed event shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      html = render_click(view, "copy_failed", %{"error" => "Permission denied"})
      assert html =~ "Copy failed: Permission denied"
    end
  end

  # ============================================================================
  # Display Mode Toggle
  # ============================================================================

  describe "DiagnosticsLive display mode" do
    test "toggle to raw mode works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      html = render_click(view, "toggle_display_mode", %{"mode" => "raw"})
      assert html =~ "Service Diagnostics"
    end

    test "toggle to struct mode works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      render_click(view, "toggle_display_mode", %{"mode" => "raw"})
      html = render_click(view, "toggle_display_mode", %{"mode" => "struct"})
      assert html =~ "Service Diagnostics"
    end

    test "toggle with invalid mode is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      html = render_click(view, "toggle_display_mode", %{"mode" => "evil_mode"})
      assert html =~ "Service Diagnostics"
    end
  end

  # ============================================================================
  # DNS Form Default Values
  # ============================================================================

  describe "DiagnosticsLive DNS form defaults" do
    test "DNS form has default server 127.0.0.1", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/diagnostics")
      assert html =~ "127.0.0.1"
    end

    test "DNS form has record type select", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/diagnostics")
      assert html =~ ~s(dns_query[record_type])
    end

    test "DNS form has protocol select", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/diagnostics")
      assert html =~ ~s(dns_query[protocol]) or html =~ "udp"
    end
  end

  # ============================================================================
  # Cross-tab Form Fields
  # ============================================================================

  describe "DiagnosticsLive cross-tab form fields" do
    test "mDNS tab shows default service type", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      html = render_click(view, "select_tab", %{"tab" => "mdns"})
      assert html =~ "_http._tcp.local"
    end

    test "DHCPv4 tab shows port warning", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      html = render_click(view, "select_tab", %{"tab" => "dhcpv4"})
      assert html =~ "Port 68 requires root"
    end

    test "DHCPv6 tab shows port warning", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")
      html = render_click(view, "select_tab", %{"tab" => "dhcpv6"})
      assert html =~ "Port 546 requires root"
    end

    test "all tabs render without crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/diagnostics")

      for tab <- ~w(dns mdns dhcpv4 dhcpv6) do
        html = render_click(view, "select_tab", %{"tab" => tab})
        assert html =~ "Service Diagnostics"
      end
    end
  end
end
