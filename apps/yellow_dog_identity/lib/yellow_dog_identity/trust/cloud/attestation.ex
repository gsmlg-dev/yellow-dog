defmodule YellowDogIdentity.Trust.Cloud.Attestation do
  @moduledoc """
  Cloud attestation trust provider dispatch.

  Routes attestation documents to the appropriate cloud-specific verifier
  based on the `provider` field in the attestation payload.
  """

  @behaviour YellowDogIdentity.Trust.Provider

  alias YellowDogIdentity.Trust.Cloud.{AWS, GCP, Azure}

  @impl true
  def verify(%{attestation: nil}), do: {:skip, :not_applicable}
  def verify(%{attestation: attestation}) when map_size(attestation) == 0, do: {:skip, :not_applicable}

  def verify(%{attestation: attestation} = context) do
    provider = Map.get(attestation, "provider") || Map.get(attestation, :provider)

    case provider do
      p when p in ["aws", :aws] -> AWS.verify(context)
      p when p in ["gcp", :gcp] -> GCP.verify(context)
      p when p in ["azure", :azure] -> Azure.verify(context)
      nil -> {:skip, :not_applicable}
      _ -> {:untrusted, :unknown_cloud_provider}
    end
  end

  def verify(_context), do: {:skip, :not_applicable}
end
