defmodule YellowDog.Management.MCPTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn
  alias YellowDog.Management.{Domain, DomainFixtures, IntegrationSettings, MCP, Operations, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    previous = Application.get_env(:yellow_dog_management, :integration)

    config = %{
      mode: :trusted_local,
      http_enabled: true,
      mcp_enabled: true,
      write_enabled: true,
      resource: "http://localhost",
      allowed_scopes: IntegrationSettings.scopes()
    }

    Application.put_env(:yellow_dog_management, :integration, config)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:yellow_dog_management, :integration, previous),
        else: Application.delete_env(:yellow_dog_management, :integration)
    end)

    :ok
  end

  test "initialize negotiates the pinned revision, notifications return empty 202 and calls are stateless" do
    conn =
      request(
        %{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "initialize",
          "params" => %{
            "protocolVersion" => "2099-01-01",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "test", "version" => "1"}
          }
        },
        version: nil
      )

    assert conn.status == 200
    result = body(conn)["result"]
    assert result["protocolVersion"] == "2025-11-25"
    assert result["capabilities"] == %{"tools" => %{"listChanged" => false}}
    assert get_resp_header(conn, "mcp-session-id") == []
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    notification = request(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    assert notification.status == 202
    assert notification.resp_body == ""
    response = request(%{"jsonrpc" => "2.0", "id" => 12, "result" => %{}})
    assert response.status == 202
    assert response.resp_body == ""
    assert request(rpc("ping")) |> body() == %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}

    assert request(rpc("tools/list")) |> body() |> get_in(["result", "tools"]) |> length() ==
             length(Operations.all())
  end

  test "transport rejects missing or unsupported version, content type, Accept and oversized bodies" do
    assert request(rpc("tools/list"), version: nil).status == 400
    assert request(rpc("tools/list"), version: "2026-07-28").status == 400
    assert request(rpc("ping"), type: "text/plain").status == 415
    assert request(rpc("ping"), type: "application/json; charset=latin1").status == 415
    assert request(rpc("ping"), accept: "application/json").status == 406
    assert request(rpc("ping"), accept: "application/json, text/event-stream;q=0").status == 406
    assert request(String.duplicate("x", MCP.body_limit() + 1)).status == 413

    for method <- ["GET", "DELETE", "PUT"] do
      response = base(method, "") |> MCP.call([])
      assert response.status == 405
      assert get_resp_header(response, "allow") == ["POST"]
    end
  end

  test "malformed envelopes, batches, initialize notification and untrusted metadata are rejected" do
    for message <- [
          "{",
          [],
          [rpc("ping")],
          Map.put(rpc("ping"), "id", nil),
          Map.put(rpc("ping"), "actor", "admin"),
          %{"jsonrpc" => "2.0", "method" => "initialize"}
        ] do
      response = request(message)
      assert response.status == 400
      assert body(response)["error"]["code"] in [-32700, -32600]
    end

    assert request(rpc("ping", %{"_meta" => "bad"})) |> body() |> get_in(["error", "code"]) ==
             -32602

    assert request(rpc("initialize", %{})) |> body() |> get_in(["error", "code"]) == -32602
    assert request(rpc("resources/list")) |> body() |> get_in(["error", "code"]) == -32601

    assert request(rpc("tools/list", %{"cursor" => "next"}))
           |> body()
           |> get_in(["error", "code"]) == -32602

    assert call("raw_command", %{}) |> get_in(["error", "code"]) == -32602

    assert request(rpc("tools/call", %{"name" => "zone_get", "arguments" => []}))
           |> body()
           |> get_in(["error", "code"]) == -32602
  end

  test "tool discovery is finite, schema-backed and filtered by actual authorization" do
    tools = request(rpc("tools/list")) |> body() |> get_in(["result", "tools"])

    for tool <- tools do
      assert tool["inputSchema"]["type"] == "object"
      assert tool["outputSchema"]["type"] == "object"
      assert length(tool["outputSchema"]["oneOf"]) == 2
      assert is_map(tool["annotations"])
      {:ok, operation} = Operations.get(tool["name"])

      if operation.kind == :command do
        assert "logical_request_key" in tool["inputSchema"]["required"]
      end
    end

    configure(%{allowed_scopes: ["config:read"]})
    read_tools = request(rpc("tools/list")) |> body() |> get_in(["result", "tools"])
    assert length(read_tools) < length(tools)

    for tool <- read_tools do
      assert {:ok, %{scope: "config:read"}} = Operations.get(tool["name"])
    end

    denied = call("zone_create", Map.put(DomainFixtures.zone(), "logical_request_key", "denied"))
    assert denied["result"]["isError"]
    assert denied["result"]["structuredContent"]["error"]["code"] == "forbidden"
    assert Domain.list_zones() == []
  end

  test "canonical results, business errors and same logical-key replay survive a new connection" do
    params = Map.put(DomainFixtures.zone(), "logical_request_key", "create-zone")
    first = call("zone_create", params)["result"]
    refute first["isError"]
    zone = first["structuredContent"]["data"]
    assert is_binary(first["structuredContent"]["correlation_id"])
    assert Jason.decode!(hd(first["content"])["text"]) == first["structuredContent"]
    replay = call("zone_create", params)["result"]["structuredContent"]["data"]
    assert replay == zone
    assert length(Domain.list_zones()) == 1
    changed = put_in(params, ["records", Access.at(2), "data", "address"], "192.0.2.11")
    assert call("zone_create", changed)["result"]["isError"]
    assert call("zone_get", %{"id" => zone["id"]})["result"]["structuredContent"]["data"] == zone
    assert call("zone_get", %{})["result"]["isError"]
    assert call("zone_get", %{"id" => zone["id"], "actor" => "root"})["result"]["isError"]

    assert call("zone_update", %{
             "id" => zone["id"],
             "expected_revision" => 99,
             "content" => DomainFixtures.zone(),
             "logical_request_key" => "stale"
           })["result"]["isError"]

    assert Domain.get_zone(zone["id"]) == {:ok, zone}
  end

  test "disabled integration and malicious Host, Origin or forwarding headers fail closed" do
    for {header, value} <- [{"origin", "https://evil.test"}, {"x-forwarded-for", "127.0.0.1"}] do
      response =
        base("POST", Jason.encode!(rpc("ping"))) |> put_req_header(header, value) |> MCP.call([])

      assert response.status == 403
    end

    response = %{base("POST", "") | host: "evil.test"} |> MCP.call([])
    assert response.status == 403
    configure(%{mcp_enabled: false})
    assert request(rpc("ping")).status == 503
    configure(%{mcp_enabled: true, mode: :protected_remote})
    response = request(rpc("ping"))
    assert response.status == 401
    assert [challenge] = get_resp_header(response, "www-authenticate")
    assert challenge =~ "resource_metadata="
  end

  defp configure(values) do
    Application.put_env(
      :yellow_dog_management,
      :integration,
      Map.merge(Application.get_env(:yellow_dog_management, :integration), values)
    )
  end

  defp rpc(method, params \\ %{}),
    do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

  defp call(name, arguments),
    do: request(rpc("tools/call", %{"name" => name, "arguments" => arguments})) |> body()

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp base(method, body) do
    %{conn(method, "/", body) | remote_ip: {127, 0, 0, 1}, host: "localhost"}
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", MCP.protocol_version())
  end

  defp request(message, options \\ []) do
    payload = if is_binary(message), do: message, else: Jason.encode!(message)
    conn = base("POST", payload)

    conn =
      case Keyword.get(options, :version, MCP.protocol_version()) do
        nil -> delete_req_header(conn, "mcp-protocol-version")
        version -> put_req_header(conn, "mcp-protocol-version", version)
      end

    conn
    |> put_req_header("content-type", Keyword.get(options, :type, "application/json"))
    |> put_req_header(
      "accept",
      Keyword.get(options, :accept, "application/json, text/event-stream")
    )
    |> MCP.call([])
  end
end
