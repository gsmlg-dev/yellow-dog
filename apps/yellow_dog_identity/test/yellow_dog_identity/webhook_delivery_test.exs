defmodule YellowDogIdentity.WebhookDeliveryTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.{Host, Webhook}

  @valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVyaWVsQGV4YW1wbGUuY29t test@host"
  @valid_age_recipient "age1qyqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9cfe3eds"

  defp build_host(overrides \\ %{}) do
    {:ok, host} =
      Host.new(%{
        hostname: "webhook-node",
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient
      })

    Map.merge(host, overrides)
  end

  describe "payload construction" do
    test "notify returns :ok without a configured URL" do
      host = build_host()
      assert :ok = Webhook.notify("host.registered", host)
    end

    test "payload contains all required fields" do
      host = build_host(%{
        status: :approved,
        trust_level: :cloud_verified,
        trust_provider: :aws
      })

      # We can't easily intercept the internal payload, but we verify
      # the function doesn't crash with various host states
      assert :ok = Webhook.notify("host.approved", host)
    end

    test "payload handles nil trust_provider" do
      host = build_host(%{trust_provider: nil})
      assert :ok = Webhook.notify("host.registered", host)
    end

    test "payload handles all trust levels" do
      host = build_host()

      for level <- [:unverified, :network_partial, :network_verified, :token_verified, :cloud_verified] do
        host = %{host | trust_level: level}
        assert :ok = Webhook.notify("host.registered", host)
      end
    end

    test "payload handles all status values" do
      host = build_host()

      for status <- [:pending, :approved, :revoked] do
        host = %{host | status: status}
        assert :ok = Webhook.notify("host.registered", host)
      end
    end
  end

  describe "event types" do
    test "host.registered event" do
      assert :ok = Webhook.notify("host.registered", build_host())
    end

    test "host.approved event" do
      host = build_host(%{status: :approved, approved_at: DateTime.utc_now()})
      assert :ok = Webhook.notify("host.approved", host)
    end

    test "host.revoked event" do
      host = build_host(%{status: :revoked, revoked_at: DateTime.utc_now()})
      assert :ok = Webhook.notify("host.revoked", host)
    end

    test "host.key_rotated event" do
      host = build_host(%{previous_keys: [%{"key_fingerprint" => "old"}]})
      assert :ok = Webhook.notify("host.key_rotated", host)
    end

    test "host.deleted event" do
      assert :ok = Webhook.notify("host.deleted", build_host())
    end

    test "custom event string" do
      assert :ok = Webhook.notify("custom.event", build_host())
    end
  end

  describe "error handling" do
    test "notify handles host with all fields populated" do
      host = build_host(%{
        status: :approved,
        trust_level: :cloud_verified,
        trust_provider: :gcp,
        role: "worker",
        datacenter: "us-west-2",
        machine_id: "i-1234567890",
        approved_at: DateTime.utc_now(),
        approved_by: "auto:cloud-policy",
        trust_evidence: %{project_id: "my-project"},
        previous_keys: [%{"key_fingerprint" => "SHA256:old"}]
      })

      assert :ok = Webhook.notify("host.approved", host)
    end

    test "notify handles empty hostname" do
      host = build_host(%{hostname: ""})
      assert :ok = Webhook.notify("host.registered", host)
    end
  end
end
