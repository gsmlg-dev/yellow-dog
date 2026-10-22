defmodule YellowDog.Management.IntegrationSettings do
  @moduledoc "Deployment trust configuration for the Management resource server."
  alias YellowDog.Management.SettingsIP

  @scopes ~w(config:read nodes:write data:write targets:publish sync:run sync:settings audit:read ui:admin)
  def scopes, do: @scopes

  def get do
    defaults = %{
      mode: mode(System.get_env("YELLOW_DOG_MANAGEMENT_AUTH_MODE", "disabled")),
      http_enabled: enabled?("YELLOW_DOG_MANAGEMENT_API_ENABLED"),
      mcp_enabled: enabled?("YELLOW_DOG_MANAGEMENT_MCP_ENABLED"),
      write_enabled: enabled?("YELLOW_DOG_MANAGEMENT_REMOTE_WRITES_ENABLED"),
      resource: resource(),
      issuer: System.get_env("YELLOW_DOG_MANAGEMENT_OAUTH_ISSUER"),
      access_jwks_file: System.get_env("YELLOW_DOG_MANAGEMENT_OAUTH_JWKS_FILE"),
      gateway_issuer: System.get_env("YELLOW_DOG_MANAGEMENT_GATEWAY_ISSUER"),
      gateway_audience: System.get_env("YELLOW_DOG_MANAGEMENT_GATEWAY_AUDIENCE"),
      gateway_jwks_file: System.get_env("YELLOW_DOG_MANAGEMENT_GATEWAY_JWKS_FILE"),
      operator: System.get_env("YELLOW_DOG_MANAGEMENT_LOCAL_OPERATOR", "local-operator"),
      policy_revision: System.get_env("YELLOW_DOG_MANAGEMENT_POLICY_REVISION", "1"),
      allowed_scopes: configured_scopes(),
      allowed_hosts: nil
    }

    Map.merge(defaults, Application.get_env(:yellow_dog_management, :integration, %{}))
  end

  def public do
    Map.take(get(), [
      :mode,
      :http_enabled,
      :mcp_enabled,
      :write_enabled,
      :resource,
      :issuer,
      :policy_revision,
      :allowed_scopes
    ])
  end

  def validate! do
    config = get()
    uri = URI.parse(config.resource)

    unless uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.port in 1..65535 and
             Regex.match?(
               ~r/\Ahttps?:\/\/(?:[a-zA-Z0-9.-]+|\[[a-fA-F0-9:]+\])(?::[0-9]+)?\z/,
               config.resource
             ) and
             uri.path in [nil, ""] and is_nil(uri.userinfo) and is_nil(uri.query) and
             is_nil(uri.fragment),
           do: raise("Management resource must be an HTTP(S) origin")

    case config.mode do
      :trusted_local ->
        unless SettingsIP.loopback?(listener_ip()) and
                 uri.host in ["localhost", "127.0.0.1", "::1"] and
                 is_nil(System.get_env("YELLOW_DOG_MANAGEMENT_TRUSTED_PROXY_IP")) and
                 is_nil(System.get_env("YELLOW_DOG_MANAGEMENT_EXTERNAL_ORIGIN")),
               do: raise("Trusted-local Management requires a loopback listener without a proxy")

      :protected_remote ->
        for key <- [
              :issuer,
              :access_jwks_file,
              :gateway_issuer,
              :gateway_audience,
              :gateway_jwks_file
            ] do
          unless is_binary(config[key]) and byte_size(config[key]) > 0,
            do: raise("Protected Management requires #{key}")
        end

        for issuer <- [config.issuer, config.gateway_issuer] do
          parsed = URI.parse(issuer)

          unless is_binary(parsed.host) and byte_size(issuer) <= 1024 and
                   is_nil(parsed.userinfo) and is_nil(parsed.query) and is_nil(parsed.fragment) and
                   (parsed.scheme == "https" or
                      (parsed.scheme == "http" and
                         parsed.host in ["localhost", "127.0.0.1", "::1"])),
                 do:
                   raise("Management issuer must use HTTPS; HTTP is limited to loopback fixtures")
        end

        unless uri.scheme == "https" or uri.host in ["localhost", "127.0.0.1", "::1"],
          do: raise("Protected Management requires an HTTPS resource origin")

        unless byte_size(System.get_env("YELLOW_DOG_MANAGEMENT_SECRET_KEY_BASE", "")) >= 64,
          do: raise("Protected Management requires stable secret key base (64 bytes minimum)")

      :disabled ->
        :ok

      _ ->
        raise("Invalid Management authentication mode")
    end

    :ok
  end

  defp listener_ip do
    {:ok, ip} =
      :inet.parse_address(
        String.to_charlist(System.get_env("YELLOW_DOG_MANAGEMENT_BIND_ADDRESS", "127.0.0.1"))
      )

    ip
  end

  defp resource do
    System.get_env("YELLOW_DOG_MANAGEMENT_RESOURCE") ||
      System.get_env("YELLOW_DOG_MANAGEMENT_EXTERNAL_ORIGIN") ||
      "http://127.0.0.1:#{System.get_env("YELLOW_DOG_MANAGEMENT_PORT", "4270")}"
  end

  defp configured_scopes do
    case System.get_env("YELLOW_DOG_MANAGEMENT_ALLOWED_SCOPES") do
      nil -> @scopes
      scopes -> String.split(scopes, " ", trim: true) |> Enum.filter(&(&1 in @scopes))
    end
  end

  defp enabled?(name), do: System.get_env(name) == "1"
  defp mode("disabled"), do: :disabled
  defp mode("trusted_local"), do: :trusted_local
  defp mode("protected_remote"), do: :protected_remote
  defp mode(_), do: :invalid
end

defmodule YellowDog.Management.SettingsIP do
  @moduledoc false
  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?(_), do: false
end
