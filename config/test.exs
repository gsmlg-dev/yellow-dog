import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :yellow_dog_console, YellowDog.Console.Endpoint,
  http: [
    ip: {127, 0, 0, 1},
    port: 4002,
    thousand_island_options: [
      num_acceptors: 8,
      num_connections: 128
    ]
  ],
  secret_key_base: "uUZt2Ta9p5DqwqmSNhQH5/S21duMx2BXfCxxwEXhzYdLAlGA/sXXpExoD62eacr6",
  server: false,
  code_reloader: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :yellow_dog_console, YellowDog.Console.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "yellow_dog_console_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# WORKAROUND(upstream): gsmlg-dev/concord#8
config :concord, prometheus_enabled: false

config :yellow_dog_store, provider_persistence_backend: YellowDog.Store.Backend.Ets

config :logger, :console, level: :debug

# YellowDog Telemetry Configuration for Testing
config :yellow_dog_telemetry,
  level: :warning,
  format: :minimal,
  console_colors: false,
  show_spans: false,
  show_span_start: false,
  span_threshold_ms: 0,
  filter_apps: nil,
  exclude_apps: nil,
  app_levels: %{},
  span_thresholds: %{}

# Disable Swoosh API client during tests
config :yellow_dog_console, :swoosh_api_client, false

# Resolved: disable in test (requires privileged port 53)
config :yellow_dog_resolved, enabled: false

# YellowDog Netman: use a writable temp path for the CLI Unix socket in tests
config :yellow_dog_netman,
  socket_path: "/tmp/yellow_dog_netman_test.sock",
  netlink_backend: :mock

# Abyss DHCP socket NIF: skip Rust compilation in test (cargo may not be available).
# Tests use DhcpSocket.UdpFallback configured via :socket_impl env key.
config :abyss, Abyss.DhcpSocket.Native, skip_compilation?: true

# Use the gen_udp fallback socket in tests — the Rust NIF requires cargo + capabilities.
config :yellow_dog_dhcp_client, :socket_impl, YellowDog.DhcpClient.DhcpSocket.UdpFallback
