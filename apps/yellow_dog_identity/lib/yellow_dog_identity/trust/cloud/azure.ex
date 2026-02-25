defmodule YellowDogIdentity.Trust.Cloud.Azure do
  @moduledoc """
  Azure attested document verification.

  Verifies attested documents from Azure IMDS. Validates claims, timestamp
  anti-replay, subscription/location allowlists, and optionally verifies
  the document signature against a configured certificate.
  """

  @behaviour YellowDogIdentity.Trust.Provider

  require Logger

  @replay_window_seconds 300

  @impl true
  def verify(%{attestation: attestation} = context) do
    provider = Map.get(attestation, "provider") || Map.get(attestation, :provider)

    if provider in ["azure", :azure] do
      do_verify(attestation, context)
    else
      {:skip, :not_applicable}
    end
  end

  def verify(_), do: {:skip, :not_applicable}

  defp do_verify(attestation, context) do
    start_time = System.monotonic_time()

    document_b64 = Map.get(attestation, "document") || Map.get(attestation, :document)
    signature_b64 = Map.get(attestation, "signature") || Map.get(attestation, :signature)
    cert_chain = Map.get(attestation, "certificate") || Map.get(attestation, :certificate)

    with {:ok, document_json} <- decode_document(document_b64),
         :ok <- verify_azure_signature(document_json, signature_b64, cert_chain),
         {:ok, claims} <- extract_claims(document_json),
         :ok <- check_timestamp(claims),
         :ok <- check_allowed_subscription(claims),
         :ok <- check_allowed_locations(claims) do
      evidence = %{
        provider: :azure,
        subscription_id: Map.get(claims, "subscriptionId"),
        vm_id: Map.get(claims, "vmId"),
        resource_group: Map.get(claims, "resourceGroupName"),
        location: Map.get(claims, "location"),
        verified_at: DateTime.utc_now()
      }

      duration = System.monotonic_time() - start_time

      YellowDogIdentity.Telemetry.attestation_verify(
        duration,
        :azure,
        evidence.subscription_id,
        evidence.vm_id,
        :verified
      )

      {:trusted, :cloud_verified, evidence}
    else
      {:error, reason} ->
        YellowDogIdentity.Telemetry.attestation_reject(:azure, reason, context.source_ip)
        {:untrusted, reason}
    end
  end

  defp decode_document(nil), do: {:error, :missing_document}

  defp decode_document(document_b64) do
    case Base.decode64(document_b64) do
      {:ok, json} -> {:ok, json}
      :error -> {:error, :invalid_document_encoding}
    end
  end

  defp extract_claims(json) do
    case Jason.decode(json) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      _ -> {:error, :invalid_document_format}
    end
  rescue
    _ -> {:error, :json_decode_failed}
  end

  defp check_timestamp(claims) do
    case Map.get(claims, "timestamp") do
      nil ->
        :ok

      timestamp when is_binary(timestamp) ->
        case DateTime.from_iso8601(timestamp) do
          {:ok, dt, _} ->
            age = DateTime.diff(DateTime.utc_now(), dt, :second)
            window = get_cloud_config("replay_window_seconds", @replay_window_seconds)

            if age <= window do
              :ok
            else
              {:error, :document_too_old}
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp check_allowed_subscription(claims) do
    subscription_id = Map.get(claims, "subscriptionId")
    allowed = get_cloud_config("allowed_subscriptions", [])

    if allowed == [] or subscription_id in allowed do
      :ok
    else
      {:error, :subscription_not_allowed}
    end
  end

  defp check_allowed_locations(claims) do
    location = Map.get(claims, "location")
    allowed = get_cloud_config("allowed_locations", [])

    if allowed == [] or location in allowed do
      :ok
    else
      {:error, :location_not_allowed}
    end
  end

  defp verify_azure_signature(_document, nil, _cert_chain) do
    # No signature provided — skip verification (claims-only mode)
    :ok
  end

  defp verify_azure_signature(document, signature_b64, cert_pem) do
    with {:ok, sig_bytes} <- decode_base64(signature_b64),
         {:ok, public_key} <- extract_signing_key(cert_pem) do
      # Azure signs with RSA-SHA256
      if :public_key.verify(document, :sha256, sig_bytes, public_key) do
        :ok
      else
        {:error, :invalid_signature}
      end
    else
      {:error, :no_certificate} ->
        # No certificate chain provided — skip signature verification
        Logger.warning("Azure signature verification skipped: no certificate provided")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      Logger.warning("Azure signature verification failed: #{Exception.message(e)}")
      {:error, :signature_verification_failed}
  end

  defp decode_base64(b64) do
    cleaned = String.replace(b64, ["\n", "\r", " "], "")

    case Base.decode64(cleaned) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, :invalid_signature_encoding}
    end
  end

  defp extract_signing_key(nil), do: {:error, :no_certificate}
  defp extract_signing_key(""), do: {:error, :no_certificate}

  defp extract_signing_key(cert_pem) when is_binary(cert_pem) do
    case :public_key.pem_decode(cert_pem) do
      [{:Certificate, cert_der, :not_encrypted} | _] ->
        cert = :public_key.pkix_decode_cert(cert_der, :otp)
        tbs = elem(cert, 1)
        spki = elem(tbs, 7)
        {:ok, elem(spki, 2)}

      _ ->
        {:error, :invalid_certificate}
    end
  rescue
    _ -> {:error, :cert_decode_failed}
  end

  defp get_cloud_config(key, default) do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          config = YellowDog.Config.get_all()
          azure_config = get_in(config, ["identity", "cloud", "azure"]) || %{}
          Map.get(azure_config, key, default)
        rescue
          _ -> default
        catch
          :exit, _ -> default
        end

      _ ->
        default
    end
  end
end
