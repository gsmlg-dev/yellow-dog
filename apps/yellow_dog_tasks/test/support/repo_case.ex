defmodule YellowDog.Tasks.RepoCase do
  @moduledoc """
  Shared test case for repository-backed task tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias YellowDog.Tasks.Repo

      import Ecto.Query
    end
  end

  setup_all do
    case GenServer.whereis(YellowDog.Tasks.Repo) do
      nil -> start_supervised!(YellowDog.Tasks.Repo)
      _pid -> :ok
    end

    :ok = YellowDog.Tasks.Migrator.migrate()
    :ok
  end

  setup do
    YellowDog.Tasks.Repo.delete_all(Oban.Job)
    :ok
  end
end
