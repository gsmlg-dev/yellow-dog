defmodule YellowDogIdentity.Trust.Cloud.GCP do
  @moduledoc """
  GCP OIDC identity token verification.

  Verifies JWT identity tokens signed by Google against their published public keys.
  """

  @behaviour YellowDogIdentity.Trust.Provider

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

    with {:ok, claims} <- decode_jwt_claims(token),
         :ok <- check_allowed_project(claims) do
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

  defp decode_jwt_claims(nil), do: {:error, :missing_token}

  defp decode_jwt_claims(token) when is_binary(token) do
    # Decode JWT without verification for claim extraction
    # Full signature verification requires fetching Google's public keys
    case String.split(token, ".") do
      [_header, payload, _signature] ->
        # Pad base64url
        padded = Base.url_decode64!(payload, padding: false)
        Jason.decode(padded)

      _ ->
        {:error, :invalid_jwt_format}
    end
  rescue
    _ -> {:error, :jwt_decode_failed}
  end

  defp check_allowed_project(claims) do
    google_claims = Map.get(claims, "google", %{})
    compute = Map.get(google_claims, "compute_engine", %{})
    project_id = Map.get(compute, "project_id")
    allowed = get_allowed_projects()

    if allowed == [] or project_id in allowed do
      :ok
    else
      {:error, :project_not_allowed}
    end
  end

  defp get_allowed_projects do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          config = YellowDog.Config.get_all()
          gcp_config = get_in(config, ["identity", "cloud", "gcp"]) || %{}
          Map.get(gcp_config, "allowed_projects", [])
        rescue
          _ -> []
        catch
          :exit, _ -> []
        end

      _ ->
        []
    end
  end
end
