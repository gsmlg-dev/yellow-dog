defmodule YellowDog.Tasks.Application do
  @moduledoc false

  use Application

  alias YellowDog.Tasks.Config
  alias YellowDog.Tasks.Migrator
  alias YellowDog.Tasks.Repo

  @impl true
  def start(_type, _args) do
    config = Config.load()

    configure_repo(config)
    configure_oban(config)

    children = [
      Repo,
      {Migrator, []},
      {Oban, Application.fetch_env!(:yellow_dog_tasks, Oban)}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: YellowDog.Tasks.Supervisor)
  end

  defp configure_repo(config) do
    repo_config =
      :yellow_dog_tasks
      |> Application.get_env(Repo, [])
      |> Keyword.put_new(:database, Config.database_path(config))
      |> Keyword.put_new(:pool_size, 5)

    Application.put_env(:yellow_dog_tasks, Repo, repo_config)
  end

  defp configure_oban(config) do
    oban_config =
      config
      |> Config.oban_config()
      |> Keyword.merge(Application.get_env(:yellow_dog_tasks, Oban, []))

    Application.put_env(:yellow_dog_tasks, Oban, oban_config)
  end
end
