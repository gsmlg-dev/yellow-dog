defmodule YellowDog.Console.ManagementLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  @pages [
    {"/management", "Management Overview"},
    {"/management/servers", "Management Servers"},
    {"/management/netman", "Management Netman"},
    {"/management/profiles", "Management Profiles"},
    {"/management/config", "Management Config"},
    {"/management/events", "Management Events"}
  ]

  setup do
    YellowDog.Management.Servers.reset()
    YellowDog.Management.Netmans.reset()

    on_exit(fn ->
      YellowDog.Management.Servers.reset()
      YellowDog.Management.Netmans.reset()
    end)
  end

  test "management routes mount successfully", %{conn: conn} do
    for {path, title} <- @pages do
      {:ok, _view, html} = live(conn, path)

      assert html =~ title
      refute html =~ "Node Management"
    end
  end

  test "management navigation is visible from the overview", %{conn: conn} do
    {:ok, view, html} = live(conn, "/management")

    assert html =~ "Management"
    refute html =~ "Node Management"

    assert has_element?(view, "a[href='/management']", "Management")
    assert has_element?(view, "a[href='/management']", "Overview")
    assert has_element?(view, "a[href='/management/servers']", "Servers")
    assert has_element?(view, "a[href='/management/netman']", "Netman")
    assert has_element?(view, "a[href='/management/profiles']", "Profiles")
    assert has_element?(view, "a[href='/management/config']", "Config")
    assert has_element?(view, "a[href='/management/events']", "Events")
  end

  test "management overview summarizes facade-backed counts", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/management")

    assert html =~ "Servers"
    assert html =~ "Netman Instances"
    assert html =~ "Profiles"
    assert html =~ "Recent Events"
  end

  test "management detail pages expose expected skeleton content", %{conn: conn} do
    assertions = [
      {"/management/servers", ["Profile", "Status", "Services", "Last Seen"]},
      {"/management/netman", ["Profile", "Status", "Features", "Apply Mode", "Last Seen"]},
      {"/management/profiles", ["Server Profiles", "Netman Profiles"]},
      {"/management/config",
       ["Published Versions", "Pending Changes", "Applied Status", "Drift"]},
      {"/management/events", ["Server Events", "Netman Events", "Audit Logs"]}
    ]

    for {path, expected_strings} <- assertions do
      {:ok, _view, html} = live(conn, path)

      for expected <- expected_strings do
        assert html =~ expected
      end
    end
  end

  test "management pages render facade-backed records and events", %{conn: conn} do
    {:ok, _server} =
      YellowDog.ManagementCore.register_server(%{
        id: "srv-cloud-dns-01",
        name: "Cloud DNS 01",
        profile: :cloud_dns,
        status: :online,
        services: %{dns: true, server_agent: true},
        last_seen_at: ~U[2026-07-07 00:00:00Z]
      })

    {:ok, _netman} =
      YellowDog.ManagementCore.register_netman(%{
        id: "netman-cloud-app-01",
        name: "Cloud App 01 Netman",
        profile: :cloud_server,
        status: :degraded,
        features: %{interfaces: true, routes: true},
        apply_mode: :observe_first,
        last_seen_at: ~U[2026-07-07 00:00:00Z]
      })

    {:ok, _view, servers_html} = live(conn, "/management/servers")
    assert servers_html =~ "srv-cloud-dns-01"
    assert servers_html =~ "Cloud DNS 01"
    assert servers_html =~ "cloud dns"
    assert servers_html =~ "dns"
    assert servers_html =~ "server agent"

    {:ok, _view, netman_html} = live(conn, "/management/netman")
    assert netman_html =~ "netman-cloud-app-01"
    assert netman_html =~ "Cloud App 01 Netman"
    assert netman_html =~ "cloud server"
    assert netman_html =~ "observe first"

    {:ok, _view, events_html} = live(conn, "/management/events")
    assert events_html =~ "Server registered"
    assert events_html =~ "Netman registered"
  end
end
