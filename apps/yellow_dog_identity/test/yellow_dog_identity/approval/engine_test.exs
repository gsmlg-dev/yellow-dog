defmodule YellowDogIdentity.Approval.Engine.Test do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Approval.{Engine, Policy}
  alias YellowDogIdentity.Host

  @valid_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHUzjC6gKCLjRoHMvMXBx3cCe49wjm69r9B7YBcFcAv1 test@host"
  @valid_age_recipient "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"

  # Helper to build a Host struct with sensible defaults, overridable via attrs.
  # Uses Host.new/1 to get a valid id and key_fingerprint, then merges overrides.
  defp make_host(attrs \\ %{}) do
    hostname = Map.get(attrs, :hostname, "node-01.example.com")

    {:ok, host} =
      Host.new(%{
        hostname: hostname,
        ssh_pubkey: @valid_ssh_pubkey,
        age_recipient: @valid_age_recipient
      })

    host
    |> Map.merge(Map.drop(attrs, [:hostname]))
  end

  defp make_policy(attrs) do
    %Policy{
      name: Map.get(attrs, :name, "test-policy"),
      description: Map.get(attrs, :description),
      match: Map.get(attrs, :match, %{}),
      action: Map.get(attrs, :action, :approve)
    }
  end

  # ---------------------------------------------------------------------------
  # 1. No policies -> falls back to default action, auto: false
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 with no policies" do
    test "returns default action :pending when policy list is empty" do
      host = make_host()
      result = Engine.evaluate_with_policies(host, [], :pending)

      assert result == %{action: :pending, policy_name: nil, auto: false}
    end

    test "returns default action :approve when policy list is empty" do
      host = make_host()
      result = Engine.evaluate_with_policies(host, [], :approve)

      assert result == %{action: :approve, policy_name: nil, auto: false}
    end

    test "returns default action :reject when policy list is empty" do
      host = make_host()
      result = Engine.evaluate_with_policies(host, [], :reject)

      assert result == %{action: :reject, policy_name: nil, auto: false}
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Single matching policy -> returns that policy's action, auto: true
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 with a single matching policy" do
    test "returns :approve with policy name and auto: true" do
      policy = make_policy(%{name: "auto-approve", action: :approve, match: %{"trust_level" => "cloud_verified"}})
      host = make_host(%{trust_level: :cloud_verified, trust_provider: :aws})

      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
      assert result.policy_name == "auto-approve"
      assert result.auto == true
    end

    test "returns :reject with policy name and auto: true" do
      policy = make_policy(%{name: "block-unverified", action: :reject, match: %{"trust_level" => "unverified"}})
      host = make_host(%{trust_level: :unverified})

      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :reject
      assert result.policy_name == "block-unverified"
      assert result.auto == true
    end

    test "returns :pending with policy name and auto: true for pending action policy" do
      policy = make_policy(%{name: "manual-review", action: :pending, match: %{"trust_level" => "network_partial"}})
      host = make_host(%{trust_level: :network_partial})

      result = Engine.evaluate_with_policies(host, [policy], :approve)

      assert result.action == :pending
      assert result.policy_name == "manual-review"
      assert result.auto == true
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Multiple policies -> first match wins (priority order)
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 first-match-wins ordering" do
    test "first matching policy takes precedence over later ones" do
      policies = [
        make_policy(%{name: "first-approve", action: :approve, match: %{"trust_level" => "cloud_verified"}}),
        make_policy(%{name: "second-reject", action: :reject, match: %{"trust_level" => "cloud_verified"}})
      ]

      host = make_host(%{trust_level: :cloud_verified})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :approve
      assert result.policy_name == "first-approve"
    end

    test "skips non-matching policies and applies first matching one" do
      policies = [
        make_policy(%{name: "cloud-only", action: :approve, match: %{"trust_level" => "cloud_verified"}}),
        make_policy(%{name: "netboot-only", action: :reject, match: %{"trust_level" => "netboot_verified"}}),
        make_policy(%{name: "catch-remaining", action: :pending, match: %{"trust_level" => "unverified"}})
      ]

      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate_with_policies(host, policies, :reject)

      assert result.action == :pending
      assert result.policy_name == "catch-remaining"
    end

    test "when first policy matches, later policies are irrelevant" do
      policies = [
        make_policy(%{name: "reject-all-unverified", action: :reject, match: %{"trust_level" => "unverified"}}),
        make_policy(%{name: "approve-us-east", action: :approve, match: %{"datacenter" => "us-east-1"}})
      ]

      # Host is both unverified AND in us-east-1, but first policy wins
      host = make_host(%{trust_level: :unverified, datacenter: "us-east-1"})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :reject
      assert result.policy_name == "reject-all-unverified"
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Policy with no match conditions -> matches everything (empty match map)
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 with catch-all policy (empty match)" do
    test "policy with empty match map matches any host" do
      policy = make_policy(%{name: "catch-all", action: :approve, match: %{}})
      host = make_host(%{trust_level: :unverified, trust_provider: :none})

      result = Engine.evaluate_with_policies(host, [policy], :reject)

      assert result.action == :approve
      assert result.policy_name == "catch-all"
      assert result.auto == true
    end

    test "catch-all policy as last in chain catches everything" do
      policies = [
        make_policy(%{name: "cloud-approve", action: :approve, match: %{"trust_level" => "cloud_verified"}}),
        make_policy(%{name: "fallback", action: :pending, match: %{}})
      ]

      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate_with_policies(host, policies, :reject)

      # The catch-all should match, not the default
      assert result.action == :pending
      assert result.policy_name == "fallback"
      assert result.auto == true
    end
  end

  # ---------------------------------------------------------------------------
  # 5. Policy with hostname glob pattern (e.g., "web-*")
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 hostname glob patterns" do
    test "matches hostname prefix pattern web-*" do
      policy = make_policy(%{name: "web-approve", action: :approve, match: %{"hostname_pattern" => "web-*"}})
      host = make_host(%{hostname: "web-frontend-01"})

      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
      assert result.policy_name == "web-approve"
    end

    test "matches hostname suffix pattern *-prod" do
      policy = make_policy(%{name: "prod-approve", action: :approve, match: %{"hostname_pattern" => "*-prod"}})
      host = make_host(%{hostname: "api-service-prod"})

      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
    end

    test "matches hostname middle-wildcard pattern node-*-dc1" do
      policy = make_policy(%{name: "dc1-nodes", action: :approve, match: %{"hostname_pattern" => "node-*-dc1"}})
      host = make_host(%{hostname: "node-42-dc1"})

      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
    end

    test "does not match hostname when pattern does not fit" do
      policy = make_policy(%{name: "web-only", action: :approve, match: %{"hostname_pattern" => "web-*"}})
      host = make_host(%{hostname: "db-primary-01"})

      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :pending
      assert result.policy_name == nil
      assert result.auto == false
    end

    test "rejects temp hosts via hostname glob" do
      policy = make_policy(%{name: "reject-temp", action: :reject, match: %{"hostname_pattern" => "tmp-*"}})
      host = make_host(%{hostname: "tmp-debug-session"})

      result = Engine.evaluate_with_policies(host, [policy], :approve)

      assert result.action == :reject
      assert result.policy_name == "reject-temp"
    end

    test "matches hostname field with exact string (no glob)" do
      policy = make_policy(%{name: "exact-host", action: :approve, match: %{"hostname" => "specific-host.example.com"}})
      host = make_host(%{hostname: "specific-host.example.com"})

      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Policy with trust_level match
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 trust_level matching" do
    test "matches cloud_verified trust_level" do
      policy = make_policy(%{name: "cloud", action: :approve, match: %{"trust_level" => "cloud_verified"}})
      host = make_host(%{trust_level: :cloud_verified})

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "matches netboot_verified trust_level" do
      policy = make_policy(%{name: "netboot", action: :approve, match: %{"trust_level" => "netboot_verified"}})
      host = make_host(%{trust_level: :netboot_verified})

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "matches network_verified trust_level" do
      policy = make_policy(%{name: "network", action: :approve, match: %{"trust_level" => "network_verified"}})
      host = make_host(%{trust_level: :network_verified})

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "matches token_verified trust_level" do
      policy = make_policy(%{name: "token", action: :approve, match: %{"trust_level" => "token_verified"}})
      host = make_host(%{trust_level: :token_verified})

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "does not match when trust_level differs" do
      policy = make_policy(%{name: "cloud-only", action: :approve, match: %{"trust_level" => "cloud_verified"}})
      host = make_host(%{trust_level: :unverified})

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :pending
      assert result.policy_name == nil
    end
  end

  # ---------------------------------------------------------------------------
  # 7. Policy with multiple conditions (all must match)
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 multi-condition policies" do
    test "matches when all conditions are satisfied" do
      policy =
        make_policy(%{
          name: "cloud-web-us",
          action: :approve,
          match: %{
            "trust_level" => "cloud_verified",
            "datacenter" => "us-east-1",
            "role" => "web"
          }
        })

      host = make_host(%{trust_level: :cloud_verified, datacenter: "us-east-1", role: "web"})
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
      assert result.policy_name == "cloud-web-us"
    end

    test "does not match when one condition fails" do
      policy =
        make_policy(%{
          name: "cloud-web-us",
          action: :approve,
          match: %{
            "trust_level" => "cloud_verified",
            "datacenter" => "us-east-1",
            "role" => "web"
          }
        })

      # trust_level and datacenter match, but role is "db" not "web"
      host = make_host(%{trust_level: :cloud_verified, datacenter: "us-east-1", role: "db"})
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :pending
      assert result.policy_name == nil
    end

    test "does not match when a required field is nil on the host" do
      policy =
        make_policy(%{
          name: "needs-datacenter",
          action: :approve,
          match: %{"datacenter" => "us-east-1", "trust_level" => "cloud_verified"}
        })

      # datacenter is nil by default
      host = make_host(%{trust_level: :cloud_verified})
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :pending
      assert result.policy_name == nil
    end

    test "matches with trust_level and hostname glob combined" do
      policy =
        make_policy(%{
          name: "cloud-web-hosts",
          action: :approve,
          match: %{
            "trust_level" => "cloud_verified",
            "hostname_pattern" => "web-*"
          }
        })

      host = make_host(%{hostname: "web-frontend-03", trust_level: :cloud_verified})
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
    end

    test "fails multi-condition when glob does not match" do
      policy =
        make_policy(%{
          name: "cloud-web-hosts",
          action: :approve,
          match: %{
            "trust_level" => "cloud_verified",
            "hostname_pattern" => "web-*"
          }
        })

      host = make_host(%{hostname: "db-primary", trust_level: :cloud_verified})
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :pending
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Policy with list values (e.g., datacenter in ["us-east-1", "eu-west-1"])
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 list-valued match conditions" do
    test "matches when datacenter is in the allowed list" do
      policy =
        make_policy(%{
          name: "multi-dc",
          action: :approve,
          match: %{"datacenter" => ["us-east-1", "us-west-2", "eu-west-1"]}
        })

      host = make_host(%{datacenter: "us-east-1"})
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
    end

    test "matches second element in the list" do
      policy =
        make_policy(%{
          name: "multi-dc",
          action: :approve,
          match: %{"datacenter" => ["us-east-1", "eu-west-1"]}
        })

      host = make_host(%{datacenter: "eu-west-1"})
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
    end

    test "does not match when value is not in the list" do
      policy =
        make_policy(%{
          name: "multi-dc",
          action: :approve,
          match: %{"datacenter" => ["us-east-1", "eu-west-1"]}
        })

      host = make_host(%{datacenter: "ap-southeast-1"})
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :pending
      assert result.policy_name == nil
    end

    test "matches trust_level from a list of allowed levels" do
      policy =
        make_policy(%{
          name: "verified-only",
          action: :approve,
          match: %{"trust_level" => ["cloud_verified", "netboot_verified", "network_verified"]}
        })

      for level <- [:cloud_verified, :netboot_verified, :network_verified] do
        host = make_host(%{trust_level: level})
        result = Engine.evaluate_with_policies(host, [policy], :reject)

        assert result.action == :approve,
               "Expected :approve for trust_level #{level}, got #{result.action}"
      end
    end

    test "does not match unverified when list requires verified levels" do
      policy =
        make_policy(%{
          name: "verified-only",
          action: :approve,
          match: %{"trust_level" => ["cloud_verified", "netboot_verified"]}
        })

      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate_with_policies(host, [policy], :reject)

      assert result.action == :reject
    end

    test "list match combined with other conditions" do
      policy =
        make_policy(%{
          name: "verified-in-us",
          action: :approve,
          match: %{
            "trust_level" => ["cloud_verified", "netboot_verified"],
            "datacenter" => ["us-east-1", "us-west-2"]
          }
        })

      host = make_host(%{trust_level: :cloud_verified, datacenter: "us-west-2"})
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
    end
  end

  # ---------------------------------------------------------------------------
  # 9. No policy matches -> falls back to default
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 fallback to default when no match" do
    test "falls back to :pending default" do
      policies = [
        make_policy(%{name: "cloud-only", action: :approve, match: %{"trust_level" => "cloud_verified"}})
      ]

      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result == %{action: :pending, policy_name: nil, auto: false}
    end

    test "falls back to :reject default" do
      policies = [
        make_policy(%{name: "cloud-only", action: :approve, match: %{"trust_level" => "cloud_verified"}})
      ]

      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate_with_policies(host, policies, :reject)

      assert result == %{action: :reject, policy_name: nil, auto: false}
    end

    test "falls back to :approve default" do
      policies = [
        make_policy(%{name: "reject-temp", action: :reject, match: %{"hostname_pattern" => "tmp-*"}})
      ]

      host = make_host(%{hostname: "prod-server-01"})
      result = Engine.evaluate_with_policies(host, policies, :approve)

      assert result == %{action: :approve, policy_name: nil, auto: false}
    end

    test "multiple non-matching policies all fall through to default" do
      policies = [
        make_policy(%{name: "cloud-aws", action: :approve, match: %{"trust_provider" => "aws"}}),
        make_policy(%{name: "cloud-gcp", action: :approve, match: %{"trust_provider" => "gcp"}}),
        make_policy(%{name: "cloud-azure", action: :approve, match: %{"trust_provider" => "azure"}})
      ]

      host = make_host(%{trust_provider: :dhcp})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result == %{action: :pending, policy_name: nil, auto: false}
    end
  end

  # ---------------------------------------------------------------------------
  # 10. Different default actions (:approve, :reject, :pending)
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 default_action parameter" do
    test "default :approve with empty policies" do
      result = Engine.evaluate_with_policies(make_host(), [], :approve)
      assert result.action == :approve
      assert result.auto == false
    end

    test "default :reject with empty policies" do
      result = Engine.evaluate_with_policies(make_host(), [], :reject)
      assert result.action == :reject
      assert result.auto == false
    end

    test "default :pending with empty policies" do
      result = Engine.evaluate_with_policies(make_host(), [], :pending)
      assert result.action == :pending
      assert result.auto == false
    end

    test "default action is irrelevant when a policy matches" do
      policy = make_policy(%{name: "approve-all", action: :approve, match: %{}})

      for default <- [:approve, :reject, :pending] do
        result = Engine.evaluate_with_policies(make_host(), [policy], default)
        assert result.action == :approve
        assert result.auto == true
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 11. Trust result map merges into context
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 trust_result merging" do
    test "trust_result fields are available for policy matching" do
      policy =
        make_policy(%{
          name: "verified-attestation",
          action: :approve,
          match: %{"attestation_valid" => "true"}
        })

      host = make_host()
      trust_result = %{"attestation_valid" => "true", "verified_at" => "2026-02-26T12:00:00Z"}

      result = Engine.evaluate_with_policies(host, [policy], :pending, trust_result)

      assert result.action == :approve
      assert result.policy_name == "verified-attestation"
    end

    test "trust_result overrides context fields from host" do
      # build_context sets "trust_level" from host, but trust_result can override it
      policy =
        make_policy(%{
          name: "override-trust",
          action: :approve,
          match: %{"trust_level" => "cloud_verified"}
        })

      # Host has :unverified, but trust_result overrides
      host = make_host(%{trust_level: :unverified})
      trust_result = %{"trust_level" => "cloud_verified"}

      result = Engine.evaluate_with_policies(host, [policy], :pending, trust_result)

      assert result.action == :approve
    end

    test "trust_result with custom fields for matching" do
      policy =
        make_policy(%{
          name: "custom-field",
          action: :approve,
          match: %{"attestation_type" => "tpm2"}
        })

      host = make_host()
      trust_result = %{"attestation_type" => "tpm2"}

      result = Engine.evaluate_with_policies(host, [policy], :pending, trust_result)

      assert result.action == :approve
    end

    test "default trust_result is empty map" do
      policy = make_policy(%{name: "catch-all", action: :approve, match: %{}})
      host = make_host()

      # Calling without explicit trust_result (default param)
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
    end
  end

  # ---------------------------------------------------------------------------
  # 12. trust_evidence fields extracted into context
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 trust_evidence context extraction" do
    test "extracts cloud_account from trust_evidence account_id (string key)" do
      policy =
        make_policy(%{
          name: "aws-prod",
          action: :approve,
          match: %{"cloud_account" => "123456789012"}
        })

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :aws,
          trust_evidence: %{"account_id" => "123456789012", "region" => "us-east-1"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
      assert result.policy_name == "aws-prod"
    end

    test "extracts cloud_account from trust_evidence account_id (atom key)" do
      policy = make_policy(%{name: "aws-atom", action: :approve, match: %{"cloud_account" => "111222333444"}})

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :aws,
          trust_evidence: %{account_id: "111222333444"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "extracts cloud_account from GCP project_id (string key)" do
      policy = make_policy(%{name: "gcp-project", action: :approve, match: %{"cloud_account" => "my-gcp-project"}})

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :gcp,
          trust_evidence: %{"project_id" => "my-gcp-project"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "extracts cloud_account from GCP project_id (atom key)" do
      policy = make_policy(%{name: "gcp-atom", action: :approve, match: %{"cloud_account" => "staging-project"}})

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :gcp,
          trust_evidence: %{project_id: "staging-project"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "extracts cloud_account from Azure subscription_id" do
      policy = make_policy(%{name: "azure-sub", action: :approve, match: %{"cloud_account" => "sub-abc-123"}})

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :azure,
          trust_evidence: %{"subscription_id" => "sub-abc-123"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "extracts cloud_region from region (string key)" do
      policy = make_policy(%{name: "us-east", action: :approve, match: %{"cloud_region" => "us-east-1"}})

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{"region" => "us-east-1"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "extracts cloud_region from region (atom key)" do
      policy = make_policy(%{name: "us-west", action: :approve, match: %{"cloud_region" => "us-west-2"}})

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{region: "us-west-2"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "extracts cloud_region from GCP zone" do
      policy = make_policy(%{name: "gcp-zone", action: :approve, match: %{"cloud_region" => "us-central1-a"}})

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :gcp,
          trust_evidence: %{"zone" => "us-central1-a"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "extracts cloud_region from Azure location" do
      policy = make_policy(%{name: "azure-loc", action: :approve, match: %{"cloud_region" => "westeurope"}})

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :azure,
          trust_evidence: %{"location" => "westeurope"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "extracts mac_prefix from trust_evidence mac (string key, 8+ chars)" do
      policy = make_policy(%{name: "mac-vendor", action: :approve, match: %{"mac_prefix" => "00:1A:2B"}})

      host =
        make_host(%{
          trust_level: :network_verified,
          trust_provider: :dhcp,
          trust_evidence: %{"mac" => "00:1A:2B:3C:4D:5E"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "extracts mac_prefix from trust_evidence mac (atom key)" do
      policy = make_policy(%{name: "mac-atom", action: :approve, match: %{"mac_prefix" => "AA:BB:CC"}})

      host =
        make_host(%{
          trust_level: :network_verified,
          trust_provider: :dhcp,
          trust_evidence: %{mac: "AA:BB:CC:DD:EE:FF"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "mac_prefix is nil when mac is too short" do
      policy = make_policy(%{name: "mac-short", action: :approve, match: %{"mac_prefix" => "AA:BB"}})

      host =
        make_host(%{
          trust_level: :network_verified,
          trust_provider: :dhcp,
          trust_evidence: %{"mac" => "AA:BB"}
        })

      # MAC "AA:BB" is only 5 chars, < 8, so mac_prefix will be nil
      # nil actual vs "AA:BB" expected => no match
      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :pending
      assert result.policy_name == nil
    end

    test "extracts cloud_image from trust_evidence image_id" do
      policy = make_policy(%{name: "ami-check", action: :approve, match: %{"cloud_image" => "ami-0abc123"}})

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :aws,
          trust_evidence: %{"image_id" => "ami-0abc123"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "extracts cloud_image from trust_evidence image_id (atom key)" do
      policy = make_policy(%{name: "ami-atom", action: :approve, match: %{"cloud_image" => "ami-xyz999"}})

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :aws,
          trust_evidence: %{image_id: "ami-xyz999"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "extracts fingerprint_class from trust_evidence" do
      policy = make_policy(%{name: "linux-only", action: :approve, match: %{"fingerprint_class" => "Linux"}})

      host =
        make_host(%{
          trust_level: :network_verified,
          trust_provider: :dhcp,
          trust_evidence: %{"fingerprint_class" => "Linux"}
        })

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "nil trust_evidence produces nil context fields without crashing" do
      policy = make_policy(%{name: "cloud-check", action: :approve, match: %{"cloud_account" => "12345"}})

      host = make_host(%{trust_evidence: nil})
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :pending
      assert result.policy_name == nil
    end

    test "empty trust_evidence map produces nil context fields" do
      policy = make_policy(%{name: "cloud-check", action: :approve, match: %{"cloud_account" => "12345"}})

      host = make_host(%{trust_evidence: %{}})
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :pending
    end
  end

  # ---------------------------------------------------------------------------
  # Additional: trust_provider matching
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 trust_provider matching" do
    test "matches on trust_provider field" do
      policy = make_policy(%{name: "aws-only", action: :approve, match: %{"trust_provider" => "aws"}})
      host = make_host(%{trust_provider: :aws})

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "matches trust_provider from list" do
      policy =
        make_policy(%{
          name: "cloud-providers",
          action: :approve,
          match: %{"trust_provider" => ["aws", "gcp", "azure"]}
        })

      host = make_host(%{trust_provider: :gcp})
      result = Engine.evaluate_with_policies(host, [policy], :pending)

      assert result.action == :approve
    end

    test "does not match when trust_provider differs" do
      policy = make_policy(%{name: "aws-only", action: :approve, match: %{"trust_provider" => "aws"}})
      host = make_host(%{trust_provider: :dhcp})

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :pending
    end
  end

  # ---------------------------------------------------------------------------
  # Additional: role and datacenter matching
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 role and datacenter matching" do
    test "matches on role field" do
      policy = make_policy(%{name: "web-role", action: :approve, match: %{"role" => "web"}})
      host = make_host(%{role: "web"})

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "matches on datacenter field" do
      policy = make_policy(%{name: "us-east", action: :approve, match: %{"datacenter" => "us-east-1"}})
      host = make_host(%{datacenter: "us-east-1"})

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :approve
    end

    test "nil role does not match a non-nil expected role" do
      policy = make_policy(%{name: "needs-role", action: :approve, match: %{"role" => "web"}})
      host = make_host()

      result = Engine.evaluate_with_policies(host, [policy], :pending)
      assert result.action == :pending
    end
  end

  # ---------------------------------------------------------------------------
  # Additional: evaluate/2 without config
  # ---------------------------------------------------------------------------
  describe "evaluate/2 without config" do
    test "returns pending with no policy when YellowDog.Config is unavailable" do
      host = make_host()
      result = Engine.evaluate(host)

      assert result == %{action: :pending, policy_name: nil, auto: false}
    end

    test "evaluate/2 with explicit trust_result and no config" do
      host = make_host()
      result = Engine.evaluate(host, %{"custom_field" => "value"})

      assert result == %{action: :pending, policy_name: nil, auto: false}
    end
  end

  # ---------------------------------------------------------------------------
  # Additional: list_policies/0
  # ---------------------------------------------------------------------------
  describe "list_policies/0" do
    test "returns empty policies and pending default when no config available" do
      result = Engine.list_policies()

      assert result == %{policies: [], default_action: :pending}
    end
  end

  # ---------------------------------------------------------------------------
  # Additional: complex real-world policy chains
  # ---------------------------------------------------------------------------
  describe "evaluate_with_policies/4 realistic multi-policy chains" do
    test "tiered approval: cloud auto-approve, netboot review, rest reject" do
      policies = [
        make_policy(%{name: "cloud-auto", action: :approve, match: %{"trust_level" => "cloud_verified"}}),
        make_policy(%{name: "netboot-review", action: :pending, match: %{"trust_level" => "netboot_verified"}}),
        make_policy(%{name: "reject-rest", action: :reject, match: %{}})
      ]

      # Cloud host -> auto-approve
      cloud_host = make_host(%{trust_level: :cloud_verified, trust_provider: :aws})
      assert %{action: :approve, policy_name: "cloud-auto", auto: true} =
               Engine.evaluate_with_policies(cloud_host, policies, :pending)

      # Netboot host -> pending review
      netboot_host = make_host(%{trust_level: :netboot_verified, trust_provider: :netboot})
      assert %{action: :pending, policy_name: "netboot-review", auto: true} =
               Engine.evaluate_with_policies(netboot_host, policies, :pending)

      # Unknown host -> caught by catch-all reject
      unknown_host = make_host(%{trust_level: :unverified, trust_provider: :none})
      assert %{action: :reject, policy_name: "reject-rest", auto: true} =
               Engine.evaluate_with_policies(unknown_host, policies, :pending)
    end

    test "environment-based policy: auto-approve production cloud, reject staging temp hosts" do
      policies = [
        make_policy(%{
          name: "prod-cloud",
          action: :approve,
          match: %{"trust_level" => "cloud_verified", "datacenter" => ["us-east-1", "us-west-2"]}
        }),
        make_policy(%{
          name: "reject-staging-tmp",
          action: :reject,
          match: %{"hostname_pattern" => "tmp-*", "datacenter" => "staging"}
        })
      ]

      # Prod cloud host in us-east-1 -> approve
      prod_host = make_host(%{trust_level: :cloud_verified, datacenter: "us-east-1"})
      assert %{action: :approve, policy_name: "prod-cloud"} =
               Engine.evaluate_with_policies(prod_host, policies, :pending)

      # Staging temp host -> reject
      tmp_host = make_host(%{hostname: "tmp-debug-session", datacenter: "staging"})
      assert %{action: :reject, policy_name: "reject-staging-tmp"} =
               Engine.evaluate_with_policies(tmp_host, policies, :pending)

      # Unmatched host -> falls through to default
      other_host = make_host(%{trust_level: :unverified, datacenter: "dev"})
      assert %{action: :pending, policy_name: nil, auto: false} =
               Engine.evaluate_with_policies(other_host, policies, :pending)
    end

    test "account-scoped approval with cloud provider list" do
      policies = [
        make_policy(%{
          name: "approved-accounts",
          action: :approve,
          match: %{
            "cloud_account" => ["123456789012", "my-gcp-project", "azure-sub-001"],
            "trust_level" => ["cloud_verified"]
          }
        })
      ]

      aws_host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :aws,
          trust_evidence: %{"account_id" => "123456789012"}
        })

      assert %{action: :approve} = Engine.evaluate_with_policies(aws_host, policies, :reject)

      # Wrong account -> falls to default reject
      wrong_acct =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :aws,
          trust_evidence: %{"account_id" => "999999999999"}
        })

      assert %{action: :reject, policy_name: nil} =
               Engine.evaluate_with_policies(wrong_acct, policies, :reject)
    end
  end
end
