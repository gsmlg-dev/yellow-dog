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

  describe "notify/2" do
    test "returns :ok when no webhook URL is configured" do
      host = build_host()
      assert :ok = Webhook.notify("host.registered", host)
    end

    test "returns :ok for host.approved event" do
      host = build_host(%{status: :approved, approved_at: DateTime.utc_now(), approved_by: "admin"})
      assert :ok = Webhook.notify("host.approved", host)
    end

    test "returns :ok for host.revoked event" do
      host = build_host(%{status: :revoked, revoked_at: DateTime.utc_now(), revoked_by: "admin"})
      assert :ok = Webhook.notify("host.revoked", host)
    end

    test "handles host with minimal fields" do
      host = %Host{
        id: "test-id-000",
        hostname: "minimal-node",
        ssh_pubkey: @valid_ssh_pubkey,
        key_fingerprint: "SHA256:test",
        age_recipient: @valid_age_recipient
      }

      assert :ok = Webhook.notify("host.registered", host)
    end

    test "handles various event strings" do
      host = build_host()

      for event <- ~w(host.registered host.approved host.revoked host.key_rotated) do
        assert :ok = Webhook.notify(event, host)
      end
    end
  end
end
