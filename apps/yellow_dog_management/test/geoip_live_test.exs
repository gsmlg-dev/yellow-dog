defmodule YellowDog.Management.GeoipLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{GeoIP, GeoIPFixtures, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    directory =
      Path.join(System.tmp_dir!(), "management-geoip-ui-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    path = GeoIPFixtures.write!(directory)
    server = start_supervised!({GeoIP, name: nil, paths: %{city: path, country: path}})
    GeoIPFixtures.wait_loaded(server)
    previous = Application.fetch_env(:yellow_dog_management, :geoip_server)
    Application.put_env(:yellow_dog_management, :geoip_server, server)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:yellow_dog_management, :geoip_server, value)
        :error -> Application.delete_env(:yellow_dog_management, :geoip_server)
      end

      File.rm_rf!(directory)
    end)

    %{conn: build_conn(), server: server}
  end

  test "real local lookup retains labels and every geographic field", %{conn: conn} do
    {:ok, view, html} = live(conn, "/tool/geoip")
    assert html =~ "IP Geo Lookup"
    assert html =~ "Enter IP address (e.g. 8.8.8.8)"
    assert has_element?(view, "#geoip-database-info", "GeoIP2-City")
    view |> form("#geoip-lookup-form", ip: " 216.160.83.56 ", type: "city") |> render_submit()
    html = render_async(view)

    for value <- [
          "Country",
          "City",
          "Subdivision",
          "Continent",
          "Timezone",
          "Postal Code",
          "Coordinates",
          "United States",
          "US",
          "Milton",
          "Washington",
          "North America",
          "America/Los_Angeles",
          "98354",
          "47.2513, -122.3149"
        ] do
      assert html =~ value
    end

    assert has_element?(view, "#geoip-lookup-result")
    refute has_element?(view, "input[name='ip'][disabled]")
  end

  test "IPv6 and country selection query the actual configured decoder", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tool/geoip")
    view |> form("#geoip-lookup-form", ip: "2001:218::", type: "country") |> render_submit()
    assert render_async(view) =~ "Japan"
    assert has_element?(view, "select[name='type'] option[value='country'][selected]")
    assert has_element?(view, "#geoip-lookup-result", "Asia/Tokyo")
  end

  test "invalid IP, not found and blank input leave a usable page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tool/geoip")

    for {ip, expected} <- [
          {"not-an-ip", "Invalid IP address format"},
          {"192.0.2.1", "IP address not found in database"}
        ] do
      view |> form("#geoip-lookup-form", ip: ip, type: "city") |> render_submit()
      assert render_async(view) =~ expected
      refute has_element?(view, "#geoip-lookup-result")
      assert Process.alive?(view.pid)
    end

    view |> form("#geoip-lookup-form", ip: " ", type: "city") |> render_submit()
    refute has_element?(view, "#geoip-lookup-error")
    refute has_element?(view, "#geoip-lookup-result")
    assert has_element?(view, "input[name='ip'][value='']")
  end

  test "unloaded, unconfigured and unavailable backends are distinct", %{
    conn: conn,
    server: server
  } do
    :ok = GeoIP.unload(:city, server)
    {:ok, view, _html} = live(conn, "/tool/geoip")
    view |> form("#geoip-lookup-form", ip: "81.2.69.160", type: "city") |> render_submit()
    assert render_async(view) =~ "Database is not loaded"

    unconfigured = start_supervised!({GeoIP, name: nil, paths: %{}}, id: :unconfigured)
    Application.put_env(:yellow_dog_management, :geoip_server, unconfigured)
    {:ok, view, _html} = live(conn, "/tool/geoip")
    view |> form("#geoip-lookup-form", ip: "81.2.69.160", type: "city") |> render_submit()
    assert render_async(view) =~ "Database is not configured"

    Application.put_env(:yellow_dog_management, :geoip_server, :nonexistent_management_geoip_test)
    {:ok, view, html} = live(conn, "/tool/geoip")
    assert html =~ "Database service unavailable"
    view |> form("#geoip-lookup-form", ip: "81.2.69.160", type: "city") |> render_submit()
    assert render_async(view) =~ "Database service unavailable"
  end

  test "forged type or resource data cannot select a file or database", %{
    conn: conn,
    server: server
  } do
    {:ok, view, _html} = live(conn, "/tool/geoip")

    html =
      render_submit(view, "lookup", %{
        "ip" => "81.2.69.160",
        "type" => "arbitrary",
        "path" => "/etc/passwd"
      })

    assert html =~ "Invalid database selection"
    refute has_element?(view, "#geoip-lookup-result")
    assert Enum.all?(GeoIP.info(server), & &1.loaded)
  end
end
