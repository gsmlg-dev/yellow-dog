defmodule YellowDog.Management.TrustedLanTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias YellowDog.Management.{
    Access,
    Audit,
    Auth,
    Caller,
    Domain,
    Idempotency,
    IntegrationSecurityFixtures,
    IntegrationSettings,
    Repo
  }

  @endpoint YellowDog.ManagementUI.Endpoint
  @resource "http://10.100.10.15:4270"
  @peer {10, 100, 10, 20}
  @environment ~w(YELLOW_DOG_MANAGEMENT_AUTH_MODE YELLOW_DOG_MANAGEMENT_BIND_ADDRESS YELLOW_DOG_MANAGEMENT_PORT YELLOW_DOG_MANAGEMENT_RESOURCE YELLOW_DOG_MANAGEMENT_TRUSTED_LAN_NETWORK YELLOW_DOG_MANAGEMENT_TRUSTED_PROXY_IP YELLOW_DOG_MANAGEMENT_EXTERNAL_ORIGIN)

  setup_all do
    {:ok, keys: IntegrationSecurityFixtures.keys()}
  end

  setup %{keys: keys} do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    previous = Application.get_env(:yellow_dog_management, :integration)
    environment = Map.new(@environment, &{&1, System.get_env(&1)})
    {base, directory} = IntegrationSecurityFixtures.configure(keys)

    config =
      Map.merge(base, %{
        mode: :trusted_lan,
        resource: @resource,
        trusted_lan_network: "10.100.0.0/20",
        allowed_hosts: nil
      })

    System.put_env("YELLOW_DOG_MANAGEMENT_AUTH_MODE", "trusted_lan")
    System.put_env("YELLOW_DOG_MANAGEMENT_BIND_ADDRESS", "0.0.0.0")
    System.put_env("YELLOW_DOG_MANAGEMENT_PORT", "4270")
    System.put_env("YELLOW_DOG_MANAGEMENT_RESOURCE", @resource)
    System.put_env("YELLOW_DOG_MANAGEMENT_TRUSTED_LAN_NETWORK", "10.100.0.0/20")
    System.delete_env("YELLOW_DOG_MANAGEMENT_TRUSTED_PROXY_IP")
    System.delete_env("YELLOW_DOG_MANAGEMENT_EXTERNAL_ORIGIN")
    Application.put_env(:yellow_dog_management, :integration, config)

    on_exit(fn ->
      Application.put_env(:yellow_dog_management, :integration, previous)

      for {name, value} <- environment do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      File.rm_rf!(directory)
    end)

    %{config: config}
  end

  test "explicit private LAN configuration is recognized and validated", %{config: config} do
    Application.put_env(:yellow_dog_management, :integration, Map.delete(config, :mode))
    assert IntegrationSettings.get().mode == :trusted_lan
    assert :ok = IntegrationSettings.validate!()
  end

  test "missing, malformed and non-private networks fail deployment validation", %{config: config} do
    for network <- [
          nil,
          "",
          "10.100.0.0",
          "10.100.10.15/20",
          "10.100.0.0/33",
          "0.0.0.0/0",
          "10.0.0.0/7",
          "172.16.0.0/11",
          "192.168.0.0/15",
          "8.8.8.0/24",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "::1/128",
          "10.100.0.0/20,192.168.0.0/16"
        ] do
      Application.put_env(:yellow_dog_management, :integration, %{
        config
        | trusted_lan_network: network
      })

      assert_raise RuntimeError, &IntegrationSettings.validate!/0
    end
  end

  test "resource must identify the private listener inside the configured network", %{
    config: config
  } do
    for resource <- [
          "http://8.8.8.8:4270",
          "http://10.100.16.15:4270",
          "http://192.168.1.15:4270",
          "http://0.0.0.0:4270",
          "http://localhost:4270",
          "http://lan.example.test:4270",
          "http://10.100.10.15:4271",
          "http://10.100.10.15:4270/management"
        ] do
      Application.put_env(:yellow_dog_management, :integration, %{config | resource: resource})
      assert_raise RuntimeError, &IntegrationSettings.validate!/0
    end
  end

  test "LAN trust refuses proxy and external-origin deployment settings" do
    for {name, value} <- [
          {"YELLOW_DOG_MANAGEMENT_TRUSTED_PROXY_IP", "127.0.0.1"},
          {"YELLOW_DOG_MANAGEMENT_EXTERNAL_ORIGIN", @resource}
        ] do
      System.put_env(name, value)
      assert_raise RuntimeError, &IntegrationSettings.validate!/0
      System.delete_env(name)
    end
  end

  test "direct LAN UI receives a distinct identity and mounts a signed LiveView session" do
    conn = lan_conn() |> put_req_header("origin", @resource)
    assert {:ok, caller} = Auth.authenticate(conn, :ui)
    assert caller.issuer == "urn:yellow-dog:trusted-lan"
    assert caller.authentication == :trusted_lan
    assert caller.source == :ui
    assert caller.client_id == nil
    assert :ok = Access.authorize(caller, "config:read")

    assert {:ok, restored} =
             Caller.from_session(
               Caller.session(caller)
               |> Map.put("authentication", "trusted_lan")
             )

    assert restored.authentication == :trusted_lan
    assert Caller.same_identity?(restored, caller)
    assert {:ok, view, _html} = live(conn, "/management")
    assert has_element?(view, "#management-overview")
    assert render_click(view, "refresh") =~ "management-overview"
  end

  test "LAN sockets recheck peer, Host, Origin, signed identity and authorization lifetime", %{
    config: config
  } do
    assert {:ok, caller} = Auth.authenticate(lan_conn(), :ui)
    session = %{"management_caller" => Caller.session(caller)}
    uri = URI.parse(@resource <> "/live/websocket")
    headers = [{"origin", @resource}]
    peer = %{address: @peer}
    assert {:ok, connected} = Auth.socket(headers, peer, uri, session)
    assert connected.authentication == :trusted_lan

    for {request_headers, request_peer, request_uri, saved} <- [
          {headers, %{address: {10, 100, 16, 1}}, uri, session},
          {headers, peer, URI.parse("http://10.100.10.16:4270/live/websocket"), session},
          {[{"origin", "http://evil.test"}], peer, uri, session},
          {[{"origin", @resource}, {"forwarded", "for=10.100.10.20"}], peer, uri, session},
          {headers, peer, uri, %{}},
          {headers, peer, uri,
           %{"management_caller" => Caller.session(%{caller | issuer: "urn:other"})}},
          {headers, peer, uri,
           %{
             "management_caller" =>
               Caller.session(%{caller | expires_at: System.system_time(:second) - 1})
           }}
        ] do
      assert {:error, _} = Auth.socket(request_headers, request_peer, request_uri, saved)
    end

    Application.put_env(:yellow_dog_management, :integration, %{
      config
      | policy_revision: "lan-policy-2"
    })

    assert {:error, _} = Auth.socket(headers, peer, uri, session)
  end

  test "network boundaries, alternate hosts, origins and forwarding headers cannot claim LAN trust" do
    for conn <- [
          %{lan_conn() | remote_ip: {10, 99, 255, 255}},
          %{lan_conn() | remote_ip: {10, 100, 16, 0}},
          %{lan_conn() | remote_ip: {192, 168, 1, 10}},
          %{lan_conn() | remote_ip: {8, 8, 8, 8}},
          %{lan_conn() | host: "evil.test"},
          %{lan_conn() | host: "localhost"},
          %{lan_conn() | host: "10.100.10.16"},
          %{lan_conn() | port: 4271},
          %{lan_conn() | scheme: :https},
          put_req_header(lan_conn(), "origin", "http://10.100.10.15:4271"),
          put_req_header(lan_conn(), "origin", "https://10.100.10.15:4270"),
          put_req_header(lan_conn(), "origin", "null"),
          %{lan_conn() | req_headers: [{"origin", @resource}, {"origin", @resource}]}
        ] do
      assert {:error, %{code: "forbidden"}} = Auth.authenticate(conn, :ui)
    end

    for header <- ~w(forwarded x-forwarded-for x-forwarded-host x-forwarded-proto x-real-ip) do
      assert {:error, %{code: "forbidden"}} =
               Auth.authenticate(put_req_header(lan_conn(), header, "127.0.0.1"), :ui)
    end

    assert {:ok, _} = Auth.authenticate(%{lan_conn() | remote_ip: {10, 100, 0, 1}}, :ui)
    assert {:ok, _} = Auth.authenticate(%{lan_conn() | remote_ip: {10, 100, 15, 254}}, :ui)
  end

  test "caller provenance, expiry, scopes and policy remain authoritative", %{config: config} do
    assert {:ok, caller} = Auth.authenticate(lan_conn(), :ui)

    for forged <- [
          %{caller | source: :http},
          %{caller | source: :mcp},
          %{caller | authentication: :trusted_local},
          %{caller | authentication: :gateway},
          %{caller | issuer: "urn:yellow-dog:trusted-local"},
          %{caller | scopes: []}
        ] do
      assert {:error, %{code: "forbidden"}} = Access.authorize(forged, "config:read")
    end

    assert {:error, %{code: "invalid_token"}} =
             Access.authorize(
               %{caller | expires_at: System.system_time(:second) - 1},
               "config:read"
             )

    Application.put_env(:yellow_dog_management, :integration, %{config | allowed_scopes: []})
    assert {:error, %{code: "forbidden"}} = Access.authorize(caller, "config:read")

    Application.put_env(:yellow_dog_management, :integration, %{
      config
      | policy_revision: "lan-policy-2"
    })

    assert {:error, %{code: "forbidden"}} = Access.authorize(caller, "config:read")
  end

  test "mounted LAN UI loses access when policy changes", %{config: config} do
    assert {:ok, view, _} = live(lan_conn(), "/management")

    Application.put_env(:yellow_dog_management, :integration, %{
      config
      | policy_revision: "lan-policy-2"
    })

    assert {:error, {:redirect, %{to: "/management"}}} = render_click(view, "refresh")
  end

  test "enabled API and MCP flags never promote LAN trust into an integration identity" do
    for source <- [:http, :mcp] do
      assert {:error, _} = Auth.authenticate(lan_conn(), source)
    end

    assert get(lan_conn(), "/api/v1/workers").status in [401, 403, 503]

    conn =
      lan_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2025-11-25")

    assert post(conn, "/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})).status in [
             401,
             403,
             503
           ]
  end

  test "LAN legacy reads and commands are retired without durable side effects" do
    before = {Domain.list_workers(), Domain.list_zones(), Repo.all(Audit), Repo.all(Idempotency)}
    assert response(get(lan_conn(), "/api/workers"), 410) =~ "legacy_disabled"
    assert response(get(lan_conn(), "/api/zones"), 410) =~ "legacy_disabled"

    assert response(
             post(lan_conn(), "/api/commands/create_worker", %{"name" => "LAN bypass"}),
             410
           ) =~ "legacy_disabled"

    assert {Domain.list_workers(), Domain.list_zones(), Repo.all(Audit), Repo.all(Idempotency)} ==
             before
  end

  test "direct loopback keeps localhost UI and legacy readiness probes without forwarding" do
    conn = %{build_conn() | host: "127.0.0.1", port: 4270}
    assert {:ok, _} = Auth.authenticate(conn, :ui)
    assert response(get(conn, "/api/workers"), 200) =~ "data"
    assert {:ok, view, _} = live(conn, "/management")
    assert has_element?(view, "#management-overview")

    assert {:error, %{code: "forbidden"}} =
             Auth.authenticate(put_req_header(conn, "x-forwarded-for", "127.0.0.1"), :ui)
  end

  defp lan_conn do
    %{build_conn() | host: "10.100.10.15", port: 4270, remote_ip: @peer}
  end
end
