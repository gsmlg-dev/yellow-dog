defmodule YellowDog.Console.DnsLiveConfigUnavailableTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "DNS views page renders when YellowDog.Config is unavailable", %{conn: conn} do
    Application.stop(:yellow_dog)
    on_exit(fn -> Application.ensure_all_started(:yellow_dog) end)

    refute Process.whereis(YellowDog.Config)

    assert {:ok, _view, html} = live(conn, "/server/dns/views")
    assert html =~ "DNS Views"
  end
end
