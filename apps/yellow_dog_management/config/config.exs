import Config

config :yellow_dog_management, ecto_repos: [YellowDog.Management.Repo]

if config_env() == :test do
  config :yellow_dog_management, :http_enabled, false
  config :yellow_dog_management, YellowDog.Management.Repo, pool: Ecto.Adapters.SQL.Sandbox
  config :logger, level: :warning
end
