defmodule YellowDogIdentity.Trust.Cloud.AttestationTest do
  # async: false because GCP tests share the global :gcp_jwks_cache ETS table
  # with gcp_attestation_test.exs which is also async: false
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Trust.Cloud.{Attestation, AWS, GCP, Azure}

  @source_ip {10, 0, 0, 1}
  @kid "test-key-id-1"

  # Generate a test RSA key pair for signing GCP JWTs
  setup_all do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public_map} = JOSE.JWK.to_map(jwk)
    public_map = Map.put(public_map, "kid", @kid)

    %{jwk: jwk, public_map: public_map}
  end

  setup %{public_map: public_map} do
    try do
      :ets.new(:gcp_jwks_cache, [:set, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    jwks = %{"keys" => [public_map]}
    :ets.insert(:gcp_jwks_cache, {:keys, jwks, System.monotonic_time(:second)})

    on_exit(fn ->
      try do
        :ets.delete(:gcp_jwks_cache)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  defp sign_gcp_jwt(claims, jwk) do
    jws = %{"alg" => "RS256", "kid" => @kid}
    {_, token} = JOSE.JWT.sign(jwk, jws, claims) |> JOSE.JWS.compact()
    token
  end

  describe "Attestation dispatch" do
    test "skips when attestation is nil" do
      assert {:skip, :not_applicable} = Attestation.verify(%{attestation: nil})
    end

    test "skips when attestation is empty map" do
      assert {:skip, :not_applicable} = Attestation.verify(%{attestation: %{}})
    end

    test "skips when no attestation key" do
      assert {:skip, :not_applicable} = Attestation.verify(%{some_key: "value"})
    end

    test "returns untrusted for unknown provider" do
      ctx = %{attestation: %{"provider" => "digitalocean"}, source_ip: @source_ip}
      assert {:untrusted, :unknown_cloud_provider} = Attestation.verify(ctx)
    end

    test "routes AWS attestation" do
      doc = %{"accountId" => "123456789012", "instanceId" => "i-abc123", "region" => "us-east-1"}
      document_b64 = Base.encode64(Jason.encode!(doc))

      ctx = %{
        attestation: %{"provider" => "aws", "document" => document_b64},
        source_ip: @source_ip
      }

      assert {:trusted, :cloud_verified, evidence} = Attestation.verify(ctx)
      assert evidence.provider == :aws
      assert evidence.account_id == "123456789012"
      assert evidence.instance_id == "i-abc123"
    end

    test "routes GCP attestation", %{jwk: jwk} do
      claims = %{
        "iss" => "https://accounts.google.com",
        "google" => %{
          "compute_engine" => %{
            "project_id" => "my-project",
            "instance_id" => 12345,
            "instance_name" => "test-vm",
            "zone" => "us-central1-a"
          }
        },
        "exp" => System.system_time(:second) + 3600
      }

      token = sign_gcp_jwt(claims, jwk)

      ctx = %{
        attestation: %{"provider" => "gcp", "token" => token},
        source_ip: @source_ip
      }

      assert {:trusted, :cloud_verified, evidence} = Attestation.verify(ctx)
      assert evidence.provider == :gcp
      assert evidence.project_id == "my-project"
      assert evidence.instance_id == "12345"
    end

    test "routes Azure attestation" do
      doc = %{
        "subscriptionId" => "sub-123",
        "vmId" => "vm-456",
        "resourceGroupName" => "rg-test",
        "location" => "eastus"
      }

      document_b64 = Base.encode64(Jason.encode!(doc))

      ctx = %{
        attestation: %{"provider" => "azure", "document" => document_b64},
        source_ip: @source_ip
      }

      assert {:trusted, :cloud_verified, evidence} = Attestation.verify(ctx)
      assert evidence.provider == :azure
      assert evidence.subscription_id == "sub-123"
      assert evidence.vm_id == "vm-456"
    end
  end

  describe "AWS verification" do
    test "verifies valid document" do
      doc = %{
        "accountId" => "123456789012",
        "instanceId" => "i-abc123",
        "region" => "us-west-2",
        "imageId" => "ami-12345",
        "instanceType" => "t3.medium",
        "pendingTime" => DateTime.to_iso8601(DateTime.utc_now())
      }

      document_b64 = Base.encode64(Jason.encode!(doc))

      ctx = %{
        attestation: %{"provider" => "aws", "document" => document_b64},
        source_ip: @source_ip
      }

      assert {:trusted, :cloud_verified, evidence} = AWS.verify(ctx)
      assert evidence.account_id == "123456789012"
      assert evidence.region == "us-west-2"
      assert evidence.image_id == "ami-12345"
    end

    test "rejects missing document" do
      ctx = %{
        attestation: %{"provider" => "aws", "document" => nil},
        source_ip: @source_ip
      }

      assert {:untrusted, :missing_document} = AWS.verify(ctx)
    end

    test "rejects invalid base64" do
      ctx = %{
        attestation: %{"provider" => "aws", "document" => "not-valid-base64!!!"},
        source_ip: @source_ip
      }

      assert {:untrusted, :invalid_document_encoding} = AWS.verify(ctx)
    end

    test "rejects invalid JSON" do
      ctx = %{
        attestation: %{"provider" => "aws", "document" => Base.encode64("not json")},
        source_ip: @source_ip
      }

      assert {:untrusted, _reason} = AWS.verify(ctx)
    end

    test "rejects expired document" do
      old_time = DateTime.utc_now() |> DateTime.add(-600, :second) |> DateTime.to_iso8601()

      doc = %{
        "accountId" => "123456789012",
        "instanceId" => "i-abc123",
        "region" => "us-east-1",
        "pendingTime" => old_time
      }

      document_b64 = Base.encode64(Jason.encode!(doc))

      ctx = %{
        attestation: %{"provider" => "aws", "document" => document_b64},
        source_ip: @source_ip
      }

      assert {:untrusted, :document_too_old} = AWS.verify(ctx)
    end

    test "skips for non-AWS provider" do
      ctx = %{
        attestation: %{"provider" => "gcp"},
        source_ip: @source_ip
      }

      assert {:skip, :not_applicable} = AWS.verify(ctx)
    end
  end

  describe "GCP verification" do
    test "verifies valid JWT token", %{jwk: jwk} do
      claims = %{
        "iss" => "https://accounts.google.com",
        "google" => %{
          "compute_engine" => %{
            "project_id" => "test-project",
            "instance_id" => 67890,
            "instance_name" => "worker-1",
            "zone" => "europe-west1-b"
          }
        },
        "exp" => System.system_time(:second) + 3600
      }

      token = sign_gcp_jwt(claims, jwk)

      ctx = %{
        attestation: %{"provider" => "gcp", "token" => token},
        source_ip: @source_ip
      }

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.project_id == "test-project"
      assert evidence.zone == "europe-west1-b"
    end

    test "rejects missing token" do
      ctx = %{
        attestation: %{"provider" => "gcp", "token" => nil},
        source_ip: @source_ip
      }

      assert {:untrusted, :missing_token} = GCP.verify(ctx)
    end

    test "rejects invalid JWT format" do
      ctx = %{
        attestation: %{"provider" => "gcp", "token" => "not.a.valid.jwt.format"},
        source_ip: @source_ip
      }

      assert {:untrusted, _reason} = GCP.verify(ctx)
    end

    test "skips for non-GCP provider" do
      ctx = %{attestation: %{"provider" => "aws"}, source_ip: @source_ip}
      assert {:skip, :not_applicable} = GCP.verify(ctx)
    end
  end

  describe "Azure verification" do
    test "verifies valid attested document" do
      doc = %{
        "subscriptionId" => "sub-abc",
        "vmId" => "vm-xyz",
        "resourceGroupName" => "rg-prod",
        "location" => "westus2"
      }

      document_b64 = Base.encode64(Jason.encode!(doc))

      ctx = %{
        attestation: %{"provider" => "azure", "document" => document_b64},
        source_ip: @source_ip
      }

      assert {:trusted, :cloud_verified, evidence} = Azure.verify(ctx)
      assert evidence.subscription_id == "sub-abc"
      assert evidence.resource_group == "rg-prod"
      assert evidence.location == "westus2"
    end

    test "rejects missing document" do
      ctx = %{
        attestation: %{"provider" => "azure", "document" => nil},
        source_ip: @source_ip
      }

      assert {:untrusted, :missing_document} = Azure.verify(ctx)
    end

    test "rejects invalid base64" do
      ctx = %{
        attestation: %{"provider" => "azure", "document" => "!!!invalid!!!"},
        source_ip: @source_ip
      }

      assert {:untrusted, :invalid_document_encoding} = Azure.verify(ctx)
    end

    test "skips for non-Azure provider" do
      ctx = %{attestation: %{"provider" => "gcp"}, source_ip: @source_ip}
      assert {:skip, :not_applicable} = Azure.verify(ctx)
    end
  end
end
