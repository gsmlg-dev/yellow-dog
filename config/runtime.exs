import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/yellow_dog_console start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :yellow_dog_console, YellowDog.Console.Endpoint, server: true
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4270")

  config :yellow_dog_console, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :yellow_dog_console, YellowDog.Console.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # Configure basic authentication for the web console
  # CONSOLE_AUTH_ENABLED defaults to true in production
  # Set CONSOLE_PASSWORD to enable authentication (required for auth to work)
  auth_enabled = System.get_env("CONSOLE_AUTH_ENABLED", "true") != "false"

  config :yellow_dog_console, YellowDog.Console.Plugs.BasicAuth,
    enabled: auth_enabled,
    username: System.get_env("CONSOLE_USERNAME", "admin"),
    password: System.get_env("CONSOLE_PASSWORD"),
    realm: System.get_env("CONSOLE_REALM", "YellowDog Console")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :yellow_dog_console, YellowDog.Console.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :yellow_dog_console, YellowDog.Console.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

# Handle LOG_LEVEL environment variable
if config_env() == :prod do
  case System.fetch_env("LOG_LEVEL") do
    {:ok, level}
    when level in ~w(emergency alert critical error warning warn notice info debug) ->
      config :logger, :console, level: String.to_existing_atom(level)

    {:ok, invalid} ->
      IO.warn(
        "Invalid LOG_LEVEL=#{inspect(invalid)}, ignoring (valid: emergency|alert|critical|error|warning|info|debug)"
      )

    _ ->
      nil
  end
end

# Helper function to parse CLI argument value
get_cli_arg = fn arg_name ->
  args = System.argv()

  case Enum.find_index(args, &(&1 == arg_name)) do
    nil ->
      nil

    index ->
      value = Enum.at(args, index + 1)
      if value && not String.starts_with?(value, "-"), do: value
  end
end

# Default configuration fallback
default_config_path =
  Path.expand("../apps/yellow_dog/priv/yellowdogdns_default_config.toml", __DIR__)

# Determine which config file to use (CLI > ENV > default)
# Priority: --config CLI arg > YELLOW_DOG_CONFIG env > default
config_path =
  get_cli_arg.("--config") ||
    System.get_env("YELLOW_DOG_CONFIG") ||
    default_config_path

config_to_load =
  if File.exists?(config_path) do
    config_path
  else
    default_config_path
  end

# Store config file path in application config (the actual TOML reading will be done in the application)
config :yellow_dog, :config_file_path, config_to_load

# Determine data directory (CLI > ENV > default)
# Priority: --data-dir CLI arg > YELLOW_DOG_DATA_DIR env > default from config
data_dir =
  get_cli_arg.("--data-dir") ||
    System.get_env("YELLOW_DOG_DATA_DIR")

# Store data directory in application config (nil means use config file value or default)
config :yellow_dog, :data_dir, data_dir

# Configure Tailwind CSS binary path from environment variable
if tailwind_bin = System.get_env("TAILWINDCSS_BIN") do
  config :tailwind, path: tailwind_bin
end

# Configure Bun binary path from environment variable
if bun_bin = System.get_env("BUN_BIN") do
  config :bun, path: bun_bin
end
