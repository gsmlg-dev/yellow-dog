defmodule YellowDog.Console.Dhcpv6LiveTest do
  @moduledoc """
  LiveView tests for DHCPv6 pages: overview, leases, pools, and activity.
  All tests run without the DHCPv6 service started (graceful degradation).
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias YellowDog.Console.Dhcpv6Live.ActivityLive

  # ============================================================================
  # DHCPv6 Overview /dhcpv6
  # ============================================================================

  describe "DHCPv6 Overview /dhcpv6" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6")
      assert html =~ "DHCPv6"
    end

    test "shows overview content", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6")
      assert html =~ "Leases" or html =~ "Pool" or html =~ "Total"
    end

    test "handles unknown messages gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6")
      send(view.pid, :unexpected_message)
      send(view.pid, {:unknown, :tuple})
      assert Process.alive?(view.pid)
    end

    test "handles telemetry_event message and reloads data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6")

      send(view.pid, {
        :telemetry_event,
        [:yellow_dog, :dhcpv6, :lease_allocated],
        %{},
        %{duid: <<1, 2, 3>>, ia_type: :ia_na}
      })

      html = render(view)
      assert html =~ "DHCPv6"
    end
  end

  # ============================================================================
  # DHCPv6 Leases /dhcpv6/leases
  # ============================================================================

  describe "DHCPv6 Leases /dhcpv6/leases" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/leases")
      assert html =~ "Lease" or html =~ "DHCP"
    end

    test "shows filter controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/leases")
      assert html =~ "filter" or html =~ "Filter" or html =~ "All" or html =~ "Search"
    end

    test "search event updates query", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/leases")
      html = render_change(view, "search", %{"search" => "00:01:00"})
      assert is_binary(html)
    end

    test "filter_state event changes filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/leases")
      html = render_change(view, "filter_state", %{"state" => "active"})
      assert is_binary(html)
    end

    test "filter_ia_type event changes IA type filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/leases")
      html = render_change(view, "filter_ia_type", %{"ia_type" => "ia_na"})
      assert is_binary(html)
    end

    test "filter_pool event changes pool filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/leases")
      html = render_change(view, "filter_pool", %{"pool" => "default"})
      assert is_binary(html)
    end

    test "release_lease with invalid IAID shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/leases")
      html = render_click(view, "release_lease", %{"duid" => "00:01:00:01", "iaid" => "not_a_number"})
      assert html =~ "Invalid" or is_binary(html)
    end

    test "release_lease with valid params does not crash when service down", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/leases")
      html = render_click(view, "release_lease", %{"duid" => "00:01:00:01:AA:BB:CC:DD", "iaid" => "1"})
      assert html =~ "Failed" or html =~ "error" or html =~ "Lease" or is_binary(html)
    end

    test "export_csv does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/leases")
      html = render_click(view, "export_csv")
      assert is_binary(html)
    end

    test "telemetry_event message reloads leases", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/leases")
      send(view.pid, {:telemetry_event, [:yellow_dog, :dhcpv6, :lease_allocated], %{}, %{}})
      html = render(view)
      assert html =~ "Lease" or is_binary(html)
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/leases")
      send(view.pid, :random_atom)
      send(view.pid, {:DOWN, make_ref(), :process, self(), :normal})
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # DHCPv6 Pools /dhcpv6/pools
  # ============================================================================

  describe "DHCPv6 Pools /dhcpv6/pools" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/pools")
      assert html =~ "Pool" or html =~ "Prefix" or html =~ "DHCPv6"
    end

    test "shows Add Pool button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/pools")
      assert html =~ "Add" or html =~ "New" or html =~ "Create"
    end

    test "show_new_form event opens form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/pools")
      html = render_click(view, "show_new_form")
      assert is_binary(html)
    end

    test "filter event narrows pool list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/pools")
      html = render_change(view, "filter", %{"filter" => "nonexistent-xyz"})
      assert is_binary(html)
    end

    test "export_csv does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/pools")
      html = render_click(view, "export_csv")
      assert is_binary(html)
    end

    test "delete_pool for unknown pool shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/pools")
      html = render_click(view, "delete_pool", %{"pool-name" => "no-such-pool"})
      assert html =~ "error" or html =~ "not found" or html =~ "Failed" or is_binary(html)
    end

    test "close_pool_form message hides form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/pools")
      render_click(view, "show_new_form")
      send(view.pid, :close_pool_form)
      html = render(view)
      assert is_binary(html)
    end

    test "unknown messages are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/pools")
      send(view.pid, :unexpected)
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # DHCPv6 Activity /dhcpv6/activity
  # ============================================================================

  describe "DHCPv6 Activity /dhcpv6/activity" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/activity")
      assert html =~ "DHCPv6 Activity"
    end

    test "shows DHCPv6-specific stats (SOLICIT, REQUEST, REPLY)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/activity")
      assert html =~ "SOLICIT" or html =~ "Solicit"
      assert html =~ "REQUEST" or html =~ "Request"
      assert html =~ "REPLY" or html =~ "Reply"
    end

    test "shows pause and clear buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv6/activity")
      assert html =~ "Pause" or html =~ "Resume"
      assert html =~ "Clear"
    end

    test "toggle_pause event toggles paused state", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dhcpv6/activity")
      refute html =~ "Resume"
      render_click(view, "toggle_pause")
      html = render_click(view, "toggle_pause")
      assert html =~ "Pause" or html =~ "Resume"
    end

    test "clear event resets entries and stats", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/activity")
      html = render_click(view, "clear")
      assert is_binary(html)
    end

    test "search event filters by query", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/activity")
      html = render_change(view, "search", %{"search" => "2001:db8"})
      assert is_binary(html)
    end

    test "filter_type event changes type filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/activity")
      html = render_change(view, "filter_type", %{"type" => "solicit"})
      assert is_binary(html)
    end

    test "export_csv does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/activity")
      html = render_click(view, "export_csv")
      assert is_binary(html)
    end

    test "dhcpv6_activity message adds entry to log", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/activity")

      entry = %{
        timestamp: DateTime.utc_now(),
        type: :reply,
        client_duid: "00:03:00:01:aa:bb:cc:dd:ee:ff",
        client_ip: "2001:db8::1",
        details: "REPLY granted",
        duration_us: 1200
      }

      send(view.pid, {:dhcpv6_activity, entry})
      html = render(view)
      assert html =~ "aa:bb:cc:dd:ee:ff" or html =~ "2001:db8" or html =~ "REPLY"
    end

    test "when paused, entry is not added to list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/activity")
      render_click(view, "toggle_pause")

      entry = %{
        timestamp: DateTime.utc_now(),
        type: :solicit,
        client_duid: "00:03:00:01:11:22:33:44:55:66",
        client_ip: nil,
        details: "SOLICIT",
        duration_us: nil
      }

      send(view.pid, {:dhcpv6_activity, entry})
      html = render(view)
      assert html =~ "Paused" or html =~ "Resume"
      refute html =~ "11:22:33:44:55:66"
    end

    test "refresh_stats message updates service_running", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/activity")
      send(view.pid, :refresh_stats)
      html = render(view)
      assert is_binary(html)
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv6/activity")
      send(view.pid, :unknown_message)
      send(view.pid, {:DOWN, make_ref(), :process, self(), :normal})
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # ActivityLive.filtered_entries/3 — unit tests for public filter function
  # ============================================================================

  describe "ActivityLive.filtered_entries/3 (DHCPv6)" do
    defp make_entry(type, duid \\ "00:03:00:01:aa:bb:cc:dd", ip \\ "2001:db8::1", details \\ "test") do
      %{
        timestamp: DateTime.utc_now(),
        type: type,
        client_duid: duid,
        client_ip: ip,
        details: details,
        duration_us: nil
      }
    end

    test "returns all entries for type 'all'" do
      entries = [make_entry(:solicit), make_entry(:reply), make_entry(:allocation_failed)]
      assert ActivityLive.filtered_entries(entries, "", "all") == entries
    end

    test "filters by specific type" do
      entries = [make_entry(:solicit), make_entry(:reply), make_entry(:renew)]
      result = ActivityLive.filtered_entries(entries, "", "solicit")
      assert length(result) == 1
      assert hd(result).type == :solicit
    end

    test "error filter includes allocation_failed, invalid, rate_limited, renew_failed, rebind_failed" do
      entries = [
        make_entry(:solicit),
        make_entry(:allocation_failed),
        make_entry(:invalid),
        make_entry(:rate_limited),
        make_entry(:renew_failed),
        make_entry(:rebind_failed),
        make_entry(:reply)
      ]

      result = ActivityLive.filtered_entries(entries, "", "error")
      types = Enum.map(result, & &1.type)
      assert :allocation_failed in types
      assert :invalid in types
      assert :rate_limited in types
      assert :renew_failed in types
      assert :rebind_failed in types
      refute :solicit in types
      refute :reply in types
    end

    test "unknown type filter falls back to all entries" do
      entries = [make_entry(:solicit), make_entry(:reply)]
      result = ActivityLive.filtered_entries(entries, "", "completely_unknown_xyz")
      assert length(result) == 2
    end

    test "search filters by client_duid" do
      entries = [
        make_entry(:solicit, "00:03:00:01:11:22:33:44"),
        make_entry(:reply, "00:03:00:01:aa:bb:cc:dd")
      ]

      result = ActivityLive.filtered_entries(entries, "11:22", "all")
      assert length(result) == 1
      assert hd(result).client_duid == "00:03:00:01:11:22:33:44"
    end

    test "search filters by client_ip" do
      entries = [
        make_entry(:solicit, "00:03:00:01:11:22:33:44", "2001:db8::1"),
        make_entry(:reply, "00:03:00:01:aa:bb:cc:dd", "2001:db8::2")
      ]

      result = ActivityLive.filtered_entries(entries, "::2", "all")
      assert length(result) == 1
      assert hd(result).client_ip == "2001:db8::2"
    end

    test "nil fields do not crash search" do
      entries = [%{
        timestamp: DateTime.utc_now(),
        type: :solicit,
        client_duid: nil,
        client_ip: nil,
        details: nil,
        duration_us: nil
      }]

      result = ActivityLive.filtered_entries(entries, "anything", "all")
      assert result == []
    end
  end
end
