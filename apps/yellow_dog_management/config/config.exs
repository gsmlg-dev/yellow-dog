import Config

config :yellow_dog_management, ecto_repos: [YellowDog.Management.Repo]

config :phoenix, :json_library, Jason

config :yellow_dog_management, YellowDog.ManagementUI.Endpoint,
  adapter: Gaoxy.PhoenixAdapter,
  websocket_paths: ["/live/websocket"],
  url: [host: "localhost"],
  check_origin: :conn,
  pubsub_server: YellowDog.ManagementUI.PubSub,
  live_view: [signing_salt: "management-live-view"]

config :yellow_dog_management, YellowDog.ManagementUI.Gettext, default_locale: "en"

config :yellow_dog_management, Styx,
  repo: YellowDog.Management.Repo,
  prefix: "management_jobs",
  queues: [management_sync: 1, management_backups: 1],
  plugins: [{Styx.Lifeline, rescue_after: 240_000}]

if config_env() == :test do
  config :yellow_dog_management, :integration, %{
    mode: :trusted_local,
    http_enabled: true,
    mcp_enabled: true,
    write_enabled: true,
    allowed_hosts: ["www.example.com", "localhost", "127.0.0.1", "::1"],
    policy_revision: "test-1"
  }

  config :yellow_dog_management, :task_scheduler_enabled, false
  config :yellow_dog_management, :restore_geoip_selection, false
  config :yellow_dog_management, Styx, testing: :manual, queues: false, plugins: false
  config :yellow_dog_management, :http_enabled, false
  config :yellow_dog_management, YellowDog.Management.Repo, pool: Ecto.Adapters.SQL.Sandbox
  config :logger, level: :warning
end
