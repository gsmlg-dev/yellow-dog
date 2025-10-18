defmodule YellowDogCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Configuration manager
      {YellowDogCore.Config, %{}}
    ]

    opts = [strategy: :one_for_one, name: YellowDogCore.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
