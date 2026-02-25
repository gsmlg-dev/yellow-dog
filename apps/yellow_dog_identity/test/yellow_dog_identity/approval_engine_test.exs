defmodule YellowDogIdentity.Approval.EngineTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Approval.{Engine, Policy}
  alias YellowDogIdentity.Host

  @valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHVyaWVsQGV4YW1wbGUuY29t test@host"
  @valid_age_recipient "age1qyqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9cfe3eds"

  defp make_host(attrs \\ %{}) do
    {:ok, host} =
      Host.new(%{
        hostname: Map.get(attrs, :hostname, "node-01"),
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient
      })

    host
    |> Map.merge(Map.drop(attrs, [:hostname]))
  end

  describe "evaluate/2 with no policies loaded" do
    test "returns pending with no policy when config is unavailable" do
      host = make_host()
      result = Engine.evaluate(host)

      assert result == %{action: :pending, policy_name: nil, auto: false}
    end
  end

  describe "evaluate_with_policies/4" do
    test "approves host matching trust_level: cloud_verified" do
      policies = [
        %Policy{
          name: "auto-approve-cloud",
          action: :approve,
          match: %{"trust_level" => "cloud_verified"}
        }
      ]

      host = make_host(%{trust_level: :cloud_verified, trust_provider: :aws})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :approve
      assert result.policy_name == "auto-approve-cloud"
      assert result.auto == true
    end

    test "rejects host matching hostname pattern" do
      policies = [
        %Policy{
          name: "reject-temp-hosts",
          action: :reject,
          match: %{"hostname_pattern" => "tmp-*"}
        }
      ]

      host = make_host(%{hostname: "tmp-debug-01"})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :reject
      assert result.policy_name == "reject-temp-hosts"
      assert result.auto == true
    end

    test "falls back to default_action when no policy matches" do
      policies = [
        %Policy{
          name: "only-cloud",
          action: :approve,
          match: %{"trust_level" => "cloud_verified"}
        }
      ]

      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result == %{action: :pending, policy_name: nil, auto: false}
    end

    test "falls back to :reject default_action when no policy matches" do
      policies = [
        %Policy{
          name: "only-cloud",
          action: :approve,
          match: %{"trust_level" => "cloud_verified"}
        }
      ]

      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate_with_policies(host, policies, :reject)

      assert result.action == :reject
      assert result.policy_name == nil
      assert result.auto == false
    end
  end

  describe "list_policies/0" do
    test "returns empty policies and pending default when no config available" do
      result = Engine.list_policies()

      assert result == %{policies: [], default_action: :pending}
    end
  end

  describe "build_context via evaluate_with_policies" do
    test "extracts cloud_account from trust_evidence" do
      policies = [
        %Policy{
          name: "aws-prod-only",
          action: :approve,
          match: %{"cloud_account" => "123456789012"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :aws,
          trust_evidence: %{"account_id" => "123456789012", "region" => "us-east-1"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :approve
      assert result.policy_name == "aws-prod-only"
    end

    test "extracts cloud_account from atom-keyed evidence" do
      policies = [
        %Policy{
          name: "gcp-staging",
          action: :approve,
          match: %{"cloud_account" => "my-gcp-project"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :gcp,
          trust_evidence: %{project_id: "my-gcp-project"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :approve
      assert result.policy_name == "gcp-staging"
    end
  end

  describe "rejection policy" do
    test "returns action: :reject with policy_name" do
      policies = [
        %Policy{
          name: "block-unverified",
          action: :reject,
          match: %{"trust_level" => "unverified"}
        }
      ]

      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :reject
      assert result.policy_name == "block-unverified"
      assert result.auto == true
    end
  end
end
