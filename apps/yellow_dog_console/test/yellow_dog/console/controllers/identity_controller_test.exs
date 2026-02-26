defmodule YellowDog.Console.IdentityControllerTest do
  use YellowDog.Console.ConnCase, async: false

  alias YellowDogIdentity.{Host, Registry}

  @valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVyaWVsQGV4YW1wbGUuY29t test@host"
  @valid_age_recipient "age1qyqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9cfe3eds"

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "ctrl_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    start_supervised!(
      {YellowDogIdentity.Registry, data_dir: tmp_dir, name: YellowDogIdentity.Registry}
    )

    on_exit(fn -> File.rm_rf!(tmp_dir) end)
    %{tmp_dir: tmp_dir}
  end

  describe "POST /api/hosts/register" do
    test "registers a new host", %{conn: conn} do
      payload = %{
        "hostname" => "node-01",
        "ssh_pubkey" => @valid_ssh_pubkey,
        "age_recipient" => @valid_age_recipient
      }

      conn = post(conn, "/api/hosts/register", payload)
      body = json_response(conn, 201)

      assert body["status"] in ["pending", "approved"]
      assert body["id"]
      assert body["message"] == "Registration accepted"
    end

    test "returns 200 for idempotent re-registration", %{conn: conn} do
      payload = %{
        "hostname" => "node-02",
        "ssh_pubkey" => @valid_ssh_pubkey,
        "age_recipient" => @valid_age_recipient
      }

      post(conn, "/api/hosts/register", payload)
      conn = post(conn, "/api/hosts/register", payload)
      body = json_response(conn, 200)

      assert body["message"] == "Already registered"
    end

    test "returns 422 for missing hostname", %{conn: conn} do
      payload = %{
        "ssh_pubkey" => @valid_ssh_pubkey,
        "age_recipient" => @valid_age_recipient
      }

      conn = post(conn, "/api/hosts/register", payload)
      body = json_response(conn, 422)

      assert body["error"]
    end

    test "returns 409 for conflicting key without force", %{conn: conn} do
      payload = %{
        "hostname" => "node-03",
        "ssh_pubkey" => @valid_ssh_pubkey,
        "age_recipient" => @valid_age_recipient
      }

      post(conn, "/api/hosts/register", payload)

      conflict_payload = %{
        "hostname" => "node-03",
        "ssh_pubkey" =>
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBxRhNpqVVPZOFRZNvKGVfCjXN5US8MLXiEy1Ox7xDT6 alt@host",
        "age_recipient" => "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"
      }

      conn = post(conn, "/api/hosts/register", conflict_payload)
      body = json_response(conn, 409)

      assert body["error"] == "conflict"
    end
  end

  describe "GET /api/hosts/recipients" do
    test "returns YAML recipients for approved hosts", %{conn: conn} do
      # Create and approve a host
      {:ok, host} =
        Host.new(%{
          hostname: "approved-host",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      approved = %{host | status: :approved, approved_at: DateTime.utc_now(), approved_by: "test"}
      :ok = Registry.put_host(approved)

      conn = get(conn, "/api/hosts/recipients")
      assert response_content_type(conn, :yaml) =~ "yaml"
      body = response(conn, 200)
      assert body =~ "age"
    end

    test "returns sops format when requested", %{conn: conn} do
      {:ok, host} =
        Host.new(%{
          hostname: "sops-host",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      approved = %{host | status: :approved, approved_at: DateTime.utc_now(), approved_by: "test"}
      :ok = Registry.put_host(approved)

      conn = get(conn, "/api/hosts/recipients?format=sops")
      body = response(conn, 200)
      assert body =~ "creation_rules"
    end
  end

  describe "GET /api/hosts/:id/status" do
    test "returns host status", %{conn: conn} do
      {:ok, host} =
        Host.new(%{
          hostname: "status-host",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      :ok = Registry.put_host(host)

      conn = get(conn, "/api/hosts/#{host.id}/status")
      body = json_response(conn, 200)

      assert body["hostname"] == "status-host"
      assert body["status"] == "pending"
    end

    test "returns 404 for unknown host", %{conn: conn} do
      conn = get(conn, "/api/hosts/nonexistent-uuid/status")
      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  describe "PUT /api/hosts/:id/approve" do
    test "approves pending host", %{conn: conn} do
      {:ok, host} =
        Host.new(%{
          hostname: "approve-host",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      :ok = Registry.put_host(host)

      conn = put(conn, "/api/hosts/#{host.id}/approve")
      body = json_response(conn, 200)

      assert body["status"] == "approved"
      assert body["message"] == "Host approved"
    end

    test "returns 404 for unknown host", %{conn: conn} do
      conn = put(conn, "/api/hosts/nonexistent-uuid/approve")
      assert json_response(conn, 404)["error"] == "not_found"
    end

    test "returns 409 for already-approved host", %{conn: conn} do
      {:ok, host} =
        Host.new(%{
          hostname: "already-approved",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      approved = %{host | status: :approved, approved_at: DateTime.utc_now(), approved_by: "test"}
      :ok = Registry.put_host(approved)

      conn = put(conn, "/api/hosts/#{host.id}/approve")
      assert json_response(conn, 409)["error"] == "invalid_status"
    end
  end

  describe "POST /api/hosts/:id/revoke" do
    test "revokes approved host", %{conn: conn} do
      {:ok, host} =
        Host.new(%{
          hostname: "revoke-host",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      approved = %{host | status: :approved, approved_at: DateTime.utc_now(), approved_by: "test"}
      :ok = Registry.put_host(approved)

      conn =
        post(conn, "/api/hosts/#{host.id}/revoke", %{
          "reason" => "decommissioned"
        })

      body = json_response(conn, 200)
      assert body["status"] == "revoked"
      assert body["message"] == "Host revoked"
    end

    test "returns 409 for already-revoked host", %{conn: conn} do
      {:ok, host} =
        Host.new(%{
          hostname: "revoked-host",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      revoked = %{
        host
        | status: :revoked,
          revoked_at: DateTime.utc_now(),
          revoked_by: "test",
          revoke_reason: "test"
      }

      :ok = Registry.put_host(revoked)

      conn = post(conn, "/api/hosts/#{host.id}/revoke", %{"reason" => "retry"})
      assert json_response(conn, 409)["error"] == "already_revoked"
    end

    test "returns 404 for unknown host", %{conn: conn} do
      conn = post(conn, "/api/hosts/nonexistent-uuid/revoke", %{"reason" => "test"})
      assert json_response(conn, 404)["error"] == "not_found"
    end
  end

  describe "DELETE /api/hosts/:id" do
    test "deletes host record", %{conn: conn} do
      {:ok, host} =
        Host.new(%{
          hostname: "delete-host",
          ssh_pubkey: @valid_ssh_pubkey,
          age_recipient: @valid_age_recipient
        })

      :ok = Registry.put_host(host)

      conn = delete(conn, "/api/hosts/#{host.id}")
      body = json_response(conn, 200)
      assert body["message"] == "Host deleted"

      # Verify host is gone
      conn = get(build_conn(), "/api/hosts/#{host.id}/status")
      assert json_response(conn, 404)
    end

    test "returns 404 for unknown host", %{conn: conn} do
      conn = delete(conn, "/api/hosts/nonexistent-uuid")
      assert json_response(conn, 404)["error"] == "not_found"
    end
  end
end
