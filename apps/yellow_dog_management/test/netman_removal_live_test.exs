defmodule YellowDog.Management.NetmanRemovalLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias YellowDog.Management.{Domain, DomainFixtures, Repo}
  alias YellowDog.ManagementUI.Commands

  @endpoint YellowDog.ManagementUI.Endpoint
  @removed_paths [
    "/management/netman",
    "/management/netman/new",
    "/netman",
    "/netman/retired",
    "/netman/retired/config",
    "/netman/retired/resolved",
    "/netman/retired/interfaces",
    "/netman/retired/dhcp-client"
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    %{conn: build_conn()}
  end

  test "retired node and resolver entries return 404 without changing durable state", %{
    conn: conn
  } do
    before_read = {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()}

    for path <- @removed_paths do
      assert get(conn, path).status == 404, path
    end

    assert {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()} == before_read
  end

  test "native command dispatch rejects every retired node operation", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/management")
    socket = :sys.get_state(view.pid).socket
    before_commands = Domain.list_audit()

    for operation <-
          ~w(create_netman update_netman update_netman_config confirm_netman_config rollback_netman_config) do
      assert {:error, %{code: "forbidden", message: "UI operation is not supported"}} =
               Commands.command(socket, operation, %{"id" => "retired"}, Ecto.UUID.generate())
    end

    assert Domain.list_audit() == before_commands
  end

  test "Worker, DNS, Zone and IP pages retain their business context", %{conn: conn} do
    worker = mutate("create_worker", %{"id" => "retained-worker", "name" => "Retained Worker"})
    service = mutate("put_service", DomainFixtures.service(worker["id"], worker["revision"]))
    zone = mutate("create_zone", DomainFixtures.zone("retained.test."))
    before_read = {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()}

    for {path, selector} <- [
          {"/management/servers", "#server-selector-retained-worker"},
          {"/server/retained-worker/services", "#server-selection-form-select"},
          {"/server/retained-worker/dns/views/#{service["id"]}",
           "#dns-view-service-selector [aria-current='page']"},
          {"/server/retained-worker/dns/acl/#{service["id"]}", "#dns-acls-workflow"},
          {"/management/zones/#{zone["id"]}/records", "#records-table"},
          {"/system/ip-database", "#ip-database-workflow"}
        ] do
      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, selector), path
      refute has_element?(view, "#record-scope-error, #dns-view-error, #dns-acl-error")
      refute has_element?(view, "a[href^='/netman'], a[href='/management/netman']")
      refute has_element?(view, "#app-sidebar-navigation", "Netman")
      refute has_element?(view, "#app-sidebar-navigation", "Resolved")
    end

    assert {Domain.list_workers(), Domain.list_zones(), Domain.list_audit()} == before_read
  end

  defp mutate(operation, params) do
    assert {:ok, result} = Domain.mutate(operation, params, "operator", Ecto.UUID.generate())
    result
  end
end
