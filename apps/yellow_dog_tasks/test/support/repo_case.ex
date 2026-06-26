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
end
