defmodule YellowDog.Management.NavigationLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Audit, Domain, DomainFixtures, Idempotency, Repo}
  alias YellowDog.ManagementUI.Layouts

  @endpoint YellowDog.ManagementUI.Endpoint
  @sections ~w(nodes data monitoring system)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "desktop and mobile navigation contain exactly four ordered groups with zero Workers", %{
    conn: conn
  } do
    assert Domain.list_workers() == []

    for {path, section} <- [
          {"/management/servers", "nodes"},
          {"/management/zones", "data"},
          {"/management", "monitoring"},
          {"/system/process-map", "system"}
        ] do
      {:ok, view, html} = live(conn, path)
      document = LazyHTML.from_fragment(html)

      for label <- ["Main navigation", "Mobile navigation"] do
        links = LazyHTML.query(document, "nav[aria-label='#{label}'] a[data-section]")
        assert LazyHTML.attribute(links, "data-section") == @sections

        assert has_element?(
                 view,
                 "nav[aria-label='#{label}'] a[data-section='#{section}'][aria-current='page']"
               )
      end

      assert has_element?(
               view,
               "#app-sidebar[data-scroll-key='sidebar:#{section}'][data-section='#{section}']"
             )

      assert has_element?(
               view,
               "#mobile-navigation-toggle[aria-controls='app-sidebar'][aria-expanded='false']"
             )

      assert has_element?(
               view,
               "#app-sidebar-navigation[phx-hook='DuskmoonLeftMenu'][data-storage-key]"
             )

      assert has_element?(
               view,
               "#app-sidebar-navigation [data-left-menu-toggle][aria-expanded='true'][aria-controls='app-sidebar-navigation-scroll']"
             )

      assert has_element?(view, "#app-sidebar-navigation details[id][data-nav-group] > summary")
      refute has_element?(view, "#app-sidebar-navigation .management-help")

      refute has_element?(view, "#app-sidebar-navigation a[href='#']")

      refute has_element?(
               view,
               "#server-selection-form-select option[selected][value]:not([value=''])"
             )
    end
  end

  test "planned and scope-dependent items have explanations and no navigation or events", %{
    conn: conn
  } do
    for path <- ["/management/servers", "/management/zones", "/management", "/system/process-map"] do
      {:ok, _view, html} = live(conn, path)

      disabled =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#app-sidebar-navigation [aria-disabled='true'][data-nav-item]")

      assert LazyHTML.attribute(disabled, "title") |> Enum.all?(&(&1 != ""))
      assert LazyHTML.attribute(disabled, "aria-label") |> Enum.all?(&(&1 != ""))

      for attribute <- [
            "href",
            "phx-click",
            "phx-change",
            "phx-submit",
            "phx-target",
            "data-phx-link"
          ] do
        assert LazyHTML.attribute(disabled, attribute) == []
      end
    end

    {:ok, view, _} = live(conn, "/management/zones")

    assert has_element?(
             view,
             "[data-nav-item='dns_acls'][aria-disabled='true']",
             "Requires scope"
           )

    assert has_element?(view, "[data-nav-item='dhcpv4_data'][aria-disabled='true']", "Planned")
    assert has_element?(view, "[data-nav-item='ip_database'][href='/system/ip-database']")
  end

  test "scoped DNS pages retain Worker and DNS service and highlight only their owner", %{
    conn: conn
  } do
    worker = mutate("create_worker", %{"id" => "nav-worker", "name" => "Navigation Worker"})

    service =
      mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"], "stopped"))

    zone = mutate("create_zone", DomainFixtures.zone())
    base = "/server/nav-worker/dns"

    for {path, item} <- [
          {"#{base}/zones/import", "dns_zones"},
          {"#{base}/zones/#{zone["id"]}/records/bulk", "dns_zones"},
          {"#{base}/zones/#{zone["id"]}/records/0/edit", "dns_zones"},
          {"#{base}/views/#{service["id"]}", "dns_views"},
          {"#{base}/acl/#{service["id"]}", "dns_acls"}
        ] do
      {:ok, view, html} = live(conn, path <> "?server_id=other&service_id=other#editor")

      assert has_element?(
               view,
               "nav[aria-label='Main navigation'] a[data-section='data'][aria-current='page']"
             )

      assert has_element?(
               view,
               "#server-selection-form-select option[value='nav-worker'][selected]"
             )

      active =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#app-sidebar-navigation a[aria-current='page']")

      assert LazyHTML.attribute(active, "data-nav-item") == [item]
      assert has_element?(view, "[data-nav-item='dns_zones'][href='#{base}/zones']")

      if item in ["dns_views", "dns_acls"] do
        assert has_element?(
                 view,
                 "[data-nav-item='dns_views'][href='#{base}/views/#{service["id"]}']"
               )

        assert has_element?(
                 view,
                 "[data-nav-item='dns_acls'][href='#{base}/acl/#{service["id"]}']"
               )
      end
    end
  end

  test "scoped selection accepts only supplied records and does not select the first Worker", %{
    conn: conn
  } do
    mutate("create_worker", %{"id" => "nav-first", "name" => "First Worker"})
    mutate("create_worker", %{"id" => "nav-second", "name" => "Second Worker"})
    {:ok, view, _} = live(conn, "/server/nav-second/dashboard")

    assert has_element?(
             view,
             "#server-selection-form-select option[value='nav-second'][selected]"
           )

    assert has_element?(view, "[data-nav-item='worker_services'][aria-current='page']")

    before = Domain.list_audit()

    view
    |> element("#server-selection-form")
    |> render_change(%{"selection" => %{"id" => "not-registered"}})

    refute_redirected(view)
    assert Domain.list_audit() == before

    assert has_element?(
             view,
             "#server-selection-form-select option[value='nav-second'][selected]"
           )
  end

  test "global Data pages keep their dataset selectors without adding a global Worker selector",
       %{conn: conn} do
    mutate("create_worker", %{"id" => "nav-unselected", "name" => "Unselected Worker"})

    for path <- ["/management/zones", "/management/dns/views"] do
      {:ok, view, _} = live(conn, path)
      refute has_element?(view, "#server-selection-form")
      assert has_element?(view, "[data-nav-item='dns_views'][href='/management/dns/views']")
      assert has_element?(view, "[data-nav-item='dns_zones'][href='/management/zones']")
    end
  end

  test "rendering the navigation shell does not write business, audit, or idempotency state" do
    before = snapshot()

    for path <- ["/management/servers", "/management/zones", "/management", "/system/process-map"] do
      render_component(&Layouts.app/1, current_path: path, flash: %{}, inner_content: "")
    end

    assert snapshot() == before
  end

  defp snapshot do
    {Domain.list_workers(), Domain.list_zones(), Repo.all(Audit), Repo.all(Idempotency)}
  end

  defp mutate(command, payload) do
    assert {:ok, result} =
             Domain.mutate(command, payload, "navigation-test", Ecto.UUID.generate())

    result
  end
end
