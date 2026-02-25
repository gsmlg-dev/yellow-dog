defmodule YellowDogIdentity.Trust.Router do
  @moduledoc """
  Routes registration contexts through the trust provider chain.

  Providers are tried in priority order. First `{:trusted, ...}` wins.
  If all providers return `{:skip, ...}`, the result is `{:unverified, :none, %{}}`.
  """

  alias YellowDogIdentity.Trust.Provider

  @default_providers [
    YellowDogIdentity.Trust.Cloud.Attestation,
    YellowDogIdentity.Trust.Netboot,
    YellowDogIdentity.Trust.DHCP.Correlation,
    YellowDogIdentity.Trust.Token.Verifier
  ]

  @doc """
  Verifies a registration context by dispatching to providers in priority order.

  Returns `{trust_level, trust_provider, evidence}` tuple.
  """
  @spec verify(Provider.registration_context(), keyword()) ::
          {YellowDogIdentity.Host.trust_level(), YellowDogIdentity.Host.trust_provider(), map()}
  def verify(context, opts \\ []) do
    providers = Keyword.get(opts, :providers, @default_providers)

    start_time = System.monotonic_time()

    result =
      Enum.reduce_while(providers, {:unverified, :none, %{}}, fn provider, acc ->
        case provider.verify(context) do
          {:trusted, trust_level, evidence} ->
            provider_name = provider_atom(provider, evidence)
            {:halt, {trust_level, provider_name, evidence}}

          {:untrusted, reason} ->
            provider_name = provider_atom(provider, %{})
            YellowDogIdentity.Telemetry.trust_untrusted(provider_name, reason, context.hostname)

            # Halt on untrusted — a provider that explicitly rejects should
            # not allow fallthrough to weaker providers (per PRD §5.1)
            {:halt, {:unverified, :none, %{rejected_by: provider_name, reason: reason}}}

          {:skip, :not_applicable} ->
            {:cont, acc}
        end
      end)

    duration = System.monotonic_time() - start_time

    {trust_level, provider_name, _evidence} = result

    YellowDogIdentity.Telemetry.trust_resolved(
      duration,
      trust_level,
      provider_name,
      context.hostname
    )

    result
  end

  # Cloud.Attestation dispatches to AWS/GCP/Azure — extract the specific provider
  # from evidence so trust_provider reflects the actual cloud (`:aws`, `:gcp`, `:azure`).
  defp provider_atom(YellowDogIdentity.Trust.Cloud.Attestation, evidence) do
    case Map.get(evidence, :provider) || Map.get(evidence, "provider") do
      :aws -> :aws
      :gcp -> :gcp
      :azure -> :azure
      _ -> :cloud
    end
  end

  defp provider_atom(module, _evidence), do: provider_atom(module)

  defp provider_atom(YellowDogIdentity.Trust.Cloud.AWS), do: :aws
  defp provider_atom(YellowDogIdentity.Trust.Cloud.GCP), do: :gcp
  defp provider_atom(YellowDogIdentity.Trust.Cloud.Azure), do: :azure
  defp provider_atom(YellowDogIdentity.Trust.Netboot), do: :netboot
  defp provider_atom(YellowDogIdentity.Trust.DHCP.Correlation), do: :dhcp
  defp provider_atom(YellowDogIdentity.Trust.Token.Verifier), do: :token
  defp provider_atom(_module), do: :unknown
end
