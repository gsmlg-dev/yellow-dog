defmodule YellowDogIdentity.Trust.Token.Verifier do
  @moduledoc """
  Provisioning token trust provider.

  Verifies registration requests that include an Authorization header
  containing a provisioning token.
  """

  @behaviour YellowDogIdentity.Trust.Provider

  @impl true
  def verify(%{authorization: nil}), do: {:skip, :not_applicable}
  def verify(%{authorization: ""}), do: {:skip, :not_applicable}

  def verify(%{authorization: auth_header, hostname: hostname} = _context) do
    raw_token = extract_bearer_token(auth_header)

    if raw_token do
      verify_against_stored_tokens(raw_token, hostname)
    else
      {:skip, :not_applicable}
    end
  end

  def verify(_), do: {:skip, :not_applicable}

  defp extract_bearer_token("Bearer " <> token), do: String.trim(token)
  defp extract_bearer_token(token) when is_binary(token), do: String.trim(token)
  defp extract_bearer_token(_), do: nil

  defp verify_against_stored_tokens(raw_token, hostname) do
    case Code.ensure_loaded(YellowDogIdentity.Registry) do
      {:module, _} ->
        try do
          case YellowDogIdentity.Registry.consume_token(raw_token, hostname) do
            {:ok, token} ->
              evidence = %{
                provider: :token,
                token_id: token.id,
                hostname_pattern: token.hostname_pattern,
                role: token.role,
                verified_at: DateTime.utc_now()
              }

              {:trusted, :token_verified, evidence}

            {:error, reason} ->
              {:untrusted, reason}
          end
        rescue
          _ -> {:untrusted, :invalid_token}
        catch
          :exit, _ -> {:untrusted, :invalid_token}
        end

      _ ->
        {:untrusted, :invalid_token}
    end
  end
end
