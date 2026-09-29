import Config

# Machine-local bootstrap only. No Management or database settings are consumed.
config :yellow_dog_worker, bootstrap: System.get_env("YELLOW_DOG_WORKER_BOOTSTRAP")
