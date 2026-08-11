defmodule YellowDog.Console.ManagementLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Console.TestManagementTransport
  alias YellowDog.ManagementCore

  @pages [
    {"/management", "Management Overview"},
    {"/management/servers", "Management Servers"},
    {"/management/netman", "Management Netman"},
    {"/management/profiles", "Management Profiles"},
    {"/management/config", "Management Config"},
    {"/management/events", "Management Events"}
  ]

  setup do
    previous_env =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-management-live-#{System.unique_integer([:positive, :monotonic])}"
      )

    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)

    Application.put_env(
      :yellow_dog_management_core,
      :transport_module,
      TestManagementTransport
    )

    Application.put_env(:yellow_dog_management_core, :request_timeout, 50)
    restart_management_core()
    start_supervised!(TestManagementTransport)

    YellowDog.Management.Servers.reset()
    YellowDog.Management.Netmans.reset()

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous_env, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)
  end

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
      {"/management/config",
       ["Published Config Versions", "Version", "State", "Digest", "Failure Phase", "Rollback"]},
      {"/management/events", ["Server Events", "Netman Events", "Command Outcomes"]}
    ]

    for {path, expected_strings} <- assertions do
      {:ok, _view, html} = live(conn, path)

      for expected <- expected_strings do
        assert html =~ expected
      end
    end
  end

  test "management pages render facade-backed records and events", %{conn: conn} do
    {:ok, _server} =
      YellowDog.ManagementCore.register_server(%{
        id: "srv-cloud-dns-01",
        name: "Cloud DNS 01",
        profile: :cloud_dns,
        status: :online,
        services: %{dns: true, server_agent: true},
        last_seen_at: ~U[2026-07-07 00:00:00Z]
      })

    {:ok, _netman} =
      YellowDog.ManagementCore.register_netman(%{
        id: "netman-cloud-app-01",
        name: "Cloud App 01 Netman",
        profile: :cloud_server,
        status: :degraded,
        features: %{interfaces: true, routes: true},
        apply_mode: :observe_first,
        last_seen_at: ~U[2026-07-07 00:00:00Z]
      })

    {:ok, _view, servers_html} = live(conn, "/management/servers")
    assert servers_html =~ "srv-cloud-dns-01"
    assert servers_html =~ "Cloud DNS 01"
    assert servers_html =~ "cloud dns"
    assert servers_html =~ "dns"
    assert servers_html =~ "server agent"

    {:ok, _view, netman_html} = live(conn, "/management/netman")
    assert netman_html =~ "netman-cloud-app-01"
    assert netman_html =~ "Cloud App 01 Netman"
    assert netman_html =~ "cloud server"
    assert netman_html =~ "observe first"

    {:ok, _view, events_html} = live(conn, "/management/events")
    assert events_html =~ "Server registered"
    assert events_html =~ "Netman registered"
  end

  test "service rows link directly to the selected Server and Netman", %{conn: conn} do
    assert {:ok, _server} =
             ManagementCore.register_server(%{id: "srv-direct", profile: :dns_only})

    assert {:ok, _netman} = ManagementCore.register_netman(%{id: "netman-direct", profile: :vm})

    {:ok, servers, _html} = live(conn, "/management/servers")
    assert has_element?(servers, "a[href='/server/srv-direct/dashboard']", "srv-direct")

    {:ok, netmans, _html} = live(conn, "/management/netman")
    assert has_element?(netmans, "a[href='/netman/netman-direct']", "netman-direct")
  end

  test "config lifecycle and command outcomes remain visible after management restart", %{
    conn: conn
  } do
    server_id = "srv-durable-ui"
    netman_id = "netman-durable-ui"

    assert {:ok, _server} = ManagementCore.register_server(%{id: server_id, profile: :dns_only})
    assert {:ok, _netman} = ManagementCore.register_netman(%{id: netman_id, profile: :vm})

    assert {:ok, server_version} =
             ManagementCore.publish_server_config(server_id, %{
               operation: "server.settings.update",
               payload: %{
                 "service" => "dns",
                 "entries" => [
                   %{
                     "key" => "listen",
                     "value" => %{"type" => "string", "value" => "192.0.2.53"}
                   }
                 ]
               },
               expected_revision: nil
             })

    assert {:ok, netman_version} =
             ManagementCore.publish_netman_config(netman_id, %{
               operation: "netman.resolved.config.update",
               payload: %{
                 "upstreams" => ["192.0.2.53"],
                 "search_domains" => ["example.test"]
               },
               expected_revision: nil
             })

    :ok = TestManagementTransport.connect(:server, server_id)

    :ok =
      TestManagementTransport.script_request([{:ok, %{"service" => "dns", "state" => "running"}}])

    assert {:ok, _result} =
             ManagementCore.command_server(
               server_id,
               "server.runtime.services.start",
               %{"service" => "dns"},
               nil,
               "11111111-1111-4111-8111-111111111111"
             )

    assert_management_state(
      conn,
      server_id,
      netman_id,
      server_version.digest,
      netman_version.digest
    )

    restart_management_core()

    assert_management_state(
      conn,
      server_id,
      netman_id,
      server_version.digest,
      netman_version.digest
    )
  end

  defp assert_management_state(conn, server_id, netman_id, server_digest, netman_digest) do
    {:ok, config, config_html} = live(conn, "/management/config")

    assert has_element?(config, "#management-config-versions")
    assert config_html =~ server_id
    assert config_html =~ netman_id
    assert config_html =~ server_digest
    assert config_html =~ netman_digest
    assert config_html =~ "desired"
    assert config_html =~ "Failure Phase"
    assert config_html =~ "Rollback"

    {:ok, events, events_html} = live(conn, "/management/events")

    assert has_element?(events, "#management-command-outcomes")
    assert events_html =~ server_id
    assert events_html =~ "server.runtime.services.start"
    assert events_html =~ "completed"
    assert events_html =~ "Server registered"
    assert events_html =~ "Netman registered"
  end

  defp restart_management_core do
    Application.stop(:yellow_dog_management_core)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
