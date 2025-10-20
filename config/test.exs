import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :yellow_dog_console, YellowDogConsoleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "uUZt2Ta9p5DqwqmSNhQH5/S21duMx2BXfCxxwEXhzYdLAlGA/sXXpExoD62eacr6",
  server: false

# In test we don't send emails
config :yellow_dog_console, YellowDogConsole.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :yellow_dog_console, YellowDogConsole.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "yellow_dog_console_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :yellow_dog_console, YellowDogConsoleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "BYWNrViPgoGfdU3ElxUAg5oZ1zzAu2RRVsZ5wjx+zMlmz4I0UioOFdKM3CsH1vtW",
  server: false

# In test we don't send emails
config :yellow_dog_console, YellowDogConsole.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :logger, :console, level: :debug
