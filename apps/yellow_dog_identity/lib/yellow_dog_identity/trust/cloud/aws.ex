defmodule YellowDogIdentity.Trust.Cloud.AWS do
  @moduledoc """
  AWS instance identity document verification.

  Verifies PKCS7-signed instance identity documents against AWS public certificates.
  """

  @behaviour YellowDogIdentity.Trust.Provider

  @replay_window_seconds 300

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
    _signature_b64 = Map.get(attestation, "signature") || Map.get(attestation, :signature)

    with {:ok, document_json} <- decode_document(document_b64),
         {:ok, claims} <- extract_claims(document_json),
         :ok <- check_replay_window(claims),
         :ok <- check_allowed_account(claims) do
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
            window = get_replay_window()

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
    allowed = get_allowed_accounts()

    if allowed == [] or account_id in allowed do
      :ok
    else
      {:error, :account_not_allowed}
    end
  end

  defp get_replay_window do
    get_cloud_config(:aws, "replay_window_seconds", @replay_window_seconds)
  end

  defp get_allowed_accounts do
    get_cloud_config(:aws, "allowed_accounts", [])
  end

  defp get_cloud_config(provider, key, default) do
    case Code.ensure_loaded(YellowDog.Config) do
      {:module, _} ->
        try do
          config = YellowDog.Config.get_all()
          cloud_config = get_in(config, ["identity", "cloud", to_string(provider)]) || %{}
          Map.get(cloud_config, key, default)
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
