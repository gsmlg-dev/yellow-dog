defmodule YellowDog.Management.NetmanRemovalTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias YellowDog.Management.{Audit, Domain, Idempotency, Operations, ProfileCatalog, Repo, Web}

  @operations ~w(create_netman update_netman update_netman_config confirm_netman_config rollback_netman_config)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "standalone Netman commands reject before producing business or idempotency records" do
    before = {Repo.aggregate(Audit, :count), Repo.aggregate(Idempotency, :count)}

    for operation <- @operations do
      assert {:error, %{code: "invalid_request"}} =
               Domain.mutate(operation, %{"id" => "removed"}, "operator", Ecto.UUID.generate())

      response =
        conn(:post, "/api/commands/" <> operation, Jason.encode!(%{"id" => "removed"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("idempotency-key", Ecto.UUID.generate())
        |> Web.call(Web.init([]))

      assert response.status == 422
      assert Jason.decode!(response.resp_body)["error"]["code"] == "invalid_request"
    end

    assert {Repo.aggregate(Audit, :count), Repo.aggregate(Idempotency, :count)} == before
    assert Domain.list_workers() == []
  end

  test "removed Netman query routes return 404" do
    for path <- [
          "/api/netmans",
          "/api/netmans/removed",
          "/api/netmans/removed/config",
          "/api/netmans/removed/versions"
        ] do
      response = conn(:get, path) |> Web.call(Web.init([]))
      assert response.status == 404
      assert Jason.decode!(response.resp_body)["error"]["code"] == "not_found"
    end
  end

  test "Management exports Worker operations and profiles without standalone Netman queries" do
    assert Code.ensure_loaded?(Domain)
    assert Code.ensure_loaded?(ProfileCatalog)

    for {name, arity} <- [
          list_netmans: 0,
          get_netman: 1,
          get_netman_config: 1,
          list_netman_versions: 1,
          list_netman_history: 0
        ] do
      refute function_exported?(Domain, name, arity)
    end

    refute function_exported?(ProfileCatalog, :list_netman_profiles, 0)
    refute function_exported?(ProfileCatalog, :netman_feature_keys, 0)
    assert Enum.any?(ProfileCatalog.list_server_profiles(), &(&1.name == :dns_only))

    refute Enum.any?(Operations.all(), fn operation ->
             String.contains?(operation.id, "netman") or
               String.contains?(operation.path, "netman")
           end)

    response =
      conn(
        :post,
        "/api/commands/create_worker",
        Jason.encode!(%{"id" => "worker", "name" => "Worker"})
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", Ecto.UUID.generate())
      |> Web.call(Web.init([]))

    assert response.status == 200
    assert [%{"id" => "worker"}] = Domain.list_workers()
  end

  test "the current schema has no standalone Netman tables" do
    for table <-
          ~w(management_netmans management_netman_config_drafts management_netman_config_versions) do
      assert %{rows: [[nil]]} = Repo.query!("SELECT to_regclass($1)::text", ["public." <> table])
    end
  end
end
