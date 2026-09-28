defmodule YellowDog.Console.DnsZoneControllerTest do
  use YellowDog.Console.ConnCase, async: false

  alias YellowDog.Management.DnsZones
  alias YellowDog.Management.Servers

  setup do
    old_dir = Application.get_env(:yellow_dog_management_core, :data_dir)
    old_release = Application.get_env(:yellow_dog_console, :management_release_only)
    dir = Path.join(System.tmp_dir!(), "dns-api-#{System.unique_integer([:positive])}")
    Application.put_env(:yellow_dog_management_core, :data_dir, dir)
    Application.put_env(:yellow_dog_console, :management_release_only, true)
    restart(DnsZones)
    restart(Servers)
    {:ok, _} = Servers.register(%{id: "api-server", profile: :cloud_dns})

    on_exit(fn ->
      restore(:yellow_dog_management_core, :data_dir, old_dir)
      restore(:yellow_dog_console, :management_release_only, old_release)
      restart(DnsZones)
      restart(Servers)
      File.rm_rf(dir)
    end)

    :ok
  end

  test "operator API keeps draft and publication separate", %{conn: conn} do
    assert conn |> post("/api/v1/zones", zone_body()) |> response(401) == "Unauthorized"

    zone =
      conn
      |> auth()
      |> put_req_header("idempotency-key", "create-one")
      |> post("/api/v1/zones", zone_body())
      |> json_response(201)

    assert zone["revision"] == 1
    assert zone["published_version"] == nil

    invalid_edit = %{
      "expected_revision" => 1,
      "edits" => [%{"owner" => "outside.test.", "type" => "A", "delete" => true}]
    }

    assert conn
           |> auth()
           |> put_req_header("idempotency-key", "outside-delete")
           |> patch("/api/v1/zones/#{zone["id"]}/rrsets", invalid_edit)
           |> json_response(422)
           |> get_in(["error", "code"]) == "invalid_edits"

    servers =
      conn |> auth() |> get("/api/v1/servers") |> json_response(200) |> Map.fetch!("servers")

    assert Enum.any?(servers, &(&1["id"] == "api-server" and &1["connected"] == false))

    assert conn
           |> auth()
           |> put_req_header("idempotency-key", "create-one")
           |> post("/api/v1/zones", zone_body())
           |> json_response(201)
           |> Map.fetch!("id") == zone["id"]

    assert conn
           |> auth()
           |> get("/api/v1/zones/#{zone["id"]}/rrsets")
           |> json_response(200)
           |> Map.fetch!("rrsets")
           |> length() == 3

    assert conn
           |> auth()
           |> post("/api/v1/zones/#{zone["id"]}/publish", %{"expected_revision" => 1})
           |> response(400)

    deployment =
      conn
      |> auth()
      |> put_req_header("idempotency-key", "publish-one")
      |> post("/api/v1/zones/#{zone["id"]}/publish", %{"expected_revision" => 1})
      |> json_response(202)

    assert deployment["soa_serial"] == 1

    assert conn
           |> auth()
           |> get("/api/v1/deployments/#{deployment["id"]}")
           |> json_response(200)
           |> Map.fetch!("id") == deployment["id"]

    assert conn
           |> auth()
           |> put_req_header("idempotency-key", "publish-one")
           |> post("/api/v1/zones/#{zone["id"]}/publish", %{"expected_revision" => 2})
           |> response(409)
  end

  test "raw JSON over 65536 bytes is rejected before parsing", %{conn: conn} do
    body = String.duplicate(" ", 65_536) <> Jason.encode!(zone_body())

    error =
      conn
      |> auth()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("idempotency-key", "oversized-create")
      |> post("/api/v1/zones", body)
      |> json_response(413)

    assert error["error"]["code"] == "too_large"
    assert DnsZones.list() == []
  end

  defp zone_body do
    %{
      "apex" => "example.test.",
      "targets" => ["api-server"],
      "rrsets" => [
        %{
          "owner" => "example.test.",
          "type" => "SOA",
          "ttl" => 300,
          "records" => [
            %{
              "mname" => "ns1.example.test.",
              "rname" => "hostmaster.example.test.",
              "refresh" => 3600,
              "retry" => 600,
              "expire" => 86400,
              "minimum" => 300
            }
          ]
        },
        %{
          "owner" => "example.test.",
          "type" => "NS",
          "ttl" => 300,
          "records" => ["ns1.example.test."]
        },
        %{
          "owner" => "ns1.example.test.",
          "type" => "A",
          "ttl" => 300,
          "records" => ["192.0.2.53"]
        }
      ]
    }
  end

  defp auth(conn), do: put_req_header(conn, "authorization", "Bearer test-operator-token")

  defp restart(module) do
    pid = Process.whereis(module)
    if pid, do: Supervisor.terminate_child(YellowDog.ManagementCore.Supervisor, module)
    if pid, do: Supervisor.restart_child(YellowDog.ManagementCore.Supervisor, module)
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
