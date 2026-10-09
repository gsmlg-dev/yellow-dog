import Config

# Machine-local bootstrap chooses local TOML or authenticated Management polling.
config :yellow_dog_worker, bootstrap: System.get_env("YELLOW_DOG_WORKER_BOOTSTRAP")
