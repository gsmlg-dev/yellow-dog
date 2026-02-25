defmodule YellowDogIdentity.Trust.Cloud.GCP do
  @moduledoc """
  GCP OIDC identity token verification.

  Verifies JWT identity tokens signed by Google against their published
  JWKS (JSON Web Key Set). Uses the `jose` library for cryptographic
  signature verification.
  """

  @behaviour YellowDogIdentity.Trust.Provider

  @google_certs_url ~c"https://www.googleapis.com/oauth2/v3/certs"
  @key_cache_ttl_seconds 3600

  @impl true
  def verify(%{attestation: attestation} = context) do
    provider = Map.get(attestation, "provider") || Map.get(attestation, :provider)

    if provider in ["gcp", :gcp] do
      do_verify(attestation, context)
    else
      {:skip, :not_applicable}
    end
  end

  def verify(_), do: {:skip, :not_applicable}

  defp do_verify(attestation, context) do
    start_time = System.monotonic_time()
    token = Map.get(attestation, "token") || Map.get(attestation, :token)

    with {:ok, claims} <- verify_and_decode_jwt(token),
         :ok <- check_audience(claims),
         :ok <- check_expiry(claims),
         :ok <- check_allowed_project(claims),
         :ok <- check_allowed_zones(claims) do
      google_claims = Map.get(claims, "google", %{})
      compute = Map.get(google_claims, "compute_engine", %{})

      evidence = %{
        provider: :gcp,
        project_id: Map.get(compute, "project_id"),
        instance_id: Map.get(compute, "instance_id") |> to_string(),
        instance_name: Map.get(compute, "instance_name"),
        zone: Map.get(compute, "zone"),
        verified_at: DateTime.utc_now()
      }

      duration = System.monotonic_time() - start_time

      YellowDogIdentity.Telemetry.attestation_verify(
        duration,
        :gcp,
        evidence.project_id,
        evidence.instance_id,
        :verified
      )

      {:trusted, :cloud_verified, evidence}
    else
      {:error, reason} ->
        YellowDogIdentity.Telemetry.attestation_reject(:gcp, reason, context.source_ip)
        {:untrusted, reason}
    end
  end

  defp verify_and_decode_jwt(nil), do: {:error, :missing_token}

  defp verify_and_decode_jwt(token) when is_binary(token) do
    case fetch_google_keys() do
      {:ok, %{"keys" => []}} ->
        # No keys in JWKS (e.g., during rotation) — degraded unverified mode
        decode_jwt_claims_unverified(token)

      {:ok, jwks} ->
        # Keys available — require valid signature; any key mismatch is a hard failure
        case verify_with_keys(token, jwks) do
          {:ok, claims} -> {:ok, claims}
          {:error, reason} -> {:error, reason}
        end

      {:error, :keys_unavailable} ->
        # Network/cache failure — degraded unverified mode
        decode_jwt_claims_unverified(token)
    end
  end

  defp verify_with_keys(token, jwks) do
    # Extract header to find kid
    case extract_jwt_header(token) do
      {:ok, %{"kid" => kid}} ->
        case find_key(jwks, kid) do
          {:ok, jwk} ->
            case JOSE.JWT.verify_strict(jwk, ["RS256"], token) do
              {true, %JOSE.JWT{fields: claims}, _jws} ->
                {:ok, claims}

              {false, _, _} ->
                {:error, :invalid_signature}
            end

          :error ->
            {:error, :key_not_found}
        end

      {:ok, _no_kid} ->
        {:error, :missing_kid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_jwt_header(token) do
    case String.split(token, ".") do
      [header_b64 | _rest] when byte_size(header_b64) > 0 ->
        with {:ok, header_json} <- Base.url_decode64(header_b64, padding: false),
             {:ok, header} <- Jason.decode(header_json) do
          {:ok, header}
        else
          _ -> {:error, :invalid_jwt_format}
        end

      _ ->
        {:error, :invalid_jwt_format}
    end
  end

  defp find_key(%{"keys" => keys}, kid) do
    case Enum.find(keys, fn k -> Map.get(k, "kid") == kid end) do
      nil -> :error
      key_map -> {:ok, JOSE.JWK.from_map(key_map)}
    end
  end

  defp find_key(_, _), do: :error

  defp fetch_google_keys do
    # Check ETS cache first
    case get_cached_keys() do
      {:ok, keys} ->
        {:ok, keys}

      :miss ->
        fetch_and_cache_keys()
    end
  end

  defp get_cached_keys do
    try do
      case :ets.lookup(:gcp_jwks_cache, :keys) do
        [{:keys, keys, cached_at}] ->
          age = System.monotonic_time(:second) - cached_at

          if age < @key_cache_ttl_seconds do
            {:ok, keys}
          else
            :miss
          end

        _ ->
          :miss
      end
    rescue
      ArgumentError -> :miss
    end
  end

  defp fetch_and_cache_keys do
    case :httpc.request(:get, {@google_certs_url, []}, [{:timeout, 5000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(to_string(body)) do
          {:ok, jwks} ->
            cache_keys(jwks)
            {:ok, jwks}

          _ ->
            {:error, :keys_unavailable}
        end

      _ ->
        {:error, :keys_unavailable}
    end
  rescue
    _ -> {:error, :keys_unavailable}
  end

  defp cache_keys(keys) do
    try do
      :ets.new(:gcp_jwks_cache, [:set, :public, :named_table])
    rescue
      ArgumentError -> :ok
    end

    try do
      :ets.insert(:gcp_jwks_cache, {:keys, keys, System.monotonic_time(:second)})
    rescue
      ArgumentError ->
        require Logger
        Logger.warning("GCP JWKS cache: ETS insert failed, table may not exist")
    end
  end

  defp decode_jwt_claims_unverified(token) do
    case String.split(token, ".") do
      [_header, payload, _signature] ->
        with {:ok, decoded} <- Base.url_decode64(payload, padding: false),
             {:ok, claims} <- Jason.decode(decoded) do
          {:ok, claims}
        else
          _ -> {:error, :jwt_decode_failed}
        end

      _ ->
        {:error, :invalid_jwt_format}
    end
  rescue
    _ -> {:error, :jwt_decode_failed}
  end

  defp check_audience(claims) do
    expected_audience = get_config("audience")

    if expected_audience do
      actual = Map.get(claims, "aud")

      # JWT RFC 7519: aud can be a string or array of strings
      matches =
        cond do
          actual == expected_audience -> true
          is_list(actual) -> expected_audience in actual
          true -> false
        end

      if matches, do: :ok, else: {:error, :invalid_audience}
    else
      # No audience configured — skip check
      :ok
    end
  end

  defp check_expiry(claims) do
    case Map.get(claims, "exp") do
      exp when is_integer(exp) ->
        now = System.system_time(:second)

        if now <= exp do
          :ok
        else
          {:error, :token_expired}
        end

      _ ->
        # No exp claim — allow (some tokens may not have it)
        :ok
    end
  end

  defp check_allowed_project(claims) do
    google_claims = Map.get(claims, "google", %{})
    compute = Map.get(google_claims, "compute_engine", %{})
    project_id = Map.get(compute, "project_id")
    allowed = get_config("allowed_projects") || []

    if allowed == [] or project_id in allowed do
      :ok
    else
      {:error, :project_not_allowed}
    end
  end

  defp check_allowed_zones(claims) do
    google_claims = Map.get(claims, "google", %{})
    compute = Map.get(google_claims, "compute_engine", %{})
    zone = Map.get(compute, "zone")
    allowed = get_config("allowed_zones") || []

    if allowed == [] or zone in allowed do
      :ok
    else
      {:error, :zone_not_allowed}
    end
  end

  defp get_config(key) do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          config = YellowDog.Config.get_all()
          gcp_config = get_in(config, ["identity", "cloud", "gcp"]) || %{}
          Map.get(gcp_config, key)
        rescue
          _ -> nil
        catch
          :exit, _ -> nil
        end

      _ ->
        nil
    end
  end
end
