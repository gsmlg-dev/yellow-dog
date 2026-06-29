# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.

import Config

config :yellow_dog_tasks, time_zone_database: Tz.TimeZoneDatabase

config :yellow_dog_console,
  ecto_repos: [YellowDog.Console.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :yellow_dog_console, YellowDog.Console.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: YellowDog.Console.ErrorHTML, json: YellowDog.Console.ErrorJSON],
    layout: false
  ],
  pubsub_server: YellowDog.Console.PubSub,
  live_view: [signing_salt: "yellow_dog_console_secret"]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  yellow_dog_console: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/yellow_dog_console", __DIR__)
  ]

# Configure bun (the version is required)
config :bun,
  version: "1.3.13",
  yellow_dog_console: [
    args: ~w(
      build assets/js/app.js
      --outdir=priv/static/assets
      --target=browser
      --sourcemap=external
    ),
    cd: Path.expand("../apps/yellow_dog_console", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Concord is still the embedded store, but libcluster discovery is opt-in.
# config/runtime.exs enables clustering only when cluster env is configured.
config :concord, clustering: false

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
