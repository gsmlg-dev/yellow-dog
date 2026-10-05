defmodule YellowDog.Management.NetmanDomainTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias YellowDog.Management.{Domain, Netman, NetmanConfig, NetmanConfigVersion, Repo, Web}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "registration applies real catalog defaults with no fabricated observations" do
    node =
      mutate("create_netman", %{
        "id" => "config",
        "name" => "LAN Node",
        "profile_name" => "observe_only"
      })

    assert node["apply_mode"] == "observe"
    assert node["features"]["interfaces"]
    refute node["features"]["dhcp_client"]
    assert node["status"] == "not_yet_connected"
    assert node["actual_state"] == "unknown"
    assert is_nil(node["last_seen_at"])
    assert {:ok, %{"revision" => 1, "document" => document}} = Domain.get_netman_config("config")
    assert document == NetmanConfig.default()
    assert Domain.list_workers() == []
    assert [%{"id" => "config"}] = Domain.list_netmans()
    assert [%{"operation" => "create_netman"}] = Domain.list_audit()
  end

  test "registration retries exactly once and never permits a claimed online status" do
    params = %{"id" => "durable", "name" => "Durable"}
    assert {:ok, first} = Domain.mutate("create_netman", params, "operator", "register-once")
    assert {:ok, ^first} = Domain.mutate("create_netman", params, "operator", "register-once")
    assert length(Domain.list_audit()) == 1

    assert {:error, %{code: "idempotency_conflict"}} =
             Domain.mutate(
               "create_netman",
               Map.put(params, "name", "Changed"),
               "operator",
               "register-once"
             )

    assert {:error, %{code: "invalid_request"}} =
             command("create_netman", %{"id" => "fake", "status" => "online"})

    assert {:error, %{code: "not_found"}} = Domain.get_netman("fake")
    assert {:error, %{code: "not_found"}} = Domain.get_netman_config("fake")
    assert {:error, %{code: "conflict"}} = command("create_netman", params)
  end

  test "malformed scoped identities never reach PostgreSQL readers" do
    for id <- [nil, [], "bad id", "../node", <<255>>, String.duplicate("a", 65)] do
      assert {:error, %{code: "invalid_request"}} = Domain.get_netman(id)
      assert {:error, %{code: "invalid_request"}} = Domain.get_netman_config(id)
      assert Domain.list_netman_versions(id) == []
    end
  end

  test "metadata CAS preserves registration time and configuration revision" do
    node = create_node()

    updated =
      mutate("update_netman", %{
        "id" => node["id"],
        "name" => "Renamed",
        "profile_name" => "observe_only",
        "expected_revision" => 1
      })

    assert updated["revision"] == 2
    assert updated["registered_at"] == node["registered_at"]
    assert updated["apply_mode"] == "observe"
    assert {:ok, %{"revision" => 1}} = Domain.get_netman_config(node["id"])

    assert {:error, %{code: "revision_conflict"}} =
             command("update_netman", %{
               "id" => node["id"],
               "name" => "Stale",
               "expected_revision" => 1
             })

    assert {:ok, ^updated} = Domain.get_netman(node["id"])
  end

  test "noninteger CAS revisions are rejected with durable failure receipts and unchanged business state" do
    node = create_node()
    {:ok, draft} = Domain.get_netman_config("node")

    for operation <-
          ~w(update_netman update_netman_config confirm_netman_config rollback_netman_config),
        expected <- [1.0, "1", nil, true] do
      params = %{"id" => "node", "expected_revision" => expected}

      params =
        case operation do
          "update_netman" -> Map.put(params, "name", "Rejected")
          "update_netman_config" -> Map.put(params, "document", document("192.0.2.10/24"))
          "rollback_netman_config" -> Map.put(params, "target_version", 1)
          _operation -> params
        end

      key = Ecto.UUID.generate()

      assert {:error, %{code: "invalid_request"}} =
               result = Domain.mutate(operation, params, "operator", key)

      assert Domain.mutate(operation, params, "operator", key) == result
      assert {:ok, ^node} = Domain.get_netman("node")
      assert {:ok, ^draft} = Domain.get_netman_config("node")
      assert Domain.list_netman_versions("node") == []
    end

    assert length(Domain.list_audit()) == 17
  end

  test "invalid node metadata is rejected atomically" do
    for params <- [
          %{"id" => "../bad"},
          %{"id" => "bad-preset", "profile_name" => "invented"},
          %{"id" => "bad-features", "features" => %{"vpn" => "true"}},
          %{"id" => "bad-mode", "apply_mode" => "online"},
          %{"id" => "bad-feature", "features" => %{"invented" => true}},
          %{"id" => "bad-metadata", "metadata" => []}
        ] do
      assert {:error, %{code: "invalid_request"}} = command("create_netman", params)
    end

    assert Domain.list_netmans() == []
    assert Repo.aggregate(Netman, :count) == 0
  end

  test "desired configuration validates the full candidate and preserves prior state on failure" do
    create_node()

    saved =
      mutate("update_netman_config", %{
        "id" => "node",
        "expected_revision" => 1,
        "document" => document("192.0.2.10/24")
      })

    assert saved["revision"] == 2
    assert saved["actual_state"] == "unknown"
    assert {:ok, ^saved} = Domain.get_netman_config("node")

    assert {:error, %{code: "revision_conflict"}} =
             command("update_netman_config", %{
               "id" => "node",
               "expected_revision" => 1,
               "document" => NetmanConfig.default()
             })

    assert {:error, %{code: "invalid_request"}} =
             command("update_netman_config", %{
               "id" => "node",
               "expected_revision" => 2,
               "document" => document("2001:db8::1/64")
             })

    assert {:ok, ^saved} = Domain.get_netman_config("node")
    assert Domain.list_netman_versions("node") == []
  end

  test "prepared snapshots deduplicate source revisions and rollback publishes new desired history" do
    create_node()

    mutate("update_netman_config", %{
      "id" => "node",
      "expected_revision" => 1,
      "document" => document("192.0.2.10/24")
    })

    first = mutate("confirm_netman_config", %{"id" => "node", "expected_revision" => 2})
    assert first["version"] == 1
    assert first["status"] == "prepared"
    assert first["actual_state"] == "unknown"
    assert byte_size(first["digest"]) == 64
    assert mutate("confirm_netman_config", %{"id" => "node", "expected_revision" => 2}) == first

    mutate("update_netman_config", %{
      "id" => "node",
      "expected_revision" => 2,
      "document" => document("192.0.2.11/24")
    })

    second = mutate("confirm_netman_config", %{"id" => "node", "expected_revision" => 3})

    rolled =
      mutate("rollback_netman_config", %{
        "id" => "node",
        "expected_revision" => 3,
        "target_version" => 1
      })

    assert rolled["version"] == 3
    assert rolled["source_revision"] == 4
    assert rolled["operation"] == "rollback_netman_config"
    assert rolled["rollback_source_id"] == first["id"]
    assert rolled["document"] == first["document"]
    assert rolled["digest"] == first["digest"]
    assert Domain.list_netman_versions("node") == [rolled, second, first]
    assert {:ok, %{"document" => restored, "revision" => 4}} = Domain.get_netman_config("node")
    assert restored == first["document"]
    assert [%{"netman_name" => "Node"} | _rest] = Domain.list_netman_history()
  end

  test "observe-only policy is enforced by the domain, not only disabled controls" do
    mutate("create_netman", %{"id" => "observer", "profile_name" => "observe_only"})

    for operation <- ~w(update_netman_config confirm_netman_config rollback_netman_config) do
      params = %{"id" => "observer", "expected_revision" => 1}

      params =
        case operation do
          "update_netman_config" -> Map.put(params, "document", NetmanConfig.default())
          "rollback_netman_config" -> Map.put(params, "target_version", 1)
          _operation -> params
        end

      assert {:error, %{code: "read_only"}} = command(operation, params)
    end

    assert {:ok, %{"revision" => 1}} = Domain.get_netman_config("observer")
    assert Domain.list_netman_versions("observer") == []
  end

  test "rollback cannot refer to a different node's history" do
    create_node()
    mutate("create_netman", %{"id" => "other"})
    mutate("confirm_netman_config", %{"id" => "other", "expected_revision" => 1})

    assert {:error, %{code: "not_found"}} =
             command("rollback_netman_config", %{
               "id" => "node",
               "expected_revision" => 1,
               "target_version" => 1
             })

    assert {:ok, %{"revision" => 1}} = Domain.get_netman_config("node")
  end

  test "PostgreSQL forbids modifying or deleting prepared Netman versions" do
    create_node()
    version = mutate("confirm_netman_config", %{"id" => "node", "expected_revision" => 1})

    for statement <- [
          "UPDATE management_netman_config_versions SET digest = 'changed' WHERE id = $1",
          "DELETE FROM management_netman_config_versions WHERE id = $1"
        ] do
      assert {:error, %Postgrex.Error{}} = Repo.query(statement, [Ecto.UUID.dump!(version["id"])])
    end

    assert Repo.aggregate(NetmanConfigVersion, :count) == 1
    assert Domain.list_netman_versions("node") == [version]
  end

  test "Netman API is unauthenticated, bounded by idempotency, and scopes unknown IDs" do
    response =
      api(:post, "/api/commands/create_netman", %{"id" => "api-node", "name" => "API Node"})

    assert response.status == 200

    for request_path <- [
          "/api/netmans",
          "/api/netmans/api-node",
          "/api/netmans/api-node/config",
          "/api/netmans/api-node/versions"
        ] do
      read = api(:get, request_path)
      assert read.status == 200
      assert get_resp_header(read, "www-authenticate") == []
    end

    assert api(:get, "/api/netmans/unknown/versions").status == 404
    assert api(:post, "/api/commands/create_netman", %{"id" => "second"}, false).status == 422
  end

  defp create_node, do: mutate("create_netman", %{"id" => "node", "name" => "Node"})

  defp command(operation, params),
    do: Domain.mutate(operation, params, "operator", Ecto.UUID.generate())

  defp mutate(operation, params) do
    assert {:ok, result} = command(operation, params)
    result
  end

  defp document(address) do
    %{
      "profiles" => [
        %{
          "profile_id" => "wired",
          "type" => "ethernet",
          "interface" => "eth0",
          "zone" => "lan",
          "autoconnect" => true,
          "autoconnect_priority" => 10,
          "ethernet" => %{"mtu" => 1500},
          "ipv4" => %{
            "method" => "manual",
            "address" => address,
            "gateway" => "192.0.2.1",
            "dns" => ["192.0.2.53"],
            "dns_search" => ["example.test"]
          },
          "ipv6" => %{
            "method" => "disabled",
            "address" => nil,
            "gateway" => nil,
            "dns" => [],
            "dns_search" => []
          }
        }
      ],
      "resolved" => %{"upstreams" => ["192.0.2.53"], "search_domains" => ["example.test"]}
    }
  end

  defp api(method, request_path, body \\ nil, with_key \\ true) do
    connection =
      if body,
        do:
          conn(method, request_path, Jason.encode!(body))
          |> put_req_header("content-type", "application/json"),
        else: conn(method, request_path)

    connection =
      if body && with_key,
        do: put_req_header(connection, "idempotency-key", Ecto.UUID.generate()),
        else: connection

    Web.call(connection, Web.init([]))
  end
end
