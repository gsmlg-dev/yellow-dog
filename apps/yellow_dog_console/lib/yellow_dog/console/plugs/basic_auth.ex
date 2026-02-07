defmodule YellowDog.Console.Plugs.BasicAuth do
  @moduledoc """
  Basic HTTP Authentication plug for the YellowDog Console.

  This plug provides configurable basic authentication that can be enabled/disabled
  via configuration. In production, credentials should be set via environment variables.

  ## Configuration

  Configure in your endpoint or router:

      # In config/prod.exs or config/runtime.exs
      config :yellow_dog_console, YellowDog.Console.Plugs.BasicAuth,
        enabled: true,
        username: System.get_env("CONSOLE_USERNAME"),
        password: System.get_env("CONSOLE_PASSWORD"),
        realm: "YellowDog Console"

      # In config/dev.exs or config/test.exs (disabled by default)
      config :yellow_dog_console, YellowDog.Console.Plugs.BasicAuth,
        enabled: false

  ## Environment Variables (Production)

  - `CONSOLE_USERNAME` - The username for basic auth (default: "admin")
  - `CONSOLE_PASSWORD` - The password for basic auth (required in production)
  - `CONSOLE_AUTH_ENABLED` - Set to "false" to disable (default: "true" in production)

  ## Security Features

  - Always use HTTPS in production when using Basic Auth
  - Use strong, unique passwords
  - Rate limiting on failed authentication attempts via `AuthRateLimiter`
  - IP addresses are locked out after 5 failed attempts (configurable)
  """

  alias YellowDog.Console.Plugs.AuthRateLimiter

  import Plug.Conn
  require Logger

  @behaviour Plug

  @default_realm "YellowDog Console"
  @default_username "admin"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    config = get_config()

    if auth_enabled?(config) do
      authenticate(conn, config)
    else
      conn
    end
  end

  # Get configuration from application environment
  defp get_config do
    Application.get_env(:yellow_dog_console, __MODULE__, [])
  end

  # Check if authentication is enabled
  defp auth_enabled?(config) do
    case Keyword.get(config, :enabled) do
      nil ->
        # Default: enabled in production, disabled otherwise
        Application.get_env(:yellow_dog_console, :env, :dev) == :prod

      enabled ->
        enabled
    end
  end

  # Perform the actual authentication
  defp authenticate(conn, config) do
    username = Keyword.get(config, :username, @default_username)
    password = Keyword.get(config, :password)
    realm = Keyword.get(config, :realm, @default_realm)
    client_ip = get_client_ip(conn)

    cond do
      is_nil(password) or password == "" ->
        Logger.warning(
          "Basic auth is enabled but CONSOLE_PASSWORD is not set. " <>
            "Authentication is disabled until password is configured."
        )

        conn

      true ->
        # Check rate limiting before processing credentials
        case AuthRateLimiter.check_rate_limit(client_ip) do
          {:error, :locked_out, seconds_remaining} ->
            Logger.warning("[BasicAuth] IP locked out due to failed attempts",
              ip: client_ip,
              lockout_seconds: seconds_remaining
            )

            too_many_requests(conn, seconds_remaining)

          {:ok, _attempts_remaining} ->
            case get_auth_header(conn) do
              nil ->
                unauthorized(conn, realm)

              credentials ->
                verify_credentials(conn, credentials, username, password, realm, client_ip)
            end
        end
    end
  end

  # Extract the Authorization header
  defp get_auth_header(conn) do
    case get_req_header(conn, "authorization") do
      ["Basic " <> encoded | _] ->
        case Base.decode64(encoded) do
          {:ok, decoded} -> decoded
          :error -> nil
        end

      _ ->
        nil
    end
  end

  # Verify the provided credentials
  defp verify_credentials(conn, credentials, username, password, realm, client_ip) do
    case String.split(credentials, ":", parts: 2) do
      [provided_user, provided_pass] ->
        if secure_compare(provided_user, username) and secure_compare(provided_pass, password) do
          # Successful authentication - reset rate limiter
          AuthRateLimiter.record_success(client_ip)
          conn
        else
          # Failed authentication - record for rate limiting
          AuthRateLimiter.record_failure(client_ip)

          Logger.debug("Failed authentication attempt",
            user: provided_user,
            ip: client_ip
          )

          unauthorized(conn, realm)
        end

      _ ->
        # Malformed credentials - count as failure
        AuthRateLimiter.record_failure(client_ip)
        unauthorized(conn, realm)
    end
  end

  # Send 401 Unauthorized response
  defp unauthorized(conn, realm) do
    conn
    |> put_resp_header("www-authenticate", ~s(Basic realm="#{realm}"))
    |> send_resp(401, "Unauthorized")
    |> halt()
  end

  # Send 429 Too Many Requests response for rate limiting
  defp too_many_requests(conn, seconds_remaining) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds_remaining))
    |> send_resp(429, "Too Many Requests. Try again in #{seconds_remaining} seconds.")
    |> halt()
  end

  # Extract client IP from connection
  defp get_client_ip(conn) do
    # Check X-Forwarded-For header first (for proxy setups)
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded
        |> String.split(",")
        |> List.first()
        |> String.trim()

      [] ->
        # Fall back to direct connection IP
        conn.remote_ip
        |> :inet.ntoa()
        |> to_string()
    end
  end

  # Constant-time string comparison to prevent timing attacks
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false
end
