defmodule YellowDog.Management.Access do
  @moduledoc "Fixed Management permissions, checked again for every call and receipt replay."
  alias YellowDog.Management.{Caller, IntegrationSettings}
  def scopes, do: IntegrationSettings.scopes()

  def authorize(%Caller{} = caller, scope) do
    config = IntegrationSettings.get()

    result =
      cond do
        scope not in scopes() ->
          denied()

        caller.expires_at <= System.system_time(:second) ->
          {:error, %{code: "invalid_token", message: "Authorization expired"}}

        caller.policy_revision != config.policy_revision ->
          denied()

        not provenance?(caller, config.mode) ->
          denied()

        caller.source == :http and not config.http_enabled ->
          disabled()

        caller.source == :mcp and not config.mcp_enabled ->
          disabled()

        scope not in caller.scopes or scope not in config.allowed_scopes ->
          denied()

        scope not in ["config:read", "audit:read"] and caller.source in [:http, :mcp] and
            not config.write_enabled ->
          denied()

        true ->
          :ok
      end

    case result do
      {:error, error} -> YellowDog.Management.Limits.denied(caller.source, error.code)
      _ -> :ok
    end

    result
  end

  def authorize(_, _), do: denied()

  def ui_admin(%Caller{source: :ui} = caller), do: authorize(caller, "ui:admin")
  def ui_admin(_), do: denied()
  defp provenance?(%Caller{authentication: :trusted_local}, :trusted_local), do: true
  defp provenance?(%Caller{authentication: :gateway, source: :ui}, :protected_remote), do: true

  defp provenance?(%Caller{authentication: :access_token, source: source}, :protected_remote),
    do: source in [:http, :mcp]

  defp provenance?(_, _), do: false

  defp denied,
    do:
      {:error, %{code: "forbidden", message: "Caller is not permitted to perform this operation"}}

  defp disabled,
    do: {:error, %{code: "adapters_disabled", message: "Management integration is disabled"}}
end
