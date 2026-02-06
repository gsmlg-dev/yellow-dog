defmodule YellowDog.Console.ServicePagesLiveTest do
  @moduledoc """
  LiveView tests for service pages: Dashboard, mDNS, DHCPv4, DHCPv6.
  Tests page mounting and basic rendering when services are not running.
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # Dashboard
  # ============================================================================

  describe "Dashboard /dashboard" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "Dashboard" or html =~ "YellowDog"
    end

    test "shows service status cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "DNS"
      assert html =~ "mDNS"
      assert html =~ "DHCPv4"
      assert html =~ "DHCPv6"
    end

    test "shows stopped status when services not running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dashboard")
      assert html =~ "Stopped"
    end
  end

  # ============================================================================
  # mDNS Pages
  # ============================================================================

  describe "mDNS Overview /mdns" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns")
      assert html =~ "mDNS"
    end
  end

  describe "mDNS Services /mdns/services" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/services")
      assert html =~ "Service" or html =~ "mDNS"
    end

    test "has export button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/services")
      assert html =~ "Export"
    end
  end

  describe "mDNS Discovery /mdns/discovery" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/discovery")
      assert html =~ "Discovery" or html =~ "Discover"
    end

    test "has search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/discovery")
      assert html =~ "search" or html =~ "Search" or html =~ "Filter"
    end

    test "has export button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/discovery")
      assert html =~ "Export"
    end
  end

  describe "mDNS Monitor /mdns/monitor" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/mdns/monitor")
      assert html =~ "Monitor" or html =~ "Network"
    end
  end

  # ============================================================================
  # DHCPv4 Pages
  # ============================================================================

  describe "DHCPv4 Overview /dhcpv4" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4")
      assert html =~ "DHCPv4" or html =~ "DHCP"
    end
  end

  describe "DHCPv4 Leases /dhcpv4/leases" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/leases")
      assert html =~ "Lease" or html =~ "DHCPv4"
    end

    test "has export button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/leases")
      assert html =~ "Export"
    end
  end

  describe "DHCPv4 Pools /dhcpv4/pools" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/pools")
      assert html =~ "Pool" or html =~ "DHCPv4"
    end
  end

  # ============================================================================
  # DHCPv6 Pages
  # ============================================================================

  describe "DHCPv6 Overview /dhcpv6" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6")
      assert html =~ "DHCPv6" or html =~ "DHCP"
    end
  end

  describe "DHCPv6 Leases /dhcpv6/leases" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/leases")
      assert html =~ "Lease" or html =~ "DHCPv6"
    end

    test "has export button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/leases")
      assert html =~ "Export"
    end
  end

  describe "DHCPv6 Pools /dhcpv6/pools" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/pools")
      assert html =~ "Pool" or html =~ "DHCPv6"
    end
  end

  # ============================================================================
  # Other Pages
  # ============================================================================

  describe "Diagnostics /diagnostics" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/diagnostics")
      assert html =~ "Diagnostics"
    end
  end

  describe "Logs /logs" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/logs")
      assert html =~ "Log" or html =~ "log"
    end
  end

  describe "Process Map /process-map" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/process-map")
      assert html =~ "Process" or html =~ "process"
    end
  end

  describe "Settings /settings" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")
      assert html =~ "Settings" or html =~ "Configuration"
    end
  end
end
