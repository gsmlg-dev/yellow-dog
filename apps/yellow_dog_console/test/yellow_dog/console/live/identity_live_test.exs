defmodule YellowDog.Console.IdentityLiveTest do
  use YellowDog.Console.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias YellowDog.Console.TestManagementTransport
  alias YellowDog.ManagementCore
  alias YellowDog.Sync.Digest
  alias YellowDog.Sync.Error

  @observed_at "2026-08-10T01:02:03Z"

  setup do
    previous =
      Map.new([:data_dir, :transport_module, :request_timeout], fn key ->
        {key, Application.fetch_env(:yellow_dog_management_core, key)}
      end)

    data_dir =
      Path.join(
        System.tmp_dir!(),
        "yellow-dog-server-identity-#{System.unique_integer([:positive, :monotonic])}"
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

  test "hosts page is selected-Server scoped and approve uses the exact host revision", %{
    conn: conn
  } do
    pending = host("host-a", "alpha.example", "pending")
    :ok = TestManagementTransport.script_request([list_result([pending])])

    {:ok, view, html} = live(conn, "/server/server-a/identity/hosts")
    assert html =~ "Alpha Server"
    assert html =~ "alpha.example"
    refute has_element?(view, "#identity-hosts", "Beta Server")
    assert has_element?(view, "a[href='/server/server-a/identity/hosts/host-a']")

    approved = host("host-a", "alpha.example", "approved")

    :ok =
      TestManagementTransport.script_request([
        {:ok,
         %{
           "resource_type" => "identity_host",
           "resource_id" => "host-a",
           "revision" => approved["revision"],
           "resource" => approved
         }}
      ])

    assert render_click(view, "approve", %{"id" => "host-a"}) =~ "Host approved"

    command = List.last(request_envelopes())
    assert command.target_id == "server-a"
    assert command.operation == "server.identity.hosts.approve"
    assert command.payload == %{"host_id" => "host-a"}
    assert command.expected_revision == pending["revision"]
    assert is_binary(command.idempotency_key)
  end

  test "identity overview, detail, and audit preserve the selected Server", %{conn: conn} do
    approved = host("host-a", "alpha.example", "approved")
    :ok = TestManagementTransport.script_request([list_result([approved])])
    {:ok, overview, html} = live(conn, "/server/server-a/identity")
    assert html =~ "1 total"

    for destination <- ~w(hosts approvals tokens policies audit) do
      assert has_element?(overview, "a[href='/server/server-a/identity/#{destination}']")
    end

    :ok = TestManagementTransport.script_request([list_result([approved])])
    {:ok, detail, html} = live(conn, "/server/server-a/identity/hosts/host-a")
    assert html =~ "alpha.example"
    assert has_element?(detail, "a[href='/server/server-a/identity/hosts']")

    audit = %{
      "audit_id" => "audit-1",
      "action" => "host.approved",
      "subject_id" => "host-a",
      "occurred_at" => @observed_at
    }

    :ok = TestManagementTransport.script_request([list_result([audit])])
    {:ok, _audit, html} = live(conn, "/server/server-a/identity/audit")
    assert html =~ "host.approved"
    assert Enum.all?(request_envelopes(), &(&1.target_id == "server-a"))
  end

  test "unsupported Identity owners are visible and never expose imperative controls", %{
    conn: conn
  } do
    unsupported = {:error, Error.new(:unsupported, "unsupported operation", %{})}

    for {path, operation, page_id} <- [
          {"approvals", "server.identity.approvals.list", "identity-approvals"},
          {"tokens", "server.identity.tokens.list", "identity-tokens"},
          {"policies", "server.identity.policies.get", "identity-policies"}
        ] do
      :ok = TestManagementTransport.script_request([unsupported])
      {:ok, view, html} = live(conn, "/server/server-a/identity/#{path}")
      assert html =~ "unsupported operation"
      assert has_element?(view, "##{page_id}")
      refute has_element?(view, "##{page_id} button[data-management-command]")
      assert List.last(request_envelopes()).operation == operation
    end
  end

  test "offline hosts use the cached snapshot and never dispatch a mutation", %{conn: conn} do
    pending = host("host-a", "cached.example", "pending")
    :ok = TestManagementTransport.script_request([list_result([pending])])
    {:ok, _online, _html} = live(conn, "/server/server-a/identity/hosts")
    request_count = length(request_envelopes())

    :ok = TestManagementTransport.disconnect(:server, "server-a")
    assert {:ok, _server} = ManagementCore.update_server_status("server-a", :offline)

    {:ok, offline, html} = live(conn, "/server/server-a/identity/hosts")
    assert html =~ "Offline cached snapshot"
    assert html =~ "cached.example"
    assert has_element?(offline, "#identity-hosts button[disabled]")
    assert length(request_envelopes()) == request_count

    assert render_click(offline, "approve", %{"id" => "host-a"}) =~
             "selected Server is offline"

    assert length(request_envelopes()) == request_count
  end

  defp host(id, name, state) do
    stable = %{"host_id" => id, "name" => name, "state" => state}
    assert {:ok, revision} = Digest.calculate(stable)
    Map.put(stable, "revision", revision)
  end

  defp list_result(items) do
    assert {:ok, revision} = Digest.calculate(items)
    {:ok, %{"items" => items, "revision" => revision, "observed_at" => @observed_at}}
  end

  defp request_envelopes do
    for {:request, envelope, _timeout} <- TestManagementTransport.recorded(), do: envelope
  end

  defp register_server(id, name, status) do
    assert {:ok, _server} =
             ManagementCore.register_server(%{id: id, name: name, profile: :full, status: status})
  end

  defp restore_env(key, {:ok, value}),
    do: Application.put_env(:yellow_dog_management_core, key, value)

  defp restore_env(key, :error), do: Application.delete_env(:yellow_dog_management_core, key)
end
