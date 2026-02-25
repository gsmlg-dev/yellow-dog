defmodule YellowDogIdentity.Trust.Token.Verifier do
  @moduledoc """
  Provisioning token trust provider.

  Verifies registration requests that include an Authorization header
  containing a provisioning token.
  """

  @behaviour YellowDogIdentity.Trust.Provider

  require Logger

  alias YellowDogIdentity.Token

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
    tokens = load_tokens()
    find_matching_token(tokens, raw_token, hostname)
  end

  defp find_matching_token(tokens, raw_token, hostname) do
    Enum.reduce_while(tokens, {:untrusted, :invalid_token}, fn token, _acc ->
      case Token.verify(token, raw_token, hostname) do
        :ok ->
          # Increment use count and persist
          updated_token = Token.increment_use(token)
          persist_token_update(updated_token)

          evidence = %{
            provider: :token,
            token_id: token.id,
            hostname_pattern: token.hostname_pattern,
            role: token.role,
            verified_at: DateTime.utc_now()
          }

          {:halt, {:trusted, :token_verified, evidence}}

        {:error, :hostname_mismatch} ->
          {:cont, {:untrusted, :hostname_mismatch}}

        {:error, _reason} ->
          {:cont, {:untrusted, :invalid_token}}
      end
    end)
  end

  defp persist_token_update(token) do
    try do
      YellowDogIdentity.Registry.put_token(token)
    rescue
      e ->
        Logger.warning("Failed to persist token use_count update for #{token.id}: #{Exception.message(e)}")
        :ok
    catch
      :exit, reason ->
        Logger.warning("Failed to persist token use_count update for #{token.id}: #{inspect(reason)}")
        :ok
    end
  end

  defp load_tokens do
    case Code.ensure_loaded(YellowDogIdentity.Registry) do
      {:module, _} ->
        try do
          YellowDogIdentity.Registry.list_tokens()
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
