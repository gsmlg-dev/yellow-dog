import Config

# Configure the endpoint for testing
config :yellow_dog_console, YellowDog.Console.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_at_least_64_bytes_long_for_testing_purposes_only",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Disable Swoosh API client during tests
config :yellow_dog_console, :swoosh_api_client, false
