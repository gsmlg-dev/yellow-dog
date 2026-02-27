defmodule YellowDogIdentity.Approval.PolicyTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Approval.Policy

  describe "from_config/1" do
    test "parses list of TOML policy maps into Policy structs" do
      config = [
        %{
          "name" => "auto-approve-cloud",
          "description" => "Auto-approve cloud-verified hosts",
          "action" => "approve",
          "match" => %{"trust_level" => "cloud_verified"}
        },
        %{
          "name" => "reject-temp",
          "action" => "reject",
          "match" => %{"hostname" => "tmp-*"}
        }
      ]

      policies = Policy.from_config(config)

      assert length(policies) == 2

      [first, second] = policies
      assert %Policy{} = first
      assert first.name == "auto-approve-cloud"
      assert first.description == "Auto-approve cloud-verified hosts"
      assert first.action == :approve
      assert first.match == %{"trust_level" => "cloud_verified"}

      assert second.name == "reject-temp"
      assert second.action == :reject
    end

    test "handles empty list" do
      assert Policy.from_config([]) == []
    end

    test "handles non-list input and returns empty list" do
      assert Policy.from_config(nil) == []
      assert Policy.from_config("not a list") == []
      assert Policy.from_config(%{}) == []
      assert Policy.from_config(42) == []
    end

    test "parses all valid actions correctly" do
      for action_str <- ~w(approve reject pending) do
        config = [%{"name" => "test", "action" => action_str}]
        [policy] = Policy.from_config(config)
        assert policy.action == String.to_existing_atom(action_str)
      end
    end

    test "defaults to unnamed when name is missing" do
      config = [%{"action" => "approve"}]
      [policy] = Policy.from_config(config)

      assert policy.name == "unnamed"
    end

    test "defaults to :pending for invalid action" do
      config = [%{"name" => "bad-action", "action" => "destroy"}]
      [policy] = Policy.from_config(config)

      assert policy.action == :pending
    end

    test "parses match criteria from nested map" do
      config = [
        %{
          "name" => "multi-match",
          "action" => "approve",
          "match" => %{
            "trust_level" => "cloud_verified",
            "cloud_account" => "123456789012",
            "region" => ["us-east-1", "us-west-2"]
          }
        }
      ]

      [policy] = Policy.from_config(config)

      assert policy.match == %{
               "trust_level" => "cloud_verified",
               "cloud_account" => "123456789012",
               "region" => ["us-east-1", "us-west-2"]
             }
    end
  end

  describe "matches?/2" do
    test "empty match matches everything" do
      policy = %Policy{name: "catch-all", action: :approve, match: %{}}
      assert Policy.matches?(policy, %{"hostname" => "anything", "trust_level" => "unverified"})
      assert Policy.matches?(policy, %{})
    end

    test "exact string match" do
      policy = %Policy{name: "exact", action: :approve, match: %{"hostname" => "node-01"}}

      assert Policy.matches?(policy, %{"hostname" => "node-01"})
      refute Policy.matches?(policy, %{"hostname" => "node-02"})
    end

    test "list match - actual value in expected list" do
      policy = %Policy{
        name: "region-list",
        action: :approve,
        match: %{"region" => ["us-east-1", "us-west-2", "eu-west-1"]}
      }

      assert Policy.matches?(policy, %{"region" => "us-east-1"})
      assert Policy.matches?(policy, %{"region" => "eu-west-1"})
      refute Policy.matches?(policy, %{"region" => "ap-southeast-1"})
    end

    test "glob pattern with * wildcard as prefix match" do
      policy = %Policy{name: "prefix", action: :approve, match: %{"hostname" => "ws-*"}}

      assert Policy.matches?(policy, %{"hostname" => "ws-001"})
      assert Policy.matches?(policy, %{"hostname" => "ws-prod-node"})
      refute Policy.matches?(policy, %{"hostname" => "db-001"})
    end

    test "glob pattern with * wildcard as suffix match" do
      policy = %Policy{name: "suffix", action: :approve, match: %{"hostname" => "*-prod"}}

      assert Policy.matches?(policy, %{"hostname" => "api-prod"})
      assert Policy.matches?(policy, %{"hostname" => "web-service-prod"})
      refute Policy.matches?(policy, %{"hostname" => "api-staging"})
    end

    test "glob pattern with * in middle" do
      policy = %Policy{name: "middle", action: :approve, match: %{"hostname" => "node-*-dc1"}}

      assert Policy.matches?(policy, %{"hostname" => "node-42-dc1"})
      assert Policy.matches?(policy, %{"hostname" => "node-web-api-dc1"})
      refute Policy.matches?(policy, %{"hostname" => "node-42-dc2"})
    end

    test "no match returns false" do
      policy = %Policy{
        name: "specific",
        action: :approve,
        match: %{"trust_level" => "cloud_verified"}
      }

      refute Policy.matches?(policy, %{"trust_level" => "unverified"})
    end

    test "consecutive wildcards (**) skip empty segments in glob matching" do
      # "node-**-dc1" splits on * → ["node-", "", "-dc1"]
      # glob_match_rest skips the empty "" segment via ["" | rest] clause, then checks suffix "-dc1"
      policy = %Policy{name: "double-wild", action: :approve, match: %{"hostname" => "node-**-dc1"}}
      assert Policy.matches?(policy, %{"hostname" => "node-web-dc1"})
      assert Policy.matches?(policy, %{"hostname" => "node-api-server-dc1"})
      refute Policy.matches?(policy, %{"hostname" => "node-web-dc2"})
    end

    test "nil actual value does not match expected" do
      policy = %Policy{
        name: "requires-field",
        action: :approve,
        match: %{"cloud_account" => "123456789012"}
      }

      refute Policy.matches?(policy, %{"cloud_account" => nil})
      refute Policy.matches?(policy, %{})
    end

    test "atom actual value matches string expected via to_string" do
      policy = %Policy{
        name: "atom-match",
        action: :approve,
        match: %{"trust_level" => "cloud_verified"}
      }

      assert Policy.matches?(policy, %{"trust_level" => :cloud_verified})
    end

    test "multi-field match requires all fields to match" do
      policy = %Policy{
        name: "multi",
        action: :approve,
        match: %{
          "trust_level" => "cloud_verified",
          "hostname" => "ws-*"
        }
      }

      assert Policy.matches?(policy, %{"trust_level" => "cloud_verified", "hostname" => "ws-001"})
    end

    test "multi-field match fails if one field does not match" do
      policy = %Policy{
        name: "multi",
        action: :approve,
        match: %{
          "trust_level" => "cloud_verified",
          "hostname" => "ws-*"
        }
      }

      refute Policy.matches?(policy, %{
               "trust_level" => "unverified",
               "hostname" => "ws-001"
             })

      refute Policy.matches?(policy, %{
               "trust_level" => "cloud_verified",
               "hostname" => "db-001"
             })
    end

    test "nil expected value matches anything (wildcard field)" do
      policy = %Policy{
        name: "nil-expected",
        action: :approve,
        match: %{"hostname" => nil}
      }

      assert Policy.matches?(policy, %{"hostname" => "anything"})
      assert Policy.matches?(policy, %{})
    end

    test "integer actual matches string expected via to_string" do
      policy = %Policy{
        name: "int-match",
        action: :approve,
        match: %{"port" => "8080"}
      }

      assert Policy.matches?(policy, %{"port" => 8080})
    end

    test "match field as atom key looks up atom key in context" do
      # When match keys are atoms (e.g., built programmatically), Map.get finds atom keys
      # and the to_string fallback finds string keys
      policy = %Policy{
        name: "atom-key",
        action: :approve,
        match: %{trust_level: "cloud_verified"}
      }

      # Atom key in context matches atom key in match
      assert Policy.matches?(policy, %{trust_level: "cloud_verified"})
      # String key in context found via to_string fallback
      assert Policy.matches?(policy, %{"trust_level" => "cloud_verified"})
    end
  end
end
