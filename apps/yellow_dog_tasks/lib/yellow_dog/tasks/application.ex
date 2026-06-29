defmodule YellowDog.Tasks.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: YellowDog.Tasks.TaskSupervisor},
      YellowDog.Tasks.Runner
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: YellowDog.Tasks.Supervisor)
  end
end
