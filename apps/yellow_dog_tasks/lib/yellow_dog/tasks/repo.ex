defmodule YellowDog.Tasks.Repo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :yellow_dog_tasks,
    adapter: Ecto.Adapters.SQLite3
end
