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

repo_root = Path.expand("..", __DIR__)

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

config :duskmoon_bundler,
  resolve_dirs: [Path.join(repo_root, "node_modules"), Path.join(repo_root, "deps")],
  target: :es2020,
  sourcemap: :hidden

console_app = Path.join(repo_root, "apps/yellow_dog_console")
console_assets = Path.join(console_app, "assets")

config :duskmoon_bundler, :yellow_dog_console,
  root: console_assets,
  entry: Path.join(console_assets, "js/app.js"),
  outdir: Path.join(console_app, "priv/static/assets"),
  asset_url_prefix: "/assets",
  tailwind: [
    css: Path.join(console_assets, "css/app.css"),
    sources: [
      %{base: Path.join(console_app, "lib"), pattern: "**/*.{ex,heex}"},
      %{
        base: Path.expand("../deps/phoenix_duskmoon/lib/phoenix_duskmoon", __DIR__),
        pattern: "**/*.{ex,heex}"
      },
      %{base: console_assets, pattern: "**/*.{js,css}"}
    ]
  ],
  server: [
    prefix: "/assets",
    watch_dirs: [Path.join(console_app, "lib"), console_assets]
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
