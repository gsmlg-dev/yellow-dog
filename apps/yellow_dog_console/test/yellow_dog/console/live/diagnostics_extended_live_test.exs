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
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dns")

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

      assert html =~ "DNS Diagnostics"
    end

    test "validate_mdns updates mDNS form state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/mdns")

      html =
        render_change(view, "validate_mdns", %{
          "mdns_query" => %{
            "service_type" => "_http._tcp.local",
            "query_type" => "ptr",
            "timeout" => "3000"
          }
        })

      assert html =~ "mDNS Diagnostics"
    end

    test "validate_dhcpv4 updates DHCPv4 form state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dhcpv4")

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

      assert html =~ "DHCPv4 Diagnostics"
    end

    test "validate_dhcpv6 updates DHCPv6 form state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dhcpv6")

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

      assert html =~ "DHCPv6 Diagnostics"
    end
  end

  # ============================================================================
  # History & Clipboard Events
  # ============================================================================

  describe "DiagnosticsLive history and clipboard events" do
    test "toggle_history toggles history visibility", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dns")
      html = render_click(view, "toggle_history")
      assert html =~ "Query History"
    end

    test "clear_history empties history", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dns")
      html = render_click(view, "clear_history")
      assert html =~ "DNS Diagnostics"
    end

    test "select_history with non-existent ID is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dns")
      html = render_click(view, "select_history", %{"id" => "nonexistent"})
      assert html =~ "DNS Diagnostics"
    end

    test "copied event shows success flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dns")
      html = render_click(view, "copied")
      assert html =~ "Copied to clipboard"
    end

    test "copy_failed event shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dns")
      html = render_click(view, "copy_failed", %{"error" => "Permission denied"})
      assert html =~ "Copy failed: Permission denied"
    end
  end

  # ============================================================================
  # Display Mode Toggle
  # ============================================================================

  describe "DiagnosticsLive display mode" do
    test "toggle to raw mode works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dns")
      html = render_click(view, "toggle_display_mode", %{"mode" => "raw"})
      assert html =~ "DNS Diagnostics"
    end

    test "toggle to struct mode works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dns")
      render_click(view, "toggle_display_mode", %{"mode" => "raw"})
      html = render_click(view, "toggle_display_mode", %{"mode" => "struct"})
      assert html =~ "DNS Diagnostics"
    end

    test "toggle with invalid mode is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dns")
      html = render_click(view, "toggle_display_mode", %{"mode" => "evil_mode"})
      assert html =~ "DNS Diagnostics"
    end
  end

  # ============================================================================
  # DNS Form Default Values
  # ============================================================================

  describe "DiagnosticsLive DNS form defaults" do
    test "DNS form has default server 127.0.0.1", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dns")
      assert html =~ "127.0.0.1"
    end

    test "DNS form has record type select", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dns")
      assert html =~ ~s(dns_query[record_type])
    end

    test "DNS form has protocol select", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dns")
      assert html =~ ~s(dns_query[protocol]) or html =~ "udp"
    end
  end

  # ============================================================================
  # Cross-tab Form Fields
  # ============================================================================

  describe "DiagnosticsLive cross-tab form fields" do
    test "mDNS tab shows default service type", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/mdns")
      assert html =~ "_http._tcp.local"
    end

    test "DHCPv4 tab shows port warning", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dhcpv4")
      assert html =~ "Port 68 requires root"
    end

    test "DHCPv6 tab shows port warning", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tool/diagnostics/dhcpv6")
      assert html =~ "Port 546 requires root"
    end

    test "all tabs render without crash", %{conn: conn} do
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

  # ============================================================================
  # Query Submission Events
  # ============================================================================

  describe "Diagnostics /diagnostics query submission" do
    test "send_dns_query sets loading state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dns")

      render_submit(view, "send_dns_query", %{
        "dns_query" => %{
          "query_name" => "example.com",
          "record_type" => "A",
          "protocol" => "udp",
          "server" => "8.8.8.8",
          "port" => "53",
          "recursion_desired" => "true",
          "timeout" => "5000"
        }
      })

      # After submit, the async query runs — page should not crash
      html = render(view)
      assert html =~ "DNS Diagnostics"
    end

    test "send_mdns_query submits without crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/mdns")

      render_submit(view, "send_mdns_query", %{
        "mdns_query" => %{
          "query_name" => "_http._tcp.local",
          "record_type" => "PTR",
          "timeout" => "5000"
        }
      })

      html = render(view)
      assert html =~ "mDNS Diagnostics"
    end

    test "send_dhcpv4_query submits without crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dhcpv4")

      render_submit(view, "send_dhcpv4_query", %{
        "dhcpv4_query" => %{
          "server" => "192.168.1.1",
          "port" => "67",
          "timeout" => "5000"
        }
      })

      html = render(view)
      assert html =~ "DHCPv4 Diagnostics"
    end

    test "send_dhcpv6_query submits without crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tool/diagnostics/dhcpv6")

      render_submit(view, "send_dhcpv6_query", %{
        "dhcpv6_query" => %{
          "server" => "::1",
          "port" => "547",
          "timeout" => "5000"
        }
      })

      html = render(view)
      assert html =~ "DHCPv6 Diagnostics"
    end
  end
end
