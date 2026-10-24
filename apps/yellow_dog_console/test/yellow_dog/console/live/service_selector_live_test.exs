defmodule YellowDog.Console.ServiceSelectorLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Management.Servers
  alias YellowDog.ManagementCore

  setup do
    Servers.reset()

    on_exit(fn ->
      Servers.reset()
    end)
  end

  test "Server selector renders a deterministic empty state", %{conn: conn} do
    {:ok, view, html} = live(conn, "/server")

    assert html =~ "Select a Server"
    assert html =~ "No servers registered"
    refute has_element?(view, "#server-selector-records a")
  end

  test "Server selector lists online and offline management records with explicit links", %{
    conn: conn
  } do
    assert {:ok, _online} =
             ManagementCore.register_server(%{
               id: "server-online",
               name: "Online Server",
               status: :online
             })

    assert {:ok, _offline} =
             ManagementCore.register_server(%{
               id: "server offline",
               name: "Offline Server",
               status: :offline,
               last_seen_at: ~U[2026-08-10 10:00:00Z]
             })

    {:ok, view, html} = live(conn, "/server")

    assert html =~ "Online Server"
    assert html =~ "Offline Server"
    assert html =~ "online"
    assert html =~ "offline"
    assert has_element?(view, "a[href='/server/server-online/dashboard']")
    assert has_element?(view, "a[href='/server/server%20offline/dashboard']")
  end

  test "reserved Server settings record is listed without a selectable link", %{conn: conn} do
    assert {:ok, _server} =
             ManagementCore.register_server(%{
               id: "settings",
               name: "Reserved ID",
               status: :online
             })

    {:ok, view, html} = live(conn, "/server")

    assert html =~ "Reserved ID"
    assert html =~ "Reserved UI path"
    refute has_element?(view, "#server-selector-settings a[href='/server/settings/dashboard']")
  end

  test "unknown and malformed scoped IDs render deterministic not-found responses", %{conn: conn} do
    assert conn |> get("/server/missing/dashboard") |> response(404) == "Server not found"

    overlong = String.duplicate("a", 129)
    assert conn |> get("/server/#{overlong}/dashboard") |> response(404) == "Server not found"

    assert conn |> get("/server/%2E%2E/dashboard") |> response(404) == "Server not found"
    assert conn |> get("/server/a%2Fb/dashboard") |> response(404) == "Server not found"
  end

  test "a valid scoped route uses the selected record and never a default", %{conn: conn} do
    assert {:ok, _first} = ManagementCore.register_server(%{id: "server-a", status: :online})
    assert {:ok, _second} = ManagementCore.register_server(%{id: "server-b", status: :offline})

    {:ok, view, _html} = live(conn, "/server/server-b/dashboard")

    assert %{selected_server: %{id: "server-b"}, service_online?: false} =
             :sys.get_state(view.pid).socket.assigns
  end

  test "encoded Server IDs resolve to their exact management records", %{conn: conn} do
    assert {:ok, _server} =
             ManagementCore.register_server(%{id: "server one@北京", status: :offline})

    {:ok, server_view, _html} =
      live(conn, "/server/server%20one%40%E5%8C%97%E4%BA%AC/dashboard")

    assert %{selected_server: %{id: "server one@北京"}} =
             :sys.get_state(server_view.pid).socket.assigns
  end
end
