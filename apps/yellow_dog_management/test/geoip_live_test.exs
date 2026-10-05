defmodule YellowDog.Management.GeoipLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Domain, Repo, TaskArtifacts}
  @endpoint YellowDog.ManagementUI.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    assert is_nil(Process.whereis(YellowDog.Management.GeoIP))
    %{conn: build_conn()}
  end

  test "the diagnostic clearly reports its Worker prerequisite and links to artifact management",
       %{conn: conn} do
    {:ok, view, html} = live(conn, "/tool/geoip")
    assert html =~ "IP Geo Lookup"

    assert has_element?(
             view,
             "#geoip-lookup-unavailable[role='status']",
             "Worker-backed diagnostics"
           )

    assert has_element?(view, "a[href='/system/ip-database']", "Manage IP database artifacts")
    refute has_element?(view, "#geoip-lookup-form")
    refute has_element?(view, "#geoip-lookup-result")
    refute has_element?(view, "#geoip-database-info")
    assert is_nil(Process.whereis(YellowDog.Management.GeoIP))
  end

  test "forged lookup requests cannot execute a local query or mutate the catalog", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tool/geoip")

    before_read =
      {TaskArtifacts.catalog(), Domain.list_tasks(), Domain.list_task_history(),
       Domain.list_audit()}

    assert render_submit(view, "lookup", %{
             "ip" => "81.2.69.160",
             "type" => "city",
             "path" => "/etc/passwd",
             "digest" => "forged"
           }) =~ "Worker-backed lookup is unavailable"

    refute has_element?(view, "#geoip-lookup-result")
    assert has_element?(view, "#geoip-lookup-unavailable")

    assert {TaskArtifacts.catalog(), Domain.list_tasks(), Domain.list_task_history(),
            Domain.list_audit()} == before_read

    assert is_nil(Process.whereis(YellowDog.Management.GeoIP))
  end
end
