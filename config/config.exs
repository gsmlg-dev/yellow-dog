import Config

import_config "../apps/yellow_dog_management/config/config.exs"
import_config "../apps/yellow_dog_worker/config/config.exs"

if config_env() in [:dev, :test] do
  config :abyss, Abyss.DhcpSocket.Native, skip_compilation?: true
end

config :logger, level: if(config_env() == :test, do: :warning, else: :info)
