defmodule YellowDogIdentity.Trust.Cloud.GCPAttestationTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Trust.Cloud.GCP

  @source_ip {10, 0, 0, 1}

  # Pre-populate the JWKS cache so tests don't hit the real Google endpoint.
  # Using {:error, :keys_unavailable} forces the unverified decode fallback path.
  setup do
    try do
      :ets.new(:gcp_jwks_cache, [:set, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    # Set cache to very old timestamp so it appears expired, which triggers
    # fetch_and_cache_keys. Instead, we insert a valid cache with empty keys
    # that will cause the "keys_unavailable" fallback.
    :ets.insert(:gcp_jwks_cache, {:keys, %{"keys" => []}, System.monotonic_time(:second)})

    on_exit(fn ->
      try do
        :ets.delete(:gcp_jwks_cache)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  defp build_context(attestation) do
    %{
      source_ip: @source_ip,
      hostname: "test-host",
      attestation: attestation,
      metadata: %{},
      authorization: nil
    }
  end

  defp build_jwt(claims, header \\ %{"alg" => "RS256"}) do
    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    payload_b64 = Base.url_encode64(Jason.encode!(claims), padding: false)
    signature_b64 = Base.url_encode64("fake-signature-bytes", padding: false)
    "#{header_b64}.#{payload_b64}.#{signature_b64}"
  end

  defp valid_gcp_claims(overrides \\ %{}) do
    base = %{
      "google" => %{
        "compute_engine" => %{
          "project_id" => "my-test-project",
          "instance_id" => 1234567890,
          "instance_name" => "worker-node-1",
          "zone" => "us-central1-a"
        }
      },
      "exp" => System.system_time(:second) + 3600,
      "iat" => System.system_time(:second),
      "sub" => "1234567890"
    }

    Map.merge(base, overrides)
  end

  describe "provider routing" do
    test "skips when provider is not gcp" do
      ctx = build_context(%{"provider" => "aws", "token" => "some-token"})
      assert {:skip, :not_applicable} = GCP.verify(ctx)
    end

    test "skips when provider is azure" do
      ctx = build_context(%{"provider" => "azure", "token" => "some-token"})
      assert {:skip, :not_applicable} = GCP.verify(ctx)
    end

    test "skips when attestation is nil" do
      # verify/1 matches %{attestation: attestation} then calls Map.get on attestation,
      # so nil attestation is handled by the fallback verify(_) clause via no match
      assert {:skip, :not_applicable} = GCP.verify(%{})
    end

    test "skips when context has no attestation key" do
      assert {:skip, :not_applicable} = GCP.verify(%{hostname: "test"})
    end
  end

  describe "missing token" do
    test "returns untrusted with missing_token when token is nil" do
      ctx = build_context(%{"provider" => "gcp", "token" => nil})
      assert {:untrusted, :missing_token} = GCP.verify(ctx)
    end

    test "returns untrusted with missing_token when token key is absent" do
      ctx = build_context(%{"provider" => "gcp"})
      assert {:untrusted, :missing_token} = GCP.verify(ctx)
    end
  end

  describe "invalid JWT format" do
    test "returns untrusted with invalid format when token has no dots" do
      ctx = build_context(%{"provider" => "gcp", "token" => "nodots"})
      assert {:untrusted, reason} = GCP.verify(ctx)
      assert reason in [:invalid_jwt_format, :jwt_decode_failed]
    end

    test "returns untrusted with invalid format when token has only one dot" do
      ctx = build_context(%{"provider" => "gcp", "token" => "one.dot"})
      assert {:untrusted, reason} = GCP.verify(ctx)
      assert reason in [:invalid_jwt_format, :jwt_decode_failed]
    end

    test "returns untrusted with invalid format when token has four dots" do
      ctx = build_context(%{"provider" => "gcp", "token" => "a.b.c.d.e"})
      assert {:untrusted, reason} = GCP.verify(ctx)
      assert reason in [:invalid_jwt_format, :jwt_decode_failed]
    end

    test "returns untrusted when payload is not valid base64url" do
      ctx = build_context(%{"provider" => "gcp", "token" => "eyJhbGciOiJSUzI1NiJ9.!!!invalid!!!.sig"})
      assert {:untrusted, reason} = GCP.verify(ctx)
      assert reason in [:invalid_jwt_format, :jwt_decode_failed]
    end
  end

  describe "signature verification security" do
    test "returns untrusted when kid is not found in non-empty JWKS (prevents forged tokens)" do
      # When JWKS contains real keys but the token's kid does not match, this must be
      # a hard failure — no fallback to unverified decode.
      jwks = %{"keys" => [%{"kid" => "real-key-id", "kty" => "RSA", "n" => "fake", "e" => "AQAB"}]}
      :ets.insert(:gcp_jwks_cache, {:keys, jwks, System.monotonic_time(:second)})

      header = %{"alg" => "RS256", "kid" => "unknown-key-id-999"}
      claims = valid_gcp_claims()
      token = build_jwt(claims, header)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      # Must fail, not fall back to unverified decode
      assert {:untrusted, reason} = GCP.verify(ctx)
      assert reason in [:key_not_found, :invalid_signature]
    end

    test "falls back to unverified decode when JWKS is empty (key rotation)" do
      # Empty JWKS list is treated as degraded mode, not a hard failure
      :ets.insert(:gcp_jwks_cache, {:keys, %{"keys" => []}, System.monotonic_time(:second)})

      claims = valid_gcp_claims()
      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, _evidence} = GCP.verify(ctx)
    end
  end

  describe "unverified JWT decode path" do
    # In test environment, Google JWKS keys return empty list (setup inserts %{"keys" => []}).
    # The implementation falls back to decode_jwt_claims_unverified for empty JWKS.

    test "returns trusted with valid unverified JWT containing compute_engine claims" do
      claims = valid_gcp_claims()
      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.provider == :gcp
      assert evidence.project_id == "my-test-project"
      assert evidence.instance_id == "1234567890"
      assert evidence.instance_name == "worker-node-1"
      assert evidence.zone == "us-central1-a"
      assert %DateTime{} = evidence.verified_at
    end

    test "returns trusted with atom provider key" do
      claims = valid_gcp_claims()
      token = build_jwt(claims)
      ctx = build_context(%{provider: :gcp, token: token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.provider == :gcp
    end

    test "returns trusted with different project and zone" do
      claims =
        valid_gcp_claims(%{
          "google" => %{
            "compute_engine" => %{
              "project_id" => "production-proj-42",
              "instance_id" => 9876543210,
              "instance_name" => "api-server",
              "zone" => "europe-west1-b"
            }
          }
        })

      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.project_id == "production-proj-42"
      assert evidence.instance_id == "9876543210"
      assert evidence.instance_name == "api-server"
      assert evidence.zone == "europe-west1-b"
    end

    test "returns trusted when claims have no google.compute_engine (nil fields)" do
      claims = %{
        "sub" => "some-subject",
        "exp" => System.system_time(:second) + 3600
      }

      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.provider == :gcp
      assert evidence.project_id == nil
      assert evidence.instance_id == ""
      assert evidence.instance_name == nil
      assert evidence.zone == nil
    end
  end

  describe "expiry check" do
    test "returns untrusted when token is expired" do
      claims = valid_gcp_claims(%{"exp" => System.system_time(:second) - 60})
      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :token_expired} = GCP.verify(ctx)
    end

    test "returns trusted when token is not yet expired" do
      claims = valid_gcp_claims(%{"exp" => System.system_time(:second) + 7200})
      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, _evidence} = GCP.verify(ctx)
    end

    test "returns trusted when no exp claim is present" do
      claims = valid_gcp_claims() |> Map.delete("exp")
      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, _evidence} = GCP.verify(ctx)
    end
  end

  describe "project and zone allowlists" do
    # With no YellowDog.Config available in test, allowed_projects and
    # allowed_zones default to [] which means all are allowed.

    test "allows any project when allowed_projects is empty (default)" do
      claims =
        valid_gcp_claims(%{
          "google" => %{
            "compute_engine" => %{
              "project_id" => "any-random-project",
              "instance_id" => 111,
              "instance_name" => "vm",
              "zone" => "us-east1-c"
            }
          }
        })

      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.project_id == "any-random-project"
    end

    test "allows any zone when allowed_zones is empty (default)" do
      claims =
        valid_gcp_claims(%{
          "google" => %{
            "compute_engine" => %{
              "project_id" => "proj",
              "instance_id" => 222,
              "instance_name" => "vm",
              "zone" => "asia-southeast1-a"
            }
          }
        })

      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.zone == "asia-southeast1-a"
    end
  end

  describe "project allowlist rejection" do
    setup do
      original = Agent.get(YellowDog.Config, & &1)

      config =
        Map.merge(original, %{
          "identity" => %{
            "cloud" => %{
              "gcp" => %{
                "allowed_projects" => ["allowed-project-1", "allowed-project-2"],
                "allowed_zones" => ["us-central1-a", "europe-west1-b"]
              }
            }
          }
        })

      Agent.update(YellowDog.Config, fn _ -> config end)
      on_exit(fn -> Agent.update(YellowDog.Config, fn _ -> original end) end)
      :ok
    end

    test "rejects project not in allowed_projects list" do
      claims =
        valid_gcp_claims(%{
          "google" => %{
            "compute_engine" => %{
              "project_id" => "unauthorized-project",
              "instance_id" => 999,
              "instance_name" => "vm",
              "zone" => "us-central1-a"
            }
          }
        })

      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :project_not_allowed} = GCP.verify(ctx)
    end

    test "allows project in allowed_projects list" do
      claims =
        valid_gcp_claims(%{
          "google" => %{
            "compute_engine" => %{
              "project_id" => "allowed-project-1",
              "instance_id" => 999,
              "instance_name" => "vm",
              "zone" => "us-central1-a"
            }
          }
        })

      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.project_id == "allowed-project-1"
    end

    test "rejects zone not in allowed_zones list" do
      claims =
        valid_gcp_claims(%{
          "google" => %{
            "compute_engine" => %{
              "project_id" => "allowed-project-1",
              "instance_id" => 999,
              "instance_name" => "vm",
              "zone" => "asia-east1-b"
            }
          }
        })

      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :zone_not_allowed} = GCP.verify(ctx)
    end

    test "allows zone in allowed_zones list" do
      claims =
        valid_gcp_claims(%{
          "google" => %{
            "compute_engine" => %{
              "project_id" => "allowed-project-1",
              "instance_id" => 999,
              "instance_name" => "vm",
              "zone" => "europe-west1-b"
            }
          }
        })

      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.zone == "europe-west1-b"
    end
  end

  describe "evidence structure" do
    test "evidence contains all expected fields" do
      claims = valid_gcp_claims()
      token = build_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)

      assert Map.has_key?(evidence, :provider)
      assert Map.has_key?(evidence, :project_id)
      assert Map.has_key?(evidence, :instance_id)
      assert Map.has_key?(evidence, :instance_name)
      assert Map.has_key?(evidence, :zone)
      assert Map.has_key?(evidence, :verified_at)
    end
  end
end
