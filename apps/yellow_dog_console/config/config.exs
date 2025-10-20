import Config

# Configure Phoenix endpoint
config :yellow_dog_console, YellowDogConsoleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: YellowDogConsoleWeb.ErrorHTML, json: YellowDogConsoleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: [Phoenix.PubSub.PG2],
  live_view: [signing_salt: "yellow_dog_console_secret"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure esbuild
config :esbuild, :version, "0.25.0"

# Configure tailwind
config :tailwind, :version, "4.1.12"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"