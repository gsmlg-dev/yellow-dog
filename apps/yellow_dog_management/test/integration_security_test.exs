defmodule YellowDog.Management.IntegrationSecurityTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn
  import Ecto.Query

  alias YellowDog.Management.{
    Access,
    ApplicationAPI,
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

  setup_all do
    {:ok, keys: IntegrationSecurityFixtures.keys()}
  end

  setup %{keys: keys} do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    previous = Application.get_env(:yellow_dog_management, :integration)
    {config, directory} = IntegrationSecurityFixtures.configure(keys)
    Application.put_env(:yellow_dog_management, :integration, config)

    on_exit(fn ->
      Application.put_env(:yellow_dog_management, :integration, previous)
      File.rm_rf!(directory)
    end)

    %{config: config}
  end

  test "external access-token profile rejects wrong identity, lifetime, type and token-controlled keys",
       %{keys: keys} do
    token = IntegrationSecurityFixtures.token(keys)
    assert {:ok, caller} = Auth.verify_access(token, :http)
    assert caller.subject == "alice"
    assert caller.authentication == :access_token
    now = System.system_time(:second)

    for opts <- [
          [claims: %{"iss" => "https://evil.test"}],
          [claims: %{"aud" => "other"}],
          [claims: %{"exp" => now - 1}],
          [claims: %{"nbf" => now + 100}],
          [claims: %{"iat" => now + 100}],
          [claims: %{"exp" => now + 7200}],
          [claims: %{"client_id" => nil}],
          [delete: ["exp"]],
          [header: %{"typ" => "JWT"}],
          [header: %{"kid" => "unknown"}],
          [header: %{"jku" => "http://127.0.0.1/keys"}],
          [header: %{"x5u" => "http://127.0.0.1/cert"}],
          [header: %{"crit" => ["custom"]}],
          [profile: :gateway]
        ] do
      assert {:error, %{code: "invalid_token"}} =
               Auth.verify_access(IntegrationSecurityFixtures.token(keys, opts), :http)
    end

    assert {:error, %{code: "invalid_token"}} = Auth.verify_access("worker-credential", :mcp)
    assert {:error, %{code: "invalid_token"}} = Auth.verify_access(token <> "x", :http)
  end

  test "JWKS outage, private keys, unknown kid and oversized key sets fail closed", %{
    keys: keys,
    config: config
  } do
    token = IntegrationSecurityFixtures.token(keys)

    Application.put_env(:yellow_dog_management, :integration, %{
      config
      | access_jwks_file: "/does/not/exist"
    })

    assert {:error, %{code: "invalid_token"}} = Auth.verify_access(token, :http)
    Application.put_env(:yellow_dog_management, :integration, config)
    {_, private} = JOSE.JWK.to_map(keys.access)

    File.write!(
      config.access_jwks_file,
      Jason.encode!(%{"keys" => [Map.put(private, "kid", "access")]})
    )

    assert {:error, %{code: "invalid_token"}} = Auth.verify_access(token, :http)
    File.write!(config.access_jwks_file, String.duplicate(" ", 65_537))
    assert {:error, %{code: "invalid_token"}} = Auth.verify_access(token, :http)
  end

  test "issued Worker credentials and Management tokens cannot cross authentication boundaries",
       %{
         keys: keys
       } do
    assert {:ok, %{"worker" => worker, "token" => credential}} =
             YellowDog.Management.WorkerConnections.create("Credential boundary fixture")

    before = {Repo.all(YellowDog.Management.Worker), Repo.all(Audit), Repo.all(Idempotency)}

    conn = build_conn() |> put_req_header("authorization", "Bearer " <> credential)
    assert get(conn, "/api/v1/workers").status == 401

    mcp =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("mcp-protocol-version", "2025-11-25")

    assert post(mcp, "/mcp", Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})).status ==
             401

    for token <- [
          IntegrationSecurityFixtures.token(keys),
          IntegrationSecurityFixtures.token(keys, profile: :gateway)
        ] do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("content-type", "application/json")

      assert post(conn, "/api/worker/connect", Jason.encode!(%{"worker_id" => worker["id"]})).status ==
               401
    end

    assert {Repo.all(YellowDog.Management.Worker), Repo.all(Audit), Repo.all(Idempotency)} ==
             before

    refute Jason.encode!(Domain.list_audit()) =~ credential
  end

  test "sync admission bounds replays across adapters without creating another job", %{keys: keys} do
    token =
      IntegrationSecurityFixtures.token(keys,
        claims: %{"sub" => "quota-" <> Ecto.UUID.generate()}
      )

    assert {:ok, caller} = Auth.verify_access(token, :http)
    job_query = from(job in Styx.Job, prefix: "management_jobs")

    before =
      {Repo.aggregate(job_query, :count), Repo.aggregate(Audit, :count),
       Repo.aggregate(Idempotency, :count)}

    results =
      for _ <- 1..10 do
        assert {:ok, job} =
                 ApplicationAPI.command(
                   caller,
                   "ip_database_sync",
                   %{"key" => "ip_city"},
                   "one-sync"
                 )

        job
      end

    assert Enum.uniq(results) |> length() == 1

    assert {:error, %{code: "rate_limited"}} =
             ApplicationAPI.command(
               %{caller | source: :mcp},
               "ip_database_sync",
               %{"key" => "ip_city"},
               "another-sync"
             )

    {jobs, audits, receipts} = before
    assert Repo.aggregate(job_query, :count) == jobs + 1
    assert Repo.aggregate(Audit, :count) == audits + 1
    assert Repo.aggregate(Idempotency, :count) == receipts + 1
    assert {:ok, _} = ApplicationAPI.query(caller, "task_get", %{"key" => "ip_city"})
  end

  test "UI gateway identity is separate and both HTTP and connected mount enforce it", %{
    keys: keys
  } do
    assertion = IntegrationSecurityFixtures.token(keys, profile: :gateway)
    assert {:ok, caller} = Auth.verify_gateway(assertion)

    assert {:error, %{code: "invalid_token"}} =
             Auth.verify_gateway(IntegrationSecurityFixtures.token(keys))

    conn = build_conn() |> put_req_header("x-yellow-dog-gateway-assertion", assertion)
    {:ok, view, html} = live(conn, "/management")
    refute html =~ assertion
    assert has_element?(view, "#management-overview")
    session = %{"management_caller" => Caller.session(caller)}
    uri = URI.parse("https://www.example.com/live/websocket")
    peer = %{address: {127, 0, 0, 1}}

    assert {:ok, _} =
             Auth.socket([{"x-yellow-dog-gateway-assertion", assertion}], peer, uri, session)

    assert {:error, _} = Auth.socket([], peer, uri, session)

    other =
      IntegrationSecurityFixtures.token(keys, profile: :gateway, claims: %{"sub" => "mallory"})

    assert {:error, _} =
             Auth.socket([{"x-yellow-dog-gateway-assertion", other}], peer, uri, session)

    assert response(get(build_conn(), "/management"), 401) =~ "gateway assertion"

    expired =
      IntegrationSecurityFixtures.token(keys,
        profile: :gateway,
        claims: %{"exp" => System.system_time(:second) - 1}
      )

    assert response(
             build_conn()
             |> put_req_header("x-yellow-dog-gateway-assertion", expired)
             |> get("/management"),
             401
           )
  end

  test "read-only UI cannot read audit or privileged pages or issue mutations", %{keys: keys} do
    assertion =
      IntegrationSecurityFixtures.token(keys,
        profile: :gateway,
        claims: %{"scope" => "config:read"}
      )

    conn = fn -> build_conn() |> put_req_header("x-yellow-dog-gateway-assertion", assertion) end
    assert response(get(conn.(), "/management/events"), 403)
    assert response(get(conn.(), "/system/backups"), 403)
    assert response(get(conn.(), "/system/process-map"), 403)
    {:ok, view, _} = live(conn.(), "/management")
    assert has_element?(view, "#management-recent-events-empty")
    {:ok, caller} = Auth.verify_gateway(assertion)

    assert {:error, %{code: "forbidden"}} =
             ApplicationAPI.command(
               caller,
               "zone_create",
               %{"name" => "forbidden.test", "records" => []},
               "no-write"
             )

    assert Repo.aggregate(Idempotency, :count) == 0
  end

  test "live callbacks and component events lose access after policy change", %{
    keys: keys,
    config: config
  } do
    conn =
      build_conn()
      |> put_req_header(
        "x-yellow-dog-gateway-assertion",
        IntegrationSecurityFixtures.token(keys, profile: :gateway)
      )

    {:ok, view, _} = live(conn, "/management")

    Application.put_env(:yellow_dog_management, :integration, %{
      config
      | policy_revision: "security-2"
    })

    assert {:error, {:redirect, %{to: "/management"}}} = render_click(view, "refresh")
  end

  test "idle socket expiration closes access even without a user event", %{keys: keys} do
    assertion =
      IntegrationSecurityFixtures.token(keys,
        profile: :gateway,
        claims: %{"exp" => System.system_time(:second) + 2}
      )

    conn = build_conn() |> put_req_header("x-yellow-dog-gateway-assertion", assertion)
    {:ok, view, _} = live(conn, "/management")
    assert_redirect(view, "/management", 3_000)
  end

  test "remote legacy commands and all legacy reads are retired; downloads still require gateway",
       %{keys: keys} do
    bearer = IntegrationSecurityFixtures.token(keys)
    conn = build_conn() |> put_req_header("authorization", "Bearer " <> bearer)
    assert get(conn, "/api/workers").status == 410
    assert post(conn, "/api/commands/create_zone", %{"name" => "bypass.test"}).status == 410
    assert get(build_conn(), "/api/workers/unknown/targets/1/export").status == 401
    assert get(build_conn(), "/api/backups/unknown/download").status == 401
    assert Repo.aggregate(Idempotency, :count) == 0
  end

  test "Host and Origin protections run before authentication; forwarded headers establish no identity",
       %{keys: keys} do
    token = IntegrationSecurityFixtures.token(keys)

    for conn <- [
          %{build_conn() | host: "evil.test"},
          build_conn() |> put_req_header("origin", "https://evil.test")
        ] do
      assert {:error, %{code: "forbidden"}} =
               Auth.authenticate(put_req_header(conn, "authorization", "Bearer " <> token), :http)
    end

    assert {:error, %{code: "authentication_required"}} =
             Auth.authenticate(build_conn() |> put_req_header("x-auth-user", "alice"), :ui)
  end

  test "trusted local requires direct loopback and refuses forwarded, wildcard or proxy deployments",
       %{config: config} do
    local = %{config | mode: :trusted_local}
    Application.put_env(:yellow_dog_management, :integration, local)

    assert {:ok, %{subject: "local-operator", client_id: nil}} =
             Auth.authenticate(build_conn(), :http)

    assert {:error, %{code: "forbidden"}} =
             Auth.authenticate(%{build_conn() | remote_ip: {10, 0, 0, 1}}, :http)

    assert {:error, %{code: "forbidden"}} =
             Auth.authenticate(
               put_req_header(build_conn(), "x-forwarded-for", "127.0.0.1"),
               :http
             )

    original = System.get_env("YELLOW_DOG_MANAGEMENT_BIND_ADDRESS")
    System.put_env("YELLOW_DOG_MANAGEMENT_BIND_ADDRESS", "0.0.0.0")

    on_exit(fn ->
      if original,
        do: System.put_env("YELLOW_DOG_MANAGEMENT_BIND_ADDRESS", original),
        else: System.delete_env("YELLOW_DOG_MANAGEMENT_BIND_ADDRESS")
    end)

    assert_raise RuntimeError, ~r/loopback listener/, &IntegrationSettings.validate!/0
  end

  test "cross-adapter logical requests share one receipt, audit verified identity, and reauthorize replay",
       %{keys: keys, config: config} do
    {:ok, http} = Auth.verify_access(IntegrationSecurityFixtures.token(keys), :http)
    mcp = %{http | source: :mcp, correlation_id: Ecto.UUID.generate()}
    params = %{"content" => YellowDog.Management.DomainFixtures.zone("shared.test.")}
    assert {:ok, zone} = ApplicationAPI.command(http, "zone_create", params, "lost-response")
    assert {:ok, ^zone} = ApplicationAPI.command(mcp, "zone_create", params, "lost-response")
    assert Repo.aggregate(Idempotency, :count) == 1
    assert [audit] = Repo.all(Audit)
    assert audit.context["subject"] == "alice"
    assert audit.context["client_id"] == "integration-client"
    assert audit.context["source"] == "http"
    refute Map.has_key?(audit.request, "records")
    refute Map.has_key?(audit.request, "name")
    changed = %{"content" => YellowDog.Management.DomainFixtures.zone("changed.test.")}

    assert {:error, %{code: "idempotency_conflict"}} =
             ApplicationAPI.command(mcp, "zone_create", changed, "lost-response")

    assert {:error, %{code: "idempotency_conflict"}} =
             ApplicationAPI.command(
               mcp,
               "zone_delete",
               %{"id" => zone["id"], "expected_revision" => zone["revision"]},
               "lost-response"
             )

    Application.put_env(:yellow_dog_management, :integration, %{
      config
      | allowed_scopes: ["config:read"]
    })

    assert {:error, %{code: "forbidden"}} =
             ApplicationAPI.command(http, "zone_create", params, "lost-response")

    assert Repo.aggregate(Audit, :count) == 1
  end

  test "caller/client key namespaces are distinct and omit transient transport context", %{
    keys: keys
  } do
    {:ok, caller} = Auth.verify_access(IntegrationSecurityFixtures.token(keys), :http)

    assert Caller.request_key(caller, "k") ==
             Caller.request_key(%{caller | source: :mcp, expires_at: caller.expires_at + 1}, "k")

    refute Caller.request_key(caller, "k") == Caller.request_key(%{caller | subject: "bob"}, "k")

    refute Caller.request_key(caller, "k") ==
             Caller.request_key(%{caller | client_id: "other"}, "k")

    assert Access.authorize(
             %{caller | expires_at: System.system_time(:second) - 1},
             "config:read"
           )
           |> elem(0) == :error

    assert {:error, _} = Access.authorize(caller, "unknown")
  end

  test "authorization is rechecked inside Domain after receipt locking", %{
    keys: keys,
    config: config
  } do
    {:ok, caller} = Auth.verify_access(IntegrationSecurityFixtures.token(keys), :http)
    {:ok, encoded} = Caller.request_key(caller, "expired")
    handler = "receipt-policy-#{Ecto.UUID.generate()}"

    :telemetry.attach(
      handler,
      [:yellow_dog, :management, :repo, :query],
      fn _, _, metadata, _ ->
        if is_binary(metadata[:query]) and String.contains?(metadata.query, "FOR UPDATE") and
             String.contains?(metadata.query, "management_idempotency") do
          Application.put_env(:yellow_dog_management, :integration, %{
            config
            | policy_revision: "after-lock"
          })
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    params = %{"content" => YellowDog.Management.DomainFixtures.zone("expired.test.")}

    assert {:error, %{code: "forbidden"}} =
             Domain.mutate("create_zone", params, Caller.actor(caller), encoded,
               caller: caller,
               scope: "data:write"
             )

    refute Repo.exists?(from(r in Idempotency, where: r.key == ^encoded))
  end
end
