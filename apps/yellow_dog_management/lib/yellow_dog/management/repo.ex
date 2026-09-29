defmodule YellowDog.Management.Repo do
  use Ecto.Repo,
    otp_app: :yellow_dog_management,
    adapter: Ecto.Adapters.Postgres
end
