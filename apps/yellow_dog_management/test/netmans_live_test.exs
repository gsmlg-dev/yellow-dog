defmodule YellowDog.Management.NetmansLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Domain, Repo}

  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "both selectors are usable without a runtime or login", %{conn: conn} do
    for path <- ["/management/netman", "/netman?netman_id[]=missing"] do
      {:ok, view, html} = live(conn, path)
      assert has_element?(view, "#netman-empty", "No Netman instances registered")
      assert has_element?(view, "#netman-form")
      assert html =~ "Actual runtime state is unknown"
      refute has_element?(view, "input[type='password']")
    end

    assert Domain.list_netmans() == []
    assert Domain.list_audit() == []
  end

  test "registration saves typed metadata and resets the form", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/management/netman")

    view
    |> form("#netman-form",
      netman: %{
        id: "config",
        name: "Network Manager",
        profile_name: "custom",
        apply_mode: "observe_first",
        features: %{interfaces: "true", vpn: "true"}
      }
    )
    |> render_submit()

    assert_push_event(view, "reset_form", %{id: "netman-form"})
    assert has_element?(view, "#netman-form input[name='netman[id]'][value='']")
    assert has_element?(view, "#netman-selector-config a[href='/netman/config']", "Manage")

    assert {:ok, node} = Domain.get_netman("config")
    assert node["name"] == "Network Manager"
    assert node["apply_mode"] == "observe_first"
    assert node["features"]["interfaces"]
    assert node["features"]["vpn"]
    assert node["status"] == "not_yet_connected"
    assert node["actual_state"] == "unknown"
    assert node["last_seen_at"] == nil
  end

  test "changing the preset uses catalog defaults without starting services", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/netman")
    view |> form("#netman-form", netman: %{profile_name: "cloud_server"}) |> render_change()

    assert has_element?(
             view,
             "select[name='netman[apply_mode]'] option[value='observe_first'][selected]"
           )

    assert has_element?(view, "input[name='netman[features][dhcp_client]'][checked]")
    refute has_element?(view, "input[name='netman[features][vpn]'][checked]")
    assert Domain.list_netmans() == []
    assert Domain.list_audit() == []
  end

  test "metadata edits retain the path identity and stale revisions cannot overwrite", %{
    conn: conn
  } do
    node = create_netman("selected")
    other = create_netman("other")
    before_visit = {Domain.list_netmans(), Domain.list_audit()}

    {:ok, view, html} = live(conn, "/netman/selected?netman_id[]=other")
    assert has_element?(view, "#netman-overview", "selected")
    assert has_element?(view, "a[href='/netman/selected/config']", "Configuration")
    assert has_element?(view, "a[href='/netman/selected/resolved']", "Resolved")
    assert html =~ "Runtime activation, interfaces, routes and VPN are not migrated"
    assert {Domain.list_netmans(), Domain.list_audit()} == before_visit

    view |> form("#netman-edit-form", netman: %{name: "Renamed"}) |> render_submit()
    assert {:ok, updated} = Domain.get_netman(node["id"])
    assert updated["name"] == "Renamed"
    assert updated["revision"] == node["revision"] + 1
    assert {:ok, ^other} = Domain.get_netman(other["id"])

    concurrent =
      mutate("update_netman", %{
        "id" => node["id"],
        "name" => "Concurrent",
        "expected_revision" => updated["revision"]
      })

    assert view |> form("#netman-edit-form", netman: %{name: "Stale"}) |> render_submit() =~
             "revision"

    assert {:ok, ^concurrent} = Domain.get_netman(node["id"])
  end

  test "unknown route identity cannot be replaced by query or forged metadata", %{conn: conn} do
    create_netman("known")
    before_visit = {Domain.list_netmans(), Domain.list_audit()}

    for query <- ["netman_id=known", "netman_id[]=known", "netman_id[id]=known"] do
      {:ok, view, _html} = live(conn, "/netman/missing?" <> query)
      assert has_element?(view, "#netman-scope-error")
      refute has_element?(view, "#netman-edit-form")
      render_submit(view, "save_netman", %{"netman" => %{"id" => "known", "name" => "Forged"}})
      assert {Domain.list_netmans(), Domain.list_audit()} == before_visit
    end
  end

  defp create_netman(id),
    do:
      mutate("create_netman", %{
        "id" => id,
        "name" => id,
        "profile_name" => "custom",
        "apply_mode" => "managed",
        "features" => %{}
      })

  defp mutate(operation, params) do
    {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
