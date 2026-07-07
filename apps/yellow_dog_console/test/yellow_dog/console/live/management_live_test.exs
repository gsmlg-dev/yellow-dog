defmodule YellowDog.Console.ManagementLiveTest do
  use YellowDog.Console.ConnCase, async: true

  import Phoenix.LiveViewTest

  @pages [
    {"/management", "Management Overview"},
    {"/management/servers", "Management Servers"},
    {"/management/netman", "Management Netman"},
    {"/management/profiles", "Management Profiles"},
    {"/management/config", "Management Config"},
    {"/management/events", "Management Events"}
  ]

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
      {"/management/config", ["Config Versions", "Applied Status"]},
      {"/management/events", ["Management Events"]}
    ]

    for {path, expected_strings} <- assertions do
      {:ok, _view, html} = live(conn, path)

      for expected <- expected_strings do
        assert html =~ expected
      end
    end
  end
end
