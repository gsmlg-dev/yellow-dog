import Config

config :yellow_dog_worker, boot: config_env() != :test
