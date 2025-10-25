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

config :yellow_dog_console,
  ecto_repos: [YellowDogConsole.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configures the endpoint
config :yellow_dog_console, YellowDogConsoleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: YellowDogConsoleWeb.ErrorHTML, json: YellowDogConsoleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: YellowDogConsole.PubSub,
  live_view: [signing_salt: "dzie3W/v"]


# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  yellow_dog_console: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/yellow_dog_console/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  yellow_dog_console: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/yellow_dog_console", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
