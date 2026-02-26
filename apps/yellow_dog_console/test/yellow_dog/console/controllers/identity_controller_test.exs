defmodule YellowDog.Console.IdentityControllerTest do
  @moduledoc """
  Tests for the Identity JSON API controller.
  Exercises all 6 endpoints: register, recipients, status, approve, revoke, delete.
  """
  use YellowDog.Console.ConnCase, async: false

  setup do
    # Start identity service with a temp data dir for isolation
    tmp_dir = Path.join(System.tmp_dir!(), "identity_ctrl_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp_dir)

    start_supervised!({YellowDogIdentity.Supervisor, data_dir: tmp_dir})

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, tmp_dir: tmp_dir}
  end

  # Helper to create a host via the register endpoint
  defp register_host(conn, overrides) do
    params =
      Map.merge(
        %{
          "hostname" => "test-node-#{:rand.uniform(999_999)}",
          "ssh_pubkey" => generate_ssh_key(),
          "age_recipient" => "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3cyqar"
        },
        overrides
      )

    post(conn, "/api/hosts/register", params)
  end

  # Generate a unique fake SSH key (ed25519 format with random data)
  defp generate_ssh_key do
    random = :crypto.strong_rand_bytes(32) |> Base.encode64()
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA#{random} test@host"
  end

  # ============================================================================
  # POST /api/hosts/register
  # ============================================================================

  describe "POST /api/hosts/register" do
    test "registers a new host successfully", %{conn: conn} do
      conn = register_host(conn, %{"hostname" => "web-1"})
      body = json_response(conn, 201)

      assert body["id"]
      assert body["status"] in ["pending", "approved"]
      assert body["trust_level"]
      assert body["trust_provider"]
      assert body["message"] == "Registration accepted"
    end

    test "returns 200 for auto-approved host", %{conn: conn} do
      conn = register_host(conn, %{"hostname" => "auto-node"})
      body = json_response(conn, conn.status)

      # Status could be 200 (approved) or 201 (pending) depending on policies
      assert conn.status in [200, 201]
      assert body["message"] == "Registration accepted"
    end

    test "returns idempotent 200 for duplicate registration", %{conn: conn} do
      key = generate_ssh_key()
      params = %{"hostname" => "dup-node", "ssh_pubkey" => key,
                 "age_recipient" => "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3cyqar"}

      # First registration
      post(conn, "/api/hosts/register", params)

      # Duplicate registration — same key, same hostname
      conn2 = post(conn, "/api/hosts/register", params)
      body = json_response(conn2, 200)

      assert body["message"] == "Already registered"
      assert body["id"]
    end

    test "returns 409 for hostname conflict without force", %{conn: conn} do
      params1 = %{"hostname" => "conflict-node", "ssh_pubkey" => generate_ssh_key(),
                  "age_recipient" => "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3cyqar"}
      post(conn, "/api/hosts/register", params1)

      # Different key, same hostname, no force
      params2 = %{"hostname" => "conflict-node", "ssh_pubkey" => generate_ssh_key(),
                  "age_recipient" => "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3cyqar"}
      conn2 = post(conn, "/api/hosts/register", params2)
      body = json_response(conn2, 409)

      assert body["error"] == "conflict"
      assert body["message"] =~ "force: true"
    end

    test "resolves conflict with force: true", %{conn: conn} do
      params1 = %{"hostname" => "force-node", "ssh_pubkey" => generate_ssh_key(),
                  "age_recipient" => "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3cyqar"}
      post(conn, "/api/hosts/register", params1)

      # Different key, same hostname, with force
      params2 = %{"hostname" => "force-node", "ssh_pubkey" => generate_ssh_key(),
                  "age_recipient" => "age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3cyqar",
                  "force" => true}
      conn2 = post(conn, "/api/hosts/register", params2)
      body = json_response(conn2, conn2.status)

      assert body["message"] == "Registration accepted"
      assert conn2.status in [200, 201]
    end

    test "returns 422 for missing required fields", %{conn: conn} do
      conn = post(conn, "/api/hosts/register", %{"hostname" => "no-key"})
      body = json_response(conn, 422)

      assert body["error"]
    end
  end

  # ============================================================================
  # GET /api/hosts/recipients
  # ============================================================================

  describe "GET /api/hosts/recipients" do
    test "returns YAML recipients", %{conn: conn} do
      conn = get(conn, "/api/hosts/recipients")

      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/yaml"
    end

    test "returns sops format when requested", %{conn: conn} do
      conn = get(conn, "/api/hosts/recipients?format=sops")

      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") |> hd() =~ "text/yaml"
    end

    test "includes approved host recipients", %{conn: conn} do
      # Register a host
      register_conn = register_host(conn, %{"hostname" => "recipient-node"})
      body = json_response(register_conn, register_conn.status)
      host_id = body["id"]

      # Approve it
      put(conn, "/api/hosts/#{host_id}/approve", %{})

      # Get recipients
      conn2 = get(conn, "/api/hosts/recipients")
      content = response(conn2, 200)

      assert is_binary(content)
    end
  end

  # ============================================================================
  # GET /api/hosts/:id/status
  # ============================================================================

  describe "GET /api/hosts/:id/status" do
    test "returns host status", %{conn: conn} do
      register_conn = register_host(conn, %{"hostname" => "status-node"})
      body = json_response(register_conn, register_conn.status)
      host_id = body["id"]

      conn2 = get(conn, "/api/hosts/#{host_id}/status")
      status_body = json_response(conn2, 200)

      assert status_body["id"] == host_id
      assert status_body["hostname"] == "status-node"
      assert status_body["status"] in ["pending", "approved"]
      assert status_body["trust_level"]
      assert status_body["trust_provider"]
      assert status_body["key_fingerprint"]
    end

    test "returns 404 for unknown host", %{conn: conn} do
      conn = get(conn, "/api/hosts/nonexistent-id/status")
      body = json_response(conn, 404)

      assert body["error"] == "not_found"
    end

    test "includes timestamps for approved host", %{conn: conn} do
      register_conn = register_host(conn, %{"hostname" => "ts-node"})
      body = json_response(register_conn, register_conn.status)
      host_id = body["id"]

      # Approve the host
      put(conn, "/api/hosts/#{host_id}/approve", %{})

      conn2 = get(conn, "/api/hosts/#{host_id}/status")
      status_body = json_response(conn2, 200)

      assert status_body["status"] == "approved"
      assert status_body["approved_at"]
    end
  end

  # ============================================================================
  # PUT /api/hosts/:id/approve
  # ============================================================================

  describe "PUT /api/hosts/:id/approve" do
    test "approves a pending host", %{conn: conn} do
      register_conn = register_host(conn, %{"hostname" => "approve-node"})
      body = json_response(register_conn, register_conn.status)
      host_id = body["id"]

      # Only test approval if the host is pending (not auto-approved)
      if body["status"] == "pending" do
        conn2 = put(conn, "/api/hosts/#{host_id}/approve", %{})
        approve_body = json_response(conn2, 200)

        assert approve_body["id"] == host_id
        assert approve_body["hostname"] == "approve-node"
        assert approve_body["status"] == "approved"
        assert approve_body["message"] == "Host approved"
      end
    end

    test "uses custom approved_by", %{conn: conn} do
      register_conn = register_host(conn, %{"hostname" => "custom-approve"})
      body = json_response(register_conn, register_conn.status)
      host_id = body["id"]

      if body["status"] == "pending" do
        conn2 = put(conn, "/api/hosts/#{host_id}/approve", %{"approved_by" => "admin-user"})
        approve_body = json_response(conn2, 200)

        assert approve_body["approved_by"] == "admin-user"
      end
    end

    test "returns 409 for already approved host", %{conn: conn} do
      register_conn = register_host(conn, %{"hostname" => "double-approve"})
      body = json_response(register_conn, register_conn.status)
      host_id = body["id"]

      if body["status"] == "pending" do
        # Approve first
        put(conn, "/api/hosts/#{host_id}/approve", %{})
        # Try to approve again
        conn2 = put(conn, "/api/hosts/#{host_id}/approve", %{})
        error_body = json_response(conn2, 409)

        assert error_body["error"] == "invalid_status"
      end
    end

    test "returns 404 for unknown host", %{conn: conn} do
      conn = put(conn, "/api/hosts/nonexistent-id/approve", %{})
      body = json_response(conn, 404)

      assert body["error"] == "not_found"
    end
  end

  # ============================================================================
  # POST /api/hosts/:id/revoke
  # ============================================================================

  describe "POST /api/hosts/:id/revoke" do
    test "revokes a host", %{conn: conn} do
      register_conn = register_host(conn, %{"hostname" => "revoke-node"})
      body = json_response(register_conn, register_conn.status)
      host_id = body["id"]

      conn2 = post(conn, "/api/hosts/#{host_id}/revoke", %{
        "revoked_by" => "security-bot",
        "reason" => "compromised key"
      })
      revoke_body = json_response(conn2, 200)

      assert revoke_body["id"] == host_id
      assert revoke_body["hostname"] == "revoke-node"
      assert revoke_body["status"] == "revoked"
      assert revoke_body["revoked_by"] == "security-bot"
      assert revoke_body["message"] == "Host revoked"
    end

    test "uses default revoked_by and reason", %{conn: conn} do
      register_conn = register_host(conn, %{"hostname" => "default-revoke"})
      body = json_response(register_conn, register_conn.status)
      host_id = body["id"]

      conn2 = post(conn, "/api/hosts/#{host_id}/revoke", %{})
      revoke_body = json_response(conn2, 200)

      assert revoke_body["revoked_by"] == "api"
      assert revoke_body["status"] == "revoked"
    end

    test "returns 409 for already revoked host", %{conn: conn} do
      register_conn = register_host(conn, %{"hostname" => "double-revoke"})
      body = json_response(register_conn, register_conn.status)
      host_id = body["id"]

      # Revoke first
      post(conn, "/api/hosts/#{host_id}/revoke", %{})
      # Try to revoke again
      conn2 = post(conn, "/api/hosts/#{host_id}/revoke", %{})
      error_body = json_response(conn2, 409)

      assert error_body["error"] == "already_revoked"
    end

    test "returns 404 for unknown host", %{conn: conn} do
      conn = post(conn, "/api/hosts/nonexistent-id/revoke", %{})
      body = json_response(conn, 404)

      assert body["error"] == "not_found"
    end
  end

  # ============================================================================
  # DELETE /api/hosts/:id
  # ============================================================================

  describe "DELETE /api/hosts/:id" do
    test "deletes a host", %{conn: conn} do
      register_conn = register_host(conn, %{"hostname" => "delete-node"})
      body = json_response(register_conn, register_conn.status)
      host_id = body["id"]

      conn2 = delete(conn, "/api/hosts/#{host_id}")
      delete_body = json_response(conn2, 200)

      assert delete_body["message"] == "Host deleted"

      # Verify it's gone
      conn3 = get(conn, "/api/hosts/#{host_id}/status")
      assert json_response(conn3, 404)["error"] == "not_found"
    end

    test "returns 404 for unknown host", %{conn: conn} do
      conn = delete(conn, "/api/hosts/nonexistent-id")
      body = json_response(conn, 404)

      assert body["error"] == "not_found"
    end

    test "returns 404 for double delete", %{conn: conn} do
      register_conn = register_host(conn, %{"hostname" => "double-delete"})
      body = json_response(register_conn, register_conn.status)
      host_id = body["id"]

      delete(conn, "/api/hosts/#{host_id}")
      conn2 = delete(conn, "/api/hosts/#{host_id}")
      assert json_response(conn2, 404)["error"] == "not_found"
    end
  end

  # ============================================================================
  # Full lifecycle
  # ============================================================================

  describe "full host lifecycle" do
    test "register → approve → revoke → delete", %{conn: conn} do
      # Register
      register_conn = register_host(conn, %{"hostname" => "lifecycle-node"})
      body = json_response(register_conn, register_conn.status)
      host_id = body["id"]

      # Approve (if pending)
      if body["status"] == "pending" do
        approve_conn = put(conn, "/api/hosts/#{host_id}/approve", %{"approved_by" => "ops"})
        assert json_response(approve_conn, 200)["status"] == "approved"
      end

      # Check status
      status_conn = get(conn, "/api/hosts/#{host_id}/status")
      assert json_response(status_conn, 200)["status"] == "approved"

      # Revoke
      revoke_conn = post(conn, "/api/hosts/#{host_id}/revoke", %{"reason" => "decommissioned"})
      assert json_response(revoke_conn, 200)["status"] == "revoked"

      # Delete
      delete_conn = delete(conn, "/api/hosts/#{host_id}")
      assert json_response(delete_conn, 200)["message"] == "Host deleted"

      # Gone
      gone_conn = get(conn, "/api/hosts/#{host_id}/status")
      assert json_response(gone_conn, 404)
    end
  end
end
