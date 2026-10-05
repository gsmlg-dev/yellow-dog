import Config

config :yellow_dog_worker, bootstrap: System.get_env("YELLOW_DOG_WORKER_BOOTSTRAP")
