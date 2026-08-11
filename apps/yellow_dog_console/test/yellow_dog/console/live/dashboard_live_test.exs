defmodule YellowDog.Console.DashboardLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Console.TestManagementTransport
  alias YellowDog.ManagementCore

  setup do
    previous =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-server-dashboard-#{System.unique_integer([:positive, :monotonic])}"
      )

    Application.stop(:yellow_dog_management_core)
    Application.put_env(:yellow_dog_management_core, :data_dir, data_dir)
    Application.put_env(:yellow_dog_management_core, :transport_module, TestManagementTransport)
    Application.put_env(:yellow_dog_management_core, :request_timeout, 50)
    {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
    start_supervised!(TestManagementTransport)

    register_server("server-a", "Alpha Server", :online)
    register_server("server-b", "Beta Server", :online)
    :ok = TestManagementTransport.connect(:server, "server-a")
    :ok = TestManagementTransport.connect(:server, "server-b")

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)

    :ok
  end

  test "reads only the selected Server and keeps every service link scoped", %{conn: conn} do
    :ok = TestManagementTransport.script_request(dashboard_responses("dns", "running", 42))

    {:ok, view, _html} = live(conn, "/server/server-a/dashboard")
    html = view |> element("#server-dashboard") |> render()

    assert html =~ "Alpha Server"
    refute html =~ "Beta Server"
    assert html =~ "DNS"
    assert html =~ "Running"
    assert html =~ "42"
    refute html =~ "BEAM VM Health"

    for path <- ~w(dns dhcpv4 dhcpv6 mdns netboot identity settings) do
      assert has_element?(view, "a[href='/server/server-a/#{path}']")
    end

    assert Enum.map(request_envelopes(), &{&1.target_id, &1.operation}) == [
             {"server-a", "server.runtime.services.list"},
             {"server-a", "server.runtime.health.get"},
             {"server-a", "server.runtime.stats.get"}
           ]
  end

  test "two selected Servers render distinct management state", %{conn: conn} do
    :ok = TestManagementTransport.script_request(dashboard_responses("dns", "running", 11))
    {:ok, alpha, _html} = live(conn, "/server/server-a/dashboard")
    alpha_html = alpha |> element("#server-dashboard") |> render()

    :ok = TestManagementTransport.script_request(dashboard_responses("mdns", "failed", 22))
    {:ok, beta, _html} = live(conn, "/server/server-b/dashboard")
    beta_html = beta |> element("#server-dashboard") |> render()

    assert alpha_html =~ "Alpha Server"
    assert alpha_html =~ "11"
    refute alpha_html =~ "Beta Server"

    assert beta_html =~ "Beta Server"
    assert beta_html =~ "22"
    refute beta_html =~ "Alpha Server"
  end

  test "start and stop use typed commands with generated idempotency keys", %{conn: conn} do
    :ok = TestManagementTransport.script_request(dashboard_responses("dns", "stopped", 1))
    {:ok, view, _html} = live(conn, "/server/server-a/dashboard")

    :ok =
      TestManagementTransport.script_request([{:ok, %{"service" => "dns", "state" => "running"}}])

    html = render_click(view, "start_service", %{"service" => "dns"})
    assert html =~ "DNS is now running"

    command = List.last(request_envelopes())
    assert command.target_id == "server-a"
    assert command.operation == "server.runtime.services.start"
    assert command.payload == %{"service" => "dns"}
    assert is_binary(command.idempotency_key)

    assert {:ok, expected_revision} =
             YellowDog.Sync.Digest.calculate(%{"service" => "dns", "state" => "stopped"})

    assert command.expected_revision == expected_revision

    :ok =
      TestManagementTransport.script_request([{:ok, %{"service" => "dns", "state" => "stopped"}}])

    html = render_click(view, "stop_service", %{"service" => "dns"})
    assert html =~ "DNS is now stopped"

    stop_command = List.last(request_envelopes())
    assert stop_command.operation == "server.runtime.services.stop"

    assert {:ok, expected_revision} =
             YellowDog.Sync.Digest.calculate(%{"service" => "dns", "state" => "running"})

    assert stop_command.expected_revision == expected_revision
  end

  test "offline Server uses cached reads and disables imperative actions", %{conn: conn} do
    :ok = TestManagementTransport.script_request(dashboard_responses("dns", "running", 9))
    {:ok, _online, _html} = live(conn, "/server/server-a/dashboard")
    online_request_count = length(request_envelopes())

    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)

    {:ok, offline, html} = live(conn, "/server/server-a/dashboard")

    assert html =~ "Showing the latest management snapshot"
    assert html =~ "Runtime actions are disabled"
    assert html =~ "9"
    assert has_element?(offline, "#server-dashboard button[disabled]")
    assert length(request_envelopes()) == online_request_count

    html = render_click(offline, "stop_service", %{"service" => "dns"})
    assert html =~ "The selected Server is offline"
    assert length(request_envelopes()) == online_request_count
  end

  test "selected Server connection broadcasts refresh controls and ignore other Servers", %{
    conn: conn
  } do
    :ok = TestManagementTransport.script_request(dashboard_responses("dns", "running", 9))
    {:ok, view, _html} = live(conn, "/server/server-a/dashboard")
    request_count = length(request_envelopes())

    refute has_element?(view, "button[phx-click='stop_service'][disabled]")

    broadcast_server("server-b", :offline)
    refute render(view) =~ "Showing the latest management snapshot"
    assert length(request_envelopes()) == request_count

    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)
    broadcast_server("server-a", :offline)

    assert render(view) =~ "Showing the latest management snapshot"
    assert has_element?(view, "button[phx-click='stop_service'][disabled]")
    assert length(request_envelopes()) == request_count

    :ok = TestManagementTransport.connect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :online)
    :ok = TestManagementTransport.script_request(dashboard_responses("dns", "running", 99))
    broadcast_server("server-a", :online)

    html = render(view)
    assert html =~ "99"
    refute html =~ "Showing the latest management snapshot"
    refute has_element?(view, "button[phx-click='stop_service'][disabled]")
  end

  test "invalid service input never reaches the management transport", %{conn: conn} do
    :ok = TestManagementTransport.script_request(dashboard_responses("dns", "stopped", 0))
    {:ok, view, _html} = live(conn, "/server/server-a/dashboard")
    before_count = length(request_envelopes())

    html = render_click(view, "start_service", %{"service" => "evil_service"})
    assert html =~ "Invalid service name"
    assert length(request_envelopes()) == before_count
  end

  defp dashboard_responses(active_service, active_state, requests) do
    items =
      Enum.map(~w(dns mdns dhcpv4 dhcpv6 netboot identity), fn service ->
        state = if service == active_service, do: active_state, else: "stopped"
        %{"service" => service, "state" => state}
      end)

    [
      {:ok,
       %{
         "items" => items,
         "revision" => String.duplicate("a", 64),
         "observed_at" => "2026-08-10T01:02:03Z"
       }},
      {:ok,
       %{
         "status" => if(active_state == "failed", do: "degraded", else: "healthy"),
         "checks" => [
           %{
             "name" => active_service,
             "status" => if(active_state == "failed", do: "unhealthy", else: "healthy")
           }
         ]
       }},
      {:ok, %{"requests" => requests, "errors" => if(active_state == "failed", do: 1, else: 0)}}
    ]
  end

  defp register_server(id, name, status) do
    assert {:ok, _server} =
             ManagementCore.register_server(%{
               id: id,
               name: name,
               profile: :dns_only,
               status: status
             })
  end

  defp request_envelopes do
    for {:request, envelope, _timeout} <- TestManagementTransport.recorded(), do: envelope
  end

  defp broadcast_server(server_id, state) do
    Phoenix.PubSub.broadcast(
      YellowDog.Console.PubSub,
      "management:server:#{server_id}",
      {:server_connection, state, %{server_id: server_id}}
    )
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
