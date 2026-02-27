defmodule YellowDogIdentity.Trust.Cloud.AttestationDispatchTest do
  use ExUnit.Case, async: true

  alias YellowDogIdentity.Trust.Cloud.Attestation

  @source_ip {10, 0, 0, 1}

  describe "skip conditions" do
    test "skips when attestation is nil" do
      assert {:skip, :not_applicable} = Attestation.verify(%{attestation: nil})
    end

    test "skips when attestation is empty map" do
      assert {:skip, :not_applicable} = Attestation.verify(%{attestation: %{}})
    end

    test "skips when context has no attestation key" do
      assert {:skip, :not_applicable} = Attestation.verify(%{})
    end

    test "skips when provider is nil (string key)" do
      assert {:skip, :not_applicable} =
               Attestation.verify(%{attestation: %{"provider" => nil}})
    end
  end

  describe "unknown provider" do
    test "returns untrusted for unknown string provider" do
      ctx = %{attestation: %{"provider" => "unknown"}, source_ip: @source_ip}
      assert {:untrusted, :unknown_cloud_provider} = Attestation.verify(ctx)
    end

    test "returns untrusted for digitalocean provider" do
      ctx = %{attestation: %{"provider" => "digitalocean"}, source_ip: @source_ip}
      assert {:untrusted, :unknown_cloud_provider} = Attestation.verify(ctx)
    end
  end

  describe "dispatch to AWS (atom key)" do
    test "dispatches to AWS verifier with atom provider key" do
      ctx = %{
        attestation: %{provider: :aws},
        hostname: "h",
        source_ip: @source_ip
      }

      # AWS verifier returns untrusted because no attestation document is present
      assert {:untrusted, :missing_document} = Attestation.verify(ctx)
    end
  end

  describe "dispatch to GCP (atom key)" do
    test "dispatches to GCP verifier with atom provider key" do
      ctx = %{
        attestation: %{provider: :gcp},
        hostname: "h",
        source_ip: @source_ip
      }

      # GCP verifier returns untrusted because no token is present
      assert {:untrusted, :missing_token} = Attestation.verify(ctx)
    end
  end

  describe "dispatch to Azure (atom key)" do
    test "dispatches to Azure verifier with atom provider key" do
      ctx = %{
        attestation: %{provider: :azure},
        hostname: "h",
        source_ip: @source_ip
      }

      # Azure verifier returns untrusted because no attestation document is present
      assert {:untrusted, :missing_document} = Attestation.verify(ctx)
    end
  end

  describe "dispatch to AWS (string key)" do
    test "dispatches to AWS verifier with string provider key" do
      ctx = %{
        attestation: %{"provider" => "aws"},
        hostname: "h",
        source_ip: @source_ip
      }

      assert {:untrusted, :missing_document} = Attestation.verify(ctx)
    end
  end

  describe "dispatch to GCP (string key)" do
    test "dispatches to GCP verifier with string provider key" do
      ctx = %{
        attestation: %{"provider" => "gcp"},
        hostname: "h",
        source_ip: @source_ip
      }

      assert {:untrusted, :missing_token} = Attestation.verify(ctx)
    end
  end

  describe "dispatch to Azure (string key)" do
    test "dispatches to Azure verifier with string provider key" do
      ctx = %{
        attestation: %{"provider" => "azure"},
        hostname: "h",
        source_ip: @source_ip
      }

      assert {:untrusted, :missing_document} = Attestation.verify(ctx)
    end
  end
end
