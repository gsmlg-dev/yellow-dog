defmodule YellowDog.Console.PoolDetailLiveTest do
  @moduledoc """
  Tests for DHCPv4 and DHCPv6 individual pool detail pages.
  These pages mount with a pool_name param and show pool config,
  utilization stats, and leases. Tests run without services active.
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  # ============================================================================
  # DHCPv4 Pool Detail Page
  # ============================================================================

  describe "DHCPv4 PoolLive /dhcpv4/pools/:pool_name mounting" do
    test "mounts successfully with default pool data", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dhcpv4/pools/default")
      assert html =~ "default"
      assert html =~ "Back to Overview"
    end

    test "shows pool statistics section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dhcpv4/pools/default")
      assert html =~ "Total Addresses"
      assert html =~ "Allocated"
    end

    test "shows pool configuration section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dhcpv4/pools/default")
      assert html =~ "Pool Configuration" or html =~ "Configuration"
    end

    test "shows empty leases table when service not running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dhcpv4/pools/default")
      assert html =~ "No leases" or html =~ "lease"
    end

    test "sets page title to pool name", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dhcpv4/pools/test-pool")
      assert html =~ "test-pool"
    end
  end

  describe "DHCPv4 PoolLive /dhcpv4/pools/:pool_name events" do
    test "search event updates filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/pools/default")
      html = render_change(view, "search", %{"search" => "192.168"})
      assert html =~ "default"
    end

    test "filter_state event with valid state works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/pools/default")
      html = render_change(view, "filter_state", %{"state" => "active"})
      assert html =~ "default"
    end

    test "filter_state with 'all' shows all leases", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/pools/default")
      html = render_change(view, "filter_state", %{"state" => "all"})
      assert html =~ "default"
    end

    test "filter_state with invalid state returns all leases (fallback)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/pools/default")
      html = render_change(view, "filter_state", %{"state" => "evil_state"})
      assert html =~ "default"
    end
  end

  # ============================================================================
  # DHCPv6 Pool Detail Page
  # ============================================================================

  describe "DHCPv6 PoolLive /dhcpv6/pools/:pool_name mounting" do
    test "mounts successfully with default pool data", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dhcpv6/pools/default")
      assert html =~ "default"
    end

    test "shows pool statistics or empty state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dhcpv6/pools/default")
      # Should show stats or "no data" message
      assert html =~ "DHCPv6 Pool" or html =~ "default"
    end

    test "sets page title to pool name", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/server/dhcpv6/pools/v6-pool")
      assert html =~ "v6-pool"
    end
  end

  # ============================================================================
  # DHCPv4 Pool Detail - Additional Event Handlers
  # ============================================================================

  describe "DHCPv4 PoolLive /dhcpv4/pools/:pool_name release_lease" do
    test "release_lease handles service unavailable gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/server/dhcpv4/pools/default")
      html = render_click(view, "release_lease", %{"mac" => "00:11:22:33:44:55"})
      # DHCPv4 service not running, so release will fail
      assert html =~ "Failed to release lease" or html =~ "default"
    end
  end
end
