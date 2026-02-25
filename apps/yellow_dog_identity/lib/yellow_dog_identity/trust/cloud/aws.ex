defmodule YellowDogIdentity.Trust.Cloud.AWS do
  @moduledoc """
  AWS instance identity document verification.

  Verifies PKCS7-signed instance identity documents against AWS public
  certificates. The document is signed with RSA and the signature is
  delivered as a PKCS7 (CMS SignedData) structure.
  """

  @behaviour YellowDogIdentity.Trust.Provider

  @replay_window_seconds 300

  require Logger

  # AWS public certificates for instance identity document signing (per region)
  # Loaded from config or fetched from AWS. The certificate is region-specific.
  # See: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/verify-signature.html

  @impl true
  def verify(%{attestation: attestation} = context) do
    provider = Map.get(attestation, "provider") || Map.get(attestation, :provider)

    if provider in ["aws", :aws] do
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

    with {:ok, document_json} <- decode_document(document_b64),
         :ok <- verify_pkcs7_signature(document_json, signature_b64),
         {:ok, claims} <- extract_claims(document_json),
         :ok <- check_replay_window(claims),
         :ok <- check_allowed_account(claims),
         :ok <- check_allowed_regions(claims) do
      evidence = %{
        provider: :aws,
        account_id: claims["accountId"],
        instance_id: claims["instanceId"],
        region: claims["region"],
        image_id: claims["imageId"],
        instance_type: claims["instanceType"],
        verified_at: DateTime.utc_now(),
        document_time: claims["pendingTime"]
      }

      duration = System.monotonic_time() - start_time

      YellowDogIdentity.Telemetry.attestation_verify(
        duration,
        :aws,
        claims["accountId"],
        claims["instanceId"],
        :verified
      )

      {:trusted, :cloud_verified, evidence}
    else
      {:error, reason} ->
        YellowDogIdentity.Telemetry.attestation_reject(:aws, reason, context.source_ip)
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

  defp check_replay_window(claims) do
    case Map.get(claims, "pendingTime") do
      nil ->
        :ok

      pending_time when is_binary(pending_time) ->
        case DateTime.from_iso8601(pending_time) do
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

  defp check_allowed_account(claims) do
    account_id = Map.get(claims, "accountId")
    allowed = get_cloud_config("allowed_accounts", [])

    if allowed == [] or account_id in allowed do
      :ok
    else
      {:error, :account_not_allowed}
    end
  end

  defp check_allowed_regions(claims) do
    region = Map.get(claims, "region")
    allowed = get_cloud_config("allowed_regions", [])

    if allowed == [] or region in allowed do
      :ok
    else
      {:error, :region_not_allowed}
    end
  end

  defp verify_pkcs7_signature(document, signature_b64) do
    case get_aws_cert_pem() do
      nil ->
        # No certificate configured — skip signature verification (claims-only mode)
        :ok

      _cert_pem when is_nil(signature_b64) ->
        {:error, :missing_signature}

      cert_pem ->
        do_verify_signature(document, signature_b64, cert_pem)
    end
  end

  defp do_verify_signature(document, signature_b64, cert_pem) do
    with {:ok, sig_der} <- decode_signature(signature_b64),
         {:ok, rsa_key} <- extract_cert_public_key(cert_pem),
         {:ok, raw_sig} <- extract_pkcs7_signature(sig_der) do
      # AWS signs with SHA1 (SHA-1 with RSA) for the PKCS7 signature
      if :public_key.verify(document, :sha, raw_sig, rsa_key) or
           :public_key.verify(document, :sha256, raw_sig, rsa_key) do
        :ok
      else
        {:error, :invalid_signature}
      end
    end
  rescue
    e ->
      Logger.warning("AWS signature verification failed: #{Exception.message(e)}")
      {:error, :signature_verification_failed}
  end

  defp decode_signature(signature_b64) do
    cleaned = String.replace(signature_b64, ["\n", "\r", " "], "")

    case Base.decode64(cleaned) do
      {:ok, der} -> {:ok, der}
      :error -> {:error, :invalid_signature_encoding}
    end
  end

  defp extract_cert_public_key(cert_pem) do
    case :public_key.pem_decode(cert_pem) do
      [{:Certificate, cert_der, :not_encrypted} | _] ->
        cert = :public_key.pkix_decode_cert(cert_der, :otp)
        tbs = elem(cert, 1)
        spki = elem(tbs, 7)
        # In OTP cert format: element 2 of SPKI is the public key record
        {:ok, elem(spki, 2)}

      _ ->
        {:error, :invalid_cert_format}
    end
  rescue
    _ -> {:error, :cert_decode_failed}
  end

  defp extract_pkcs7_signature(der) do
    # PKCS7 SignedData: outer ContentInfo wraps SignedData with signerInfos
    case :public_key.der_decode(:"ContentInfo", der) do
      {:"ContentInfo", _content_type, signed_data_der} ->
        case :public_key.der_decode(:"SignedData", signed_data_der) do
          signed_data when is_tuple(signed_data) ->
            # SignerInfos is typically the last element
            signer_infos = elem(signed_data, tuple_size(signed_data) - 1)
            extract_first_signature(signer_infos)

          _ ->
            {:error, :invalid_pkcs7_structure}
        end

      _ ->
        {:error, :invalid_pkcs7_structure}
    end
  rescue
    _ -> {:error, :pkcs7_decode_failed}
  end

  defp extract_first_signature([signer_info | _]) when is_tuple(signer_info) do
    # Signature is typically at index 6 in the SignerInfo record
    sig = elem(signer_info, 6)

    if is_binary(sig) do
      {:ok, sig}
    else
      {:error, :no_signature_in_signer_info}
    end
  rescue
    _ -> {:error, :signer_info_decode_failed}
  end

  defp extract_first_signature(_), do: {:error, :no_signer_info}

  defp get_aws_cert_pem do
    get_cloud_config("certificate_pem", nil)
  end

  defp get_cloud_config(key, default) do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          config = YellowDog.Config.get_all()
          aws_config = get_in(config, ["identity", "cloud", "aws"]) || %{}
          Map.get(aws_config, key, default)
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
