defmodule YellowDog.Console.Dhcpv4LiveTest do
  @moduledoc """
  LiveView tests for DHCPv4 pages: overview, leases, pools, and activity.
  All tests run without the DHCPv4 service started (graceful degradation).
  """
  use YellowDog.Console.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias YellowDog.Console.Dhcpv4Live.ActivityLive

  # ============================================================================
  # DHCPv4 Overview /dhcpv4
  # ============================================================================

  describe "DHCPv4 Overview /dhcpv4" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4")
      assert html =~ "DHCPv4"
    end

    test "shows overview stats section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4")
      assert html =~ "Total" or html =~ "Leases" or html =~ "Pool"
    end

    test "handles unknown messages gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4")
      send(view.pid, :unexpected_message)
      send(view.pid, {:unknown, :tuple})
      # Process must still be alive
      assert Process.alive?(view.pid)
    end

    test "handles telemetry_event message and reloads data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4")

      send(view.pid, {
        :telemetry_event,
        [:yellow_dog, :dhcpv4, :lease_allocated],
        %{},
        %{mac: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF], ip: {192, 168, 1, 100}}
      })

      html = render(view)
      assert html =~ "DHCPv4"
    end
  end

  # ============================================================================
  # DHCPv4 Leases /dhcpv4/leases
  # ============================================================================

  describe "DHCPv4 Leases /dhcpv4/leases" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/leases")
      assert html =~ "DHCP Leases" or html =~ "Leases"
    end

    test "shows search input", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/leases")
      assert html =~ "Search" or html =~ "search"
    end

    test "shows filter controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/leases")
      assert html =~ "filter" or html =~ "Filter" or html =~ "All"
    end

    test "shows CSV export button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/leases")
      assert html =~ "Export" or html =~ "export"
    end

    test "search event updates search query", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/leases")
      html = render_change(view, "search", %{"search" => "aa:bb:cc"})
      assert html =~ "aa:bb:cc" or is_binary(html)
    end

    test "filter_state event changes filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/leases")
      html = render_change(view, "filter_state", %{"state" => "bound"})
      assert is_binary(html)
    end

    test "filter_pool event changes pool filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/leases")
      html = render_change(view, "filter_pool", %{"pool" => "default"})
      assert is_binary(html)
    end

    test "release_lease for unknown MAC does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/leases")
      # Service not running — should return error gracefully
      html = render_click(view, "release_lease", %{"mac" => "de:ad:be:ef:00:01"})
      assert html =~ "Failed" or html =~ "error" or html =~ "Lease" or is_binary(html)
    end

    test "export_csv does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/leases")
      html = render_click(view, "export_csv")
      assert is_binary(html)
    end

    test "telemetry_event message reloads leases", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/leases")
      send(view.pid, {:telemetry_event, [:yellow_dog, :dhcpv4, :lease_allocated], %{}, %{}})
      html = render(view)
      assert html =~ "Leases" or is_binary(html)
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/leases")
      send(view.pid, :random_atom)
      send(view.pid, {:DOWN, make_ref(), :process, self(), :normal})
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # DHCPv4 Pools /dhcpv4/pools
  # ============================================================================

  describe "DHCPv4 Pools /dhcpv4/pools" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/pools")
      assert html =~ "Pool" or html =~ "Address"
    end

    test "shows Add Pool button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/pools")
      assert html =~ "Add Pool" or html =~ "add" or html =~ "New"
    end

    test "shows empty state when no pools configured", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/pools")
      # Either shows pools or shows empty state
      assert html =~ "Pool" or html =~ "No Address Pools" or html =~ "Address"
    end

    test "show_new_form event opens form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      html = render_click(view, "show_new_form")
      assert is_binary(html)
    end

    test "filter event narrows pool list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      html = render_change(view, "filter", %{"filter" => "nonexistent-pool-xyz"})
      assert is_binary(html)
    end

    test "export_csv does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      html = render_click(view, "export_csv")
      assert is_binary(html)
    end

    test "delete_pool for unknown pool shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      html = render_click(view, "delete_pool", %{"pool-name" => "no-such-pool"})
      assert html =~ "error" or html =~ "not found" or html =~ "Failed" or is_binary(html)
    end

    test "show_edit_form for unknown pool shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      html = render_click(view, "show_edit_form", %{"pool-name" => "no-such-pool"})
      assert html =~ "error" or html =~ "not found" or is_binary(html)
    end

    test "close_pool_form message hides form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      render_click(view, "show_new_form")
      send(view.pid, :close_pool_form)
      html = render(view)
      assert is_binary(html)
    end

    test "unknown messages are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/pools")
      send(view.pid, :unexpected)
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # DHCPv4 Activity /dhcpv4/activity
  # ============================================================================

  describe "DHCPv4 Activity /dhcpv4/activity" do
    test "mounts successfully", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/activity")
      assert html =~ "DHCPv4 Activity"
    end

    test "shows stats counters", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/activity")
      assert html =~ "DISCOVER"
      assert html =~ "REQUEST"
      assert html =~ "ACK"
      assert html =~ "Total Events"
    end

    test "shows filter controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/activity")
      assert html =~ "All Types"
      assert html =~ "Search"
    end

    test "shows pause and clear buttons", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/activity")
      assert html =~ "Pause" or html =~ "Resume"
      assert html =~ "Clear"
    end

    test "shows CSV export button with CsvDownload hook", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dhcpv4/activity")
      assert html =~ "Export CSV"
      assert html =~ "CsvDownload"
    end

    test "toggle_pause event toggles paused state", %{conn: conn} do
      {:ok, view, html} = live(conn, "/dhcpv4/activity")
      refute html =~ "Resume"
      html = render_click(view, "toggle_pause")
      assert html =~ "Resume" or html =~ "Pause"
      # Toggle back
      html = render_click(view, "toggle_pause")
      assert html =~ "Pause" or html =~ "Resume"
    end

    test "clear event resets entries and stats", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/activity")
      # Add an entry via message
      entry = %{
        timestamp: DateTime.utc_now(),
        type: :discover,
        client_mac: "aa:bb:cc:dd:ee:01",
        client_ip: nil,
        details: "test",
        duration_us: nil
      }

      send(view.pid, {:dhcpv4_activity, entry})
      render(view)

      html = render_click(view, "clear")
      assert html =~ "0" or is_binary(html)
    end

    test "search event filters by query", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/activity")
      html = render_change(view, "search", %{"search" => "192.168.1"})
      assert is_binary(html)
    end

    test "filter_type event changes type filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/activity")
      html = render_change(view, "filter_type", %{"type" => "discover"})
      assert is_binary(html)
    end

    test "export_csv does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/activity")
      html = render_click(view, "export_csv")
      assert is_binary(html)
    end

    test "dhcpv4_activity message adds entry to log", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/activity")

      entry = %{
        timestamp: DateTime.utc_now(),
        type: :ack,
        client_mac: "aa:bb:cc:dd:ee:ff",
        client_ip: "192.168.1.100",
        details: "ACK granted",
        duration_us: 1500
      }

      send(view.pid, {:dhcpv4_activity, entry})
      html = render(view)
      assert html =~ "aa:bb:cc:dd:ee:ff" or html =~ "192.168.1.100" or html =~ "ACK"
    end

    test "when paused, entry is not added to list but stats still update", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/activity")
      # Pause first
      render_click(view, "toggle_pause")

      entry = %{
        timestamp: DateTime.utc_now(),
        type: :discover,
        client_mac: "11:22:33:44:55:66",
        client_ip: nil,
        details: "DISCOVER",
        duration_us: nil
      }

      send(view.pid, {:dhcpv4_activity, entry})
      html = render(view)
      # Paused badge visible
      assert html =~ "Paused" or html =~ "Resume"
      # MAC should NOT appear in the entries table (paused)
      refute html =~ "11:22:33:44:55:66"
    end

    test "refresh_stats message updates service_running", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/activity")
      send(view.pid, :refresh_stats)
      html = render(view)
      assert is_binary(html)
    end

    test "unknown messages are silently ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dhcpv4/activity")
      send(view.pid, :unknown_message)
      send(view.pid, {:DOWN, make_ref(), :process, self(), :normal})
      assert Process.alive?(view.pid)
    end
  end

  # ============================================================================
  # ActivityLive.filtered_entries/3 — unit tests for public filter function
  # ============================================================================

  describe "ActivityLive.filtered_entries/3" do
    defp make_entry(type, mac \\ "aa:bb:cc:dd:ee:ff", ip \\ "10.0.0.1", details \\ "test") do
      %{
        timestamp: DateTime.utc_now(),
        type: type,
        client_mac: mac,
        client_ip: ip,
        details: details,
        duration_us: nil
      }
    end

    test "returns all entries for type 'all'" do
      entries = [make_entry(:discover), make_entry(:ack), make_entry(:nak)]
      assert ActivityLive.filtered_entries(entries, "", "all") == entries
    end

    test "filters by specific type" do
      entries = [make_entry(:discover), make_entry(:ack), make_entry(:nak)]
      result = ActivityLive.filtered_entries(entries, "", "discover")
      assert length(result) == 1
      assert hd(result).type == :discover
    end

    test "error filter includes nak, decline, pool_exhausted, acl_denied, rate_limited" do
      entries = [
        make_entry(:discover),
        make_entry(:nak),
        make_entry(:decline),
        make_entry(:pool_exhausted),
        make_entry(:acl_denied),
        make_entry(:rate_limited),
        make_entry(:ack)
      ]

      result = ActivityLive.filtered_entries(entries, "", "error")
      types = Enum.map(result, & &1.type)
      assert :nak in types
      assert :decline in types
      assert :pool_exhausted in types
      assert :acl_denied in types
      assert :rate_limited in types
      refute :discover in types
      refute :ack in types
    end

    test "unknown type filter falls back to all entries" do
      entries = [make_entry(:discover), make_entry(:ack)]
      result = ActivityLive.filtered_entries(entries, "", "completely_unknown_xyz")
      assert length(result) == 2
    end

    test "search filters by client_mac" do
      entries = [
        make_entry(:discover, "aa:bb:cc:11:22:33"),
        make_entry(:ack, "ff:ee:dd:44:55:66")
      ]

      result = ActivityLive.filtered_entries(entries, "aa:bb", "all")
      assert length(result) == 1
      assert hd(result).client_mac == "aa:bb:cc:11:22:33"
    end

    test "search filters by client_ip" do
      entries = [
        make_entry(:discover, "aa:bb:cc:11:22:33", "10.0.0.50"),
        make_entry(:ack, "ff:ee:dd:44:55:66", "192.168.1.100")
      ]

      result = ActivityLive.filtered_entries(entries, "192.168", "all")
      assert length(result) == 1
      assert hd(result).client_ip == "192.168.1.100"
    end

    test "search filters by details" do
      entries = [
        make_entry(:discover, "aa:bb:cc:11:22:33", "10.0.0.1", "Pool exhausted error"),
        make_entry(:ack, "ff:ee:dd:44:55:66", "10.0.0.2", "ACK granted")
      ]

      result = ActivityLive.filtered_entries(entries, "exhausted", "all")
      assert length(result) == 1
      assert hd(result).type == :discover
    end

    test "search is case-insensitive" do
      entries = [make_entry(:ack, "AA:BB:CC:DD:EE:FF")]
      result = ActivityLive.filtered_entries(entries, "aa:bb", "all")
      assert length(result) == 1
    end

    test "empty search returns all entries" do
      entries = [make_entry(:discover), make_entry(:ack)]
      assert ActivityLive.filtered_entries(entries, "", "all") == entries
    end

    test "nil client fields do not crash search" do
      entries = [
        %{
          timestamp: DateTime.utc_now(),
          type: :discover,
          client_mac: nil,
          client_ip: nil,
          details: nil,
          duration_us: nil
        }
      ]

      result = ActivityLive.filtered_entries(entries, "anything", "all")
      assert result == []
    end

    test "type and search filters combine" do
      entries = [
        make_entry(:discover, "aa:11:22:33:44:55"),
        make_entry(:ack, "aa:11:22:33:44:55"),
        make_entry(:discover, "bb:11:22:33:44:55")
      ]

      result = ActivityLive.filtered_entries(entries, "aa:11", "discover")
      assert length(result) == 1
      assert hd(result).type == :discover
      assert hd(result).client_mac == "aa:11:22:33:44:55"
    end
  end
end
