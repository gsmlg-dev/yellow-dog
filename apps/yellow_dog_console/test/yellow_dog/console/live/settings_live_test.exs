defmodule YellowDog.Console.SettingsLiveTest do
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
        "yellow-dog-server-settings-#{System.unique_integer([:positive, :monotonic])}"
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

    assert {:ok, %{draft_revision: 1}} =
             ManagementCore.put_server_config("server-a", 0, server_document("alpha.example"))

    assert {:ok, %{draft_revision: 1}} =
             ManagementCore.put_server_config("server-b", 0, server_document("beta.example"))

    on_exit(fn ->
      Application.stop(:yellow_dog_management_core)
      Enum.each(previous, fn {key, value} -> restore_env(key, value) end)
      {:ok, _apps} = Application.ensure_all_started(:yellow_dog_management_core)
      File.rm_rf(data_dir)
    end)

    :ok
  end

  test "reads the Management-owned draft for only the selected Server and scopes every tab", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, "/server/server-a/settings/dns")

    assert html =~ "Alpha Server"
    assert html =~ "alpha.example"
    refute has_element?(view, "#server-settings", "Beta Server")
    assert html =~ "Management draft"
    assert has_element?(view, "#settings-draft-form")
    assert has_element?(view, "#settings-enabled")
    assert has_element?(view, "#settings-hostname[value='alpha.example']")
    refute has_element?(view, "#settings-entries-json")
    refute html =~ "Managed configuration mutations are not enabled"

    for service <- ~w(dns mdns dhcpv4 dhcpv6 netboot) do
      assert has_element?(view, "a[href='/server/server-a/settings/#{service}']")
    end

    assert TestManagementTransport.recorded() == []
  end

  test "two selected Servers render distinct Settings state", %{conn: conn} do
    {:ok, alpha, _html} = live(conn, "/server/server-a/settings/dns")
    alpha_html = alpha |> element("#server-settings") |> render()

    {:ok, beta, _html} = live(conn, "/server/server-b/settings/dns")
    beta_html = beta |> element("#server-settings") |> render()

    assert alpha_html =~ "alpha.example"
    refute alpha_html =~ "beta.example"
    assert beta_html =~ "beta.example"
    refute beta_html =~ "alpha.example"
    assert TestManagementTransport.recorded() == []
  end

  test "offline Settings save a full draft patch and preserve every other service", %{
    conn: conn
  } do
    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)

    {:ok, offline, html} = live(conn, "/server/server-a/settings/dns")

    assert html =~ "Offline changes remain in Management"
    assert has_element?(offline, "#settings-draft-form")

    rendered =
      offline
      |> form("#settings-draft-form",
        settings: %{
          "profile" => "dns_only",
          "enabled" => "inherit",
          "hostname" => "changed.example",
          "listen" => "",
          "port" => ""
        }
      )
      |> render_submit()

    assert rendered =~ "Draft saved"

    assert {:ok, %{draft_revision: 2, document: document}} =
             ManagementCore.get_server_config("server-a")

    assert document["entries"] == [
             managed_entry("dns.hostname", "changed.example"),
             managed_entry("mdns.hostname", "mdns-alpha.example")
           ]

    assert TestManagementTransport.recorded() == []

    applied_html = render_click(offline, "apply")
    assert applied_html =~ "Waiting for Server acknowledgement"

    assert {:ok, %{version: 1, state: :desired}} =
             ManagementCore.get_server_config_version("server-a", 1)

    assert TestManagementTransport.recorded() == []
  end

  test "stale draft CAS is visible and never overwrites the newer Management document", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/server/server-a/settings/dns")

    newer = server_document("newer.example")

    assert {:ok, %{draft_revision: 2}} =
             ManagementCore.put_server_config("server-a", 1, newer)

    html =
      view
      |> form("#settings-draft-form",
        settings: %{
          "profile" => "dns_only",
          "enabled" => "inherit",
          "hostname" => "stale.example",
          "listen" => "",
          "port" => ""
        }
      )
      |> render_submit()

    assert html =~ "server config draft changed"

    assert {:ok, %{draft_revision: 2, document: ^newer}} =
             ManagementCore.get_server_config("server-a")
  end

  test "publishing disables a second Apply while the deployment is in flight", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/server/server-a/settings/dns")

    html = render_click(view, "apply")

    assert html =~ "Waiting for Server acknowledgement"
    assert has_element?(view, "#settings-apply[disabled]")
    assert [{:config, envelope}] = TestManagementTransport.recorded()
    assert envelope.target_id == "server-a"
    assert envelope.operation == "server.config.replace"

    html = render_click(view, "apply")
    assert html =~ "configuration deployment is already in flight"
    assert [_one_delivery] = TestManagementTransport.recorded()
  end

  test "refresh reloads the same selected Management draft and service", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/server/server-a/settings/mdns")

    assert {:ok, %{draft_revision: 2}} =
             ManagementCore.put_server_config(
               "server-a",
               1,
               server_document("alpha.example", "second-mdns.example")
             )

    html = render_click(view, "refresh")

    assert html =~ "second-mdns.example"
    assert TestManagementTransport.recorded() == []
  end

  test "typed Settings validation rejects invalid ports without changing the draft", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/server/server-a/settings/dns")

    html =
      view
      |> form("#settings-draft-form",
        settings: %{
          "profile" => "dns_only",
          "enabled" => "true",
          "hostname" => "alpha.example",
          "listen" => "0.0.0.0",
          "port" => "70000"
        }
      )
      |> render_submit()

    assert html =~ "port must be between 1 and 65535"

    assert {:ok, %{draft_revision: 1, document: document}} =
             ManagementCore.get_server_config("server-a")

    assert document == server_document("alpha.example")
  end

  test "typed Settings save preserves managed entries outside the visible form", %{conn: conn} do
    document =
      server_document("alpha.example")
      |> Map.update!("entries", fn entries ->
        Enum.sort_by(
          [
            %{
              "setting" => "dns.cache_size",
              "value" => %{"type" => "integer", "value" => 512}
            }
            | entries
          ],
          & &1["setting"]
        )
      end)

    assert {:ok, %{draft_revision: 2}} =
             ManagementCore.put_server_config("server-a", 1, document)

    {:ok, view, _html} = live(conn, "/server/server-a/settings/dns")

    view
    |> form("#settings-draft-form",
      settings: %{
        "profile" => "dns_only",
        "enabled" => "inherit",
        "hostname" => "changed.example",
        "listen" => "",
        "port" => ""
      }
    )
    |> render_submit()

    assert {:ok, %{draft_revision: 3, document: saved}} =
             ManagementCore.get_server_config("server-a")

    assert Enum.any?(saved["entries"], fn entry ->
             entry["setting"] == "dns.cache_size" and entry["value"]["value"] == 512
           end)
  end

  defp server_document(dns_hostname, mdns_hostname \\ nil) do
    mdns_hostname = mdns_hostname || "mdns-#{dns_hostname}"

    %{
      "schema_version" => 1,
      "profile" => "dns_only",
      "entries" => [
        managed_entry("dns.hostname", dns_hostname),
        managed_entry("mdns.hostname", mdns_hostname)
      ]
    }
  end

  defp managed_entry(setting, value) do
    %{
      "setting" => setting,
      "value" => %{"type" => "string", "value" => value}
    }
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

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
