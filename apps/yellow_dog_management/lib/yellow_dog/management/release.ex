defmodule YellowDog.Management.Release do
  @moduledoc "Explicit schema migrations; never imports legacy business data."
  alias YellowDog.Management.{Repo, Settings}

  def migrate do
    Application.load(:yellow_dog_management)
    Application.put_env(:yellow_dog_management, Repo, Settings.repo())

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        Ecto.Migrator.run(repo, :up, all: true)
      end)

    :ok
  end
end
