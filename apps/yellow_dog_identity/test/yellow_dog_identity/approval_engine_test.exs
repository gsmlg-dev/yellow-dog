defmodule YellowDogIdentity.Approval.EngineTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Approval.{Engine, Policy}
  alias YellowDogIdentity.Host

  @valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHUzjC6gKCLjRoHMvMXBx3cCe49wjm69r9B7YBcFcAv1 test@host"
  @valid_age_recipient "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"

  defp make_host(attrs) do
    {:ok, host} =
      Host.new(%{
        hostname: Map.get(attrs, :hostname, "node-01"),
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient
      })

    host
    |> Map.merge(Map.drop(attrs, [:hostname]))
  end

  describe "evaluate_with_policies/4" do
    test "matches trust_level policy" do
      policies = [
        %Policy{
          name: "auto-approve-verified",
          action: :approve,
          match: %{"trust_level" => "network_verified"}
        }
      ]

      host = make_host(%{trust_level: :network_verified})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :approve
      assert result.policy_name == "auto-approve-verified"
      assert result.auto == true
    end

    test "matches trust_level list" do
      policies = [
        %Policy{
          name: "approve-verified",
          action: :approve,
          match: %{"trust_level" => ["network_verified", "cloud_verified"]}
        }
      ]

      host = make_host(%{trust_level: :cloud_verified})
      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end

    test "matches hostname_pattern with glob" do
      policies = [
        %Policy{
          name: "dc1-workstations",
          action: :approve,
          match: %{"hostname_pattern" => "ws-*"}
        }
      ]

      host = make_host(%{hostname: "ws-042"})
      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end

    test "falls through to default when no match" do
      policies = [
        %Policy{
          name: "only-verified",
          action: :approve,
          match: %{"trust_level" => "network_verified"}
        }
      ]

      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate_with_policies(host, policies, :reject)

      assert result.action == :reject
      assert result.policy_name == nil
      assert result.auto == false
    end

    test "first matching policy wins" do
      policies = [
        %Policy{
          name: "reject-unverified",
          action: :reject,
          match: %{"trust_level" => "unverified"}
        },
        %Policy{
          name: "approve-all",
          action: :approve,
          match: %{}
        }
      ]

      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :reject
      assert result.policy_name == "reject-unverified"
    end

    test "matches cloud_account from trust_evidence" do
      policies = [
        %Policy{
          name: "aws-prod",
          action: :approve,
          match: %{"trust_level" => "cloud_verified", "cloud_account" => "123456789012"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :aws,
          trust_evidence: %{account_id: "123456789012", region: "us-east-1"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end
  end
end
