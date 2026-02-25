defmodule YellowDogIdentity.Approval.EngineWithConfigTest do
  use ExUnit.Case, async: false

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

    Map.merge(host, Map.drop(attrs, [:hostname]))
  end

  # Injects approval config via Agent.update and restores on exit.
  defp inject_approval_config(policies_list, default_action) do
    original = Agent.get(YellowDog.Config, & &1)

    config =
      Map.merge(original, %{
        "identity" => %{
          "approval" => %{
            "policies" => policies_list,
            "default_action" => default_action
          }
        }
      })

    Agent.update(YellowDog.Config, fn _ -> config end)
    on_exit(fn -> Agent.update(YellowDog.Config, fn _ -> original end) end)
  end

  # ---------------------------------------------------------------------------
  # evaluate/2 exercising load_policies() + get_default_action()
  # ---------------------------------------------------------------------------

  describe "evaluate/2 with configured policies (load_policies path)" do
    setup do
      inject_approval_config(
        [
          %{
            "name" => "auto-approve-cloud",
            "action" => "approve",
            "match" => %{"trust_level" => "cloud_verified"}
          },
          %{
            "name" => "reject-unverified",
            "action" => "reject",
            "match" => %{"trust_level" => "unverified"}
          }
        ],
        "pending"
      )
    end

    test "first matching policy is applied (approve)" do
      host = make_host(%{trust_level: :cloud_verified})
      result = Engine.evaluate(host)

      assert result.action == :approve
      assert result.policy_name == "auto-approve-cloud"
      assert result.auto == true
    end

    test "second matching policy is applied (reject)" do
      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate(host)

      assert result.action == :reject
      assert result.policy_name == "reject-unverified"
      assert result.auto == true
    end

    test "no matching policy falls back to configured default_action (:pending)" do
      host = make_host(%{trust_level: :network_partial})
      result = Engine.evaluate(host)

      assert result.action == :pending
      assert result.policy_name == nil
      assert result.auto == false
    end
  end

  describe "evaluate/2 with default_action: approve" do
    setup do
      inject_approval_config(
        [
          %{
            "name" => "cloud-only",
            "action" => "reject",
            "match" => %{"trust_level" => "cloud_verified"}
          }
        ],
        "approve"
      )
    end

    test "returns configured :approve default when no policy matches" do
      host = make_host(%{trust_level: :network_verified})
      result = Engine.evaluate(host)

      assert result.action == :approve
      assert result.policy_name == nil
      assert result.auto == false
    end
  end

  describe "evaluate/2 with default_action: reject" do
    setup do
      inject_approval_config([], "reject")
    end

    test "returns configured :reject default when no policies are configured" do
      host = make_host()
      result = Engine.evaluate(host)

      assert result.action == :reject
      assert result.policy_name == nil
      assert result.auto == false
    end
  end

  describe "evaluate/2 with trust_result override" do
    setup do
      inject_approval_config(
        [
          %{
            "name" => "fingerprint-nixos",
            "action" => "approve",
            "match" => %{"fingerprint_class" => "NixOS"}
          }
        ],
        "pending"
      )
    end

    test "trust_result fields are available for policy matching" do
      host = make_host(%{trust_level: :network_verified})
      result = Engine.evaluate(host, %{"fingerprint_class" => "NixOS"})

      assert result.action == :approve
      assert result.policy_name == "fingerprint-nixos"
    end
  end

  # ---------------------------------------------------------------------------
  # list_policies/0 with live config
  # ---------------------------------------------------------------------------

  describe "list_policies/0 with configured policies" do
    setup do
      inject_approval_config(
        [
          %{
            "name" => "policy-a",
            "action" => "approve",
            "match" => %{"trust_level" => "cloud_verified"}
          },
          %{
            "name" => "policy-b",
            "action" => "pending",
            "match" => %{}
          }
        ],
        "reject"
      )
    end

    test "returns loaded policies and configured default_action" do
      result = Engine.list_policies()

      assert result.default_action == :reject
      assert length(result.policies) == 2

      [first, second] = result.policies
      assert %Policy{} = first
      assert first.name == "policy-a"
      assert first.action == :approve

      assert %Policy{} = second
      assert second.name == "policy-b"
      assert second.action == :pending
    end
  end

  describe "list_policies/0 with no policies but custom default_action" do
    setup do
      inject_approval_config([], "approve")
    end

    test "returns empty policy list with configured default_action" do
      result = Engine.list_policies()

      assert result.policies == []
      assert result.default_action == :approve
    end
  end
end
