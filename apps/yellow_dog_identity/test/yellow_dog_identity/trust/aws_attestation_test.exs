defmodule YellowDogIdentity.Trust.Cloud.AWSAttestationTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Trust.Cloud.AWS

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

  defp valid_aws_document(overrides \\ %{}) do
    doc =
      Map.merge(
        %{
          "accountId" => "123456789012",
          "instanceId" => "i-0abcdef1234567890",
          "region" => "us-east-1",
          "imageId" => "ami-0abcdef1234567890",
          "instanceType" => "t3.medium",
          "pendingTime" => DateTime.to_iso8601(DateTime.utc_now())
        },
        overrides
      )

    Base.encode64(Jason.encode!(doc))
  end

  describe "provider routing" do
    test "skips when provider is not aws" do
      ctx = build_context(%{"provider" => "gcp", "document" => "irrelevant"})
      assert {:skip, :not_applicable} = AWS.verify(ctx)
    end

    test "skips when provider is azure" do
      ctx = build_context(%{"provider" => "azure", "document" => "irrelevant"})
      assert {:skip, :not_applicable} = AWS.verify(ctx)
    end

    test "skips when attestation is nil" do
      # verify/1 matches %{attestation: attestation} then calls Map.get on attestation,
      # so nil attestation is handled by the fallback verify(_) clause via no match
      assert {:skip, :not_applicable} = AWS.verify(%{})
    end

    test "skips when context has no attestation key" do
      assert {:skip, :not_applicable} = AWS.verify(%{hostname: "test"})
    end
  end

  describe "valid document verification" do
    test "returns trusted with valid base64-encoded JSON document" do
      document_b64 = valid_aws_document()

      ctx =
        build_context(%{
          "provider" => "aws",
          "document" => document_b64,
          "signature" => "fake-pkcs7-signature"
        })

      assert {:trusted, :cloud_verified, evidence} = AWS.verify(ctx)
      assert evidence.provider == :aws
      assert evidence.account_id == "123456789012"
      assert evidence.instance_id == "i-0abcdef1234567890"
      assert evidence.region == "us-east-1"
      assert evidence.image_id == "ami-0abcdef1234567890"
      assert evidence.instance_type == "t3.medium"
      assert %DateTime{} = evidence.verified_at
      assert is_binary(evidence.document_time)
    end

    test "returns trusted with atom provider key" do
      document_b64 = valid_aws_document()
      ctx = build_context(%{provider: :aws, document: document_b64})

      assert {:trusted, :cloud_verified, evidence} = AWS.verify(ctx)
      assert evidence.provider == :aws
      assert evidence.account_id == "123456789012"
    end

    test "returns trusted with minimal document (no pendingTime)" do
      doc = %{
        "accountId" => "999888777666",
        "instanceId" => "i-minimal",
        "region" => "eu-west-1"
      }

      document_b64 = Base.encode64(Jason.encode!(doc))
      ctx = build_context(%{"provider" => "aws", "document" => document_b64})

      assert {:trusted, :cloud_verified, evidence} = AWS.verify(ctx)
      assert evidence.account_id == "999888777666"
      assert evidence.instance_id == "i-minimal"
      assert evidence.region == "eu-west-1"
      assert evidence.image_id == nil
      assert evidence.instance_type == nil
      assert evidence.document_time == nil
    end
  end

  describe "document decoding errors" do
    test "returns untrusted with missing document (nil)" do
      ctx = build_context(%{"provider" => "aws", "document" => nil})
      assert {:untrusted, :missing_document} = AWS.verify(ctx)
    end

    test "returns untrusted when document key is absent" do
      ctx = build_context(%{"provider" => "aws"})
      assert {:untrusted, :missing_document} = AWS.verify(ctx)
    end

    test "returns untrusted with invalid base64 encoding" do
      ctx = build_context(%{"provider" => "aws", "document" => "!!!not-base64!!!"})
      assert {:untrusted, :invalid_document_encoding} = AWS.verify(ctx)
    end

    test "returns untrusted with base64 that decodes to invalid JSON" do
      ctx = build_context(%{"provider" => "aws", "document" => Base.encode64("not json at all")})
      assert {:untrusted, reason} = AWS.verify(ctx)
      assert reason in [:invalid_document_format, :json_decode_failed]
    end

    test "returns untrusted with base64 that decodes to non-map JSON" do
      ctx = build_context(%{"provider" => "aws", "document" => Base.encode64("[1, 2, 3]")})
      assert {:untrusted, :invalid_document_format} = AWS.verify(ctx)
    end
  end

  describe "replay window (document_too_old)" do
    test "returns untrusted when pendingTime exceeds 300s replay window" do
      old_time =
        DateTime.utc_now()
        |> DateTime.add(-600, :second)
        |> DateTime.to_iso8601()

      document_b64 = valid_aws_document(%{"pendingTime" => old_time})
      ctx = build_context(%{"provider" => "aws", "document" => document_b64})

      assert {:untrusted, :document_too_old} = AWS.verify(ctx)
    end

    test "returns trusted when pendingTime is within replay window" do
      recent_time =
        DateTime.utc_now()
        |> DateTime.add(-10, :second)
        |> DateTime.to_iso8601()

      document_b64 = valid_aws_document(%{"pendingTime" => recent_time})
      ctx = build_context(%{"provider" => "aws", "document" => document_b64})

      assert {:trusted, :cloud_verified, _evidence} = AWS.verify(ctx)
    end

    test "returns trusted when pendingTime is exactly now" do
      document_b64 = valid_aws_document(%{"pendingTime" => DateTime.to_iso8601(DateTime.utc_now())})
      ctx = build_context(%{"provider" => "aws", "document" => document_b64})

      assert {:trusted, :cloud_verified, _evidence} = AWS.verify(ctx)
    end

    test "returns untrusted when pendingTime is in the future (prevents clock skew attacks)" do
      future_time =
        DateTime.utc_now()
        |> DateTime.add(60, :second)
        |> DateTime.to_iso8601()

      document_b64 = valid_aws_document(%{"pendingTime" => future_time})
      ctx = build_context(%{"provider" => "aws", "document" => document_b64})

      assert {:untrusted, :document_too_old} = AWS.verify(ctx)
    end
  end

  describe "account allowlist" do
    # With no YellowDog.Config available in test, allowed_accounts defaults to []
    # which means all accounts are allowed. We test the positive case here.

    test "allows any account when allowed_accounts is empty (default)" do
      document_b64 = valid_aws_document(%{"accountId" => "any-account-id"})
      ctx = build_context(%{"provider" => "aws", "document" => document_b64})

      assert {:trusted, :cloud_verified, evidence} = AWS.verify(ctx)
      assert evidence.account_id == "any-account-id"
    end

    test "allows different account IDs when no config restriction" do
      for account <- ["111111111111", "222222222222", "333333333333"] do
        document_b64 = valid_aws_document(%{"accountId" => account})
        ctx = build_context(%{"provider" => "aws", "document" => document_b64})

        assert {:trusted, :cloud_verified, evidence} = AWS.verify(ctx)
        assert evidence.account_id == account
      end
    end
  end

  describe "region allowlist" do
    # With no YellowDog.Config available in test, allowed_regions defaults to []
    # which means all regions are allowed. We test the positive case here.

    test "allows any region when allowed_regions is empty (default)" do
      document_b64 = valid_aws_document(%{"region" => "ap-southeast-1"})
      ctx = build_context(%{"provider" => "aws", "document" => document_b64})

      assert {:trusted, :cloud_verified, evidence} = AWS.verify(ctx)
      assert evidence.region == "ap-southeast-1"
    end

    test "allows various regions when no config restriction" do
      for region <- ["us-east-1", "eu-west-1", "ap-northeast-1", "sa-east-1"] do
        document_b64 = valid_aws_document(%{"region" => region})
        ctx = build_context(%{"provider" => "aws", "document" => document_b64})

        assert {:trusted, :cloud_verified, evidence} = AWS.verify(ctx)
        assert evidence.region == region
      end
    end
  end

  describe "evidence structure" do
    test "evidence contains all expected fields" do
      document_b64 =
        valid_aws_document(%{
          "accountId" => "acct-test",
          "instanceId" => "i-evidence-test",
          "region" => "us-west-2",
          "imageId" => "ami-evidence",
          "instanceType" => "m5.large"
        })

      ctx =
        build_context(%{
          "provider" => "aws",
          "document" => document_b64,
          "signature" => "sig"
        })

      assert {:trusted, :cloud_verified, evidence} = AWS.verify(ctx)

      assert Map.has_key?(evidence, :provider)
      assert Map.has_key?(evidence, :account_id)
      assert Map.has_key?(evidence, :instance_id)
      assert Map.has_key?(evidence, :region)
      assert Map.has_key?(evidence, :image_id)
      assert Map.has_key?(evidence, :instance_type)
      assert Map.has_key?(evidence, :verified_at)
      assert Map.has_key?(evidence, :document_time)
    end
  end
end
