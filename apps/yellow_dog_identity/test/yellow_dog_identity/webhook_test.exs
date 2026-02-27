defmodule YellowDogIdentity.WebhookTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.{Host, Webhook}

  @valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHUzjC6gKCLjRoHMvMXBx3cCe49wjm69r9B7YBcFcAv1 test@host"
  @valid_age_recipient "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"

  defp build_host(overrides \\ %{}) do
    {:ok, host} =
      Host.new(%{
        hostname: "webhook-test-node",
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient
      })

    Map.merge(host, overrides)
  end

  describe "module" do
    test "is loadable" do
      assert {:module, Webhook} = Code.ensure_loaded(Webhook)
    end

    test "exports notify/2" do
      assert function_exported?(Webhook, :notify, 2)
    end
  end

  describe "notify/2 with no webhook URL configured" do
    test "returns :ok when no webhook URL is configured" do
      host = build_host()
      assert :ok = Webhook.notify("host.registered", host)
    end
  end

  describe "notify/2 event types" do
    test "returns :ok for host.registered event" do
      host = build_host()
      assert :ok = Webhook.notify("host.registered", host)
    end

    test "returns :ok for host.approved event" do
      host = build_host(%{status: :approved, approved_at: DateTime.utc_now(), approved_by: "admin"})
      assert :ok = Webhook.notify("host.approved", host)
    end

    test "returns :ok for host.revoked event" do
      host =
        build_host(%{
          status: :revoked,
          revoked_at: DateTime.utc_now(),
          revoked_by: "admin",
          revoke_reason: "compromised"
        })

      assert :ok = Webhook.notify("host.revoked", host)
    end

    test "returns :ok for host.key_rotated event" do
      host = build_host(%{previous_keys: [%{"key_fingerprint" => "SHA256:old"}]})
      assert :ok = Webhook.notify("host.key_rotated", host)
    end

    test "returns :ok for host.deleted event" do
      host = build_host()
      assert :ok = Webhook.notify("host.deleted", host)
    end

    test "returns :ok for arbitrary custom event string" do
      host = build_host()
      assert :ok = Webhook.notify("custom.event.name", host)
    end
  end

  describe "notify/2 with various host statuses" do
    test "handles pending status" do
      host = build_host(%{status: :pending})
      assert :ok = Webhook.notify("host.registered", host)
    end

    test "handles approved status" do
      host = build_host(%{status: :approved, approved_at: DateTime.utc_now()})
      assert :ok = Webhook.notify("host.approved", host)
    end

    test "handles revoked status" do
      host = build_host(%{status: :revoked, revoked_at: DateTime.utc_now()})
      assert :ok = Webhook.notify("host.revoked", host)
    end
  end

  describe "notify/2 with various trust levels" do
    for level <- ~w(unverified network_partial network_verified netboot_verified token_verified cloud_verified)a do
      test "handles #{level} trust level" do
        host = build_host(%{trust_level: unquote(level)})
        assert :ok = Webhook.notify("host.registered", host)
      end
    end
  end

  describe "notify/2 with various trust providers" do
    for provider <- ~w(none dhcp netboot aws gcp azure token)a do
      test "handles #{provider} trust provider" do
        host = build_host(%{trust_provider: unquote(provider)})
        assert :ok = Webhook.notify("host.registered", host)
      end
    end
  end

  describe "notify/2 with edge-case host data" do
    test "handles host with minimal required fields only" do
      host = %Host{
        id: "minimal-id-000",
        hostname: "minimal-node",
        ssh_pubkey: @valid_ssh_pubkey,
        key_fingerprint: "SHA256:test",
        age_recipient: @valid_age_recipient
      }

      assert :ok = Webhook.notify("host.registered", host)
    end

    test "handles host with all optional fields populated" do
      host =
        build_host(%{
          status: :approved,
          trust_level: :cloud_verified,
          trust_provider: :gcp,
          role: "worker",
          datacenter: "us-west-2",
          machine_id: "i-1234567890abcdef",
          approved_at: DateTime.utc_now(),
          approved_by: "auto:cloud-policy",
          trust_evidence: %{project_id: "my-project", zone: "us-west-2a"},
          metadata: %{"environment" => "production"},
          previous_keys: [%{"key_fingerprint" => "SHA256:old"}]
        })

      assert :ok = Webhook.notify("host.approved", host)
    end

    test "handles host with nil trust_provider" do
      host = build_host(%{trust_provider: nil})
      assert :ok = Webhook.notify("host.registered", host)
    end

    test "handles host with nil trust_level" do
      host = build_host(%{trust_level: nil})
      assert :ok = Webhook.notify("host.registered", host)
    end

    test "handles host with empty hostname" do
      host = build_host(%{hostname: ""})
      assert :ok = Webhook.notify("host.registered", host)
    end

    test "handles host with empty event string" do
      host = build_host()
      assert :ok = Webhook.notify("", host)
    end
  end
end
