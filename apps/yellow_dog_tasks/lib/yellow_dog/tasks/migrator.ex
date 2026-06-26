defmodule YellowDog.Tasks.Migrator do
  @moduledoc """
  Runs YellowDog task storage migrations before Oban starts.
  """

  alias YellowDog.Tasks.Repo

  @doc false
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :temporary
    }
  end

  @doc false
  def start_link do
    :ok = migrate()
    :ignore
  end

  @doc """
  Runs pending repository migrations for the task database.
  """
  @spec migrate() :: :ok
  def migrate do
    ensure_database_dir!()

    Repo
    |> Ecto.Migrator.run(migrations_path(), :up, all: true)

    :ok
  end

  defp ensure_database_dir! do
    Repo.config()
    |> Keyword.fetch!(:database)
    |> Path.dirname()
    |> File.mkdir_p!()
  end

  defp migrations_path do
    Application.app_dir(:yellow_dog_tasks, "priv/repo/migrations")
  end
end
