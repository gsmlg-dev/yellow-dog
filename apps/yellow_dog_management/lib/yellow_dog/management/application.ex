defmodule YellowDog.Management.Application do
  use Application
  alias YellowDog.Management.{Repo, Settings}

  @impl true
  def start(_type, _args) do
    children = [{Repo, Settings.repo()}]

    children =
      if Application.get_env(:yellow_dog_management, :http_enabled, true),
        do: children ++ [{Bandit, Settings.listener()}],
        else: children

    Supervisor.start_link(children, strategy: :one_for_one, name: YellowDog.Management.Supervisor)
  end
end
