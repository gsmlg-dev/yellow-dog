defmodule YellowDog.Console.Components.SidebarScopeTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Console.Hooks.CurrentPath
  alias YellowDog.Management.Netmans
  alias YellowDog.Management.Servers
  alias YellowDog.ManagementCore

  defmodule ScopeHarness do
    use Phoenix.LiveView

    alias YellowDog.Console.Layouts

    @impl true
    def mount(_params, %{"path" => path}, socket),
      do: {:ok, Phoenix.Component.assign(socket, :scoped_path, path)}

    @impl true
    def render(assigns) do
      ~H"""
      <Layouts.app flash={@flash} current_path={@scoped_path}>
        <div id="scope-harness">Scoped navigation</div>
      </Layouts.app>
      """
    end
  end

  setup do
    Servers.reset()
    Netmans.reset()

    on_exit(fn ->
      Servers.reset()
      Netmans.reset()
    end)
  end

  test "top navigation keeps the approved order and enabled selector destinations", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/server")

    top_menu = view |> element(".navbar ul") |> render()

    assert top_menu
           |> Floki.parse_fragment!()
           |> Floki.find("a")
           |> Enum.map(fn anchor ->
             {Floki.text(anchor) |> String.replace(~r/\s+/, " ") |> String.trim(),
              Floki.attribute(anchor, "href") |> List.first()}
           end) == [
             {"Management", "/management"},
             {"Servers", "/server"},
             {"Netman", "/netman"},
             {"Tools", "/tool/geoip"},
             {"System", "/system/process-map"}
           ]

    assert has_element?(view, ".navbar a[href='/server']:not([aria-disabled='true'])", "Servers")
    assert has_element?(view, ".navbar a[href='/netman']:not([aria-disabled='true'])", "Netman")
  end

  test "navigation scope decodes exact IDs without treating reserved UI paths as selections" do
    assert CurrentPath.selection_for_path("/server/server%20one%40%E5%8C%97%E4%BA%AC/dns/zones") ==
             {:server, "server one@\u5317\u4eac"}

    assert CurrentPath.selection_for_path("/netman/netman%20one/config") ==
             {:netman, "netman one"}

    assert CurrentPath.selection_for_path("/server") == nil
    assert CurrentPath.selection_for_path("/server/settings/dns") == nil
    assert CurrentPath.selection_for_path("/netman/config") == nil
  end

  test "Server service navigation is disabled before an explicit selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/server")

    assert has_element?(view, "#server-selection-form select[name='selection[id]']")

    items = service_navigation_items(view, "server")
    assert length(items) > 10

    for item <- items do
      assert Floki.attribute(item, "href") == []
      assert Floki.attribute(item, "data-phx-link") == []

      assert Floki.attribute(item, "disabled") != [] or
               Floki.attribute(item, "aria-disabled") == ["true"]
    end
  end

  test "Netman service navigation is disabled before an explicit selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/netman")

    assert has_element?(view, "#netman-selection-form select[name='selection[id]']")

    items = service_navigation_items(view, "netman")
    assert length(items) == 5

    for item <- items do
      assert Floki.attribute(item, "href") == []
      assert Floki.attribute(item, "data-phx-link") == []

      assert Floki.attribute(item, "disabled") != [] or
               Floki.attribute(item, "aria-disabled") == ["true"]
    end
  end

  test "sidebar selectors never expose reserved Console path IDs", %{conn: conn} do
    register_server("settings", "Reserved Server")
    register_netman("config", "Reserved Netman")

    {:ok, server_view, _html} = live(conn, "/server")
    refute has_element?(server_view, "#server-selection-form option[value='settings']")

    {:ok, netman_view, _html} = live(conn, "/netman")
    refute has_element?(netman_view, "#netman-selection-form option[value='config']")
  end

  test "selected Server links retain the exact encoded ID and nested destinations", %{conn: conn} do
    register_server("server one@\u5317\u4eac", "Primary Server")
    register_server("server-two", "Secondary Server")

    {:ok, view, _html} =
      live(conn, "/server/server%20one%40%E5%8C%97%E4%BA%AC/dns/zones")

    hrefs = service_navigation_hrefs(view, "server")

    assert hrefs != []

    assert Enum.all?(
             hrefs,
             &String.starts_with?(&1, "/server/server%20one%40%E5%8C%97%E4%BA%AC/")
           )

    assert "/server/server%20one%40%E5%8C%97%E4%BA%AC/dashboard" in hrefs
    assert "/server/server%20one%40%E5%8C%97%E4%BA%AC/dns/zones" in hrefs
    assert "/server/server%20one%40%E5%8C%97%E4%BA%AC/dhcpv4/leases" in hrefs
    assert "/server/server%20one%40%E5%8C%97%E4%BA%AC/netboot/profiles" in hrefs

    assert has_element?(
             view,
             "a.active[data-service-target='server'][href='/server/server%20one%40%E5%8C%97%E4%BA%AC/dns/zones']"
           )

    assert has_element?(
             view,
             "#server-selection-form option[value='server one@\u5317\u4eac'][selected]",
             "Primary Server"
           )

    assert has_element?(
             view,
             "#server-selection-form option[value='server-two']",
             "Secondary Server"
           )
  end

  test "switching the Server selector changes every destination and active state", %{conn: conn} do
    register_server("server-a", "Server A")
    register_server("server-b", "Server B")

    {:ok, view, _html} = live(conn, "/server/server-a/dashboard")

    view
    |> form("#server-selection-form", selection: %{id: "server-b"})
    |> render_change()

    assert_redirect(view, "/server/server-b/dashboard")

    {:ok, switched, _html} = live(conn, "/server/server-b/dashboard")
    hrefs = service_navigation_hrefs(switched, "server")

    assert hrefs != []
    assert Enum.all?(hrefs, &String.starts_with?(&1, "/server/server-b/"))
    refute Enum.any?(hrefs, &String.contains?(&1, "/server/server-a/"))

    assert has_element?(
             switched,
             "a.active[data-service-target='server'][href='/server/server-b/dashboard']"
           )
  end

  test "selected Netman links use only its exact ID and keep config reserved for the UI", %{
    conn: conn
  } do
    register_netman("netman one@\u5317\u4eac", "Primary Netman")
    register_netman("config", "Reserved Netman")

    {:ok, view, _html} =
      live_isolated(conn, ScopeHarness,
        session: %{"path" => "/netman/netman%20one%40%E5%8C%97%E4%BA%AC/config"}
      )

    assert service_navigation_hrefs(view, "netman") == [
             "/netman/netman%20one%40%E5%8C%97%E4%BA%AC",
             "/netman/netman%20one%40%E5%8C%97%E4%BA%AC/config",
             "/netman/netman%20one%40%E5%8C%97%E4%BA%AC/interfaces",
             "/netman/netman%20one%40%E5%8C%97%E4%BA%AC/resolved",
             "/netman/netman%20one%40%E5%8C%97%E4%BA%AC/dhcp-client"
           ]

    assert has_element?(
             view,
             "a.active[data-service-target='netman'][href='/netman/netman%20one%40%E5%8C%97%E4%BA%AC/config']"
           )

    assert has_element?(view, "#netman-selection-form select")
    refute has_element?(view, "#netman-selection-form option[value='config']")
  end

  defp service_navigation_items(view, target_type) do
    view
    |> element("#app-sidebar")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find("[data-service-navigation][data-service-target='#{target_type}']")
  end

  defp service_navigation_hrefs(view, target_type) do
    view
    |> service_navigation_items(target_type)
    |> Enum.flat_map(&Floki.attribute(&1, "href"))
  end

  defp register_server(id, name) do
    assert {:ok, _server} =
             ManagementCore.register_server(%{id: id, name: name, status: :offline})
  end

  defp register_netman(id, name) do
    assert {:ok, _netman} =
             ManagementCore.register_netman(%{id: id, name: name, status: :offline})
  end
end
