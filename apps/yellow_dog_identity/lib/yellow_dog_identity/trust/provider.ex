defmodule YellowDogIdentity.Trust.Provider do
  @moduledoc """
  Behaviour for trust providers.

  Each trust provider verifies a registration context and returns a trust result.
  Providers are tried in priority order by the router; first `{:trusted, ...}` wins.
  """

  @type registration_context :: %{
          source_ip: :inet.ip_address(),
          hostname: String.t(),
          attestation: map() | nil,
          metadata: map(),
          authorization: String.t() | nil
        }

  @type trust_level ::
          :cloud_verified
          | :netboot_verified
          | :network_verified
          | :network_partial
          | :token_verified

  @type trust_result ::
          {:trusted, trust_level(), evidence :: map()}
          | {:untrusted, reason :: atom()}
          | {:skip, :not_applicable}

  @doc """
  Verifies a registration context and returns a trust result.

  Returns:
  - `{:trusted, trust_level, evidence}` — verification succeeded
  - `{:untrusted, reason}` — verification failed
  - `{:skip, :not_applicable}` — provider doesn't apply to this context
  """
  @callback verify(registration_context()) :: trust_result()
end
