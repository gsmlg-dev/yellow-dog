defmodule YellowDog.Management.Auth do
  @moduledoc "External JWT resource-server authentication and explicit loopback development trust."
  import Plug.Conn
  alias YellowDog.Management.{Caller, IntegrationSettings, SettingsIP}

  @max_token 16_384
  @max_jwks 65_536

  def authenticate(conn, source) when source in [:ui, :http, :mcp] do
    config = IntegrationSettings.get()

    result =
      with :ok <- enabled(config, source), :ok <- guard_request(conn, config) do
        case config.mode do
          :trusted_local -> local(conn, source, config)
          :protected_remote -> protected(conn, source, config)
          _ -> failure("adapters_disabled", "Management trust mode is not configured")
        end
      end

    case result do
      {:error, error} -> YellowDog.Management.Limits.denied(source, error.code)
      _ -> :ok
    end

    result
  end

  def challenge(conn, error) do
    if error[:code] in ["authentication_required", "invalid_token", "forbidden"] do
      metadata = IntegrationSettings.get().resource <> "/.well-known/oauth-protected-resource"
      error_code = if error[:code] == "forbidden", do: "insufficient_scope", else: "invalid_token"

      put_resp_header(
        conn,
        "www-authenticate",
        ~s(Bearer resource_metadata="#{metadata}", error="#{error_code}")
      )
    else
      conn
    end
  end

  def metadata do
    config = IntegrationSettings.get()

    %{
      "resource" => config.resource,
      "authorization_servers" => [config.issuer],
      "scopes_supported" => IntegrationSettings.scopes() -- ["ui:admin"],
      "bearer_methods_supported" => ["header"],
      "resource_name" => "Yellow Dog Management"
    }
  end

  def socket(headers, peer, uri, session) do
    with %URI{} <- uri,
         %{address: address} <- peer,
         {:ok, saved} <- Caller.from_session(session["management_caller"]) do
      conn = %Plug.Conn{
        host: uri.host,
        port: uri.port,
        scheme: uri.scheme |> to_string() |> scheme(),
        remote_ip: address,
        req_headers: headers || []
      }

      with {:ok, current} <- authenticate(conn, :ui),
           true <- Caller.same_identity?(saved, current),
           :ok <- YellowDog.Management.Access.authorize(saved, "config:read") do
        # Neither the signed session nor a fresh gateway assertion can extend the
        # other's lifetime. Both must identify the same principal and client.
        {:ok,
         %{
           current
           | expires_at: min(saved.expires_at, current.expires_at),
             scopes: Enum.filter(current.scopes, &(&1 in saved.scopes))
         }}
      else
        _ -> failure("invalid_token", "UI connection identity or authorization changed")
      end
    else
      _ -> failure("authentication_required", "Verified UI connection required")
    end
  end

  def verify_access(token, source), do: verify(token, source, :access, IntegrationSettings.get())
  def verify_gateway(token), do: verify(token, :ui, :gateway, IntegrationSettings.get())

  defp protected(conn, :ui, config) do
    case get_req_header(conn, "x-yellow-dog-gateway-assertion") do
      [token] -> verify(token, :ui, :gateway, config)
      _ -> failure("authentication_required", "Verified gateway assertion required")
    end
  end

  defp protected(conn, source, config) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> verify(token, source, :access, config)
      _ -> failure("authentication_required", "Management access token required")
    end
  end

  defp local(conn, source, config) do
    if SettingsIP.loopback?(conn.remote_ip) and not forwarding?(conn.req_headers) do
      {:ok,
       %Caller{
         issuer: "urn:yellow-dog:trusted-local",
         subject: config.operator,
         client_id: nil,
         scopes: config.allowed_scopes,
         source: source,
         correlation_id: Ecto.UUID.generate(),
         expires_at: System.system_time(:second) + 3600,
         policy_revision: config.policy_revision,
         authentication: :trusted_local
       }}
    else
      failure("forbidden", "Trusted-local Management accepts direct loopback callers only")
    end
  end

  defp verify(token, source, profile, config)
       when is_binary(token) and byte_size(token) in 1..@max_token do
    {issuer, audience, file, typ, max_lifetime} =
      case profile do
        :access ->
          {config.issuer, config.resource, config.access_jwks_file, "at+jwt", 3600}

        :gateway ->
          {config.gateway_issuer, config.gateway_audience, config.gateway_jwks_file,
           "yd-gateway+jwt", 300}
      end

    with [protected, _payload, _signature] <- String.split(token, "."),
         {:ok, bytes} <- Base.url_decode64(protected, padding: false),
         {:ok, header} <- Jason.decode(bytes),
         %{"alg" => "RS256", "typ" => ^typ, "kid" => kid} <- header,
         true <- is_binary(kid) and byte_size(kid) in 1..128,
         true <- Map.keys(header) -- ~w(alg typ kid) == [],
         {:ok, jwk} <- key(file, kid),
         {true, %JOSE.JWT{fields: claims}, _} <- JOSE.JWT.verify_strict(jwk, ["RS256"], token),
         :ok <- claims(claims, issuer, audience, max_lifetime),
         {:ok, scopes} <- scopes(claims["scope"], config.allowed_scopes) do
      {:ok,
       %Caller{
         issuer: claims["iss"],
         subject: claims["sub"],
         client_id: claims["client_id"],
         scopes: scopes,
         source: source,
         correlation_id: Ecto.UUID.generate(),
         expires_at: claims["exp"],
         policy_revision: config.policy_revision,
         authentication: if(profile == :access, do: :access_token, else: :gateway)
       }}
    else
      _ -> failure("invalid_token", "Management credential could not be verified")
    end
  rescue
    _ in [ArgumentError, ErlangError, MatchError, FunctionClauseError, KeyError] ->
      failure("invalid_token", "Management credential could not be verified")
  end

  defp verify(_, _, _, _), do: failure("invalid_token", "Management credential exceeds limits")

  # Deployment distributes the external issuer's PUBLIC JWKS to this trusted
  # path atomically. Each verification rereads it: no stale-key fallback, cache,
  # request URL, token jku/x5u, network lookup or outbound bearer forwarding.
  defp key(file, kid) when is_binary(file) do
    with {:ok, %{type: :regular, size: size}} <- File.stat(file),
         true <- size in 1..@max_jwks,
         {:ok, data} <- File.open(file, [:read, :binary], &IO.binread(&1, @max_jwks + 1)),
         true <- is_binary(data) and byte_size(data) <= @max_jwks,
         {:ok, %{"keys" => keys}} <- Jason.decode(data),
         true <- is_list(keys) and length(keys) in 1..16,
         [public] <- Enum.filter(keys, &(is_map(&1) and &1["kid"] == kid)),
         %{"kty" => "RSA", "n" => modulus, "e" => exponent} <- public,
         true <- is_binary(modulus) and is_binary(exponent),
         true <- public["use"] in [nil, "sig"] and public["alg"] in [nil, "RS256"],
         true <- public["key_ops"] in [nil, ["verify"]],
         true <- Map.keys(public) -- ~w(kty n e kid use alg key_ops) == [],
         {:ok, decoded} <- Base.url_decode64(modulus, padding: false),
         true <- byte_size(decoded) in 256..1024 do
      {:ok, JOSE.JWK.from_map(public)}
    else
      _ -> :error
    end
  end

  defp key(_, _), do: :error

  defp claims(claims, issuer, audience, max_lifetime) do
    now = System.system_time(:second)

    valid =
      is_map(claims) and is_binary(issuer) and is_binary(audience) and
        claims["iss"] == issuer and audience?(claims["aud"], audience) and
        bounded?(claims["sub"], 256) and bounded?(claims["client_id"], 128) and
        is_integer(claims["exp"]) and is_integer(claims["iat"]) and
        claims["exp"] > now and claims["iat"] <= now + 5 and
        (claims["exp"] - claims["iat"]) in 1..max_lifetime and
        (is_nil(claims["nbf"]) or (is_integer(claims["nbf"]) and claims["nbf"] <= now)) and
        byte_size(Jason.encode!(claims)) <= 8192

    if valid, do: :ok, else: :error
  end

  defp scopes(value, allowed) when is_binary(value) and byte_size(value) <= 1024 do
    scopes = String.split(value, " ", trim: true) |> Enum.uniq()

    if Enum.all?(scopes, &bounded?(&1, 64)),
      do: {:ok, Enum.filter(scopes, &(&1 in allowed))},
      else: :error
  end

  defp scopes(_, _), do: :error
  defp audience?(aud, wanted) when is_binary(aud), do: aud == wanted

  defp audience?(aud, wanted) when is_list(aud),
    do: length(aud) <= 8 and Enum.all?(aud, &is_binary/1) and wanted in aud

  defp audience?(_, _), do: false
  defp bounded?(value, limit), do: is_binary(value) and byte_size(value) in 1..limit

  def guard_request(conn, config \\ IntegrationSettings.get()) do
    expected = URI.parse(config.resource)

    allowed_hosts =
      config.allowed_hosts ||
        if(config.mode == :trusted_local,
          do: ["localhost", "127.0.0.1", "::1"],
          else: [expected.host]
        )

    origin_ok =
      case get_req_header(conn, "origin") do
        [] ->
          true

        [origin] ->
          origin == config.resource or
            (config.mode == :trusted_local and
               origin == "#{conn.scheme}://#{format_host(conn.host)}:#{conn.port}")

        _ ->
          false
      end

    if conn.host in allowed_hosts and origin_ok and
         (config.mode != :trusted_local or not forwarding?(conn.req_headers)),
       do: :ok,
       else: failure("forbidden", "Management Host or Origin rejected")
  end

  defp forwarding?(headers),
    do:
      Enum.any?(headers, fn {name, _} ->
        String.downcase(name) in [
          "forwarded",
          "x-forwarded-for",
          "x-forwarded-host",
          "x-forwarded-proto",
          "x-real-ip"
        ]
      end)

  defp format_host("::1"), do: "[::1]"
  defp format_host(host), do: host
  defp scheme("https"), do: :https
  defp scheme(_), do: :http

  defp enabled(%{mode: :disabled}, _),
    do: failure("adapters_disabled", "Management trust mode is not configured")

  defp enabled(%{http_enabled: false}, :http),
    do: failure("adapters_disabled", "Management HTTP API is disabled")

  defp enabled(%{mcp_enabled: false}, :mcp),
    do: failure("adapters_disabled", "Management MCP is disabled")

  defp enabled(_, _), do: :ok
  defp failure(code, message), do: {:error, %{code: code, message: message}}
end
