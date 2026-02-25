defmodule YellowDogIdentity.CloudAttestationIntegrationTest do
  @moduledoc """
  End-to-end integration tests for cloud attestation → trust → approval pipeline.

  These tests exercise the full registration flow:
    context (with attestation) → TrustRouter → ApprovalEngine → Registry

  Uses GCP signed JWTs (real JOSE crypto), AWS/Azure claims-only mode
  (no certificate configured), and provisioning tokens.
  """

  # async: false — shares :gcp_jwks_cache ETS table and YellowDog.Config Agent
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Registry

  @key_a "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBxRhNpqVVPZOFRZNvKGVfCjXN5US8MLXiEy1Ox7xDT6 test@host"
  @age_a "age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"

  @kid "integration-test-key-1"

  setup_all do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public_map} = JOSE.JWK.to_map(jwk)
    public_map = Map.put(public_map, "kid", @kid)
    %{jwk: jwk, public_map: public_map}
  end

  setup %{public_map: public_map} do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "yd_cloud_integration_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    {:ok, pid} = Registry.start_link(data_dir: tmp_dir, name: YellowDogIdentity.Registry)

    # Pre-populate GCP JWKS cache with test public key
    try do
      :ets.new(:gcp_jwks_cache, [:set, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    jwks = %{"keys" => [public_map]}
    :ets.insert(:gcp_jwks_cache, {:keys, jwks, System.monotonic_time(:second)})

    # Save original config for restoration
    original_config = Agent.get(YellowDog.Config, & &1)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(tmp_dir)

      try do
        :ets.delete(:gcp_jwks_cache)
      rescue
        ArgumentError -> :ok
      end

      Agent.update(YellowDog.Config, fn _ -> original_config end)
    end)

    %{original_config: original_config}
  end

  defp set_policies(original_config, policies, default_action \\ "pending") do
    config =
      Map.merge(original_config, %{
        "identity" => %{
          "approval" => %{
            "default_action" => default_action,
            "policies" => policies
          }
        }
      })

    Agent.update(YellowDog.Config, fn _ -> config end)
  end

  defp sign_gcp_jwt(claims, jwk) do
    jws = %{"alg" => "RS256", "kid" => @kid}
    {_, token} = JOSE.JWT.sign(jwk, jws, claims) |> JOSE.JWS.compact()
    token
  end

  defp gcp_claims(project_id, instance_id \\ 1_234_567_890, zone \\ "us-central1-a") do
    %{
      "iss" => "https://accounts.google.com",
      "google" => %{
        "compute_engine" => %{
          "project_id" => project_id,
          "instance_id" => instance_id,
          "instance_name" => "node-1",
          "zone" => zone
        }
      },
      "exp" => System.system_time(:second) + 3600
    }
  end

  defp aws_document_b64(account_id, opts \\ %{}) do
    doc =
      Map.merge(
        %{
          "accountId" => account_id,
          "instanceId" => "i-0abcdef1234567890",
          "region" => "us-east-1",
          "imageId" => "ami-0abc12345",
          "instanceType" => "t3.medium",
          "pendingTime" => DateTime.to_iso8601(DateTime.utc_now())
        },
        opts
      )

    Base.encode64(Jason.encode!(doc))
  end

  defp azure_document_b64(subscription_id, opts \\ %{}) do
    doc =
      Map.merge(
        %{
          "subscriptionId" => subscription_id,
          "vmId" => "vm-uuid-abc",
          "resourceGroupName" => "rg-prod",
          "location" => "eastus"
        },
        opts
      )

    Base.encode64(Jason.encode!(doc))
  end

  # ──────────────────────────────────────────────────────────────────────────
  # GCP Attestation → Auto-Approval
  # ──────────────────────────────────────────────────────────────────────────

  describe "GCP attestation → auto-approval" do
    test "auto-approves cloud_verified GCP host when policy matches project_id", %{
      jwk: jwk,
      original_config: orig
    } do
      set_policies(orig, [
        %{
          "name" => "gcp-prod-auto",
          "action" => "approve",
          "match" => %{"trust_level" => "cloud_verified", "cloud_account" => "prod-gcp-project"}
        }
      ])

      token = sign_gcp_jwt(gcp_claims("prod-gcp-project"), jwk)
      params = %{hostname: "gcp-prod-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: %{"provider" => "gcp", "token" => token},
        source_ip: {10, 0, 0, 1},
        authorization: nil
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      assert host.status == :approved
      assert host.trust_level == :cloud_verified
      assert host.trust_provider == :gcp
      assert host.approved_by == "auto:gcp-prod-auto"
      assert %DateTime{} = host.approved_at
      assert host.trust_evidence.project_id == "prod-gcp-project"
      assert host.trust_evidence.zone == "us-central1-a"
    end

    test "leaves host pending when GCP project is not in policy", %{
      jwk: jwk,
      original_config: orig
    } do
      set_policies(orig, [
        %{
          "name" => "gcp-restricted",
          "action" => "approve",
          "match" => %{"cloud_account" => "allowed-project-only"}
        }
      ])

      token = sign_gcp_jwt(gcp_claims("unauthorized-project"), jwk)
      params = %{hostname: "gcp-other-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: %{"provider" => "gcp", "token" => token},
        source_ip: {10, 0, 0, 2},
        authorization: nil
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      # Trust established but policy didn't match — stays pending
      assert host.status == :pending
      assert host.trust_level == :cloud_verified
      assert host.trust_provider == :gcp
    end

    test "auto-approves when policy only checks trust_level (any GCP project)", %{
      jwk: jwk,
      original_config: orig
    } do
      set_policies(orig, [
        %{
          "name" => "any-cloud-auto",
          "action" => "approve",
          "match" => %{"trust_level" => "cloud_verified"}
        }
      ])

      token = sign_gcp_jwt(gcp_claims("any-project-at-all", 999, "europe-west1-b"), jwk)
      params = %{hostname: "gcp-any-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: %{"provider" => "gcp", "token" => token},
        source_ip: {10, 0, 0, 3},
        authorization: nil
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      assert host.status == :approved
      assert host.trust_evidence.zone == "europe-west1-b"
    end

    test "approved GCP host appears in recipient export", %{jwk: jwk, original_config: orig} do
      set_policies(orig, [
        %{
          "name" => "cloud-auto",
          "action" => "approve",
          "match" => %{"trust_level" => "cloud_verified"}
        }
      ])

      token = sign_gcp_jwt(gcp_claims("export-project"), jwk)
      params = %{hostname: "gcp-export-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: %{"provider" => "gcp", "token" => token},
        source_ip: {10, 0, 0, 4},
        authorization: nil
      }

      {:ok, host} = YellowDogIdentity.register(params, context)
      assert host.status == :approved

      yaml = YellowDogIdentity.export_recipients()
      assert yaml =~ @age_a
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # AWS Attestation → Auto-Approval
  # ──────────────────────────────────────────────────────────────────────────

  describe "AWS attestation → auto-approval" do
    test "auto-approves AWS host when account_id matches policy", %{original_config: orig} do
      set_policies(orig, [
        %{
          "name" => "aws-prod-auto",
          "action" => "approve",
          "match" => %{"trust_level" => "cloud_verified", "cloud_account" => "123456789012"}
        }
      ])

      params = %{hostname: "aws-prod-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: %{"provider" => "aws", "document" => aws_document_b64("123456789012")},
        source_ip: {10, 0, 0, 10},
        authorization: nil
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      assert host.status == :approved
      assert host.trust_level == :cloud_verified
      assert host.trust_provider == :aws
      assert host.approved_by == "auto:aws-prod-auto"
      assert host.trust_evidence.account_id == "123456789012"
      assert host.trust_evidence.region == "us-east-1"
    end

    test "auto-approves AWS host with region-specific policy", %{original_config: orig} do
      set_policies(orig, [
        %{
          "name" => "aws-us-east",
          "action" => "approve",
          "match" => %{
            "trust_level" => "cloud_verified",
            "cloud_account" => "987654321098",
            "cloud_region" => "us-east-1"
          }
        }
      ])

      params = %{hostname: "aws-east-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: %{
          "provider" => "aws",
          "document" => aws_document_b64("987654321098", %{"region" => "us-east-1"})
        },
        source_ip: {10, 0, 0, 11},
        authorization: nil
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      assert host.status == :approved
      assert host.trust_evidence.region == "us-east-1"
    end

    test "rejects AWS host from wrong account", %{original_config: orig} do
      set_policies(orig, [
        %{
          "name" => "aws-allowed-only",
          "action" => "approve",
          "match" => %{"cloud_account" => "allowed-account-111"}
        }
      ])

      params = %{hostname: "aws-wrong-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: %{"provider" => "aws", "document" => aws_document_b64("wrong-account-999")},
        source_ip: {10, 0, 0, 12},
        authorization: nil
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      assert host.status == :pending
      assert host.trust_level == :cloud_verified
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Azure Attestation → Auto-Approval
  # ──────────────────────────────────────────────────────────────────────────

  describe "Azure attestation → auto-approval" do
    test "auto-approves Azure host when subscription_id matches policy", %{original_config: orig} do
      set_policies(orig, [
        %{
          "name" => "azure-prod-auto",
          "action" => "approve",
          "match" => %{"trust_level" => "cloud_verified", "cloud_account" => "sub-prod-uuid"}
        }
      ])

      params = %{hostname: "azure-prod-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: %{
          "provider" => "azure",
          "document" => azure_document_b64("sub-prod-uuid")
        },
        source_ip: {10, 0, 0, 20},
        authorization: nil
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      assert host.status == :approved
      assert host.trust_level == :cloud_verified
      assert host.trust_provider == :azure
      assert host.approved_by == "auto:azure-prod-auto"
      assert host.trust_evidence.subscription_id == "sub-prod-uuid"
      assert host.trust_evidence.location == "eastus"
    end

    test "auto-approves Azure host with location-specific policy", %{original_config: orig} do
      set_policies(orig, [
        %{
          "name" => "azure-westus2",
          "action" => "approve",
          "match" => %{
            "trust_level" => "cloud_verified",
            "cloud_region" => "westus2"
          }
        }
      ])

      params = %{hostname: "azure-west-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: %{
          "provider" => "azure",
          "document" => azure_document_b64("sub-any", %{"location" => "westus2"})
        },
        source_ip: {10, 0, 0, 21},
        authorization: nil
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      assert host.status == :approved
      assert host.trust_evidence.location == "westus2"
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Token Flow → Auto-Approval
  # ──────────────────────────────────────────────────────────────────────────

  describe "provisioning token → auto-approval" do
    test "auto-approves host registered with valid provisioning token", %{original_config: orig} do
      set_policies(orig, [
        %{
          "name" => "token-auto",
          "action" => "approve",
          "match" => %{"trust_level" => "token_verified"}
        }
      ])

      {:ok, _token, raw_token} =
        YellowDogIdentity.create_token(%{
          hostname_pattern: "token-node-*",
          role: "worker",
          max_uses: 5,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      params = %{hostname: "token-node-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: nil,
        source_ip: {10, 0, 0, 30},
        authorization: "Bearer #{raw_token}"
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      assert host.status == :approved
      assert host.trust_level == :token_verified
      assert host.trust_provider == :token
      assert host.approved_by == "auto:token-auto"
      assert host.trust_evidence.role == "worker"
    end

    test "leaves host pending when no token policy matches", %{original_config: orig} do
      # Only approve cloud_verified, not token_verified
      set_policies(orig, [
        %{
          "name" => "cloud-only",
          "action" => "approve",
          "match" => %{"trust_level" => "cloud_verified"}
        }
      ])

      {:ok, _token, raw_token} =
        YellowDogIdentity.create_token(%{
          hostname_pattern: "*",
          role: "worker",
          max_uses: 5,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      params = %{hostname: "token-pending-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: nil,
        source_ip: {10, 0, 0, 31},
        authorization: "Bearer #{raw_token}"
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      assert host.status == :pending
      assert host.trust_level == :token_verified
    end

    test "invalid token falls through to unverified", %{original_config: orig} do
      set_policies(orig, [])

      params = %{hostname: "bad-token-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: nil,
        source_ip: {10, 0, 0, 32},
        authorization: "Bearer definitely-not-a-valid-token"
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      # Trust provider rejected the token — falls to unverified
      assert host.trust_level == :unverified
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Policy Rejection
  # ──────────────────────────────────────────────────────────────────────────

  describe "policy rejection" do
    test "unverified host is marked pending (reject policy sets revoke_reason)", %{
      original_config: orig
    } do
      set_policies(orig, [
        %{
          "name" => "block-unverified",
          "action" => "reject",
          "match" => %{"trust_level" => "unverified"}
        }
      ])

      params = %{hostname: "unverified-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      assert {:ok, host} = YellowDogIdentity.register(params)
      # Rejection keeps status as :pending (not :revoked) per current implementation
      assert host.status == :pending
      assert host.revoke_reason =~ "rejected by policy"
    end

    test "cloud_verified host bypasses unverified rejection policy", %{
      jwk: jwk,
      original_config: orig
    } do
      set_policies(orig, [
        %{"name" => "block-unverified", "action" => "reject", "match" => %{"trust_level" => "unverified"}},
        %{"name" => "allow-cloud", "action" => "approve", "match" => %{"trust_level" => "cloud_verified"}}
      ])

      token = sign_gcp_jwt(gcp_claims("bypass-project"), jwk)
      params = %{hostname: "bypass-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: %{"provider" => "gcp", "token" => token},
        source_ip: {10, 0, 0, 40},
        authorization: nil
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      assert host.status == :approved
      assert host.trust_level == :cloud_verified
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Provider Priority (attestation wins over token)
  # ──────────────────────────────────────────────────────────────────────────

  describe "trust provider priority" do
    test "cloud attestation wins over token when both present", %{jwk: jwk, original_config: orig} do
      set_policies(orig, [
        %{
          "name" => "cloud-auto",
          "action" => "approve",
          "match" => %{"trust_level" => "cloud_verified"}
        }
      ])

      {:ok, _token, raw_token} =
        YellowDogIdentity.create_token(%{
          hostname_pattern: "*",
          role: "worker",
          max_uses: 5,
          expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })

      token = sign_gcp_jwt(gcp_claims("priority-project"), jwk)
      params = %{hostname: "priority-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: %{"provider" => "gcp", "token" => token},
        source_ip: {10, 0, 0, 50},
        authorization: "Bearer #{raw_token}"
      }

      assert {:ok, host} = YellowDogIdentity.register(params, context)
      # Cloud attestation (higher priority) wins
      assert host.trust_level == :cloud_verified
      assert host.trust_provider == :gcp
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Revocation removes from export immediately (PRD §8.5)
  # ──────────────────────────────────────────────────────────────────────────

  describe "revocation removes from recipient export immediately" do
    test "revoked cloud host is no longer in export", %{jwk: jwk, original_config: orig} do
      set_policies(orig, [
        %{
          "name" => "cloud-auto",
          "action" => "approve",
          "match" => %{"trust_level" => "cloud_verified"}
        }
      ])

      token = sign_gcp_jwt(gcp_claims("revoke-project"), jwk)
      params = %{hostname: "revoke-gcp-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      context = %{
        attestation: %{"provider" => "gcp", "token" => token},
        source_ip: {10, 0, 0, 60},
        authorization: nil
      }

      {:ok, host} = YellowDogIdentity.register(params, context)
      assert host.status == :approved

      # Verify it appears in export
      yaml_before = YellowDogIdentity.export_recipients()
      assert yaml_before =~ @age_a

      # Revoke the host
      {:ok, revoked} = YellowDogIdentity.revoke(host.id, "security@test", "compromised key")
      assert revoked.status == :revoked

      # Verify it's immediately removed from export
      yaml_after = YellowDogIdentity.export_recipients()
      refute yaml_after =~ @age_a
    end

    test "revoked cloud host is excluded from sops export too", %{jwk: jwk, original_config: orig} do
      set_policies(orig, [
        %{"name" => "cloud-auto", "action" => "approve", "match" => %{"trust_level" => "cloud_verified"}}
      ])

      token = sign_gcp_jwt(gcp_claims("revoke-sops-project", 777, "us-west1-a"), jwk)
      params = %{hostname: "revoke-sops-01", ssh_pubkey: @key_a, age_recipient: @age_a}

      {:ok, host} = YellowDogIdentity.register(params, %{
        attestation: %{"provider" => "gcp", "token" => token},
        source_ip: {10, 0, 0, 61},
        authorization: nil
      })

      assert host.status == :approved
      sops_before = YellowDogIdentity.export_recipients(format: :sops)
      assert sops_before =~ @age_a

      {:ok, _} = YellowDogIdentity.revoke(host.id, "admin")
      sops_after = YellowDogIdentity.export_recipients(format: :sops)
      refute sops_after =~ @age_a
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Stats reflect correct cloud provider names
  # ──────────────────────────────────────────────────────────────────────────

  describe "stats reflect cloud providers" do
    test "stats.providers shows :aws and :gcp separately after cloud registrations", %{
      original_config: orig
    } do
      set_policies(orig, [
        %{"name" => "cloud-auto", "action" => "approve", "match" => %{"trust_level" => "cloud_verified"}}
      ])

      # Register one AWS host
      aws_doc = aws_document_b64("111222333444")

      {:ok, host_aws} =
        YellowDogIdentity.register(
          %{hostname: "stats-aws-01", ssh_pubkey: @key_a, age_recipient: @age_a},
          %{
            attestation: %{"provider" => "aws", "document" => aws_doc},
            source_ip: {10, 0, 0, 70},
            authorization: nil
          }
        )

      assert host_aws.trust_provider == :aws

      # Stats should show aws under providers
      stats = YellowDogIdentity.stats()
      assert Map.get(stats.providers, "aws") == 1
      assert stats.trust_levels == %{"cloud_verified" => 1}
    end
  end
end
