defmodule YellowDog.Console.MdnsServicesLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Console.MdnsLive.ServicesLive
  alias YellowDog.Console.TestManagementTransport
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest

  @revision String.duplicate("a", 64)
  @observed_at "2026-08-10T01:02:03Z"

  setup do
    previous =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-server-mdns-#{System.unique_integer([:positive, :monotonic])}"
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

  test "services page is selected-Server scoped and mutations use the exact item revision", %{
    conn: conn
  } do
    service = service("alpha-printer", true)
    :ok = TestManagementTransport.script_request([list_result([service])])

    {:ok, view, html} = live(conn, "/server/server-a/mdns/services")

    assert html =~ "Alpha Server"
    assert html =~ "alpha-printer"
    refute has_element?(view, "#mdns-services", "Beta Server")
    assert [{"server-a", "server.mdns.services.list"}] = target_operations()

    disabled = %{service | "enabled" => false}

    :ok =
      TestManagementTransport.script_request([
        {:ok,
         %{
           "resource_type" => "mdns_service",
           "resource_id" => service["service_id"],
           "revision" => @revision,
           "resource" => disabled
         }}
      ])

    html = render_click(view, "toggle_service", %{"id" => service["service_id"]})
    assert html =~ "Service disabled"

    command = List.last(request_envelopes())
    assert command.target_id == "server-a"
    assert command.operation == "server.mdns.services.toggle"
    assert command.payload == %{"service_id" => service["service_id"], "enabled" => false}
    assert {:ok, expected_revision} = Digest.calculate(service)
    assert command.expected_revision == expected_revision
    assert is_binary(command.idempotency_key)
  end

  test "service registration validates locally then sends one typed command", %{conn: conn} do
    :ok = TestManagementTransport.script_request([list_result([])])
    {:ok, view, _html} = live(conn, "/server/server-a/mdns/services")

    assert render_click(view, "show_new_form") =~ "Register New Service"

    assert render_change(view, "validate_service", %{
             "name" => "",
             "type" => "bad",
             "port" => "70000",
             "txt" => ""
           }) =~ "Service name is required"

    resource = service("office-printer", true)

    :ok =
      TestManagementTransport.script_request([
        {:ok,
         %{
           "resource_type" => "mdns_service",
           "resource_id" => resource["service_id"],
           "revision" => @revision,
           "resource" => resource
         }}
      ])

    html =
      render_submit(view, "save_service", %{
        "name" => "office-printer",
        "type" => "_ipp._tcp",
        "port" => "631",
        "txt" => "note=office\nroom=north"
      })

    assert html =~ "Service registered"
    command = List.last(request_envelopes())
    assert command.operation == "server.mdns.services.register"
    assert command.expected_revision == nil
    assert command.payload == Map.delete(resource, "enabled")
  end

  test "service update and delete keep exact per-item CAS", %{conn: conn} do
    service = service("alpha-printer", true)
    :ok = TestManagementTransport.script_request([list_result([service])])
    {:ok, view, _html} = live(conn, "/server/server-a/mdns/services")

    assert render_click(view, "show_edit_form", %{"id" => service["service_id"]}) =~
             "Edit Service"

    updated = %{service | "service_port" => 9_100}
    assert {:ok, updated_revision} = Digest.calculate(updated)

    :ok =
      TestManagementTransport.script_request([
        {:ok,
         %{
           "resource_type" => "mdns_service",
           "resource_id" => service["service_id"],
           "revision" => updated_revision,
           "resource" => updated
         }}
      ])

    assert render_submit(view, "save_service", %{
             "name" => "alpha-printer",
             "type" => "_ipp._tcp",
             "port" => "9100",
             "txt" => "note=office\nroom=north"
           }) =~ "Service updated"

    update = List.last(request_envelopes())
    assert update.operation == "server.mdns.services.update"
    assert {:ok, initial_revision} = Digest.calculate(service)
    assert update.expected_revision == initial_revision
    assert update.payload == Map.delete(updated, "enabled")
    assert is_binary(update.idempotency_key)

    :ok =
      TestManagementTransport.script_request([
        {:ok,
         %{
           "resource_type" => "mdns_service",
           "resource_id" => service["service_id"],
           "revision" => updated_revision,
           "resource_ref" => %{"service_id" => service["service_id"]}
         }}
      ])

    assert render_click(view, "delete_service", %{"id" => service["service_id"]}) =~
             "Service deleted"

    delete = List.last(request_envelopes())
    assert delete.operation == "server.mdns.services.delete"
    assert delete.expected_revision == updated_revision
    assert delete.payload == %{"service_id" => service["service_id"]}
    assert is_binary(delete.idempotency_key)
  end

  test "overview and discovery query only the selected Server and keep links scoped", %{
    conn: conn
  } do
    :ok =
      TestManagementTransport.script_request([
        list_result([service("alpha-printer", true)]),
        list_result([discovery("alpha-printer")]),
        {:ok, %{"entries" => [cache_entry("alpha-printer.local")]}}
      ])

    {:ok, overview, html} = live(conn, "/server/server-a/mdns")
    assert html =~ "Alpha Server"
    assert html =~ "1 registered"

    for path <- ~w(services discovery monitor) do
      assert has_element?(overview, "a[href='/server/server-a/mdns/#{path}']")
    end

    :ok = TestManagementTransport.script_request([list_result([discovery("alpha-printer")])])
    {:ok, discovery_view, html} = live(conn, "/server/server-a/mdns/discovery")
    assert html =~ "alpha-printer"
    assert html =~ "192.0.2.10"
    assert has_element?(discovery_view, "#mdns-discovery")
    assert Enum.all?(request_envelopes(), &(&1.target_id == "server-a"))
  end

  test "monitor uses the typed query log and cache clear hashes the exact cache object", %{
    conn: conn
  } do
    cache = [cache_entry("printer.local")]

    :ok =
      TestManagementTransport.script_request([
        list_result([
          %{
            "query_id" => "query-1",
            "query_name" => "printer.local",
            "record_type" => "PTR",
            "source_address" => "192.0.2.44",
            "source_port" => 5353,
            "answered" => true,
            "occurred_at" => @observed_at
          }
        ]),
        {:ok, %{"entries" => cache}}
      ])

    {:ok, view, html} = live(conn, "/server/server-a/mdns/monitor")
    assert html =~ "printer.local"
    assert html =~ "192.0.2.44"

    :ok = TestManagementTransport.script_request([{:ok, %{"cleared_entries" => 1}}])
    html = render_click(view, "clear_cache")
    assert html =~ "Cache cleared"

    command = List.last(request_envelopes())
    assert command.operation == "server.mdns.cache.clear"
    assert command.payload == %{}
    assert {:ok, expected_revision} = Digest.calculate(%{"entries" => cache})
    assert command.expected_revision == expected_revision
  end

  test "offline snapshots render observation time and never dispatch mDNS commands", %{conn: conn} do
    service = service("cached-printer", true)
    :ok = TestManagementTransport.script_request([list_result([service])])
    {:ok, _online, _html} = live(conn, "/server/server-a/mdns/services")
    request_count = length(request_envelopes())

    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)

    {:ok, offline, html} = live(conn, "/server/server-a/mdns/services")
    assert html =~ "Offline cached snapshot"
    assert html =~ "cached-printer"
    assert has_element?(offline, "#mdns-services button[disabled]")
    assert length(request_envelopes()) == request_count

    html = render_click(offline, "toggle_service", %{"id" => service["service_id"]})
    assert html =~ "selected Server is offline"
    assert length(request_envelopes()) == request_count
  end

  test "overview follows selected Server connection broadcasts only", %{conn: conn} do
    :ok = TestManagementTransport.script_request(overview_responses("alpha-printer"))
    {:ok, view, _html} = live(conn, "/server/server-a/mdns")
    request_count = length(request_envelopes())

    broadcast_server("server-b", :offline)
    assert render(view) =~ "1 registered"
    assert length(request_envelopes()) == request_count

    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)
    broadcast_server("server-a", :offline)
    assert render(view) =~ "Offline cached snapshot"

    :ok = TestManagementTransport.connect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :online)

    :ok =
      TestManagementTransport.script_request([
        list_result([service("one", true), service("two", true)]),
        list_result([discovery("one"), discovery("two")]),
        {:ok, %{"entries" => [cache_entry("one.local"), cache_entry("two.local")]}}
      ])

    broadcast_server("server-a", :online)
    html = render(view)
    assert html =~ "2 registered"
    assert html =~ "2 discovered"
    assert html =~ "2 cached"
    refute html =~ "Offline cached snapshot"
  end

  test "discovery follows selected Server connection broadcasts only", %{conn: conn} do
    :ok = TestManagementTransport.script_request([list_result([discovery("alpha-printer")])])
    {:ok, view, _html} = live(conn, "/server/server-a/mdns/discovery")
    request_count = length(request_envelopes())

    broadcast_server("server-b", :offline)
    assert render(view) =~ "alpha-printer"
    assert length(request_envelopes()) == request_count

    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)
    broadcast_server("server-a", :offline)
    assert render(view) =~ "Offline cached snapshot"

    :ok = TestManagementTransport.connect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :online)
    :ok = TestManagementTransport.script_request([list_result([discovery("reconnected")])])
    broadcast_server("server-a", :online)

    html = render(view)
    assert html =~ "reconnected"
    refute html =~ "alpha-printer"
    refute html =~ "Offline cached snapshot"
  end

  test "services follow selected Server broadcasts and toggle controls with connectivity", %{
    conn: conn
  } do
    :ok = TestManagementTransport.script_request([list_result([service("alpha-printer", true)])])
    {:ok, view, _html} = live(conn, "/server/server-a/mdns/services")
    request_count = length(request_envelopes())

    refute has_element?(view, "button[phx-click='toggle_service'][disabled]")
    broadcast_server("server-b", :offline)
    assert render(view) =~ "alpha-printer"
    assert length(request_envelopes()) == request_count

    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)
    broadcast_server("server-a", :offline)
    assert has_element?(view, "button[phx-click='toggle_service'][disabled]")

    :ok = TestManagementTransport.connect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :online)
    :ok = TestManagementTransport.script_request([list_result([service("reconnected", true)])])
    broadcast_server("server-a", :online)

    html = render(view)
    assert html =~ "reconnected"
    refute html =~ "alpha-printer"
    refute has_element?(view, "button[phx-click='toggle_service'][disabled]")
  end

  test "monitor follows selected Server broadcasts and toggles cache controls with connectivity",
       %{
         conn: conn
       } do
    :ok =
      TestManagementTransport.script_request([
        list_result([monitor_query("alpha.local")]),
        {:ok, %{"entries" => [cache_entry("alpha.local")]}}
      ])

    {:ok, view, _html} = live(conn, "/server/server-a/mdns/monitor")
    request_count = length(request_envelopes())

    refute has_element?(view, "button[phx-click='clear_cache'][disabled]")
    broadcast_server("server-b", :offline)
    assert render(view) =~ "alpha.local"
    assert length(request_envelopes()) == request_count

    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)
    broadcast_server("server-a", :offline)
    assert has_element?(view, "button[phx-click='clear_cache'][disabled]")

    :ok = TestManagementTransport.connect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :online)

    :ok =
      TestManagementTransport.script_request([
        list_result([monitor_query("reconnected.local")]),
        {:ok, %{"entries" => [cache_entry("reconnected.local")]}}
      ])

    broadcast_server("server-a", :online)

    html = render(view)
    assert html =~ "reconnected.local"
    refute html =~ "alpha.local"
    refute has_element?(view, "button[phx-click='clear_cache'][disabled]")
  end

  describe "validate_service_params/1" do
    test "accepts canonical service data" do
      assert ServicesLive.validate_service_params(%{
               "name" => "printer",
               "type" => "_ipp._tcp",
               "port" => "631",
               "txt" => "note=office"
             }) == %{}
    end

    test "rejects missing names, invalid types, ports, and TXT rows" do
      errors =
        ServicesLive.validate_service_params(%{
          "name" => "",
          "type" => "ipp",
          "port" => "70000",
          "txt" => "missing-separator"
        })

      assert errors.name == "Service name is required"
      assert errors.type =~ "_service._tcp"
      assert errors.port =~ "between 1 and 65535"
      assert errors.txt =~ "key=value"
    end
  end

  defp service(name, enabled) do
    %{
      "service_id" => "#{name}._ipp._tcp.local",
      "name" => name,
      "service_type" => "_ipp._tcp",
      "service_port" => 631,
      "txt" => [
        %{"key" => "note", "value" => "office"},
        %{"key" => "room", "value" => "north"}
      ],
      "enabled" => enabled
    }
  end

  defp discovery(name) do
    %{
      "name" => "#{name}._ipp._tcp.local",
      "service_type" => "_ipp._tcp",
      "address" => "192.0.2.10"
    }
  end

  defp cache_entry(name), do: %{"name" => name, "type" => "A", "values" => ["192.0.2.10"]}

  defp monitor_query(name) do
    %{
      "query_id" => name,
      "query_name" => name,
      "record_type" => "A",
      "source_address" => "192.0.2.44",
      "source_port" => 5353,
      "answered" => true,
      "occurred_at" => @observed_at
    }
  end

  defp overview_responses(name) do
    [
      list_result([service(name, true)]),
      list_result([discovery(name)]),
      {:ok, %{"entries" => [cache_entry("#{name}.local")]}}
    ]
  end

  defp list_result(items) do
    {:ok, %{"items" => items, "revision" => @revision, "observed_at" => @observed_at}}
  end

  defp target_operations, do: Enum.map(request_envelopes(), &{&1.target_id, &1.operation})

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

  defp register_server(id, name, status) do
    assert {:ok, _server} =
             ManagementCore.register_server(%{
               id: id,
               name: name,
               profile: :full,
               status: status
             })
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
