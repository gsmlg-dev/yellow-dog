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

  ## Security Notes

  - Always use HTTPS in production when using Basic Auth
  - Use strong, unique passwords
  - Consider rate limiting failed authentication attempts
  """

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

    cond do
      is_nil(password) or password == "" ->
        Logger.warning(
          "Basic auth is enabled but CONSOLE_PASSWORD is not set. " <>
            "Authentication is disabled until password is configured."
        )

        conn

      true ->
        case get_auth_header(conn) do
          nil ->
            unauthorized(conn, realm)

          credentials ->
            verify_credentials(conn, credentials, username, password, realm)
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
  defp verify_credentials(conn, credentials, username, password, realm) do
    case String.split(credentials, ":", parts: 2) do
      [provided_user, provided_pass] ->
        if secure_compare(provided_user, username) and secure_compare(provided_pass, password) do
          conn
        else
          Logger.debug("Failed authentication attempt for user: #{provided_user}")
          unauthorized(conn, realm)
        end

      _ ->
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

  # Constant-time string comparison to prevent timing attacks
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false
end
