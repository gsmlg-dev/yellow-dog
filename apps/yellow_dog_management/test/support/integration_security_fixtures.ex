defmodule YellowDog.Management.IntegrationSecurityFixtures do
  @moduledoc false
  alias YellowDog.Management.IntegrationSettings

  def keys do
    access = JOSE.JWK.generate_key({:rsa, 2048})
    gateway = JOSE.JWK.generate_key({:rsa, 2048})
    %{access: access, gateway: gateway}
  end

  def configure(keys) do
    directory = Path.join(System.tmp_dir!(), "yd-auth-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)

    for {kind, key} <- keys do
      {_, public} = JOSE.JWK.to_public_map(key)

      File.write!(
        Path.join(directory, "#{kind}.json"),
        Jason.encode!(%{"keys" => [Map.put(public, "kid", to_string(kind))]})
      )
    end

    config =
      Map.merge(IntegrationSettings.get(), %{
        mode: :protected_remote,
        http_enabled: true,
        mcp_enabled: true,
        write_enabled: true,
        resource: "https://www.example.com",
        issuer: "https://issuer.example.test",
        access_jwks_file: Path.join(directory, "access.json"),
        gateway_issuer: "https://gateway.example.test",
        gateway_audience: "yellow-dog-ui",
        gateway_jwks_file: Path.join(directory, "gateway.json"),
        policy_revision: "security-1",
        allowed_scopes: IntegrationSettings.scopes(),
        allowed_hosts: ["www.example.com"]
      })

    {config, directory}
  end

  def token(keys, opts \\ []) do
    profile = Keyword.get(opts, :profile, :access)
    config = IntegrationSettings.get()
    now = System.system_time(:second)

    claims = %{
      "iss" => if(profile == :access, do: config.issuer, else: config.gateway_issuer),
      "aud" => if(profile == :access, do: config.resource, else: config.gateway_audience),
      "sub" => "alice",
      "client_id" => "integration-client",
      "iat" => now,
      "exp" => now + if(profile == :access, do: 600, else: 120),
      "scope" => Enum.join(IntegrationSettings.scopes(), " ")
    }

    claims =
      Map.merge(claims, Keyword.get(opts, :claims, %{}))
      |> Map.drop(Keyword.get(opts, :delete, []))

    header =
      Map.merge(
        %{
          "alg" => "RS256",
          "typ" => if(profile == :access, do: "at+jwt", else: "yd-gateway+jwt"),
          "kid" => to_string(profile)
        },
        Keyword.get(opts, :header, %{})
      )

    {_, compact} = JOSE.JWT.sign(keys[profile], header, claims) |> JOSE.JWS.compact()
    compact
  end
end
