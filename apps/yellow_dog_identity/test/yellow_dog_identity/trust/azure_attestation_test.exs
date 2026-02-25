defmodule YellowDogIdentity.Trust.Cloud.AzureAttestationTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Trust.Cloud.Azure

  @source_ip {10, 0, 0, 1}

  defp build_context(attestation) do
    %{
      source_ip: @source_ip,
      hostname: "test-host",
      attestation: attestation,
      metadata: %{},
      authorization: nil
    }
  end

  defp valid_azure_document(overrides \\ %{}) do
    doc =
      Map.merge(
        %{
          "subscriptionId" => "sub-12345678-abcd-efgh-ijkl-123456789012",
          "vmId" => "vm-abcdef12-3456-7890-abcd-ef1234567890",
          "resourceGroupName" => "rg-production",
          "location" => "eastus",
          "name" => "prod-worker-01",
          "offer" => "UbuntuServer",
          "publisher" => "Canonical",
          "sku" => "22_04-lts",
          "timestamp" => DateTime.to_iso8601(DateTime.utc_now())
        },
        overrides
      )

    Base.encode64(Jason.encode!(doc))
  end

  describe "provider routing" do
    test "skips when provider is not azure" do
      ctx = build_context(%{"provider" => "aws", "document" => "irrelevant"})
      assert {:skip, :not_applicable} = Azure.verify(ctx)
    end

    test "skips when provider is gcp" do
      ctx = build_context(%{"provider" => "gcp", "document" => "irrelevant"})
      assert {:skip, :not_applicable} = Azure.verify(ctx)
    end

    test "skips when attestation is nil" do
      # verify/1 matches %{attestation: attestation} then calls Map.get on attestation,
      # so nil attestation is handled by the fallback verify(_) clause via no match
      assert {:skip, :not_applicable} = Azure.verify(%{})
    end

    test "skips when context has no attestation key" do
      assert {:skip, :not_applicable} = Azure.verify(%{hostname: "test"})
    end
  end

  describe "valid document verification" do
    test "returns trusted with valid base64-encoded JSON document" do
      document_b64 = valid_azure_document()

      ctx =
        build_context(%{
          "provider" => "azure",
          "document" => document_b64
        })

      assert {:trusted, :cloud_verified, evidence} = Azure.verify(ctx)
      assert evidence.provider == :azure
      assert evidence.subscription_id == "sub-12345678-abcd-efgh-ijkl-123456789012"
      assert evidence.vm_id == "vm-abcdef12-3456-7890-abcd-ef1234567890"
      assert evidence.resource_group == "rg-production"
      assert evidence.location == "eastus"
      assert %DateTime{} = evidence.verified_at
    end

    test "returns untrusted when certificate is provided but signature is absent" do
      document_b64 = valid_azure_document()

      ctx =
        build_context(%{
          "provider" => "azure",
          "document" => document_b64,
          "certificate" => "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----"
        })

      assert {:untrusted, :missing_signature} = Azure.verify(ctx)
    end

    test "returns trusted with atom provider key" do
      document_b64 = valid_azure_document()
      ctx = build_context(%{provider: :azure, document: document_b64})

      assert {:trusted, :cloud_verified, evidence} = Azure.verify(ctx)
      assert evidence.provider == :azure
      assert evidence.subscription_id == "sub-12345678-abcd-efgh-ijkl-123456789012"
    end

    test "returns trusted with minimal document (no timestamp)" do
      doc = %{
        "subscriptionId" => "sub-minimal",
        "vmId" => "vm-minimal",
        "resourceGroupName" => "rg-test",
        "location" => "westus2"
      }

      document_b64 = Base.encode64(Jason.encode!(doc))
      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:trusted, :cloud_verified, evidence} = Azure.verify(ctx)
      assert evidence.subscription_id == "sub-minimal"
      assert evidence.vm_id == "vm-minimal"
      assert evidence.resource_group == "rg-test"
      assert evidence.location == "westus2"
    end
  end

  describe "document decoding errors" do
    test "returns untrusted with missing document (nil)" do
      ctx = build_context(%{"provider" => "azure", "document" => nil})
      assert {:untrusted, :missing_document} = Azure.verify(ctx)
    end

    test "returns untrusted when document key is absent" do
      ctx = build_context(%{"provider" => "azure"})
      assert {:untrusted, :missing_document} = Azure.verify(ctx)
    end

    test "returns untrusted with invalid base64 encoding" do
      ctx = build_context(%{"provider" => "azure", "document" => "!!!not-base64!!!"})
      assert {:untrusted, :invalid_document_encoding} = Azure.verify(ctx)
    end

    test "returns untrusted with base64 that decodes to invalid JSON" do
      ctx = build_context(%{"provider" => "azure", "document" => Base.encode64("not json")})
      assert {:untrusted, reason} = Azure.verify(ctx)
      assert reason in [:invalid_document_format, :json_decode_failed]
    end

    test "returns untrusted with base64 that decodes to non-map JSON" do
      ctx = build_context(%{"provider" => "azure", "document" => Base.encode64("[1, 2, 3]")})
      assert {:untrusted, :invalid_document_format} = Azure.verify(ctx)
    end
  end

  describe "replay window (document_too_old)" do
    test "returns untrusted when timestamp exceeds 300s replay window" do
      old_time =
        DateTime.utc_now()
        |> DateTime.add(-600, :second)
        |> DateTime.to_iso8601()

      document_b64 = valid_azure_document(%{"timestamp" => old_time})
      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:untrusted, :document_too_old} = Azure.verify(ctx)
    end

    test "returns trusted when timestamp is within replay window" do
      recent_time =
        DateTime.utc_now()
        |> DateTime.add(-10, :second)
        |> DateTime.to_iso8601()

      document_b64 = valid_azure_document(%{"timestamp" => recent_time})
      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:trusted, :cloud_verified, _evidence} = Azure.verify(ctx)
    end

    test "returns trusted when timestamp is exactly now" do
      document_b64 = valid_azure_document(%{"timestamp" => DateTime.to_iso8601(DateTime.utc_now())})
      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:trusted, :cloud_verified, _evidence} = Azure.verify(ctx)
    end

    test "returns trusted when timestamp is at the boundary (just under 300s)" do
      boundary_time =
        DateTime.utc_now()
        |> DateTime.add(-295, :second)
        |> DateTime.to_iso8601()

      document_b64 = valid_azure_document(%{"timestamp" => boundary_time})
      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:trusted, :cloud_verified, _evidence} = Azure.verify(ctx)
    end

    test "returns untrusted when timestamp is in the future (prevents clock skew attacks)" do
      future_time =
        DateTime.utc_now()
        |> DateTime.add(60, :second)
        |> DateTime.to_iso8601()

      document_b64 = valid_azure_document(%{"timestamp" => future_time})
      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:untrusted, :document_too_old} = Azure.verify(ctx)
    end
  end

  describe "subscription allowlist" do
    # With no YellowDog.Config available in test, allowed_subscriptions defaults to []
    # which means all subscriptions are allowed.

    test "allows any subscription when allowed_subscriptions is empty (default)" do
      document_b64 = valid_azure_document(%{"subscriptionId" => "any-subscription-id"})
      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:trusted, :cloud_verified, evidence} = Azure.verify(ctx)
      assert evidence.subscription_id == "any-subscription-id"
    end

    test "allows different subscription IDs when no config restriction" do
      for sub <- ["sub-aaa", "sub-bbb", "sub-ccc"] do
        document_b64 = valid_azure_document(%{"subscriptionId" => sub})
        ctx = build_context(%{"provider" => "azure", "document" => document_b64})

        assert {:trusted, :cloud_verified, evidence} = Azure.verify(ctx)
        assert evidence.subscription_id == sub
      end
    end
  end

  describe "location allowlist" do
    # With no YellowDog.Config available in test, allowed_locations defaults to []
    # which means all locations are allowed.

    test "allows any location when allowed_locations is empty (default)" do
      document_b64 = valid_azure_document(%{"location" => "southeastasia"})
      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:trusted, :cloud_verified, evidence} = Azure.verify(ctx)
      assert evidence.location == "southeastasia"
    end

    test "allows various locations when no config restriction" do
      for location <- ["eastus", "westus2", "northeurope", "japaneast"] do
        document_b64 = valid_azure_document(%{"location" => location})
        ctx = build_context(%{"provider" => "azure", "document" => document_b64})

        assert {:trusted, :cloud_verified, evidence} = Azure.verify(ctx)
        assert evidence.location == location
      end
    end
  end

  describe "subscription allowlist rejection" do
    setup do
      original = Agent.get(YellowDog.Config, & &1)

      config =
        Map.merge(original, %{
          "identity" => %{
            "cloud" => %{
              "azure" => %{
                "allowed_subscriptions" => ["sub-allowed-1", "sub-allowed-2"],
                "allowed_locations" => ["eastus", "westeurope"]
              }
            }
          }
        })

      Agent.update(YellowDog.Config, fn _ -> config end)
      on_exit(fn -> Agent.update(YellowDog.Config, fn _ -> original end) end)
      :ok
    end

    test "rejects subscription not in allowed_subscriptions list" do
      document_b64 = valid_azure_document(%{"subscriptionId" => "sub-unauthorized"})
      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:untrusted, :subscription_not_allowed} = Azure.verify(ctx)
    end

    test "allows subscription in allowed_subscriptions list" do
      document_b64 = valid_azure_document(%{"subscriptionId" => "sub-allowed-1"})
      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:trusted, :cloud_verified, evidence} = Azure.verify(ctx)
      assert evidence.subscription_id == "sub-allowed-1"
    end

    test "rejects location not in allowed_locations list" do
      document_b64 = valid_azure_document(%{"subscriptionId" => "sub-allowed-1", "location" => "japaneast"})
      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:untrusted, :location_not_allowed} = Azure.verify(ctx)
    end

    test "allows location in allowed_locations list" do
      document_b64 = valid_azure_document(%{"subscriptionId" => "sub-allowed-1", "location" => "eastus"})
      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:trusted, :cloud_verified, evidence} = Azure.verify(ctx)
      assert evidence.location == "eastus"
    end
  end

  describe "evidence structure" do
    test "evidence contains all expected fields" do
      document_b64 =
        valid_azure_document(%{
          "subscriptionId" => "sub-evidence",
          "vmId" => "vm-evidence",
          "resourceGroupName" => "rg-evidence",
          "location" => "centralus"
        })

      ctx = build_context(%{"provider" => "azure", "document" => document_b64})

      assert {:trusted, :cloud_verified, evidence} = Azure.verify(ctx)

      assert Map.has_key?(evidence, :provider)
      assert Map.has_key?(evidence, :subscription_id)
      assert Map.has_key?(evidence, :vm_id)
      assert Map.has_key?(evidence, :resource_group)
      assert Map.has_key?(evidence, :location)
      assert Map.has_key?(evidence, :verified_at)
    end
  end
end
