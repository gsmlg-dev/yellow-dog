defmodule YellowDog.Netman.Control.Vpn do
  @moduledoc """
  Read-only projection of Netman VPN profile configuration state.

  This module intentionally has no mutation callback surface.
  """

  alias YellowDog.Sync.{Digest, Error}

  @test_environment Mix.env() == :test

  @spec dispatch(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def dispatch("netman.vpn.profile.get", _payload) do
    case profile_resolver().resolve() do
      %{profile: profile, features: features} when is_map(features) ->
        with {:ok, profile_id} <- profile_id(profile),
             result = %{
               "profile_id" => profile_id,
               "state" =>
                 if(Map.get(features, :vpn, false) == true, do: "resolved", else: "unavailable")
             },
             {:ok, revision} <- Digest.calculate(result) do
          {:ok, Map.put(result, "revision", revision)}
        end

      _invalid ->
        internal_error()
    end
  end

  def dispatch(_operation, _payload), do: unsupported_error()

  defp profile_id(profile) when is_atom(profile) and not is_nil(profile),
    do: {:ok, Atom.to_string(profile)}

  defp profile_id(profile) when is_binary(profile) and byte_size(profile) > 0,
    do: {:ok, profile}

  defp profile_id(_profile), do: invalid_error()

  if @test_environment do
    defp profile_resolver do
      case Application.get_env(:yellow_dog_netman, __MODULE__, []) do
        config when is_list(config) ->
          Keyword.get(config, :profile_resolver, YellowDog.Netman.ProfileResolver)

        _invalid ->
          YellowDog.Netman.ProfileResolver
      end
    end
  else
    defp profile_resolver, do: YellowDog.Netman.ProfileResolver
  end

  defp invalid_error, do: {:error, Error.new(:invalid, "invalid value", %{})}

  defp unsupported_error,
    do: {:error, Error.new(:unsupported, "unsupported operation", %{})}

  defp internal_error, do: {:error, Error.new(:internal, "internal error", %{})}
end
