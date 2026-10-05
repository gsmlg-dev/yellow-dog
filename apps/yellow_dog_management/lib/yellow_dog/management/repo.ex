defmodule YellowDog.Management.Repo do
  use Ecto.Repo,
    otp_app: :yellow_dog_management,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_type, config) do
    {:ok, Keyword.merge(config, YellowDog.Management.Settings.repo())}
  end
end
