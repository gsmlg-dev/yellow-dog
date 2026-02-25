defmodule YellowDogIdentity.Trust.Cloud.Azure do
  @moduledoc """
  Azure attested document verification.

  Verifies attested documents from Azure IMDS against Azure's certificate chain.
  Note: Full certificate chain verification requires the `x509` dependency which is
  not yet added. Currently validates claims and structure; signature verification
  is a TODO.
  """

  @behaviour YellowDogIdentity.Trust.Provider

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
    # TODO: Verify certificate chain against Azure CA (requires x509 dep)

    with {:ok, document_json} <- decode_document(document_b64),
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
