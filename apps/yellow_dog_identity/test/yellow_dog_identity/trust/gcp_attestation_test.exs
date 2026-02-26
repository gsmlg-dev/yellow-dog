defmodule YellowDogIdentity.Trust.Cloud.GCPAttestationTest do
  use ExUnit.Case, async: false

  alias YellowDogIdentity.Trust.Cloud.GCP

  @source_ip {10, 0, 0, 1}
  @kid "test-key-id-1"

  # Generate a test RSA key pair for signing JWTs
  setup_all do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, public_map} = JOSE.JWK.to_map(jwk)
    public_map = Map.put(public_map, "kid", @kid)

    %{jwk: jwk, public_map: public_map}
  end

  # Pre-populate the JWKS cache with the test public key
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

  defp build_context(attestation) do
    %{
      source_ip: @source_ip,
      hostname: "test-host",
      attestation: attestation,
      metadata: %{},
      authorization: nil
    }
  end

  defp sign_jwt(claims, jwk) do
    jws = %{"alg" => "RS256", "kid" => @kid}
    {_, token} = JOSE.JWT.sign(jwk, jws, claims) |> JOSE.JWS.compact()
    token
  end

  defp build_unsigned_jwt(claims, header \\ %{"alg" => "RS256"}) do
    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    payload_b64 = Base.url_encode64(Jason.encode!(claims), padding: false)
    signature_b64 = Base.url_encode64("fake-signature-bytes", padding: false)
    "#{header_b64}.#{payload_b64}.#{signature_b64}"
  end

  defp valid_gcp_claims(overrides \\ %{}) do
    base = %{
      "iss" => "https://accounts.google.com",
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
      assert reason in [:invalid_jwt_format, :jwt_decode_failed, :keys_unavailable]
    end

    test "returns untrusted with invalid format when token has only one dot" do
      ctx = build_context(%{"provider" => "gcp", "token" => "one.dot"})
      assert {:untrusted, reason} = GCP.verify(ctx)
      assert reason in [:invalid_jwt_format, :jwt_decode_failed, :keys_unavailable]
    end

    test "returns untrusted with invalid format when token has four dots" do
      ctx = build_context(%{"provider" => "gcp", "token" => "a.b.c.d.e"})
      assert {:untrusted, reason} = GCP.verify(ctx)
      assert reason in [:invalid_jwt_format, :jwt_decode_failed, :keys_unavailable]
    end

    test "returns untrusted when payload is not valid base64url" do
      ctx =
        build_context(%{
          "provider" => "gcp",
          "token" => "eyJhbGciOiJSUzI1NiJ9.!!!invalid!!!.sig"
        })

      assert {:untrusted, reason} = GCP.verify(ctx)
      assert reason in [:invalid_jwt_format, :jwt_decode_failed, :keys_unavailable, :missing_kid]
    end
  end

  describe "signature verification security" do
    test "returns untrusted when kid is not found in non-empty JWKS (prevents forged tokens)" do
      jwks = %{
        "keys" => [%{"kid" => "real-key-id", "kty" => "RSA", "n" => "fake", "e" => "AQAB"}]
      }

      :ets.insert(:gcp_jwks_cache, {:keys, jwks, System.monotonic_time(:second)})

      header = %{"alg" => "RS256", "kid" => "unknown-key-id-999"}
      claims = valid_gcp_claims()
      token = build_unsigned_jwt(claims, header)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, reason} = GCP.verify(ctx)
      assert reason in [:key_not_found, :invalid_signature]
    end

    test "rejects tokens when JWKS is empty (prevents forged token acceptance)" do
      :ets.insert(
        :gcp_jwks_cache,
        {:keys, %{"keys" => []}, System.monotonic_time(:second)}
      )

      claims = valid_gcp_claims()
      token = build_unsigned_jwt(claims)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :keys_unavailable} = GCP.verify(ctx)
    end

    test "rejects forged JWT even with valid claims", %{public_map: public_map} do
      # Re-populate JWKS with test key
      jwks = %{"keys" => [public_map]}
      :ets.insert(:gcp_jwks_cache, {:keys, jwks, System.monotonic_time(:second)})

      # JWT signed with wrong key should be rejected
      wrong_key = JOSE.JWK.generate_key({:rsa, 2048})
      jws = %{"alg" => "RS256", "kid" => @kid}
      {_, token} = JOSE.JWT.sign(wrong_key, jws, valid_gcp_claims()) |> JOSE.JWS.compact()
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :invalid_signature} = GCP.verify(ctx)
    end
  end

  describe "verified JWT decode path" do
    test "returns trusted with valid signed JWT containing compute_engine claims", %{jwk: jwk} do
      claims = valid_gcp_claims()
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.provider == :gcp
      assert evidence.project_id == "my-test-project"
      assert evidence.instance_id == "1234567890"
      assert evidence.instance_name == "worker-node-1"
      assert evidence.zone == "us-central1-a"
      assert %DateTime{} = evidence.verified_at
    end

    test "returns trusted with atom provider key", %{jwk: jwk} do
      claims = valid_gcp_claims()
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{provider: :gcp, token: token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.provider == :gcp
    end

    test "returns trusted with different project and zone", %{jwk: jwk} do
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

      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.project_id == "production-proj-42"
      assert evidence.instance_id == "9876543210"
      assert evidence.instance_name == "api-server"
      assert evidence.zone == "europe-west1-b"
    end

    test "returns trusted when claims have no google.compute_engine (nil fields)", %{jwk: jwk} do
      claims = %{
        "iss" => "https://accounts.google.com",
        "sub" => "some-subject",
        "exp" => System.system_time(:second) + 3600
      }

      token = sign_jwt(claims, jwk)
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
    test "returns untrusted when token is expired", %{jwk: jwk} do
      claims = valid_gcp_claims(%{"exp" => System.system_time(:second) - 60})
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :token_expired} = GCP.verify(ctx)
    end

    test "returns trusted when token is not yet expired", %{jwk: jwk} do
      claims = valid_gcp_claims(%{"exp" => System.system_time(:second) + 7200})
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, _evidence} = GCP.verify(ctx)
    end

    test "returns trusted when no exp claim is present", %{jwk: jwk} do
      claims = valid_gcp_claims() |> Map.delete("exp")
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, _evidence} = GCP.verify(ctx)
    end
  end

  describe "issuer check" do
    test "rejects JWT with missing issuer", %{jwk: jwk} do
      claims = valid_gcp_claims() |> Map.delete("iss")
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :missing_issuer} = GCP.verify(ctx)
    end

    test "rejects JWT with wrong issuer", %{jwk: jwk} do
      claims = valid_gcp_claims(%{"iss" => "https://evil.example.com"})
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :invalid_issuer} = GCP.verify(ctx)
    end

    test "accepts accounts.google.com without https prefix", %{jwk: jwk} do
      claims = valid_gcp_claims(%{"iss" => "accounts.google.com"})
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, _} = GCP.verify(ctx)
    end
  end

  describe "project and zone allowlists" do
    test "allows any project when allowed_projects is empty (default)", %{jwk: jwk} do
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

      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.project_id == "any-random-project"
    end

    test "allows any zone when allowed_zones is empty (default)", %{jwk: jwk} do
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

      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.zone == "asia-southeast1-a"
    end
  end

  describe "project allowlist rejection" do
    setup %{jwk: jwk} do
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
      %{jwk: jwk}
    end

    test "rejects project not in allowed_projects list", %{jwk: jwk} do
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

      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :project_not_allowed} = GCP.verify(ctx)
    end

    test "allows project in allowed_projects list", %{jwk: jwk} do
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

      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.project_id == "allowed-project-1"
    end

    test "rejects zone not in allowed_zones list", %{jwk: jwk} do
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

      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :zone_not_allowed} = GCP.verify(ctx)
    end

    test "allows zone in allowed_zones list", %{jwk: jwk} do
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

      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, evidence} = GCP.verify(ctx)
      assert evidence.zone == "europe-west1-b"
    end
  end

  describe "audience check" do
    setup %{jwk: jwk} do
      original = Agent.get(YellowDog.Config, & &1)

      config =
        Map.merge(original, %{
          "identity" => %{
            "cloud" => %{
              "gcp" => %{"audience" => "https://yellowdog.example.com/identity"}
            }
          }
        })

      Agent.update(YellowDog.Config, fn _ -> config end)
      on_exit(fn -> Agent.update(YellowDog.Config, fn _ -> original end) end)
      %{jwk: jwk}
    end

    test "allows JWT with matching string aud claim", %{jwk: jwk} do
      claims = valid_gcp_claims(%{"aud" => "https://yellowdog.example.com/identity"})
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, _} = GCP.verify(ctx)
    end

    test "rejects JWT with non-matching aud claim", %{jwk: jwk} do
      claims = valid_gcp_claims(%{"aud" => "https://evil.example.com/other"})
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :invalid_audience} = GCP.verify(ctx)
    end

    test "allows JWT with aud as list containing the expected audience", %{jwk: jwk} do
      claims =
        valid_gcp_claims(%{
          "aud" => ["https://other.example.com", "https://yellowdog.example.com/identity"]
        })

      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:trusted, :cloud_verified, _} = GCP.verify(ctx)
    end

    test "rejects JWT with aud as list not containing the expected audience", %{jwk: jwk} do
      claims =
        valid_gcp_claims(%{
          "aud" => ["https://other.example.com", "https://another.example.com"]
        })

      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :invalid_audience} = GCP.verify(ctx)
    end

    test "rejects JWT when aud claim is an unexpected type (integer, not string or list)", %{jwk: jwk} do
      # aud is an integer — neither matches expected string nor is a list
      # cond: actual == expected_audience → false; is_list(actual) → false; true → false
      claims = valid_gcp_claims(%{"aud" => 12345})
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :invalid_audience} = GCP.verify(ctx)
    end

    test "rejects JWT when aud claim is absent (nil)", %{jwk: jwk} do
      # aud missing → Map.get returns nil → cond true -> false → :invalid_audience
      claims = valid_gcp_claims() |> Map.delete("aud")
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :invalid_audience} = GCP.verify(ctx)
    end
  end

  describe "missing kid in JWT header" do
    test "rejects JWT with valid header but no kid field" do
      # Build a JWT with no kid — verify_with_keys pattern matches {:ok, _no_kid} → :missing_kid
      header = %{"alg" => "RS256"}  # no "kid" key
      claims = %{
        "iss" => "https://accounts.google.com",
        "exp" => System.system_time(:second) + 3600
      }
      token = build_unsigned_jwt(claims, header)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      assert {:untrusted, :missing_kid} = GCP.verify(ctx)
    end
  end

  describe "JWKS cache expiration" do
    test "expired JWKS cache triggers a refetch attempt (cache miss path)", %{jwk: jwk} do
      # Overwrite the cache entry with a stale timestamp (older than 3600s TTL)
      # age = now - stale_time = 4000 > 3600 → get_cached_keys returns :miss
      stale_time = System.monotonic_time(:second) - 4000

      :ets.insert(
        :gcp_jwks_cache,
        {:keys, %{"keys" => []}, stale_time}
      )

      claims = valid_gcp_claims()
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      # Stale cache → refetch attempted. Outcome depends on network:
      #   - No network: {:untrusted, :keys_unavailable}
      #   - Real JWKS fetched but test kid absent: {:untrusted, :key_not_found}
      # Either way the token is untrusted (test key is not a real Google key)
      result = GCP.verify(ctx)
      assert elem(result, 0) == :untrusted
      assert elem(result, 1) in [:keys_unavailable, :key_not_found]
    end
  end

  describe "find_key fallback — malformed JWKS structure" do
    test "rejects token when cached JWKS has no 'keys' field", %{jwk: jwk} do
      # find_key(_, _) catch-all is triggered when jwks is not %{"keys" => [...]}
      # Overwrite cache with a JWKS map that has no "keys" key
      :ets.insert(:gcp_jwks_cache, {:keys, %{"not_keys" => []}, System.monotonic_time(:second)})

      claims = valid_gcp_claims()
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      # find_key(%{"not_keys" => []}, kid) hits fallback → :key_not_found
      assert {:untrusted, :key_not_found} = GCP.verify(ctx)
    end
  end

  describe "find_key — malformed key map" do
    test "rejects token when matching key has invalid JWK fields", %{jwk: jwk} do
      # A key with matching kid but invalid/missing JWK fields should not crash
      malformed_key = %{"kid" => @kid, "kty" => "INVALID", "bogus" => true}
      :ets.insert(:gcp_jwks_cache, {:keys, %{"keys" => [malformed_key]}, System.monotonic_time(:second)})

      claims = valid_gcp_claims()
      token = sign_jwt(claims, jwk)
      ctx = build_context(%{"provider" => "gcp", "token" => token})

      # Should return error, not crash
      result = GCP.verify(ctx)
      assert {:untrusted, reason} = result
      assert reason in [:key_not_found, :invalid_signature]
    end
  end

  describe "evidence structure" do
    test "evidence contains all expected fields", %{jwk: jwk} do
      claims = valid_gcp_claims()
      token = sign_jwt(claims, jwk)
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
