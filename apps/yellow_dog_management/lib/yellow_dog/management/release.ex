defmodule YellowDog.Management.Release do
  @moduledoc "Explicit database setup and migrations without starting Management services."
  alias YellowDog.Management.{Repo, Settings}

  def setup do
    load_app()

    case Repo.__adapter__().storage_up(Repo.config()) do
      :ok -> IO.puts("database=created")
      {:error, :already_up} -> IO.puts("database=already_exists")
      {:error, reason} -> raise "could not create Management database: #{inspect(reason)}"
    end

    migrate()
  end

  def migrate do
    load_app()

    {:ok, versions, _} =
      Ecto.Migrator.with_repo(Repo, fn repo ->
        Ecto.Migrator.run(repo, :up, all: true)
      end)

    IO.puts("applied_migrations=#{length(versions)}")
    :ok
  end

  defp load_app do
    {:ok, _} = Application.ensure_all_started(:ssl)
    Application.load(:yellow_dog_management)
    Application.put_env(:yellow_dog_management, Repo, Settings.repo())
  end
end
