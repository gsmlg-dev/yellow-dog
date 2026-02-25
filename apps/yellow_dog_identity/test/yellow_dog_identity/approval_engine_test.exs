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

  describe "build_context — cloud_region extraction" do
    test "extracts cloud_region from string-keyed region field" do
      policies = [
        %Policy{name: "us-only", action: :approve, match: %{"cloud_region" => "us-east-1"}}
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{"region" => "us-east-1"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end

    test "extracts cloud_region from atom-keyed region field" do
      policies = [
        %Policy{name: "us-only", action: :approve, match: %{"cloud_region" => "us-west-2"}}
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{region: "us-west-2"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end

    test "extracts cloud_region from zone field as fallback" do
      policies = [
        %Policy{
          name: "gcp-zone",
          action: :approve,
          match: %{"cloud_region" => "us-central1-a"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{"zone" => "us-central1-a"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end

    test "no match when evidence is nil" do
      policies = [
        %Policy{name: "us-only", action: :approve, match: %{"cloud_region" => "us-east-1"}}
      ]

      host = make_host(%{trust_level: :cloud_verified, trust_evidence: nil})
      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :pending
    end
  end

  describe "build_context — cloud_image extraction" do
    test "extracts cloud_image from image_id field" do
      policies = [
        %Policy{
          name: "approved-image",
          action: :approve,
          match: %{"cloud_image" => "ami-0abc123456"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{"image_id" => "ami-0abc123456"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end

    test "extracts cloud_image from atom-keyed image_id" do
      policies = [
        %Policy{
          name: "approved-image",
          action: :approve,
          match: %{"cloud_image" => "ami-atom123"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{image_id: "ami-atom123"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end
  end

  describe "build_context — mac_prefix extraction" do
    test "extracts first 8 chars of MAC as prefix" do
      policies = [
        %Policy{
          name: "apple-devices",
          action: :approve,
          match: %{"mac_prefix" => "aa:bb:cc"}
        }
      ]

      host =
        make_host(%{
          trust_evidence: %{"mac" => "aa:bb:cc:dd:ee:ff"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end

    test "returns nil mac_prefix when MAC is shorter than 8 chars" do
      policies = [
        %Policy{
          name: "mac-match",
          action: :approve,
          match: %{"mac_prefix" => "aa:bb:c"}
        }
      ]

      host = make_host(%{trust_evidence: %{"mac" => "aa:bb:c"}})
      result = Engine.evaluate_with_policies(host, policies, :pending)
      # mac shorter than 8 chars → mac_prefix is nil → no match
      assert result.action == :pending
    end

    test "returns nil mac_prefix when evidence is nil" do
      policies = [
        %Policy{name: "mac-match", action: :approve, match: %{"mac_prefix" => "aa:bb:cc"}}
      ]

      host = make_host(%{trust_evidence: nil})
      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :pending
    end
  end

  describe "build_context — trust_result merge" do
    test "trust_result values override default context keys" do
      policies = [
        %Policy{
          name: "custom-field",
          action: :approve,
          match: %{"custom_key" => "custom_value"}
        }
      ]

      host = make_host()
      result = Engine.evaluate_with_policies(host, policies, :pending, %{"custom_key" => "custom_value"})
      assert result.action == :approve
      assert result.policy_name == "custom-field"
    end

    test "trust_result can override trust_level for evaluation" do
      policies = [
        %Policy{
          name: "override-trust",
          action: :approve,
          match: %{"trust_level" => "cloud_verified"}
        }
      ]

      # Host has unverified trust_level
      host = make_host(%{trust_level: :unverified})
      # But trust_result overrides it
      result =
        Engine.evaluate_with_policies(host, policies, :pending, %{
          "trust_level" => "cloud_verified"
        })

      assert result.action == :approve
    end
  end

  describe "policy ordering — first match wins" do
    test "first matching policy wins even if later policy also matches" do
      policies = [
        %Policy{name: "first", action: :approve, match: %{"trust_level" => "cloud_verified"}},
        %Policy{name: "second", action: :reject, match: %{"trust_level" => "cloud_verified"}}
      ]

      host = make_host(%{trust_level: :cloud_verified})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :approve
      assert result.policy_name == "first"
    end

    test "skips non-matching policies to find the first match" do
      policies = [
        %Policy{
          name: "cloud-only",
          action: :approve,
          match: %{"trust_level" => "cloud_verified"}
        },
        %Policy{
          name: "network-verified",
          action: :approve,
          match: %{"trust_level" => "network_verified"}
        },
        %Policy{name: "catch-all", action: :reject, match: %{"trust_level" => "unverified"}}
      ]

      host = make_host(%{trust_level: :network_verified})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :approve
      assert result.policy_name == "network-verified"
    end
  end

  describe "list match — value in list" do
    test "matches when trust_level is in a list of allowed values" do
      policies = [
        %Policy{
          name: "multi-trust",
          action: :approve,
          match: %{
            "trust_level" => ["cloud_verified", "network_verified", "netboot_verified"]
          }
        }
      ]

      host = make_host(%{trust_level: :network_verified})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :approve
    end

    test "does not match when value is not in list" do
      policies = [
        %Policy{
          name: "trusted-only",
          action: :approve,
          match: %{"trust_level" => ["cloud_verified", "network_verified"]}
        }
      ]

      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :pending
    end

    test "matches role in a list" do
      policies = [
        %Policy{
          name: "allowed-roles",
          action: :approve,
          match: %{"role" => ["worker", "storage", "compute"]}
        }
      ]

      host = make_host(%{role: "storage"})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :approve
    end
  end

  describe "multi-condition AND logic" do
    test "all conditions must match for policy to apply" do
      policies = [
        %Policy{
          name: "strict-cloud",
          action: :approve,
          match: %{
            "trust_level" => "cloud_verified",
            "cloud_account" => "123456789012",
            "cloud_region" => "us-east-1"
          }
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{
            "account_id" => "123456789012",
            "region" => "us-east-1"
          }
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end

    test "fails if one condition doesn't match" do
      policies = [
        %Policy{
          name: "strict-cloud",
          action: :approve,
          match: %{
            "trust_level" => "cloud_verified",
            "cloud_account" => "123456789012",
            "cloud_region" => "us-east-1"
          }
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{
            "account_id" => "123456789012",
            "region" => "eu-west-1"
          }
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :pending
    end

    test "datacenter + hostname_pattern combined" do
      policies = [
        %Policy{
          name: "dc1-workers",
          action: :approve,
          match: %{"datacenter" => "dc1", "hostname_pattern" => "ws-*"}
        }
      ]

      host = make_host(%{hostname: "ws-42", datacenter: "dc1"})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :approve
    end

    test "datacenter + hostname_pattern fails if hostname doesn't match" do
      policies = [
        %Policy{
          name: "dc1-workers",
          action: :approve,
          match: %{"datacenter" => "dc1", "hostname_pattern" => "ws-*"}
        }
      ]

      host = make_host(%{hostname: "db-01", datacenter: "dc1"})
      result = Engine.evaluate_with_policies(host, policies, :pending)

      assert result.action == :pending
    end
  end

  describe "empty match — matches everything" do
    test "policy with empty match map matches any host" do
      policies = [
        %Policy{name: "accept-all", action: :approve, match: %{}}
      ]

      host = make_host(%{trust_level: :unverified})
      result = Engine.evaluate_with_policies(host, policies, :reject)

      assert result.action == :approve
      assert result.policy_name == "accept-all"
    end
  end

  describe "build_context — Azure cloud_account (subscription_id)" do
    test "matches Azure subscription_id from trust_evidence" do
      policies = [
        %Policy{
          name: "azure-sub",
          action: :approve,
          match: %{"cloud_account" => "sub-12345"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{"subscription_id" => "sub-12345"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
      assert result.policy_name == "azure-sub"
    end

    test "prefers account_id over subscription_id when both present" do
      policies = [
        %Policy{
          name: "account-id-wins",
          action: :approve,
          match: %{"cloud_account" => "aws-account-999"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{
            "account_id" => "aws-account-999",
            "subscription_id" => "azure-sub-ignored"
          }
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end
  end

  describe "build_context — Azure cloud_region (location)" do
    test "matches Azure location field as cloud_region fallback" do
      policies = [
        %Policy{
          name: "azure-region",
          action: :approve,
          match: %{"cloud_region" => "westus2"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{"location" => "westus2"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
      assert result.policy_name == "azure-region"
    end

    test "prefers region over location when both present" do
      policies = [
        %Policy{
          name: "region-wins",
          action: :approve,
          match: %{"cloud_region" => "us-east-1"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{
            "region" => "us-east-1",
            "location" => "eastus"
          }
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end

    test "prefers zone over location when region absent" do
      policies = [
        %Policy{
          name: "zone-before-location",
          action: :approve,
          match: %{"cloud_region" => "us-central1-a"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{
            "zone" => "us-central1-a",
            "location" => "eastus"
          }
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end
  end
end
