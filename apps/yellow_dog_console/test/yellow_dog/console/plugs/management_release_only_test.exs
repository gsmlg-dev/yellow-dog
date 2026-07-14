defmodule YellowDog.Console.Plugs.ManagementReleaseOnlyTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    previous = Application.get_env(:yellow_dog_console, :management_release_only)
    Application.put_env(:yellow_dog_console, :management_release_only, true)

    on_exit(fn ->
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
    {:ok, _view, html} = live(conn, ~p"/management")

    assert html =~ "Management"
    refute html =~ ~s(href="/server/dashboard")
    refute html =~ ~s(href="/tool/geoip")
    refute html =~ ~s(href="/system/process-map")
    refute html =~ ~s(href="/netman")
  end

  test "blocks service, boot, and api routes", %{conn: conn} do
    assert conn |> get(~p"/server/dashboard") |> response(404) == "Not Found"
    assert conn |> get(~p"/boot/ipxe") |> response(404) == "Not Found"
    assert conn |> get(~p"/api/hosts/recipients") |> response(404) == "Not Found"
  end
end
