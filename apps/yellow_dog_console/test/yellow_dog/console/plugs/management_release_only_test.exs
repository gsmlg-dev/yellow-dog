defmodule YellowDog.Console.Plugs.ManagementReleaseOnlyTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous = Application.get_env(:yellow_dog_console, :management_release_only)
    Application.put_env(:yellow_dog_console, :management_release_only, true)
    YellowDog.Management.Servers.reset()
    YellowDog.Management.Netmans.reset()

    on_exit(fn ->
      YellowDog.Management.Servers.reset()
      YellowDog.Management.Netmans.reset()

      case previous do
        nil -> Application.delete_env(:yellow_dog_console, :management_release_only)
        value -> Application.put_env(:yellow_dog_console, :management_release_only, value)
      end
    end)

    :ok
  end

  test "redirects root to management overview", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn, 302) == ~p"/management"
  end

  test "allows management pages", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/management")

    assert html =~ "Management"
    assert has_element?(view, ".navbar a[href='/server']", "Servers")
    assert has_element?(view, ".navbar a[href='/netman']", "Netman")
    refute html =~ ~s(href="/server/dashboard")
    refute html =~ ~s(href="/tool/geoip")
    refute html =~ ~s(href="/system/process-map")
  end

  test "allows selectors, scoped service routes, and stable service not-found responses", %{
    conn: conn
  } do
    assert {:ok, _view, server_html} = live(conn, "/server")
    assert server_html =~ "Select a Server"

    assert {:ok, _view, netman_html} = live(conn, "/netman")
    assert netman_html =~ "Select a Netman"

    assert conn |> get("/server/missing/dashboard") |> response(404) == "Server not found"
    assert conn |> get("/netman/missing") |> response(404) == "Netman not found"

    assert conn |> get("/service-not-found/server") |> response(404) == "Server not found"
  end

  test "allows a registered scoped service page in the management release", %{conn: conn} do
    assert {:ok, _server} =
             YellowDog.ManagementCore.register_server(%{
               id: "management-server",
               status: :offline
             })

    {:ok, view, _html} = live(conn, "/server/management-server/dashboard")

    assert %{selected_server: %{id: "management-server"}, service_online?: false} =
             :sys.get_state(view.pid).socket.assigns
  end

  test "legacy service paths redirect while boot and api routes remain blocked", %{conn: conn} do
    assert conn |> get("/server/dashboard") |> redirected_to(302) == "/server"
    assert conn |> get("/netman/config") |> redirected_to(302) == "/netman"
    assert conn |> get(~p"/boot/ipxe") |> response(404) == "Not Found"
    assert conn |> get(~p"/api/hosts/recipients") |> response(404) == "Not Found"
  end
end
