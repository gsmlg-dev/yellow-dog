import Config

import_config "../apps/yellow_dog_management/config/config.exs"
import_config "../apps/yellow_dog_worker/config/config.exs"

config :logger, level: if(config_env() == :test, do: :warning, else: :info)
