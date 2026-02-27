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

    test "extracts mac_prefix from atom-keyed :mac field in evidence" do
      policies = [
        %Policy{name: "apple-atom", action: :approve, match: %{"mac_prefix" => "aa:bb:cc"}}
      ]

      host = make_host(%{trust_evidence: %{mac: "aa:bb:cc:dd:ee:ff"}})
      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
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

    test "matches Azure subscription_id from atom-keyed trust_evidence" do
      policies = [
        %Policy{
          name: "azure-sub-atom",
          action: :approve,
          match: %{"cloud_account" => "atom-sub-99"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{subscription_id: "atom-sub-99"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
      assert result.policy_name == "azure-sub-atom"
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

    test "matches Azure location from atom-keyed trust_evidence" do
      policies = [
        %Policy{
          name: "azure-location-atom",
          action: :approve,
          match: %{"cloud_region" => "northeurope"}
        }
      ]

      host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_evidence: %{location: "northeurope"}
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
      assert result.policy_name == "azure-location-atom"
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

  describe "netboot trust evidence matching" do
    test "approves netboot_verified host based on trust_level" do
      policies = [
        %Policy{
          name: "netboot-auto",
          action: :approve,
          match: %{"trust_level" => "netboot_verified"}
        }
      ]

      host =
        make_host(%{
          trust_level: :netboot_verified,
          trust_provider: :netboot,
          trust_evidence: %{
            "provider" => "netboot",
            "mac" => "aa:bb:cc:dd:ee:ff",
            "boot_profile" => "prod-nixos",
            "boot_state" => "booted"
          }
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
      assert result.policy_name == "netboot-auto"
    end

    test "matches on fingerprint_class from netboot evidence" do
      policies = [
        %Policy{
          name: "nixos-workstations",
          action: :approve,
          match: %{"fingerprint_class" => "nixos-workstation"}
        }
      ]

      host =
        make_host(%{
          trust_level: :netboot_verified,
          trust_evidence: %{
            "provider" => "netboot",
            "fingerprint_class" => "nixos-workstation"
          }
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
      assert result.policy_name == "nixos-workstations"
    end

    test "matches fingerprint_class from atom-keyed evidence (get_in_evidence atom fallback)" do
      # Atom key :fingerprint_class instead of string "fingerprint_class"
      # get_in_evidence tries string key first, then String.to_existing_atom fallback
      policies = [
        %Policy{
          name: "nixos-atom-key",
          action: :approve,
          match: %{"fingerprint_class" => "nixos-workstation"}
        }
      ]

      host =
        make_host(%{
          trust_level: :netboot_verified,
          trust_evidence: %{
            provider: :netboot,
            fingerprint_class: "nixos-workstation"
          }
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
      assert result.policy_name == "nixos-atom-key"
    end

    test "matches mac_prefix from netboot evidence" do
      policies = [
        %Policy{
          name: "vendor-policy",
          action: :approve,
          match: %{"mac_prefix" => "aa:bb:cc"}
        }
      ]

      host =
        make_host(%{
          trust_level: :netboot_verified,
          trust_evidence: %{
            "provider" => "netboot",
            "mac" => "aa:bb:cc:dd:ee:ff"
          }
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
    end

    test "multi-condition: trust_level + fingerprint_class for netboot" do
      policies = [
        %Policy{
          name: "netboot-nixos-prod",
          action: :approve,
          match: %{
            "trust_level" => "netboot_verified",
            "fingerprint_class" => "nixos-server"
          }
        }
      ]

      host_match =
        make_host(%{
          trust_level: :netboot_verified,
          trust_evidence: %{"fingerprint_class" => "nixos-server"}
        })

      host_no_match =
        make_host(%{
          trust_level: :netboot_verified,
          trust_evidence: %{"fingerprint_class" => "ubuntu-server"}
        })

      assert Engine.evaluate_with_policies(host_match, policies, :pending).action == :approve
      assert Engine.evaluate_with_policies(host_no_match, policies, :pending).action == :pending
    end
  end

  describe "token trust evidence matching" do
    test "approves token_verified host based on trust_level" do
      policies = [
        %Policy{
          name: "token-auto",
          action: :approve,
          match: %{"trust_level" => "token_verified"}
        }
      ]

      host =
        make_host(%{
          trust_level: :token_verified,
          trust_provider: :token,
          trust_evidence: %{
            "provider" => "token",
            "token_id" => "abc-123",
            "role" => "worker"
          }
        })

      result = Engine.evaluate_with_policies(host, policies, :pending)
      assert result.action == :approve
      assert result.policy_name == "token-auto"
    end

    test "multi-condition: token_verified + role for provisioning" do
      policies = [
        %Policy{
          name: "worker-token-auto",
          action: :approve,
          match: %{
            "trust_level" => "token_verified",
            "role" => "worker"
          }
        }
      ]

      host_worker =
        make_host(%{
          trust_level: :token_verified,
          role: "worker"
        })

      host_admin =
        make_host(%{
          trust_level: :token_verified,
          role: "admin"
        })

      assert Engine.evaluate_with_policies(host_worker, policies, :pending).action == :approve
      assert Engine.evaluate_with_policies(host_admin, policies, :pending).action == :pending
    end
  end

  describe "trust_provider matching in policies" do
    test "approves only AWS hosts when policy matches trust_provider: aws" do
      policies = [
        %Policy{
          name: "aws-only",
          action: :approve,
          match: %{"trust_level" => "cloud_verified", "trust_provider" => "aws"}
        }
      ]

      aws_host = make_host(%{trust_level: :cloud_verified, trust_provider: :aws})
      gcp_host = make_host(%{trust_level: :cloud_verified, trust_provider: :gcp})
      azure_host = make_host(%{trust_level: :cloud_verified, trust_provider: :azure})

      assert Engine.evaluate_with_policies(aws_host, policies, :pending).action == :approve
      assert Engine.evaluate_with_policies(gcp_host, policies, :pending).action == :pending
      assert Engine.evaluate_with_policies(azure_host, policies, :pending).action == :pending
    end

    test "approves only GCP hosts when policy matches trust_provider: gcp" do
      policies = [
        %Policy{
          name: "gcp-only",
          action: :approve,
          match: %{"trust_provider" => "gcp"}
        }
      ]

      gcp_host = make_host(%{trust_level: :cloud_verified, trust_provider: :gcp})
      aws_host = make_host(%{trust_level: :cloud_verified, trust_provider: :aws})
      token_host = make_host(%{trust_level: :token_verified, trust_provider: :token})

      assert Engine.evaluate_with_policies(gcp_host, policies, :pending).action == :approve
      assert Engine.evaluate_with_policies(aws_host, policies, :pending).action == :pending
      assert Engine.evaluate_with_policies(token_host, policies, :pending).action == :pending
    end

    test "approves AWS or Azure via list match on trust_provider" do
      policies = [
        %Policy{
          name: "aws-or-azure",
          action: :approve,
          match: %{"trust_provider" => ["aws", "azure"]}
        }
      ]

      aws_host = make_host(%{trust_level: :cloud_verified, trust_provider: :aws})
      azure_host = make_host(%{trust_level: :cloud_verified, trust_provider: :azure})
      gcp_host = make_host(%{trust_level: :cloud_verified, trust_provider: :gcp})

      assert Engine.evaluate_with_policies(aws_host, policies, :pending).action == :approve
      assert Engine.evaluate_with_policies(azure_host, policies, :pending).action == :approve
      assert Engine.evaluate_with_policies(gcp_host, policies, :pending).action == :pending
    end

    test "cloud_image policy field matches AWS AMI ID" do
      policies = [
        %Policy{
          name: "golden-ami-auto",
          action: :approve,
          match: %{"cloud_image" => "ami-golden-1234"}
        }
      ]

      golden_host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :aws,
          trust_evidence: %{image_id: "ami-golden-1234"}
        })

      other_host =
        make_host(%{
          trust_level: :cloud_verified,
          trust_provider: :aws,
          trust_evidence: %{image_id: "ami-unknown-9999"}
        })

      assert Engine.evaluate_with_policies(golden_host, policies, :pending).action == :approve
      assert Engine.evaluate_with_policies(other_host, policies, :pending).action == :pending
    end
  end
end
